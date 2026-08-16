# DeepSeek Harness简短调研

> **DeepSeek Harness不是一个新模型，而是一套让模型能够读取文件、调用工具、运行任务、管理状态并组合插件的Agent运行框架。**

## 一、它解决什么问题

模型本身只负责根据输入生成输出。一个可以真正工作的Agent还需要：

- 组织System Prompt和上下文；
- 向模型暴露Tools；
- 执行Tool Call并返回结果；
- 保存Session和任务状态；
- 管理文件、终端、网页和子Agent；
- 控制权限、超时、取消和恢复。

DeepSeek Harness将这些能力拆成插件，通过配置组合成Web、终端、Headless或自动化服务。当前源码版本为`0.1.0-rc.5`，仍处于开发者预览阶段。

## 二、整体架构

```text
Web / TUI / Headless / SDK
              ↓
          Agent Loop
              ↓
System Prompt + Tools + Session
              ↓
          LLM Adapter
              ↓
   Tool执行 / 文件 / Shell / Web
              ↓
          Session Log
```

|模块|作用|
|---|---|
|Agent Loop|驱动模型请求和Tool执行|
|System Prompt|组装Prompt、动态Context和Tool Schema|
|Tools|注册、限制和执行模型可调用能力|
|LLM Adapter|连接DeepSeek等模型服务|
|Session|记录消息、请求配置、Tool结果和状态变化|
|Skill|按需加载程序性说明|
|Preset/Bundle|组合一组插件，形成不同Agent形态|
|Cordis|管理插件作用域、依赖、加载和卸载|

## 三、一次任务如何运行

```text
用户输入
→ 开始Turn
→ 组装当前System Prompt和Tools
→ 从Session Log生成History
→ 构造并冻结模型请求
→ 模型返回文本或Tool Call
→ Harness执行Tool
→ Tool结果写入Session
→ 如有需要进入下一Step
```

一个Turn可以包含多个Step。每个Step只进行一次模型请求，并执行该请求产生的Tool Calls。

## 四、为什么说“一切皆插件”

Plugin是Harness中的运行时模块。它可以注册：

```text
Tool
System Prompt
Skill
Service
后台任务
权限策略
模型或存储实现
```

模型通常调用Tool，而不是直接调用Plugin：

```text
Plugin加载
→ 注册Tool
→ Tool Schema进入模型请求
→ 模型调用Tool
→ Harness执行Plugin提供的函数
```

Plugin决定Agent拥有哪些能力，Tool是模型使用能力的具体接口。

## 五、源码中与模型输入有关的设计

第一轮源码阅读确认：

- System Prompt和Tool Schema由同一套Prompt Assembly组装；
- Tools采用确定性排序，避免同一集合因为注册顺序不同而改变请求；
- 每个Step生成并冻结一份模型请求；
- Session Log记录模型可见消息和完整请求Header；
- DeepSeek Adapter可以统计未缓存输入和缓存命中Token；
- Compaction会复用原System Prompt、Tools和History前缀。

这些设计说明Harness不仅关心工具能否调用，也在考虑请求是否稳定、能否回放以及能否复用KV Cache。

## 六、插件动态加载与KV Cache

一次模型请求可以简化为：

```text
System Prompt
+ Tool Schema
+ History
+ 当前输入
```

KV Cache依赖相同Token前缀。插件新增或删除Tool时，Tool Schema变化，变化位置之后的History可能需要重新Prefill。

|模式|模型如何使用Tools|缓存特点|
|---|---|---|
|Native|模型直接调用全部真实Tools|Tool Schema变化会改变请求|
|Code|模型调用`run_code`，代码再调用Tools|原生Schema稳定，但完整Tools SDK仍在System Prompt|
|Both|同时支持Native和Code|能力重复表示，模型输入通常最大|

Code Mode并没有让真实Tools消失。它的主要价值可能是一次代码执行组合多个Tools，减少模型往返和中间History，而不是彻底解决动态Tool带来的Cache变化。

## 七、与我们当前工作的关系

我们关心的是智能体如何从大量候选中发现、组织和执行能力。DeepSeek Harness提供了一个真实的插件化运行框架，也暴露了一个值得继续研究的问题：

> 动态检索更少的Plugins和Tools可以减少模型输入，但频繁改变能力集合也会降低KV Cache复用，并增加加载、执行和卸载成本。

下一步不是立即训练新模型，而是先比较不同能力暴露方式在任务成功率、Tool数量、Prefill、Cache Hit和延迟上的实际差异。

更完整的源码链路、Session/Skill卸载、Preset/Sub-Agent和实验设计见《DeepSeek Harness完整调研》。
