# 插件动态加载与KV缓存：组会简版

> **一句话：动态加载可以减少模型每轮看到的Tools，但插件集合变化会修改请求前缀，可能降低KV Cache复用。**

## 一、Plugin和Tool是什么关系

```text
Plugin加载
→ 注册Tool、Prompt、Skill或Service
→ Tool Schema进入模型请求
→ 模型调用Tool
→ Harness执行Plugin提供的函数
```

**模型通常调用Tool，不直接调用Plugin。** Plugin决定Harness拥有哪些能力，Tool是模型实际调用的接口。

## 二、一次模型请求

```text
System Prompt
+ Tool Schema
+ History
+ 当前输入
```

KV Cache按相同Token前缀复用。插件新增或删除Tool时，Tool Schema发生变化，变化位置之后的History通常需要重新Prefill。

|情况|缓存影响|
|---|---|
|Tool集合和顺序不变|前缀可以继续复用|
|同一集合但顺序变化|产生无意义的Cache Miss|
|新增或删除Tool|从Schema变化位置开始失去复用|
|只修改Tool内部实现，接口不变|模型请求可以保持不变|

Tool排序只能保证“同一集合产生同一顺序”，不能保证动态增删Tool时缓存不变。

## 三、Native Mode和Code Mode

|模式|模型看到什么|主要特点|
|---|---|---|
|Native|全部真实Tool Schema|模型直接调用Tool|
|Code|`run_code`+System Prompt中的完整Tools SDK|模型写代码，代码调用Tools|

Code Mode没有隐藏真实Tools，只是把它们从原生`tools`字段移到了System Prompt的SDK中。因此，动态Tool变化仍会修改请求前缀。

Code Mode可能更省的原因是：一次代码执行可以组合多个Tools，中间结果不必全部进入History，模型往返次数可能更少。

## 四、插件变化什么时候生效

DeepSeek Harness每个Step重新组装System Prompt和Tools，并冻结本次模型请求：

```text
Step开始前变化
→ 当前Step可见

请求组装后变化
→ 下一Step可见
```

但Tool真正执行前会再次查询实时Registry，因此可能出现：

```text
模型看到Tool
→ Tool在执行前被卸载
→ UNKNOWN_TOOL
```

模型视图按Step冻结，执行Registry仍然动态，两者之间存在短暂竞态。

## 五、卸载并不等于模型忘记

|卸载层次|当前支持情况|
|---|---|
|执行层：函数、进程和Service消失|可以通过Plugin Disposer完成|
|发现层：下一Step不再展示Tool或Skill|可以完成|
|上下文层：删除模型已经看过的Skill和Prompt|不能自动完成|

Skill目录变化采用追加式替换，已加载的Skill正文仍留在History，直到Compaction遮蔽。这样有利于保持请求前缀，但模型仍然看过旧信息。

## 六、源码已经确认什么

- System Prompt和Tool Schema由同一套Prompt Assembly组装；
- Tool采用确定性排序；
- 每个Step构造并冻结一份请求；
- DeepSeek返回`cacheReadTokens`，可以直接统计缓存命中；
- Compaction会复用原System、Tools和History头部，再追加摘要指令；
- Code Mode原生只暴露`run_code`，但完整Tools SDK仍在System Prompt中。

## 七、当前结论

动态插件加载需要同时平衡：

```text
少暴露Tools
+ 高KV Cache复用
+ 少模型往返
+ 执行状态一致
+ 卸载后少上下文残留
```

一个值得优先验证的方案是：**任务阶段开始时加载一组Plugins，阶段内保持稳定，阶段完成后统一卸载。**

后续实验只需先回答三个问题：

1. Native动态Tools与Code动态SDK的真实Cache Hit和TTFT差多少；
2. 阶段内固定Plugin Set能否减少Prefill；
3. Plugin卸载竞态在真实执行中是否会出现。
