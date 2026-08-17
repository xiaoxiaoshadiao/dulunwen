# DeepSeek Harness完整调研

> 本文从产品侧关心的上下文选择、能力加载、权限、执行反馈和成本问题出发，再逐层进入DeepSeek Harness的Agent Loop、System Prompt、Tool、Session、Skill、Preset、Sub-Agent和KV Cache。源码快照与官方`master`提交`47f943859bef60e4160492346772ded9b24f765a`逐文件一致。

## 一、DeepSeek Harness是什么

DeepSeek Harness不是模型，而是围绕模型运行Agent任务的框架。模型负责生成文本或Tool Call，Harness负责准备上下文、暴露能力、执行操作、记录状态以及处理权限和恢复。

它采用Cordis插件架构。Agent Loop、LLM Adapter、Tools、Session、文件系统、Shell、Skill、Sub-Agent、Preset和界面均由插件提供，通过Profile和Bundle组合成不同产品形态。当前源码版本为`0.1.0-rc.5`，仍处于开发者预览阶段。

从产品角度看，读这份源码不是为了复述模块列表，而是回答：能力如何进入模型上下文、如何按作用域组合、变化后何时生效、执行失败如何返回、长期Session如何维护，以及这些选择如何影响成本和可靠性。

## 二、整体架构

```text
Web / TUI / Headless / SDK
              ↓
        Agent与Session管理
              ↓
           Agent Loop
              ↓
System Prompt / Tools / Session / LLM
              ↓
文件 / Shell / Web / Skill / Sub-Agent
              ↓
          Cordis Context
```

|层次|主要职责|代表目录|
|---|---|---|
|入口层|Web、终端、Headless和自动化协议|`apps/`、`packages/acp`、`packages/sdk`|
|控制层|Turn、Step、请求和Tool执行|`packages/core/agent-loop`|
|模型输入层|System Prompt、Tools和Session History|`packages/core/system-prompt`、`packages/core/tools`、`packages/core/session`|
|模型连接层|Provider路由、请求序列化和Usage|`packages/llm`|
|能力层|文件、Shell、Web、Skill、Sub-Agent和Workflow|`packages/fs`、`packages/shell`、`packages/web`、`packages/skill`、`packages/subagent`|
|组合层|插件作用域、依赖、加载和卸载|`vendor/cordis`、`packages/preset`、`packages/bundle`|

## 三、一次任务如何运行

一次用户输入开启一个Turn，一个Turn可以包含多个Step。一个Step对应一次模型请求以及该请求产生的Tool执行。

```text
用户输入
→ Inbox接收消息
→ 组装System Prompt和Tool Schema
→ 从Session Log生成History
→ 构造并冻结模型请求
→ LLM Adapter调用模型
→ 模型返回文本或Tool Call
→ Harness执行Tool并记录结果
→ 如仍需模型处理，进入下一Step
```

Session Log是请求重建的事实来源。用户消息、模型回复和Tool结果进入模型History；System Prompt和Tool Schema记录在`request/header`中。后续章节讨论插件变化如何修改这些内容，以及修改后对KV Cache产生什么影响。

## 四、问题定义

插件加载不仅改变程序运行时，也可能改变模型每轮请求看到的内容。对第`t`轮请求，可以抽象为：

```text
X_t = SystemPrompt(P_t) + ToolSchemas(P_t) + History_t + UserInput_t
```

其中`P_t`是当前激活的插件集合。不同插件可能注册System Prompt片段、Tools、Skills或其他上下文，因此`P_t`变化会引起`X_t`变化。

大多数Prefix Cache依赖Token前缀完全一致。可以用最长公共前缀近似描述相邻请求的缓存复用：

```text
复用Token数 = LCP(Tokenize(X_{t-1}), Tokenize(X_t))
新增Prefill数 = |Tokenize(X_t)| - 复用Token数
```

因此，插件检索减少了每轮暴露的能力数量，但如果插件集合频繁变化，也可能降低KV Cache复用率。两者之间存在实际权衡。

## 五、不同变化对KV Cache的影响

