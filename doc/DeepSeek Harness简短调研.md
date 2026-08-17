# DeepSeek Harness简短调研

> **一句话：** Harness是模型外面那层跑Agent的程序。它每一步把System Prompt、Tool Schema和历史消息拼成一次模型请求，模型回什么它就执行什么，全过程写进一份只追加的Session Log。
>
> 源码版本：官方`master`提交`47f943859bef60e4160492346772ded9b24f765a`（`0.1.0-rc.5`）。文中数字全部来自仓库自带的快照测试。

## 一、它怎么工作：一次对话的真实事件流

下面是仓库快照`examples/acp-agent/tests/snapshots/text-turn/session.jsonl`的完整记录，用户只说了一句"Reply with exactly the word: PONG"：

```text
agent/inbox/spliced   用户消息进入收件箱
turn/start            开启第1个Turn
step/start            开启第1个Step
user/message          用户原话
user/message          运行时上下文快照（沙箱策略、审批策略等）
request/header        本次请求的System Prompt和Tool Schema全文
request/context       provider、model、context window
assistant/chunk × N   流式返回的每一片
assistant/message     组装好的完整回复（带usage）
step/end / turn/end   收尾
```

三件事从这里就能看清：

- **Turn套Step。** 一次用户输入是一个Turn，一个Step等于一次模型请求加上这次请求引发的工具执行。模型每返回一批Tool Call，就多一个Step。代码在`packages/core/agent-loop/src/agent.ts`的`turn()`和`step()`。
- **Step数量没有上限。** 循环靠"模型这次没有再发Tool Call"来结束，不靠计数器。
- **模型看到的东西全部落盘。** `request/header`里存着当次的System Prompt原文和Tool Schema数组，所以任何一次请求都能离线重建。

## 二、模型每次看到的只有三段

| 段 | 装什么 | 谁往里写 | 在DeepSeek请求里的位置 |
|---|---|---|---|
| System Prompt | 身份、persona、每个工具的使用说明 | 插件调用`systemPrompt.section()` | `messages[0]`，`role: system` |
| Tool Schema | 工具名、描述、参数JSON Schema | 插件调用`tools.register()` | Chat Completions的独立`tools`字段 |
| Messages | 用户消息、模型回复、工具结果 | Session Log投影出来 | `messages[1..]` |

三段拼起来就是模型的全部输入。**插件能改动的正是前两段，而前两段位于请求最前面。** 这句话是后面所有问题的根源。

## 三、我们关心的六个点

### 1. 工具顺序是字典序，确定，但不等于稳定

无配置时按工具名逐字符排序，同一组工具在任何机器上生成同一顺序（`packages/core/system-prompt/src/index.ts`的`orderTools`）。也可以在配置里写死`toolOrder`，用`<unlisted-tools>`占位表示"其余工具插在这里"。

排序解决的是**同一组工具顺序抖动**，解决不了**工具集合变化**。拿仓库自己的两份快照算：native模式19个工具，both模式在同一组里多了一个`run_code`，字典序上它排在`read`和`send_message`之间，也就是第12位。按DeepSeek线格式序列化后，两者的公共前缀只有10,739字符，占22,848字符的**47%**——加一个工具，超过一半的Tool Schema要重新Prefill。

### 2. Code Mode不是省Token的方案

以为Code Mode只暴露一个`run_code`所以更省，这个印象是错的。真实工具会被渲染成TypeScript SDK文本塞进System Prompt。同样三份快照：

| 模式 | 原生工具数 | Tool Schema字符 | System Prompt字符 | 合计 |
|---|---|---|---|---|
| Native | 19 | 21,456 | 3,456 | 24,912 |
| Code | 1（`run_code`） | 902 | 27,968 | **28,870** |
| Both | 20 | 22,358 | 27,809 | **50,167** |

Code Mode把内容从`tools`字段搬到了System Prompt，**总量还略微变大，而且搬到了更靠前的位置**。它真正的收益不在Header，在于一段代码可以连续调多个工具、中间结果不进模型历史、模型与Harness的往返次数变少。要比就比整个任务的总成本和成功率，不能比单次Header长度。

### 3. 模型的视图按Step冻结，执行时却查实时注册表

