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

三段拼起来就是模型的全部输入。插件既能改前两段，也能往第三段末尾追加东西。**区别在于前两段在请求最前面，一改就动前缀；第三段追加在末尾，不动前缀。** 这个区别是后面所有问题的根源，也是它很多设计选择看起来"绕"的原因。

## 三、我们关心的六个点

### 1. 工具顺序是字典序，确定，但不等于稳定

**原本会出什么问题。** 插件是并发加载的，注册进来的先后每次都可能不一样。同一组工具，这次拼出`[read, bash, write]`，下次拼出`[bash, write, read]`，内容完全一样但字节不同，缓存从第一个工具就断了。

**它怎么做。** 不管谁先注册，一律按工具名逐字符排序，永远是`[bash, read, write]`（`packages/core/system-prompt/src/index.ts`的`orderTools`）。也可以在配置里写死`toolOrder`，用`<unlisted-tools>`占位表示"其余工具插在这里"。

**但这只解决了顺序抖动，没解决集合变化。** 上面那组再装一个`edit`，字典序把它排在第二位，变成`[bash, edit, read, write]`——`edit`后面的每一个工具位置都右移了，从这里往后的Token全部对不上。

仓库自带的两份快照正好能量出这个代价。Native是19个工具，Both在同一组里只多了一个`run_code`：

```text
Native  … job_output, list_agents, ralph, read,           send_message, skill, …
Both    … job_output, list_agents, ralph, read, run_code, send_message, skill, …
                                                 ↑ 从这里开始，后面全部对不上
```

`run_code`落在第12位（共20个）。按DeepSeek线格式序列化后，公共前缀只剩10,739字符，占22,848字符的**47%**——多装一个工具，超过一半的Tool Schema要重新Prefill。

### 2. Code Mode不是省Token的方案

**容易产生的误解。** Code Mode下`tools`字段只剩一个`run_code`，看起来把19个工具的Schema全省掉了。

**实际发生的事。** 那19个工具没有消失，它们被改写成TypeScript声明，搬进了System Prompt。同一个`bash`工具，两种模式下长这样：

```text
Native —— 待在 tools 字段里，3,345 字符
{
  "name": "bash",
  "description": "Execute a bash command (`bash -c`) and return its stdout/stderr. …",
  "parameters": {
    "properties": {
      "command":     { "type": "string", "description": "The bash command to execute." },
      "description": { "type": "string", "description": "Clear, concise description …" },
      "timeoutMs":   { "type": "number", "description": "Timeout in milliseconds. …" }
    },
    "required": ["command", "description"]
  }
}
```

```text
Code —— 搬进 System Prompt，3,072 字符
/** Execute a bash command (`bash -c`) and return its stdout/stderr. … */
bash: {
  /** The bash command to execute. */
  command: string;
  /** Clear, concise description … */
  description: string;
  /** Timeout in milliseconds. … */
  timeoutMs?: number;
}
```

说明文字一个字都没改，只是换了种写法。**字数几乎一样，但从请求靠后的`tools`字段挪到了靠前的System Prompt。**

三份快照合起来看：

| 模式 | 原生工具数 | Tool Schema字符 | System Prompt字符 | 合计 |
|---|---|---|---|---|
| Native | 19 | 21,456 | 3,456 | 24,912 |
| Code | 1（`run_code`） | 902 | 27,968 | **28,870** |
| Both | 20 | 22,358 | 27,809 | **50,167** |

**那它图什么。** 收益不在Header而在往返：一段`run_code`里可以连着调五个工具，中间四个的返回值不进模型历史，模型和Harness之间少跑四轮。所以要比就比整个任务的总Token和成功率，只比单次Header长度会得出反的结论。

### 3. 模型的视图按Step冻结，执行时却查实时注册表

**举个例子。** 第3步开始时`web_search`还在，Schema进了请求，模型生成了一个`web_search`调用。就在模型生成的这几秒里，另一条路径把web插件卸载了。Harness拿到这个调用去执行，它不看请求里那份Schema快照，而是重新去实时注册表里找——找不到，返回`UNKNOWN_TOOL`。

```text
Step开始：组装并深冻结请求（含 web_search）
模型生成：web_search 调用
执行之前：插件被卸载
执行时刻：查实时注册表 → 找不到 → UNKNOWN_TOOL
```

**并行时还要更细一点。** 模型一次发了5个调用，跑完前2个的时候插件集合变了，剩下3个会用**新的**注册表重新分类。源码注释写得很直白："Commit before classifying again so registry changes affect unstarted calls"。

**为什么这重要。** "模型以为自己有什么"和"运行时真正有什么"之间存在一个窗口。这不是bug，是它明确选的设计，但我们要做运行时能力增删就得处理这个窗口：要么阶段内锁住插件集合，要么给插件加执行租约，要么就接受失败、让模型下一步重新规划。

### 4. 卸载不等于遗忘

**举个例子。** 用户装了一个"报销流程"Skill，模型调`skill`工具把正文读进来，照着做了两步。这时管理员把这个Skill下架了。下一步模型会收到一份新目录，明说"这份完整目录替换本会话中此前所有可用技能列表"，再调这个名字也会失败。**但前面那段正文原封不动躺在对话历史里**，模型照样看得见，照样可能接着按它做。

**它为什么不直接删。** 删历史中段会让缓存前缀从那个位置断掉，所以它选择追加一份完整新目录来声明旧的作废；一个技能都不剩时就追加一份空目录，加一句"不要使用早先目录里的名字"。这是拿语义干净换缓存稳定。

所以卸载要分三层看，第三层现在没有机制：