|插件变化|模型可见输入|缓存影响|
|---|---|---|
|只增加后端Service|不改变System Prompt和Tools|通常无直接影响|
|增加System Prompt片段|Prompt前部改变|影响通常最大|
|增加或删除Tool Schema|Tools部分改变|从Schema变化位置起重新Prefill|
|在History末尾追加Skill说明|只增加后缀|已有前缀通常可以复用|
|删除历史中的旧说明|History中间改变|删除位置之后的缓存失效|
|追加“插件已失效”消息|只增加后缀|缓存友好，但旧信息仍在上下文中|

这里需要通过DeepSeek的模型适配层确认：Tool Schema最终如何序列化、处于System Prompt之前还是之后、是否参与Prefix Cache Key，以及缓存命中Token如何统计。

## 六、正确性问题

动态插件系统需要同时维护两份状态：

```text
模型可见状态：模型看到哪些Prompt、Skill和Tool Schema
执行状态：运行时实际注册了哪些Tool和Service
```

两者不一致会产生两类错误：

- 模型仍能看到某个Tool，但对应插件已经卸载，导致无效调用；
- 插件已经激活，但Schema没有进入模型请求，模型无法使用新能力。

比较稳妥的做法是按Step冻结工具视图：

1. Step开始时生成一份Tool Snapshot；
2. 当前模型请求和后续Tool Call都基于这份Snapshot；
3. 插件变化只在下一Step生效；
4. Session Log记录该Step使用的插件集合或Schema摘要。

还需要保证Tool Schema的顺序和序列化稳定。相同插件集合如果因为注册顺序、JSON字段顺序或默认值展开方式不同而产生不同Token，也会降低缓存命中。

## 七、插件加载与卸载

### 7.1 加载

插件加载后，模型需要知道新增能力。直接加入System Prompt或Tool Schema最自然，但会修改请求前缀。若一个任务需要多轮调用，只要插件集合在加载后保持稳定，这次缓存失效可以被后续轮次摊销。

### 7.2 卸载

卸载比加载复杂，因为模型可能已经在History中看过插件说明。

|方式|优点|问题|
|---|---|---|
|重建Prompt并删除旧信息|模型视图干净|修改中间前缀，缓存失效较多|
|保留历史并追加失效通知|保持Append-only，缓存友好|模型仍然看过旧指令，可能继续受影响|
|切换到新Session或子Agent|隔离清楚|产生新的上下文与启动成本|

因此，“语义上彻底卸载”和“保持Prefix稳定”不一定可以同时满足。需要区分：

- Tool是否仍在当前请求的Schema中；
- Skill说明是否仍出现在模型History中；
- Runtime是否仍接受旧Tool Call；
- 日志回放时如何重建当时的模型视图。

## 八、几种插件暴露方式

|方案|做法|优点|代价|
|---|---|---|---|
|动态Tool Schema|插件加载后直接增删Tools|调用自然、参数约束清楚|插件切换会修改Schema前缀|
|静态全集|始终暴露全部Tools|Tool前缀稳定|Token多，Tool选择更困难|
|统一Router Tool|只暴露搜索、激活和调用入口|Tool面稳定|参数校验与调用表达更复杂|
|Code Mode|只暴露代码执行入口，能力作为SDK|Schema小，组合灵活|代码生成与安全成本更高|
|子Agent隔离|不同插件集合交给不同子Agent|主Agent上下文稳定|增加子Agent启动与通信成本|
|阶段内固定|任务阶段开始时加载，阶段内不变|缓存失效可被多轮调用摊销|阶段切换前不够灵活|

DeepSeek Harness同时存在普通Tool模式、PTC/Code Mode、Skill和子Agent，因此比较这些模式对缓存、成功率和成本的影响具有现实意义。

## 九、插件检索需要考虑缓存成本

插件选择通常考虑相关性、依赖、权限和执行成本。动态加载后还应考虑：

- 当前插件集合与候选集合的差异；
- System Prompt变化量；
- Tool Schema变化量；
- 预计可复用前缀长度；
- 插件在后续轮次中的预计使用次数；
- 插件加载、卸载和重新Prefill成本。

当两个方案都能完成任务时，复用当前插件集合可能比切换到语义分数略高的新插件更便宜。可以把目标理解为：

```text
总成本 = 任务失败风险 + 新增Prefill成本 + Tool选择干扰 + 插件切换成本
```

这里不急于确定最终优化公式，需要先确认DeepSeek Harness的请求构造和DeepSeek模型服务的缓存统计方式。

## 十、需要观察的指标

