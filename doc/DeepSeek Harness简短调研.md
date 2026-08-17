# DeepSeek Harness简短调研

> **WorkBuddy的实践说明，产品团队已经在关注上下文选择、能力渐进式加载、Prompt Cache、权限和执行反馈。我们看DeepSeek Harness源码，是想知道这些产品问题在一个开源Harness里具体怎么实现。**

## 一、为什么看DeepSeek Harness

WorkBuddy文章给出的核心判断是：模型只是起点，Agent能否成为产品，还取决于模型每一步看到什么、能使用什么能力、执行后如何验证和纠正。文章已经明确采用意图识别、Tool/Skill渐进式加载、分层Memory、Sub-Agent隔离和Prompt Cache等机制。

DeepSeek Harness提供了一份可以直接阅读的实现。它不是模型，而是模型外部的Agent运行框架，负责组装上下文、暴露Tools、执行操作、保存Session，并管理权限、取消、恢复和子Agent。

```text
用户输入
→ Agent Loop
→ System Prompt + Tools + Session
→ DeepSeek模型
→ Tool Call
→ Harness执行Tool并记录结果
```

它基于Cordis实现“一切皆插件”。Agent Loop、Tools、Skill、文件系统、Shell、模型适配器和界面都可以由插件注册并通过配置组合。

## 二、看源码时主要盯了五个问题

1. Plugin和Tool到底是什么关系，模型调用的是谁？
2. Tool为什么要排序，排序能否保证KV Cache稳定？
3. Native Mode和Code Mode有什么区别？
4. 插件在模型请求期间加载或卸载，会不会出现状态不一致？
5. Plugin已经卸载后，模型看过的Prompt和Skill是否真的消失？

## 三、Plugin和Tool是什么关系

Plugin是运行时模块，可以注册Tool、Prompt、Skill、Service、后台任务或模型实现。Tool是Plugin向模型暴露的一种具体能力。

```text
Plugin加载
→ 注册Tool
→ Tool Schema进入模型请求
→ 模型调用Tool
→ Harness执行Plugin提供的函数
```

**模型通常调用Tool，不直接调用Plugin。** Plugin决定Agent拥有哪些能力，Tool负责具体执行。

我们后续所说的Plugin Retrieval，发生在Tool Call之前：

```text
先选择并加载Plugin
→ Plugin注册Tools
→ 模型再选择和调用Tools
```

## 四、Tool排序与KV Cache

KV Cache依赖请求Token前缀完全一致。相同Tool集合如果因为并发加载顺序不同，分别生成：

```text
[A, B, C]
[B, A, C]
```

模型请求也会不同。DeepSeek Harness按名称或配置顺序排列Tools，使同一集合稳定生成同一顺序。

但排序只能解决**同一集合顺序不稳定**，不能解决**Tool集合发生变化**：

```text
旧：[A, C, D]
新：[A, B, C, D]
```

新增B后，从B的位置开始发生分叉，后面的Tools和History仍可能需要重新Prefill。

> **排序保证确定性，不保证动态增删Tool时KV Cache不变。**

## 五、Native Mode和Code Mode

|模式|原生Tool Schema|模型如何使用真实Tools|
|---|---|---|
|Native|全部真实Tools|模型直接生成Tool Call|
|Code|只有`run_code`|模型写代码，代码调用Tools|
|Both|真实Tools+`run_code`|两种方式都可用|

Code Mode看起来只暴露一个`run_code`，但真实Tools会被渲染成SDK文本放进System Prompt：

```text
System Prompt + 完整Tools SDK
Native Tools = [run_code]
```

因此动态Tool变化仍会修改System Prompt，Code Mode并没有让KV Cache问题消失。

Code Mode真正可能节省的是：

- 一段代码可以连续调用多个Tools；
- 中间Tool Result不必全部进入模型History；
- 模型与Harness的往返次数可能更少。

所以Native和Code应该比较**整个任务的总成本和成功率**，而不是只比较一次请求的Tool Schema长度。

## 六、模型视图与执行状态的竞态

DeepSeek Harness在每个Step开始时组装System Prompt和Tool Schema，并冻结当前模型请求。插件在Assembly之后变化，通常到下一Step才会进入模型视图。

但模型生成Tool Call后，Harness执行前会再次查询实时Tool Registry：

```text
模型请求中存在web_search
→ 模型生成web_search调用
→ Plugin在执行前被卸载
→ 实时Registry找不到Tool
→ UNKNOWN_TOOL
```

因此：

```text
模型看到的Tool Schema：按Step冻结
真正执行的Tool Registry：仍然动态
```

两者之间存在短暂竞态。可能的处理方式包括阶段内固定Plugin Set、为Plugin增加执行租约，或允许失败后在下一Step重新规划。

## 七、卸载不等于模型忘记

Plugin卸载包含三个层次：

|层次|含义|当前情况|
|---|---|---|
|执行层|Tool、Service和进程不能再执行|可以通过Disposer完成|
|发现层|下一Step不再展示Tool或Skill|可以完成|
|上下文层|模型不再看到旧Prompt和Skill正文|不能自动完成|

System Prompt和Tool Schema可以在下一Step重新组装时删除，但会改变请求前缀。Skill目录为了保持Append-only，会追加一条新目录声明旧目录失效；已经加载的Skill正文仍留在History，直到Compaction将其遮蔽。

这里存在一个实际取舍：

```text
真正删除旧上下文
→ 语义干净，但Cache失效较多

追加失效通知
→ Cache友好，但模型仍然看过旧信息
```

Sub-Agent提供了更清楚的作用域：任务相关Plugin、Prompt、Tools和History都放在独立Session中，任务结束后整体关闭，只把最终结果返回主Agent。但它也会增加新的Prefill和父子通信成本。

## 八、源码给出的答案

- System Prompt和Tool Schema由同一套Prompt Assembly组装；
- Tools采用确定性排序；
- 每个Step生成并冻结一份模型请求；
- Session Log保存消息和完整请求Header；
- DeepSeek Adapter可以读取`cacheReadTokens`；
- Compaction会复用原System、Tools和History头部；
- Code Mode原生只暴露`run_code`，但完整Tools SDK仍在System Prompt中；
- Skill和Runtime Context变化采用追加式完整替换。

## 九、对产品和我们的启发

DeepSeek Harness已经把Plugin、Tool、Prompt、Session和缓存问题连接在一起。结合WorkBuddy的产品实践，可以得到三个判断：

1. **渐进式能力加载是真实需求。** 能力太多会增加上下文成本和选择干扰；
2. **动态Plugin Retrieval是否必要尚未确认。** 产品可能只需要由人预装Plugin，再在运行时检索Skill和Tool；
3. **能力选择必须与执行结果一起评价。** 只看Recall不够，还要看任务完成、权限、延迟、缓存和失败恢复。

因此，能力检索不能只优化“找得准不准”，还要考虑：

```text
暴露多少能力
能力集合变化多频繁
模型请求需要重新Prefill多少
执行状态是否和模型视图一致
任务结束后能否清理运行时和上下文
```

当前比较合理的候选方案是：**任务阶段开始时选择并加载一组能力，阶段内保持稳定，阶段完成后统一收尾。** 但在做实验前，应先向产品团队确认能力检索发生在Plugin、Skill还是Tool层，以及当前最主要的问题究竟是能力选错、上下文成本、冷启动、权限还是任务完成率。

更完整的架构、源码链路和实验设计见《DeepSeek Harness完整调研》。