| 层次 | 含义 | 现状 | 例子 |
|---|---|---|---|
| 执行层 | 工具、服务、进程不能再跑 | Cordis的Disposer可以做干净 | 卸载后再调就是`UNKNOWN_TOOL` |
| 发现层 | 下一Step不再列出这个能力 | 可以做到 | 下一份目录里没有这个名字了 |
| 上下文层 | 模型不再看到旧说明和旧正文 | **做不到** | 已读进来的Skill正文还在历史里 |

### 5. 只有Compaction会改写历史中段

**先说清楚一件事：日志和"模型看到的历史"是两个东西。** Session Log是完整记录，只追加，不删不改。模型请求里那个`messages`数组不是日志本身，而是日志的一个视图——Harness维护一份叫surface的序号清单，`deriveMessages()`按这份清单去日志里取事件、转成消息。日志里有四十多种事件，只有`user/message`、`assistant/message`、`tool/result`这三种有资格上清单。

**每条消息上清单时必须声明怎么上，只有两种方式：** `append`挂到末尾，或者`replace`把清单里已有的一段换成自己。日常对话全是`append`，清单只会变长，请求前缀天然稳定。

**举个例子。** 会话攒到第50条消息，上下文用掉了窗口的80%，自动压缩触发。它一条日志都不删，只是追加一条摘要消息，并打上`surfaceOp: { op: 'replace', start: 5, end: 40 }`：

```text
日志（完整保留，一条没少）
  1  2  3  4  5 … 40  41 … 50  + 新追加的摘要

surface 清单（被 replace 改写）
  1  2  3  4    摘要    41 … 50
```

第5到40条还完整躺在日志里，只是它们的序号被从surface清单上摘掉了，`deriveMessages()`按清单取事件时就不会再取到它们。

**这带来三个后果，方向各不相同。**

- **模型这边：** 之后每一轮请求都不再带这36条原文，只带那条摘要，上下文降下来了。
- **缓存这边：** `messages`从第5条的位置开始就变了，缓存前缀在那里断掉。前面那些机制都只往末尾加东西、前缀一个字节不动，**只有它动中间，全仓库就这一处**。
- **人这边：** 界面不读surface，读的是另一条路（只认`append`进来的事件），所以用户在界面上看到的对话仍然完整，不会因为压缩就少一段。源码注释点明了这个区分："The model-visible surface deliberately shadows replaced ranges, so it is the wrong source for a human transcript — a landed replacement would erase conversation the user already saw."

被摘掉的内容也不是找不回来——模型可以用`session_event_search`工具按需搜回本会话的历史事件。所以准确的说法是**默认不再占用上下文，而不是被删掉了**。

**它自己那次摘要调用反而很讲究。** 摘要指令不另起一个System Prompt，而是**复用原请求的System Prompt和Tool Schema，把"请总结"追加在对话最后**，让这次辅助调用变成上一次请求的真前缀。即使摘要根本不会调工具，也照样把原Tool Schema带上，否则Token序列从tools那个位置就对不齐了。修复笔记的原话是"a first token that differs — a different system prompt — invalidates the entire cached prefix"。

### 6. 缓存Harness管不了，只能读

**请求侧没有任何抓手。** DeepSeek的请求体字段就是`model`、`messages`、`stream`、`tools`那几个，**没有一个字段能说"这段请帮我缓存"**，也没有Anthropic那种`cache_control`标记。命中与否完全由服务端按Token前缀自己判断。Harness能做的只有两件事：把前缀做稳，以及从返回里读结果。

**读的时候有个坑。** 假设一次请求返回`prompt_tokens: 8000`、`prompt_cache_hit_tokens: 6500`，Harness换算成：

```text
cacheReadTokens = 6500
inputTokens     = 8000 - 6500 = 1500
```

这里的`inputTokens`是**没命中的那1500**，不是总输入8000。要算这次请求真实喂进去多少，得用`inputTokens + cacheReadTokens`。做实验时如果直接拿`inputTokens`当输入量，会把上下文规模和成本都低估一大截。另外DeepSeek这条链路不产生`cacheWriteTokens`，未命中的部分就留在`inputTokens`里。

## 四、这对我们意味着什么

**第一，这套设计已经把缓存当成一等公民了。** 工具字典序、Compaction前缀复用、Skill目录追加式替换、运行时上下文追加在历史末尾而不是塞进System Prompt——这些都不是巧合，仓库的设计笔记里反复出现同一句判断：位置越靠前的改动越贵。我们要做能力检索，就不能只优化"找得准不准"，还要算"这次换能力值不值"。

**第二，动态增删能力的两个硬约束已经摆在这里了。** 一个是Header改动位置越靠前代价越大（47%那个数字），一个是语义残留清不掉（Skill正文留在历史里）。这两条决定了"每轮重新检索一批插件"这种做法在工程上很可能是亏的。

**第三，比较合理的形态是阶段化而不是每轮化。** 任务阶段开始时选一组能力装上，阶段内保持不动，让一次缓存失效被后面多轮调用摊薄，阶段结束再统一收尾。真要做强隔离，Sub-Agent是现成的：独立Session、独立历史、可以用`toolFilter`收窄工具集，结束后整体丢弃。

**第四，在做实验之前，得先向产品团队确认几件事。** 能力检索到底发生在Plugin、Skill还是Tool这一层；插件是人预装还是系统自动装；当前最痛的到底是能力选错、上下文成本、冷启动、权限还是任务完成率。这几个问题的答案不一样，要做的东西完全不一样。

完整的模块设计、源码位置和代码摘录见《DeepSeek Harness完整调研》。