|类别|指标|
|---|---|
|缓存|Cache Hit Tokens、Uncached Prefill Tokens、复用前缀比例|
|延迟|Time to First Token、单Step延迟、任务总时长|
|上下文|System Prompt Tokens、Tool Schema Tokens、History Tokens|
|动态性|Plugin Set Churn、Schema变化次数、每次变化位置|
|正确性|Tool选择准确率、无效Tool Call、已卸载Tool调用率|
|任务|任务成功率、调用轮数、单位成功任务成本|

只比较Input Token数量不够。需要同时报告缓存命中、Prefill、插件切换次数和任务成功率。

## 十一、DeepSeek Harness源码阅读范围

本轮源码分析围绕：

1. System Prompt由哪些Section组成，如何注册、排序和拼接；
2. Tool Schema在每个Step如何收集、排序和序列化；
3. Plugin加载或卸载后，Tool Registry何时影响下一次模型请求；
4. Agent Loop是否在请求期间冻结Tool Snapshot；
5. Session Log记录了哪些模型可见状态；
6. Skill目录更新为什么采用Append-only替换消息；
7. Skill正文加载后何时从模型上下文中消失；
8. Compaction如何处理已失效的Skill和Plugin信息；
9. DeepSeek LLM Adapter是否暴露Cache Hit Token等Usage字段；
10. 标准模式、PTC/Code Mode和子Agent模式的Tool Schema是否稳定；
11. Agent Preset切换是否复用原Session和Prefix Cache；
12. 相同Tool集合是否采用确定性排序和规范化JSON。

重点目录预计包括：

```text
packages/core/system-prompt
packages/core/tools
packages/core/agent-loop
packages/core/session
packages/skill
packages/llm
packages/compaction
packages/preset
packages/subagent
packages/session
packages/bundle
apps/cli
```

实际调用链和结论记录在第十至十四节。

## 十二、普通模式的请求链

当前源码与官方`master`提交`47f943859bef60e4160492346772ded9b24f765a`逐文件一致。普通模式的调用链已经确认。

### 12.1 System Prompt与Tool Schema统一组装

`packages/core/system-prompt`维护Sections、动态Context、Tool Schema和Prompt变量。Tool Registry不是由Agent Loop单独查询，而是向System Prompt服务注册一个Tool Provider。每次组装同时得到：

```text
PromptAssembly = {
  sections,
  contexts,
  tools,
  variables
}
```

插件可以通过同一个`system-prompt/assemble`过程同时修改System Prompt和模型可见Tools。源码还会对Tools采用配置顺序或按名称排序，减少相同Tool集合因为注册顺序不同而产生的请求差异。

相关位置：

```text
packages/core/system-prompt/src/index.ts
packages/core/tools/src/index.ts
```

### 12.2 每个Step生成一份冻结请求

Agent Loop在每个Step开始前执行Prompt Assembly，再使用本次的`system`、`tools`和`session.deriveMessages()`构造请求。请求在发送前执行深冻结，因此当前Step使用的是一份固定视图，插件变化应在后续Step重新组装时体现。

当System Prompt、Tool Schema、模型或请求配置发生变化时，Agent Loop会写入新的`request/header`事件。Header包含完整的System Prompt和Tool Schema，可用于恢复和审计某个Step实际看到的模型输入。

相关位置：

```text
packages/core/agent-loop/src/agent.ts
packages/core/session
```

### 12.3 DeepSeek请求中的实际顺序

DeepSeek Adapter将System Prompt放入第一条`system`消息，随后序列化Session Messages；Tool Schema通过Chat Completions请求的独立`tools`字段发送：

```text
request = {
  model,
  messages: [system, ...history],
  tools,
  stream: true
}
```

虽然Tools在协议中不是普通消息，但仓库的设计记录明确将Tool Schema视为模型请求前缀的一部分。改变或省略Tools会破坏后续Token与已有缓存的对齐。

相关位置：

```text
packages/llm/llm-deepseek/src/serialize.ts
.agents/notes/archived/architecture/2026-06-11-tool-schemas-in-prompt-assembly.zh.md
```

### 12.4 DeepSeek缓存命中统计

DeepSeek返回的`prompt_tokens`包含命中和未命中的输入Token。Adapter按以下方式转换：