每个Step开始时组装一次，请求对象做深冻结（`deepFreeze`）后发出。但模型生成Tool Call之后，Harness执行前会重新去实时注册表里找这个工具：

```text
模型请求里有 web_search
→ 模型生成 web_search 调用
→ 插件在执行前被卸载
→ 实时注册表找不到
→ UNKNOWN_TOOL
```

而且并行执行时，**尚未启动的调用会重新分类一次**，源码注释写得很直白："Commit before classifying again so registry changes affect unstarted calls"。所以"模型看到的"和"真正能执行的"之间存在一个窗口。这不是bug，是它明确选择的设计，但我们要做运行时能力增删就必须处理这个窗口。

### 4. 卸载不等于遗忘

Skill目录变了怎么办？它不去改历史消息，而是追加一条**完整的新目录**，里面直接写"这份完整目录替换本会话中此前所有可用技能列表"，一个技能都不剩时就追加一份空目录加一句"不要使用早先目录里的名字"。

但已经通过`skill`工具加载过的技能正文，是作为工具结果留在历史里的，删掉技能文件也删不掉它。仓库自己的README承认了这点：技能正文没有卸载协议。

所以卸载要分三层看：

| 层次 | 含义 | 现状 |
|---|---|---|
| 执行层 | 工具、服务、进程不能再跑 | Cordis的Disposer可以做干净 |
| 发现层 | 下一Step不再列出这个能力 | 可以做到 |
| 上下文层 | 模型不再看到旧说明和旧正文 | **做不到** |

### 5. 只有Compaction会改写历史中段

Session Log本身是只追加的，但消息投影层有一个`replace`操作。Compaction压缩历史时，追加一条摘要消息并标记`surfaceOp: { op: 'replace', start, end }`，把中间那段历史从模型可见列表里换掉。这是全仓库唯一会改动历史中段的机制，也就是唯一会让缓存前缀从中间断掉的地方。

有意思的是，它连摘要请求本身都做了缓存优化：摘要指令不放在新的System Prompt里，而是**复用原请求的System Prompt和Tool Schema，把指令追加到对话最后**，让这次辅助调用成为上一次请求的真前缀。对应的修复笔记原话是"a first token that differs — a different system prompt — invalidates the entire cached prefix"。

### 6. 缓存Harness管不了，只能读

DeepSeek请求里没有任何缓存标记字段，命中与否完全由服务端按Token前缀判断。Harness能做的只有两件事：把请求前缀做稳定，以及从返回的usage里读命中数：

```text
cacheReadTokens = prompt_tokens_details.cached_tokens 或 prompt_cache_hit_tokens
inputTokens     = prompt_tokens - cacheReadTokens
```

注意`inputTokens`在这里表示**未命中**的输入，不是总输入。DeepSeek这条链路不产生`cacheWriteTokens`。

## 四、这对我们意味着什么

**第一，这套设计已经把缓存当成一等公民了。** 工具字典序、Compaction前缀复用、Skill目录追加式替换、运行时上下文追加在历史末尾而不是塞进System Prompt——这些都不是巧合，仓库的设计笔记里反复出现同一句判断：位置越靠前的改动越贵。我们要做能力检索，就不能只优化"找得准不准"，还要算"这次换能力值不值"。

**第二，动态增删能力的两个硬约束已经摆在这里了。** 一个是Header改动位置越靠前代价越大（47%那个数字），一个是语义残留清不掉（Skill正文留在历史里）。这两条决定了"每轮重新检索一批插件"这种做法在工程上很可能是亏的。

**第三，比较合理的形态是阶段化而不是每轮化。** 任务阶段开始时选一组能力装上，阶段内保持不动，让一次缓存失效被后面多轮调用摊薄，阶段结束再统一收尾。真要做强隔离，Sub-Agent是现成的：独立Session、独立历史、可以用`toolFilter`收窄工具集，结束后整体丢弃。

**第四，在做实验之前，得先向产品团队确认几件事。** 能力检索到底发生在Plugin、Skill还是Tool这一层；插件是人预装还是系统自动装；当前最痛的到底是能力选错、上下文成本、冷启动、权限还是任务完成率。这几个问题的答案不一样，要做的东西完全不一样。

完整的模块设计、源码位置和代码摘录见《DeepSeek Harness完整调研》。
