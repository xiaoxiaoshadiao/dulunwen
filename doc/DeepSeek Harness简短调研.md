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
- **模型看到过什么，全都存下来了。** `request/header`里躺着这一次的System Prompt原文和Tool Schema数组，所以事后想复原"当时模型到底看到了啥"，翻日志就行。

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

这笔账仓库自带的快照正好能算出来。Native是19个工具，Both在同一组里就多了一个`run_code`：

```text
Native  … job_output, list_agents, ralph, read,           send_message, skill, …
Both    … job_output, list_agents, ralph, read, run_code, send_message, skill, …
                                                 ↑ 从这里开始，后面全部对不上
```

`run_code`排在第12位（一共20个）。按DeepSeek的线格式序列化出来，两边一模一样的开头只有10,739字符，占22,848字符的**47%**。换句话说，**就多装了一个工具，一多半的Tool Schema缓存白瞎了，得重新算一遍**。

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

**那它图什么。** 好处不在Header上，在于中间结果不进历史。比如"读三个文件、对比一下、把结论写进第四个文件"这么件事：

```text
Native：一条消息里发三个 read（read 是并发安全的，能一起跑），拿回三份文件全文
        再发一个 write —— 两个来回
        但三份全文都躺进历史了，后面每一轮请求都得把它们重新发一遍

Code：  写一段代码，三个 read 加一个 write 一次跑完 —— 一个来回
        三份全文只在代码里过了一道，没进模型历史，回来的只有一句结论
```

**真正省下来的不是那一个来回，是那三份文件全文再也不会出现在后续每一轮请求里。** 所以要比就得比整个任务跑下来一共花了多少Token、成没成功。只比单次Header谁长，会得出反的结论。

### 3. 模型的视图按Step冻结，执行时却查实时注册表

**举个例子。** 第3步开始时`web_search`还在，Schema进了请求，模型生成了一个`web_search`调用。就在模型生成的这几秒里，另一条路径把web插件卸载了。Harness拿到这个调用去执行，它不看请求里那份Schema快照，而是重新去实时注册表里找——找不到，返回`UNKNOWN_TOOL`。

```text
Step开始：组装并深冻结请求（含 web_search）
模型生成：web_search 调用
执行之前：插件被卸载
执行时刻：查实时注册表 → 找不到 → UNKNOWN_TOOL
```

**并行时还要更细一点。** 模型一次发了5个调用，跑完前2个的时候插件集合变了，剩下3个会用**新的**注册表重新分类。源码注释写得很直白："Commit before classifying again so registry changes affect unstarted calls"。

**为什么要单说这个。** "模型以为自己有哪些工具"和"运行时真的还有哪些"，中间有一小段时间对不上。这不是bug，是它想清楚了这么定的。但我们要做运行时动态增删能力，这段时间差就得自己兜住：要么一个阶段内把插件集合锁死不让改，要么给正在用的插件挂个"占用中"的标记不许卸，要么干脆让它失败，让模型下一步重新规划。

### 4. 卸载不等于遗忘

**举个例子。** 用户装了一个"报销流程"Skill，模型调`skill`工具把正文读进来，照着做了两步。这时管理员把这个Skill下架了。下一步模型会收到一份新目录，明说"这份完整目录替换本会话中此前所有可用技能列表"，再调这个名字也会失败。**但前面那段正文原封不动躺在对话历史里**，模型照样看得见，照样可能接着按它做。

**它为什么不干脆删掉。** 因为动历史中间那一段，缓存就从那个位置断了。所以它宁可再追加一份完整目录，用新的把旧的作废掉；哪怕一个技能都不剩，也是追加一份空目录，附一句"不要用早先目录里的名字"。说白了就是拿"语义干净"换"缓存稳定"。

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

**请求里根本没地方让你插手。** DeepSeek的请求体就`model`、`messages`、`stream`、`tools`那么几个字段，**没有一个能用来说"这段帮我缓存下来"**，也没有Anthropic那种`cache_control`标记。到底命不命中，全靠服务端自己比Token前缀。Harness能做的就两件事：把前缀弄稳，以及从返回里把结果读出来。

**读的时候有个坑，很容易踩。** 假设一次请求返回`prompt_tokens: 8000`、`prompt_cache_hit_tokens: 6500`，Harness会换算成：

```text
cacheReadTokens = 6500
inputTokens     = 8000 - 6500 = 1500
```

这个`inputTokens`是**没命中的那1500**，不是总输入8000。想知道这次到底喂进去多少，得自己加：`inputTokens + cacheReadTokens`。做实验时要是顺手拿`inputTokens`当输入量，上下文规模和成本都会被低估一大截，结论就跑偏了。另外DeepSeek这条链路不产生`cacheWriteTokens`，没命中的那部分就留在`inputTokens`里。

## 四、这对我们意味着什么

**第一，人家是真在为缓存做设计，不是顺带提一嘴。** 下面这四件事看着互不相干，背后是同一个判断：**改动的位置越靠前越贵。**

| 做法 | 换来什么 |
|---|---|
| 工具按名字排序 | 同一组工具，不管谁先注册、在哪台机器上跑，拼出来的字节都一样。源码注释原话是顺序"identical on every machine" |
| Compaction复用原来的System Prompt和Tool Schema | 摘要那次调用变成上一次请求的真前缀，几万Token直接命中，而不是从第一个Token重算 |
| Skill目录只追加新的、不改旧的 | 目录变了也只是往历史末尾加一条，前面所有内容的缓存全保住。代价是旧目录还占着上下文 |
| 运行时上下文放历史末尾，不进System Prompt | 沙箱、审批策略变来变去，`request/header`一个字节都不变，System Prompt和Tool Schema的缓存完全不受影响 |

看得出来它一直在同一个取舍上打转：**能往末尾加就别改前面，实在要改就尽量往后挪。** 对我们的直接影响是，做能力检索光盯着"找得准不准"不够，还得算一笔"这回换不换划算"。

**第二，动态增删能力有两道坎，现在都摆在明面上了。** 一道是换工具的代价跟位置有关，前面那个47%就是例子；另一道是模型看过的东西擦不掉，Skill正文一旦进了历史就一直在那儿。这两条加一起，"每一轮都重新检索一批插件装上"这种玩法，工程上大概率是赔的。

**第三，更靠谱的做法是按阶段走，不是按轮走。** 一个任务阶段开始的时候挑一组能力装上，这个阶段里就不动了，一次缓存失效让后面十几轮调用去分摊；阶段结束再统一收拾。要是想彻底隔离，Sub-Agent是现成的：自己一个Session、自己一份历史、可以用`toolFilter`只给它几个工具，干完整个丢掉，主Agent那边一点没脏。

**第四，动手做实验之前，得先去问产品几个问题。** 能力检索到底该发生在哪一层，Plugin、Skill还是Tool？插件是人预先装好的，还是系统按任务自动装？现在最影响体验的到底是选错能力、上下文太贵、冷启动慢、权限卡壳，还是任务干不完？这几个问题答案不一样，要做的东西差得很远，不如先问清楚，别自己假设一个再去凑。

完整的模块设计、源码位置和代码摘录见《DeepSeek Harness完整调研》。