```text
cacheReadTokens =
  prompt_tokens_details.cached_tokens
  或 prompt_cache_hit_tokens

inputTokens =
  prompt_tokens - cacheReadTokens
```

Harness中的`inputTokens`表示未缓存输入，`cacheReadTokens`单独统计命中部分。Token Meter会把二者分别累计，因此可以直接用于后续缓存实验。当前DeepSeek映射没有提供`cacheWriteTokens`。

相关位置：

```text
packages/llm/llm-deepseek/src/translate.ts
packages/llm/llm/src/types.ts
packages/llm/token-meter/src/usage-projection.ts
```

### 12.5 Skill目录采用追加式替换

`tool-skill`会在每次`agent/pre-step`重新获取Skill目录，对Skill名称和描述计算Digest。目录变化时，不修改历史消息，而是追加一条完整替换目录；Skill全部消失时追加空目录，明确禁止使用旧名称。

这种设计保留较早的可复用前缀，但有两个代价：

- 每次目录变化都要追加完整目录，Token成本与当前目录大小相关；
- 已经通过`skill`工具加载的Skill正文作为Tool Result留在History中，不会因为目录移除而自动消失。

相关位置：

```text
packages/skill/tool-skill/src/index.ts
.agents/notes/implemented/feature/2026-07-27-skill-catalog-hot-refresh.zh.md
```

### 12.6 Compaction已经专门优化KV Cache

旧Compaction使用新的摘要System Prompt和扁平Transcript，导致从第一个Token起就无法复用刚刚预热的对话缓存。当前实现改为：

```text
原请求System Prompt
+ 原请求Tool Schema
+ 原始History前缀
+ 末尾Compaction指令
```

即使摘要调用不会执行工具，也必须带上原Tool Schema，否则Token序列会从Tools位置开始失去对齐。这一设计直接证明Tool Schema稳定性已经被DeepSeek Harness视为KV Cache问题，而不只是Tool Calling问题。

相关记录：

```text
.agents/notes/implemented/bug-fix/2026-07-21-compaction-summary-prefix-cache-reuse.zh.md
```

### 12.7 动态注册和卸载何时生效

System Prompt、Context、Variable和Tool注册都是Cordis Effect，卸载插件会执行对应Disposer。注册或卸载完成后，下一Step重新执行`systemPrompt.assemble()`，因此会看到新的System Prompt和Tool集合。

需要区分三个时间点：

1. **Assembly之前变化：** 当前Step直接使用新集合；
2. **Assembly之后、模型请求之前变化：** 当前请求已经持有旧Assembly，变化到下一Step才生效；
3. **模型已经产生Tool Call、Tool尚未执行时变化：** 执行层会再次查询实时Tool Registry。

第三种情况会产生竞态：

- 模型看到了Tool Schema，但执行前Tool已经卸载，会得到`UNKNOWN_TOOL`；
- 新Tool没有出现在当前Schema中，但模型若仍生成同名调用，实时Registry可能接受执行；
- 并行调用中尚未开始的Tool还会在启动前重新分类。

`system-prompt/change`和`tools/change`事件本身不会唤醒空闲Agent，也不会立刻创建新Step。必须由新用户消息、Steering或Tool continuation推动下一次Assembly。

相关位置：

```text
packages/core/scope/src/store.ts
packages/core/tools/src/index.ts
packages/core/agent-loop/src/tool-calls.ts
vendor/cordis/src/fiber.ts
```

## 十三、Native、Code和Both模式

Tool Runtime支持三种模型可见方式：

|模式|原生Tool Schema|System Prompt|直接调用|
|---|---|---|---|
|Native|全部可见Tools|不含SDK|直接调用真实Tool|
|Code|只有`run_code`|包含完整Tools SDK|只能直接调用`run_code`|
|Both|真实Tools+`run_code`|包含完整Tools SDK|两种方式都可用|

### 13.1 Code Mode并没有隐藏真实工具信息

Code Mode中，DeepSeek请求的原生`tools`字段只有`run_code`，但全部真实工具会被渲染成SDK文本放进System Prompt。SDK包含工具名、说明、参数类型和返回类型。

```text
Native：
  tools = [tool_a, tool_b, ...]

Code：
  system = 原System Prompt + tools:sdk
  tools = [run_code]
```

