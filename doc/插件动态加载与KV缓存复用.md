# 插件动态加载、模型可见状态与KV Cache复用

> 本文记录插件动态加载对System Prompt、Tool Schema和KV Cache的影响。当前内容是问题分析与源码阅读提纲，涉及DeepSeek Harness具体行为的部分仍需结合源码确认。

## 一、问题定义

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

## 二、不同变化对KV Cache的影响

|插件变化|模型可见输入|缓存影响|
|---|---|---|
|只增加后端Service|不改变System Prompt和Tools|通常无直接影响|
|增加System Prompt片段|Prompt前部改变|影响通常最大|
|增加或删除Tool Schema|Tools部分改变|从Schema变化位置起重新Prefill|
|在History末尾追加Skill说明|只增加后缀|已有前缀通常可以复用|
|删除历史中的旧说明|History中间改变|删除位置之后的缓存失效|
|追加“插件已失效”消息|只增加后缀|缓存友好，但旧信息仍在上下文中|

这里需要通过DeepSeek的模型适配层确认：Tool Schema最终如何序列化、处于System Prompt之前还是之后、是否参与Prefix Cache Key，以及缓存命中Token如何统计。

## 三、正确性问题

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

## 四、插件加载与卸载

### 4.1 加载

插件加载后，模型需要知道新增能力。直接加入System Prompt或Tool Schema最自然，但会修改请求前缀。若一个任务需要多轮调用，只要插件集合在加载后保持稳定，这次缓存失效可以被后续轮次摊销。

### 4.2 卸载

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

## 五、几种插件暴露方式

|方案|做法|优点|代价|
|---|---|---|---|
|动态Tool Schema|插件加载后直接增删Tools|调用自然、参数约束清楚|插件切换会修改Schema前缀|
|静态全集|始终暴露全部Tools|Tool前缀稳定|Token多，Tool选择更困难|
|统一Router Tool|只暴露搜索、激活和调用入口|Tool面稳定|参数校验与调用表达更复杂|
|Code Mode|只暴露代码执行入口，能力作为SDK|Schema小，组合灵活|代码生成与安全成本更高|
|子Agent隔离|不同插件集合交给不同子Agent|主Agent上下文稳定|增加子Agent启动与通信成本|
|阶段内固定|任务阶段开始时加载，阶段内不变|缓存失效可被多轮调用摊销|阶段切换前不够灵活|

DeepSeek Harness同时存在普通Tool模式、PTC/Code Mode、Skill和子Agent，因此比较这些模式对缓存、成功率和成本的影响具有现实意义。

## 六、插件检索需要考虑缓存成本

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

## 七、需要观察的指标

|类别|指标|
|---|---|
|缓存|Cache Hit Tokens、Uncached Prefill Tokens、复用前缀比例|
|延迟|Time to First Token、单Step延迟、任务总时长|
|上下文|System Prompt Tokens、Tool Schema Tokens、History Tokens|
|动态性|Plugin Set Churn、Schema变化次数、每次变化位置|
|正确性|Tool选择准确率、无效Tool Call、已卸载Tool调用率|
|任务|任务成功率、调用轮数、单位成功任务成本|

只比较Input Token数量不够。需要同时报告缓存命中、Prefill、插件切换次数和任务成功率。

## 八、DeepSeek Harness源码阅读重点

后续源码分析优先回答：

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
packages/skill
packages/llm
packages/session
packages/client
packages/bundle
```

实际目录与调用链需要在源码分析后修正。

## 九、第一轮实验设想

可以固定同一个模型和任务，对比：

1. 全量静态Tool Schema；
2. 每轮动态增删Tool Schema；
3. 任务阶段内固定Plugin Set；
4. 统一Router Tool；
5. PTC/Code Mode；
6. 子Agent隔离。

每组记录模型请求的Token序列摘要、缓存命中、Prefill、延迟、Tool选择和任务成功率。第一轮目标不是训练新模型，而是确认插件动态加载在DeepSeek Harness中到底如何影响模型输入和KV Cache。