因此，Code Mode只稳定了原生Tool Schema数量，并没有让真实工具集合变化对KV Cache免疫。新增、删除或修改真实工具会改变System Prompt中的SDK文本，且变化位置很靠前。

SDK和Tool Schema都按工具名排序。仅替换Tool执行实现、而名称、说明、参数和返回类型完全不变时，模型可见Header可以保持不变。

### 13.2 Code Mode的缓存收益来自减少往返

Code Mode可以在一次`run_code`中组合多个真实工具，嵌套调用结果也不必全部进入模型History。它的主要收益可能来自：

- 原生`tools`字段只保留一个Schema；
- 多个Tool Call合并为一次代码执行；
- 中间Tool Result不全部进入后续Prompt；
- 模型与Harness往返次数减少。

如果真实工具集合长期稳定，这些收益可能降低任务总Prefill；如果工具集合频繁变化，完整SDK位于System Prompt，前缀失效仍然明显。

### 13.3 Both模式

Both模式同时暴露原生Tools和完整SDK，同一能力会出现在两处，通常是模型可见内容最大的模式。它适合迁移和诊断，但不一定适合追求Token或缓存效率。

相关位置：

```text
packages/core/tools/src/index.ts
packages/core/tools/src/code-mode.ts
packages/core/tools/src/ts-types.ts
packages/core/tools/src/py-types.ts
```

## 十四、Session、Skill和Runtime Context

### 14.1 模型可见内容以Session Log为准

普通Agent Loop不会把临时字符串直接插入模型请求。能够进入模型History的主要事件是：

```text
user/message
assistant/message
tool/result
```

System Prompt和Tool Schema不属于History，而是记录在完整的`request/header`中。每次请求由当前Header和`session.deriveMessages()`共同构造并深冻结。

`request/header`记录：

```text
provider / model / sampling config
rendered system
ordered tool schemas
```

它不记录History、API Key、Base URL和HTTP Header。第一次请求记为`initial`，新Loop接管已有Session时记为`resume`，同一Loop内Header变化记为`change`。

### 14.2 Skill目录和正文

Skill目录变化采用完整追加式替换，旧目录仍保留在History中，由新消息声明“以后使用这份完整目录”。Skill全部删除时追加空目录Tombstone。

Skill正文没有Unload协议：

- 模型调用`skill`后，正文作为`tool/result`进入History；
- 用户通过`/name`调用后，正文作为`user/message`进入History；
- Skill文件删除后，未来调用会失败，但已加载正文继续留在模型History；
- 只有Compaction将其遮蔽后，正文才退出当前Surface，原始日志仍保留。

所以当前“卸载Skill”只撤销未来发现和未来调用，不能让模型忘记已经看过的正文。

### 14.3 Runtime Context

动态Runtime Context也采用完整快照追加：

- 文本不变时不追加；
- 任一部分变化时追加完整新快照；
- 从非空变为空时追加明确清除消息；
- 旧快照仍在History中，由新消息声明其已经失效；
- Compaction遮蔽快照后，下一Step会重新发布当前状态。

这种设计保持Session Log可重建，也保持Append-only前缀，但模型会同时看到历史快照和“新快照覆盖旧快照”的语义。

相关位置：

```text
packages/core/session/src/index.ts
packages/core/session/src/surface.ts
packages/core/agent-loop/src/runtime-context.ts
packages/skill/tool-skill/src/index.ts
```

## 十五、Preset和Sub-Agent

### 15.1 Preset切换

Web API只允许尚未开始任何Turn的空Session切换Preset。切换后复用同一个Session标识，但下一次请求会基于新Preset重新组装System Prompt和Tools。

运行中的Agent固定在已经挂载的Preset Generation上。Preset文件变化通常只影响后续新Session或重新挂载的Agent，不会直接改变当前活动Agent。

Resume时会重新读取当前Preset内容，并无条件写入一份`request/header`，原因标记为`resume`。如果同名Preset在进程重启前后发生变化，恢复后的Header可能与旧请求不同，是否命中缓存取决于最终Token前缀，而不是Session ID。

### 15.2 Sub-Agent

每个Sub-Agent具有独立Session、History和`request/header`，可以通过Tool Filter收窄继承的工具集合。

- **Spawn：** 不复制父Agent History，首请求主要复用共同的System/Tool前缀；
- **Fork：** 复制父Session到最近完整Turn，可以在Header相同时复用更长前缀；
- Persona、Tool Filter、`report` Tool或结构化输出Schema变化都会改变Header，削弱Fork的缓存收益。

Harness没有为父子Session设置显式KV Cache命名空间。是否跨Session命中由模型服务根据Token前缀决定。

相关位置：

```text
packages/preset/agent-presets
packages/subagent/subagent
packages/subagent/subagent-spawn-in-process
packages/subagent/subagent-fork-in-process
```

## 十六、三类Cache不能混淆

Harness源码中存在多种名为Cache的结构，但只有Provider侧Prefix Cache是Transformer KV Cache。

|名称|用途|模型KV Cache|
|---|---|---|
|Session派生消息缓存|增量计算当前History|否|
|Surface Manager|维护当前可见消息和Replacement|否|
|Skill目录Cache|缓存Skill发现结果|否|
|Session Projection Cache|持久化日志Projection Checkpoint|否|
|Token Meter状态|估算Context压力和累计Usage|否|
|DeepSeek Prefix Cache|复用模型前缀的K/V状态|是|

Harness不保存、删除或迁移DeepSeek的KV Cache，只能：

1. 通过稳定请求前缀提高命中概率；
2. 从Provider Usage读取`cacheReadTokens`；
3. 通过真实请求实验观察命中和延迟。

### 16.1 Usage统计边界

Harness约定：

```text
计费Prompt输入 =
  inputTokens
  + cacheReadTokens
  + cacheWriteTokens
```

`inputTokens`表示未缓存输入。DeepSeek Adapter不产生`cacheWriteTokens`，Cache Miss保留在`inputTokens`中。

Token Meter累计的是Agent Loop逻辑Step的Usage，不是所有HTTP请求的完整账单。同一Step重试时采用最后一次Usage，Compaction辅助请求和其他直接LLM请求也不一定进入同一个累计Projection。后续实验应同时保存原始Provider Usage，不能只读取Token Meter总数。

## 十七、对产品设计的结论与验证重点

结合源码和WorkBuddy的产品实践，目前可以形成以下判断：

1. **动态Tool变化会改变模型请求头。** Native改变`tools`，Code改变System Prompt中的SDK，Both通常两处都变；
2. **每个Step使用固定请求视图。** 但Tool执行前仍查实时Registry，因此卸载时存在Schema与执行状态短暂不一致；
3. **Skill和Runtime Context采用追加式语义替换。** 这种方式保留缓存前缀，却不能真正撤回模型已经看过的内容；
4. **Compaction明确按Prefix Cache设计。** 原System、Tools和历史头部必须逐字复用；
5. **Code Mode不天然解决动态工具缓存问题。** 它更可能通过减少调用轮数和History体积获益；
6. **Sub-Agent可以隔离History和工具集合。** 但是否复用父Agent缓存取决于Header是否完全一致；
7. **缓存成本应进入插件选择目标。** 能力相关性相近时，复用当前插件集合可能比频繁切换更便宜。

需要避免把结论扩大为“产品应该自动检索并安装Plugin”。现有实践已经证明Tool和Skill的渐进式加载有价值，但Plugin更接近安装、分发和作用域管理单元。运行时选择应该停在Plugin、Skill还是Tool层，需要由真实产品流程和数据决定。

第一轮实验应优先比较：

|方案|主要变量|
|---|---|
|Native静态全集|Schema大、集合稳定|
|Native动态集合|Schema小、集合变化|
|Code动态集合|`run_code`稳定、SDK变化|
|阶段内固定集合|每阶段只失效一次|
|统一Router Tool|Schema稳定、调用间接|
|Spawn Sub-Agent|独立短History|
|Fork Sub-Agent|尝试复用父History前缀|

每次请求保存：

```text
System Prompt摘要
Tool Schema摘要
Plugin Set摘要
request/header reason
inputTokens
cacheReadTokens
TTFT
任务成功率
无效Tool Call
```

当前仍需通过真实运行确认的只有三类问题：

1. DeepSeek服务端如何将独立`tools`字段编码进实际缓存Token前缀；
2. 不同模式和插件切换频率下，Cache Hit、TTFT和任务成功率的真实变化；
3. Plugin卸载与Prompt Assembly并发时，是否会出现混合代际的System/Tool视图。
