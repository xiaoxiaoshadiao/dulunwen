# 面向动态 Agent Harness 的运行时能力组合

> 问题定义、相关工作、评测指标与公开数据资源清单  
> Working title: **Learning to Compose Runtime Capabilities under Changing Environments**  
> 调研日期：2026-08-13

## 0. 如何阅读这份文档

### 0.1 一分钟版本

当前要验证的研究问题是：

> 给定用户任务、运行环境、当前 Harness 状态和插件目录，系统能否生成一个依赖闭合、策略可行、成本受控、可以执行并在任务后安全撤销的插件配置增量？

它与普通 Tool Retrieval 的区别在于：Tool Retrieval 默认能力已经被安装和暴露；这里研究的是哪些能力应当进入运行时，以及进入后如何形成合法组件图。

目前只能把它视为待验证假设。依赖图检索、多 Skill 组合、动态工具检索、执行效果评测和 Harness 对比均已有相邻工作。是否还需要独立的“运行时状态条件插件组合”任务，必须由反事实环境、真实执行和生命周期数据证明。

### 0.2 叙事顺序

正文按以下顺序展开：

```text
对象区别与研究边界
-> 一个贯穿全文的运行时例子
-> 问题输入、输出和约束
-> 为什么独立 Top-K 不够
-> Cordis 提供什么运行时语义
-> 方法假设
-> 指标与数据
-> Baselines、实验、风险和下一步
```

完整的 Cordis 形式定义放在附录 A，论文 PDF 和数据资源清单放在附录 B、C。第一次讨论时可以只读正文；需要核查定义和假设时再进入附录。

### 0.3 当前资产状态

- 已归档 17 篇相关论文 PDF；
- 已记录公开数据、代码、Registry 和 Marketplace 入口；
- 数据集、模型权重、插件包与容器镜像尚未下载；
- 本文不预设投稿 venue，也不预设问题一定成立。

---

## 1. 从信息检索到运行时能力组合

### 1.1 Document、Skill、Tool 与 Plugin

| 对象 | 主要内容 | 被选中后的直接结果 | 主要风险 |
|---|---|---|---|
| Document | 事实、证据、参考文本 | 进入模型上下文 | 噪声、冲突证据、上下文成本 |
| Skill | 程序性说明、脚本和资源 | 改变模型处理任务的方式 | 错误流程、指令污染、调用偏差 |
| Tool | 已暴露的原子调用接口 | 执行一次外部操作 | 参数错误、权限和外部副作用 |
| Plugin | 可安装的运行时组件，可提供 tools/services/policies/skills | 改变 Harness 组件图和能力边界 | 依赖、版本、权限、资源、生命周期和供应链问题 |

Plugin Retrieval 因此不能只把插件 README 当成文档。候选结果最终会进入运行时，可能注册工具、启动进程、绑定服务、读取凭据、改变权限策略，并产生需要回收的副作用。

### 1.2 暂用的问题名称

建议将任务称为：

> **Runtime-Conditioned Plugin Composition (RCPC)**  
> 运行时状态条件下的插件组合

问题不是“从目录中搜索几个相关插件”，而是：

> 给定用户任务、当前运行环境、当前 Harness 组件图和插件目录，生成一个依赖闭合、策略可行、成本受控、可以执行并能够安全撤销的运行时配置增量。

### 1.3 当前用于区分相邻工作的命题

> Existing tool retrieval selects among capabilities that are already exposed.  
> Runtime capability composition decides which capabilities should enter the agent runtime in the first place.

中文表述：

> 工具检索是在已经暴露的能力中选择调用对象；插件组合决定哪些工具、服务、策略、权限和副作用获准进入当前 Agent 运行时。

### 1.4 为什么不能只做“插件依赖图检索”

以下相邻问题已经有直接工作：

- Tool Graph Retriever 已研究依赖图增强的工具检索；
- Graph RAG-Tool Fusion 已研究根工具检索后的依赖图扩展；
- SkillWeaver 已研究任务分解、Skill 检索与 DAG 组合；
- Dynamic Tool Dependency Retrieval 已研究随执行计划变化的动态工具检索；
- ToolOmni 已研究开放工具库中的主动检索与执行；
- DynamicMCPBench 已研究真实 MCP Server 上基于执行效果的评测；
- ToolGym 已提供工具、状态、约束层面的动态扰动；
- Harness-Bench 已证明 Harness 配置会显著影响最终任务表现。

因此，单独提出“图检索”“多插件组合”“运行时执行”或“状态扰动”都不足以形成清晰的新问题。当前文献中尚未看到由同一任务完整覆盖以下四个方面的工作：

1. **Environment-conditioned**：同一任务在不同环境中应产生不同的插件方案；
2. **Graph-valued output**：输出依赖闭合的配置图，而非平面 Top-K；
3. **Execution-verified supervision**：正负标签来自可重放执行，而非只来自 LLM 判断；
4. **Lifecycle-aware evaluation**：成功不仅是完成任务，还包括权限合规和卸载后的状态恢复。

---

## 2. 一个贯穿全文的例子

用户任务：

```text
检索指定主题的论文，下载 PDF，建立索引，生成调研报告。
```

在环境 A 中：

```text
允许外网；有学术搜索 API Key；已有远程向量数据库。
```

候选计划可能是：

```text
academic-search plugin
-> pdf-fetch plugin
-> remote-embedding provider
-> existing-vector-store binding
-> report-generation plugin
```

在环境 B 中：

```text
禁止外网；没有 API Key；本地已有论文镜像和 GPU。
```

同一个 query 应切换为：

```text
local-corpus-search plugin
-> local-pdf-loader
-> local-embedding provider
-> local-vector-store
-> report-generation plugin
```

在环境 C 中，如果文件系统只读，则“下载 PDF”本身不可执行，系统应选择只读分析方案或明确拒绝，而不是继续返回语义上相关但运行时不可行的插件。

这个例子贯穿后文的四个判断：

1. **相关性**：插件是否覆盖任务意图；
2. **组合性**：多个插件的 requires/provides 是否闭合；
3. **环境可行性**：权限、凭据、平台和资源是否允许；
4. **生命周期正确性**：任务结束后进程、连接、工具注册和临时状态能否回收。

因此，模型的输出不是固定 Top-K，而是对当前 Harness 的配置增量。

---

## 3. 把直觉写成问题定义

### 3.1 输入

对每个任务定义：

```text
q：用户任务

E：运行环境
   - OS、CPU 架构、运行时版本
   - 网络与 egress policy
   - 可用凭据与认证方式
   - CPU/GPU/内存
   - 文件系统和服务权限
   - 延迟、费用和资源预算

H：当前 Harness 状态
   - 已安装和已激活插件
   - 当前 provider bindings
   - Agent/session scope
   - 正在运行的任务
   - 当前 model、memory、tools、policy 组件

P：可用 Plugin Catalog
```

### 3.2 Plugin Contract

一个可组合插件不应只由 README 表示。建议定义：

```text
Plugin p = (
    descriptor,
    requires,
    provides,
    config_schema,
    permissions,
    platform_constraints,
    resource_cost,
    effects,
    disposer
)
```

- `descriptor`：自然语言描述、工具 schema、示例，用于语义检索；
- `requires/provides`：组件依赖契约；
- `config_schema`：可配置参数；
- `permissions`：文件、网络、凭据和外部服务权限；
- `platform_constraints`：OS、架构、语言运行时和版本；
- `resource_cost`：安装、冷启动、显存、内存、延迟和费用；
- `effects`：激活后会注册或修改的状态；
- `disposer`：卸载时的逆操作或补偿策略。

第一版论文应明确限定为 **executable capability plugins**：可以安装、提供工具或服务、具有运行时依赖的插件。Agent Loop、UI、完整 Session Store 等任意 Harness 内核替换可作为扩展实验，而不是第一版数据集必须覆盖的对象。

### 3.3 输出

输出不是 Plugin Set，而是配置计划：

```text
Plan π = (
    selected_plugins,
    dependency_bindings,
    configurations,
    scopes,
    activation_order,
    disposal_order
)
```

更接近工程接口的表示是 Harness 配置增量：

```text
f(q, E, H, P) -> ΔH
H' = Apply(H, ΔH)
```

其中 `ΔH` 可以包含：

```text
ADD plugin
KEEP plugin
REMOVE plugin
BIND capability -> provider
SET config
SET scope / isolation
SET permission policy
STOP
```

### 3.4 可行性约束

一个有效计划至少满足：

1. **Task sufficiency**：能力覆盖任务所需效果；
2. **Dependency closure**：每个 `requires` 都有合法 provider；
3. **Provider consistency**：互斥 provider 不发生冲突；
4. **Acyclic precedence**：依赖先后关系无不可解循环；
5. **Version/platform compatibility**：版本、OS、架构和运行时匹配；
6. **Policy feasibility**：权限不超过当前 policy；
7. **Resource feasibility**：资源、延迟和费用不超预算；
8. **Lifecycle feasibility**：插件可激活、可停用，副作用可撤销或补偿；
9. **Minimality**：避免不必要插件，尽量复用当前组件，减少 Harness churn。

### 3.5 优化目标

```text
最大化：
    任务完成概率
    + 语义覆盖
    + 插件集合兼容性

最小化：
    安装与冷启动成本
    + 执行延迟和费用
    + 权限及供应链风险
    + Harness 修改量
    + 不可逆副作用风险

同时满足所有硬约束。
```

---

## 4. 为什么独立 Top-K 不够

### 4.1 独立排序的不充分性

需要证明：当集合效用包含 complementarity、substitution 或 conflict 时，逐插件独立分数不能表示一般的最优插件集合。

构造示例：

```text
A、B、C 对 query 单独都相关；
A + B 存在 provider 冲突；
A + C 能组成完整流水线。
```

如果 `score(p | q, E)` 不依赖已经选择了哪些插件，它无法完整表达“选择 C 后 A 的边际价值”和“选择 B 后 A 的冲突”。这可形式化为非加性集合效用下独立 Top-K 的不可表示性。

### 4.2 组合复杂度

简化到以下情形：

```text
任务需要一组 capabilities；
每个 Plugin 覆盖若干 capabilities；
每个 Plugin 有成本；
目标是最低成本覆盖全部能力。
```

该问题可由 Weighted Set Cover 规约，因此已经是 NP-hard。加入依赖、provider、版本、权限和资源约束后只会更难。这一结果为“学习检索缩小搜索空间 + 确定性约束求解保证合法”的混合架构提供理论动机。

### 4.3 Counterfactual State

同一个 query 在不同环境中应选择不同 Plan：

```text
允许外网 + 有 API Key -> 远程搜索/模型插件；
禁止外网 + 有本地快照 -> 本地索引/模型插件。

有集群写权限 -> 诊断 + 修复插件；
只读权限 -> 只允许诊断插件。

Qdrant 已激活 -> 复用 Qdrant；
只有 Elasticsearch 已激活 -> 绑定 Elasticsearch provider。
```

由此定义两类一致性：

- **Relevant-state sensitivity**：影响可行性的环境变化应导致计划切换；
- **Irrelevant-state invariance**：无关状态变化不应扰动计划。

这应成为区别于普通 Tool Retrieval 的关键训练信号和评测维度。

---

## 5. Cordis：从候选插件到可控生命周期

上一节说明为什么候选插件必须按集合和环境判断；本节说明一个候选集合进入运行时后，还需要什么生命周期语义。完整定义和定理依赖见附录 A。

### 5.1 生命周期正确性

不必重新完整证明 Cordis 的演算，可以在明确假设下复用其结论：

- 依赖闭合且 precedence 无环；
- 原子 effect 的 inverse 正确；
- 跨组件 effects 独立，或顺序由依赖显式表达；
- provision 合法且组件数量有限。

在这些前提下，可说明插件图能够进入稳定状态，provider 先于 consumer 激活、晚于 consumer 退出，卸载后恢复到观察等价状态。

需要明确：Cordis 运行时只组合和调度作者提供的 inverse，并不会自动产生或验证 inverse；外部网络消息、支付、邮件等 emission 不属于严格可逆状态。

### 5.2 Cordis 论文：动态组合的理论来源与边界

核心参考：

> Yifan Shi, Wei Zhang, Tianyi Cui.  
> **A Programming Paradigm for Spatiotemporal Composability.**  
> Peking University / DeepSeek-AI，88 页技术论文。  
> PDF：https://github.com/cordiverse/paper/blob/main/paper.pdf

这篇论文不是插件检索论文，也没有提供插件检索数据。它讨论的是一个插件已经被选中并进入运行时之后，组件如何加载、依赖、退出和恢复。因此它更适合作为本项目的**运行时语义和评测边界**，而不是直接作为检索方法的先验结果。

#### 5.2.1 论文提出的两个维度

Cordis 将动态组合拆成两个相互独立但需要同时满足的维度：

```text
Temporal composability：
组件退出时，能否撤销它对共享环境造成的修改。

Spatial composability：
组件能否声明对其他组件的依赖，并在 provider
出现、消失或更换时自动调整生命周期。
```

论文将二者分别对应到：

```text
Revertible effects：
每次 context transformation 同时返回 inverse，
运行时记录并按 LIFO 顺序组合这些 inverse。

Reactive coeffects：
组件声明所需 dependency keys；
每次 Context 改变后，运行时重新判断依赖是
activating、deactivating 还是 neutral。
```

对本文问题的直接意义是：Plugin Contract 不能只有描述和工具 schema，还需要表达“它需要什么、提供什么、改变什么、如何退出”。

#### 5.2.2 Context、Component 与 Fiber

Cordis 的 Context 同时承载：

```text
当前状态
+ inverse accumulator
+ dependency / coeffect table
+ child contexts
```

组件可抽象为：

```text
Component = (
    requires,
    provides,
    effect
)
```

组件的一次运行时实例称为 Fiber，额外记录：

```text
parent
lifecycle state
committed dependency view
target dependency view
accumulated disposer
retirement state
```

与本文拟议形式的对应关系如下：

| Cordis 概念 | 本文中的含义 | 可观测数据 |
|---|---|---|
| Context | 环境 `E` 与当前 Harness 状态 `H` | OS、权限、providers、active graph、policy |
| Component | Plugin Contract | requires、provides、effect、disposer |
| Fiber | 一次 Plugin activation | instance id、scope、lifecycle、resource handles |
| Committed view | 激活时实际绑定的 providers | capability → provider instance |
| Target view | 当前环境下应该绑定的 providers | 环境变化后的候选 bindings |
| Effect accumulator | 当前插件已产生副作用的撤销链 | registrations、processes、timers、connections |
| Isolation realm | 不同 Agent/session 下的 provider 隔离 | workspace、credentials、memory、tool namespace |
| Interception metadata | 外层施加的调用约束 | read-only、path allowlist、budget、rate limit |

因此，本文中 `f(q, E, H, P) -> ΔH` 的输出可以直接解释为对 Context/Fiber 树的期望状态修改，而 Cordis Loader 负责把配置增量协调为运行时生命周期变化。

#### 5.2.3 生命周期和依赖顺序

Cordis 的完整生命周期包括：

```text
INACTIVE
  -> LOADING
  -> ACTIVE
  -> UNLOADING
  -> INACTIVE
```

关键语义不是简单的“依赖不存在就停止”，而是：

1. provider 激活后，consumer 才能激活；
2. consumer 记录激活时解析到的 provider identity；
3. provider 准备退出时，先停止向新 consumer 提供服务；
4. 已绑定 consumer 在 teardown 中仍可使用 committed provider；
5. consumer 全部退出后，provider 才执行自己的 inverse。

这为数据和指标提供了比“插件是否安装成功”更细的观察点：

- activation order 是否正确；
- dependency view 在一次 transition 内是否保持一致；
- provider replacement 是否触发正确范围的 reload；
- consumer teardown 是否先于 provider disposal；
- partial activation 失败后是否撤销已完成 effects。

#### 5.2.4 论文的主要形式结论

在其形式化假设下，Cordis 证明或讨论了：

1. **Preservation**：生命周期转换后 registry 仍保持结构合法；
2. **Recovery exactness**：卸载某组件只删除该组件的贡献，保留其他独立组件的贡献；
3. **Ordering**：provider 的活动区间包围 consumer 的活动区间；
4. **Resolution coherence**：一次 activation 不会混用两组 provider 解析；
5. **Progress**：无环、有限、effect steps 有界时，系统最终进入稳定状态；
6. **Confluence**：满足额外条件且无失败时，最终稳定状态等价于按最终配置从头装配一次。

这些结果支持把“最终配置图”作为 Plugin Composer 的输出，但不能直接证明某个学习模型能找到正确配置，也不能证明任意第三方插件均满足这些条件。

#### 5.2.5 保证成立所需的假设

文档与后续实验必须显式记录以下前提：

```text
所有要管理的共享交互都经过 Context；
每个原子 effect 提供正确 inverse；
跨组件 effects 独立，或顺序由 dependency 明确表达；
dependency precedence 无环；
组件和每次 activation 的步骤有限；
confluence 还要求 total provision 且没有 failed fiber。
```

当前 TypeScript 实现不会自动验证 inverse 是否真的正确，也不会阻止组件绕过 Context 直接访问 Node.js 文件系统、网络或全局变量。Context 能够做 capability mediation，但不能替代进程、容器或 Wasm sandbox。

#### 5.2.6 系统边界与不可逆操作

Cordis 区分：

```text
Acquisition：
打开连接、注册句柄、启动进程；
通常可以通过 close/unregister/kill 撤销。

Emission：
发送网络消息、写入外部共享存储、支付、发邮件；
一旦被外部观察，通常无法严格撤销。
```

对 emission 只能采用：

- 延迟提交；
- transaction / outbox；
- idempotency key；
- compensation；
- 人工审批。

因此，本文提出的 `Reversible Task Success` 必须限定在可观测系统边界内。对不可逆外部操作，应评测“未越权、未重复、补偿是否完成”，不能宣称恢复到物理相同状态。

#### 5.2.7 Cordis 对 benchmark 的具体约束

如果采用 Cordis 作为执行载体，建议每条任务记录：

```text
initial context snapshot
desired effects
selected plugin graph
provider bindings
activation trace
effect ledger
policy decisions
task effects
disposal trace
final observable snapshot
```

由此可计算：

- Dependency Closure；
- Ordering Violation；
- Provider Churn；
- Partial-Activation Rollback；
- Teardown Completion；
- Observable State Restoration；
- Reversible Task Success。

#### 5.2.8 与本研究的关系应如何表述

客观表述应是：

> Cordis 给出了动态组件组合的一套条件化运行时语义。本文考虑在任务和环境条件下学习生成满足类似契约的插件配置，并通过执行验证其可行性。

不应表述为：

```text
Cordis 已经证明插件检索问题成立；
Cordis 已经保证任意插件能够安全热替换；
使用 Cordis 就自动获得安全自演化；
Koishi 的 4000 个插件已经验证了本文拟议模型。
```

Koishi 案例只能说明这种组件抽象在一个 TypeScript 生态中被长期采用。论文也明确承认其证据是观察性案例，没有受控性能比较、开发效率评测或 Cordis v4 全部假设的生产验证。

---

## 6. 方法假设：State-Conditioned Plugin Composer

暂用方法名 `PlugR`，正式命名待后续确定。

### 6.1 Stage 1：Root Plugin Retrieval

编码以下信息：

```text
query
+ environment summary
+ current active graph summary
+ policy / budget
```

从大目录召回语义相关的根插件。该阶段追求高召回，不能承担完整依赖和安全决策。

### 6.2 Stage 2：Contract-Aware Graph Composition

构建异构图：

```text
Plugin nodes
Capability nodes
Environment nodes
Policy nodes
```

边包括：

```text
requires
provides
conflicts
already-active
version-compatible
permission-allows
platform-compatible
```

模型自回归生成配置动作或对候选计划评分。

### 6.3 Stage 3：Deterministic Verifier

确定性检查：

```text
dependency closure
acyclicity
version/platform
permissions
resource budget
provider conflicts
```

无效动作应在 constrained decoding 中 hard-mask，或在 verifier-guided beam search 中剔除。语义判断交给模型，结构可行性尽量不交给 LLM 猜测。

### 6.4 Stage 4：Execution Critic

在隔离运行时中：

1. 应用候选配置；
2. 检查插件激活与健康状态；
3. 执行任务；
4. 对照 effect checkpoints；
5. 触发卸载；
6. 检查 policy violation、teardown timeout 和状态泄漏。

训练目标可以包含：

```text
Root Retrieval Loss
+ Graph Action Loss
+ Feasibility Ranking Loss
+ Counterfactual Consistency Loss
+ Execution Preference Loss（可选）
```

---

## 7. 如何判断方案是否更好

### 7.1 检索层

- Root Recall@K
- Root NDCG@K
- Candidate efficiency / catalog reduction

### 7.2 组合图层

- Plugin Set Precision / Recall
- Graph Exact Match（仅作诊断）
- Dependency Edge F1
- Dependency Closure Rate
- Provider Binding Accuracy
- Minimality / Redundancy Rate

### 7.3 环境条件层

- Feasible@K
- Counterfactual Switch Accuracy
- Irrelevant-State Invariance
- Version / platform generalization

### 7.4 成本层

- Plugin Count Regret
- Installation Cost Regret
- Cold-Start Latency
- Harness Churn
- Token / tool-schema exposure cost

### 7.5 执行层

- Effect Completion
- End-to-End Task Success
- Minefield / forbidden action rate
- Action and tool-call efficiency

### 7.6 生命周期与安全层

建议定义 headline metric：

> **Reversible Task Success (RTS)**

一次运行只有同时满足以下条件才记为成功：

1. required effects 完成；
2. 没有权限或安全违规；
3. 插件正常停用和卸载；
4. 卸载后运行时状态与初始状态观察等价。

另外单独报告：

- Rollback Completeness
- Resource Leak Rate
- Teardown Timeout Rate
- Policy Violation Rate
- External Side-Effect Error

由于多个插件方案可能 effect-equivalent，最终评测应优先检查“是否产生正确效果且符合约束”，不能只检查是否等于唯一 gold Plugin Set。

---

## 8. 数据从哪里来、如何生成

建议拆成两个互补子集，避免“规模”和“真实执行”互相牺牲。

### 8.1 PlugBench-Retrieve

大规模静态目录：

```text
Catalog：2K–10K 真实 MCP / Koishi / Harness capability plugins
Tasks：数万条 query + environment + candidate graph
用途：语义召回、环境条件匹配、依赖补全和 hard-negative 训练
```

### 8.2 PlugBench-Execute

较小但完全可执行：

```text
100–200 个容器化 capability plugins
1K–2K 个执行任务
每条任务包含多个 environment variants
```

每个测试实例必须可以：

```text
安装 -> 激活 -> 执行 -> 验证 effect -> 卸载 -> 检查状态恢复
```

### 8.3 数据生成流水线

1. 从公开 Registry/Marketplace 获取 Plugin manifest；
2. 启动插件，枚举 tools/resources/prompts/config；
3. 用 explorer agent 在真实沙箱中完成任务并记录成功轨迹；
4. 从成功轨迹蒸馏 required effects、可替代 effects、partial order 与 minefields；
5. 生成反事实环境：凭据缺失、egress 变化、权限收紧、资源变化、provider 不可用、版本变化、已有 provider 变化；
6. 对每个新环境重新寻找成功 Plan，或由约束求解器和多次执行确认不可完成；
7. 保留结构化 Reject；
8. 在 deterministic replay 中重复验证；
9. 对测试集做多专家审核。

不能因为一个弱 Agent 执行失败就标注 `impossible`。不可行标签至少需要静态约束证明，或强 explorer、多次 replay 与人工审核共同确认。

### 8.4 Reject-as-Runtime-Signal

建议的失败标签：

```text
semantic_mismatch
dependency_unsatisfied
dependency_cycle
provider_collision
version_conflict
platform_incompatible
permission_denied
credential_missing
budget_exceeded
install_failed
activation_failed
health_check_failed
effect_failed
teardown_timeout
rollback_leak
task_failed
```

### 8.5 数据划分

- Plugin-disjoint split
- Composition-disjoint split
- Counterfactual-environment split
- Version / temporal split
- Cross-lingual split
- Long-chain and high-branching stress split
- Equivalent-provider split

---

## 9. Baselines 与关键实验

### 9.1 Flat Retrieval

- BM25
- BGE-M3 / Qwen Embedding
- ToolRet retriever
- R3-Embedding / R3-Reranker
- LLM listwise selection over retrieved candidates

### 9.2 Dependency-Aware Retrieval

- Graph RAG-Tool Fusion
- Tool Graph Retriever
- GTool
- Dynamic Tool Dependency Retrieval
- SkillWeaver

### 9.3 Agentic Retrieval and Execution

- ToolOmni
- ToolGym built-in FAISS retriever
- MCP-Atlas / MCP-Bench default exposure
- all-manifest LLM planner（仅小目录）

### 9.4 Constraint Baselines

- semantic root retrieval + deterministic dependency expansion
- solver-only contract composition
- LLM plan + post-hoc verifier
- oracle root plugin + learned composer
- learned root retriever + oracle contract solver

### 9.5 关键实验问题

1. **RQ1：环境状态是否改变正确插件选择？**  
   比较 query-only、query+environment、query+environment+current graph。

2. **RQ2：平面 Top-K 是否不如图组合？**  
   比较 flat retrievers、graph retrievers、constrained composer。

3. **RQ3：Plugin Contract 的哪些字段最有用？**  
   README only、+tool schemas、+requires/provides、+permission/platform、+lifecycle/effect。

4. **RQ4：Execution Reject 是否优于 LLM Reject？**  
   比较无 Reject、语义 Reject、静态 contract Reject、runtime Reject。

5. **RQ5：是否泛化到新插件、新版本和新组合？**  
   Plugin-disjoint、version split、composition-disjoint、long-chain。

6. **RQ6：是否真正完成且可恢复？**  
   同时报告 Task Success、RTS、资源泄漏、权限违规和冷启动成本。

---

## 10. 风险、边界与可证伪问题

### 10.1 “Plugin”定义过宽

第一版限定 executable capability plugin，不直接覆盖可替换 Agent Loop 或整个 UI。

### 10.2 MCP Server 不等于任意 Harness Plugin

论文必须说明 MCP Server 是一种具有清晰工具表面的 capability plugin 实例。更一般的 memory/policy/model-router 插件通过小规模 Harness case study 验证。

### 10.3 合成环境过于玩具化

环境扰动必须来自真实 contract、服务器错误、权限策略或生产 trace；测试集由真实容器执行和人工审核。

### 10.4 唯一 Gold Plan 不成立

使用 effect checkpoints、equivalent providers 和 cost/risk constraints 定义等价成功方案，不强制匹配唯一工具链。

### 10.5 LLM 生成偏差

训练 query 可由多模型生成；测试 query 采用真实 benchmark query、多人改写和专家审核。正负可行性以执行和确定性验证为主。

### 10.6 研究范围滑向纯系统工作

如果最终以机器学习论文组织，主线需要包含可验证的学习问题，而不能只实现一套插件系统：

```text
新的学习问题
+ counterfactual state supervision
+ state-conditioned graph composer
+ executable benchmark
```

Cordis runtime 和配置系统作为语义与执行载体，而不是全文唯一贡献。

### 10.7 对研究问题的可证伪要求

加入 Cordis 定义后，本文至少应回答以下经验问题：

1. 现实 MCP/Koishi/Harness 插件能否抽取出足够完整的 `requires/provides/effect/disposer`；
2. 多数任务的环境变化是否真的改变最优 Plugin Plan，还是简单规则已经足够；
3. 独立 retriever 的错误是否主要来自集合冲突，而不是描述质量差；
4. contract verifier 是否能预测实际 activation failure；
5. disposer/state restoration 是否可稳定测量；
6. 使用生命周期监督是否提高任务完成率，还是只增加系统复杂度；
7. Cordis 的独立性、无环和 total provision 假设在真实插件中有多大比例成立。

如果这些问题的实证结果不支持假设，应缩小问题范围，而不是用理论定义替代实验。

---

## 11. 可能的论文形态与下一步

当前内容只构成一个研究方案。能否形成论文取决于三个先验验证：环境变化是否实质改变最优方案、真实插件是否能抽取稳定契约、学习式 composer 是否优于规则与约束求解器。

### 11.1 可能的贡献结构

1. **Problem**：明确界定 Runtime-Conditioned Plugin Composition，并通过文献与实验验证该定义是否必要；
2. **Theory**：独立排序不充分、组合 NP-hard、contract/lifecycle 可行性；
3. **Data**：PlugBench-Retrieve + PlugBench-Execute；
4. **Generation**：forward execution、effect distillation、counterfactual environment、typed rejects；
5. **Method**：state-conditioned root retriever + constrained graph composer + execution critic；
6. **Metrics**：Counterfactual Plan Consistency 与 Reversible Task Success；
7. **Evidence**：大目录检索、真实容器执行、生命周期恢复和跨环境泛化。

### 11.2 下一步

1. 核实所有论文 PDF、代码仓库与数据许可；
2. 为 MCP Server、Koishi Plugin 和 dsh bundle 设计统一的最小 Plugin Contract；
3. 先用 MCP-Bench 的 28 个 Server 做可执行原型；
4. 将 MCP-Bench 每个任务改造成“server 未预挂载”的 Plugin Retrieval 设置；
5. 为同一 query 构造网络、凭据、权限和 provider 状态的反事实环境；
6. 实现 flat retrieval、dependency expansion 和 constraint solver 三个最小 baseline；
7. 验证任务是否真的需要学习式 composer，而不是纯规则即可解决；
8. 通过后再扩到 MCP-Atlas、ToolGym 和更大的 MCP Registry catalog。

---

## 附录 A. Cordis 的关键定义、假设与定理依赖

本节尽量保留 Cordis 论文的定义结构，但改写成便于工程讨论的纯文本形式。编号 `D1`–`D12` 是本文为了引用方便添加的，不是原论文编号；括号中同时给出原论文的 Definition/Theorem 编号。

### A.1 基础记号

```text
Γ：
系统希望纳入动态组合边界的状态空间。

γ ∈ Γ：
某一时刻的具体系统状态。

f : Γ -> Γ：
一个正向状态变换。

g : Γ -> Γ：
与某次正向变换配对的 inverse。

K：
依赖或 capability keys 的集合。

V_k：
key k 对应的 value/interface 类型。

≈ / ≃：
观察等价关系；不要求底层物理表示完全一致。
```

### A.2 D1：Effect Context（原 Definition 2–7）

论文首先把“当前状态”和“已经积累的撤销逻辑”放在一起：

```text
EffectContext(Γ) = Γ × (Γ -> Γ)
```

一个 Effect Context 写成：

```text
(γ, φ)

γ：当前状态
φ：inverse accumulator
```

初始状态：

```text
(γ0, identity)
```

对正向变换 `f` 和候选 inverse `g`，运行时跟踪操作是：

```text
track(f, g)(γ, φ)
    = (f(γ), φ ∘ g)
```

恢复操作是：

```text
recover(γ, φ)
    = (φ(γ), identity)
```

关键点不是单个 `g` 能撤销，而是 inverse 会随执行自动组合。若先执行 `f1` 再执行 `f2`，撤销时执行顺序必须反过来：

```text
forward： f1 -> f2
inverse： g2 -> g1
```

### A.3 D2：Revertible Effect Function（原 Definition 8–16）

实际系统通常无法提前为 `f` 固定一个适用于所有状态的 inverse，因此论文让 inverse 在 effect 应用时产生：

```text
e : Γ -> (Γ, Γ -> Γ)
```

在状态 `γ` 上：

```text
e(γ) = (δ, g)
```

含义：

```text
δ：执行 effect 后的新状态
g：只需要对这次执行产生的 δ 正确
```

Witness 条件：

```text
g(δ) ≈ γ
```

这里是左逆要求：

```text
先执行 effect，再执行 inverse，可以恢复；
不要求先执行 inverse，再执行 effect 有意义；
也不要求 g 对所有可能状态都是 f 的全局逆。
```

两个 effect 的组合：

```text
先运行 e2：
    e2(γ) = (δ, s)

再运行 e1：
    e1(δ) = (ε, t)

组合结果：
    (e1 ⋄ e2)(γ) = (ε, s ∘ t)
```

执行组合 inverse 时会先运行 `t`、再运行 `s`，即 LIFO。

### A.4 D3：Effect Independence（原 Definition 17–21）

仅有 LIFO 可以安全撤销一个组件内部的 effect 序列，但不能自动保证在多个组件交错执行后任意卸载其中一个。

论文为 effect `e` 定义 transformation monoid：

```text
M(e) =
由 e 的 forward map
+ e 在不同状态可能返回的所有 inverses
生成的变换集合。
```

两个 effects `e1`、`e2` 独立，需要同时满足：

```text
1. M(e1) 中任一变换与 M(e2) 中任一变换可交换：

   a ∘ b ≈ b ∘ a

2. 另一个 effect 的变换不会改变当前 effect 会返回哪个 inverse：

   inverse_of_e1(b(γ)) ≈ inverse_of_e1(γ)

   反方向同样成立。
```

第二条比普通“最终状态可交换”更强，因为一个 effect 可能根据当前状态选择不同 disposer 或 continuation。

这一定义在工程上对应：

```text
注册两个不同名称的无序工具：
通常可能独立。

向有序 middleware chain 插入两个处理器：
通常不独立。

修改同一个全局计数器：
取决于 operation 和 observational equivalence。
```

论文后续的全局 recovery/confluence 结论依赖这种独立性，但 Cordis TypeScript 运行时不会自动证明它。

### A.5 D4：Coeffect Context（原 Definition 22–24）

依赖环境定义为带类型的有限 partial map：

```text
Σ = (k : K) ⇀ V_k
```

即：

```text
每个 key k 如果存在，
其 value 必须属于对应类型 V_k。
```

基本操作：

```text
get(k)(σ) = σ(k)

set(k, v)(σ)
    = (
        σ[k -> v],
        inverse = 删除 k
      )
```

因此“提供一个依赖”本身也是 revertible effect：

```text
注册 provider -> inverse 是撤销 provider。
```

论文进一步把一个 coeffect key 定义为三元组：

```text
Coeffect(k) = (
    V_k,
    equivalence_k,
    operations_k
)
```

- `V_k`：接口或 value 类型；
- `equivalence_k`：通过该接口观察时，哪些内部状态视为相同；
- `operations_k`：组件通过该 capability 可以执行的操作。

这说明 capability 不只是一个任意对象引用，还应定义可观察行为和等价边界。

### A.6 D5：Coeffect Specification 与通知（原 Definition 25–26）

组件声明依赖集合：

```text
d ⊆ K
```

当前环境满足依赖：

```text
σ satisfies d
    iff
对每个 k ∈ d，k 都存在于 σ。
```

一次 Context 变化 `σ -> σ'`，针对组件 `d` 分类为：

```text
activating：
    变化前不满足，变化后满足

deactivating：
    变化前满足，变化后不满足

neutral：
    其他情况
```

运行时行为：

```text
activating -> 执行组件 effects
deactivating -> 执行 accumulator
neutral -> 不切换生命周期
```

注意：该基础定义只检查 key presence。版本、权限、平台、资源预算等约束需要扩展 satisfaction predicate，不能假设原始 Cordis 定义已经覆盖。

### A.7 D6：Isolation（原 Definition 27–29）

为了让同一逻辑 key 在不同子 Context 中解析到不同 provider，论文引入 realm：

```text
IsolationContext = (
    key_to_realm,
    realm_to_value
)
```

解析过程：

```text
key k
  -> realm r = key_to_realm(k)
  -> value = realm_to_value(r)
```

不同 Agent/session 可以让相同的 `filesystem`、`credentials`、`memory` key 指向不同实例。

Isolation 通常通过派生 child Context 实现，不修改父 Context 的共享表。销毁 child Context 即可撤销这层解析，不需要额外 inverse。

### A.8 D7：Interception（原 Definition 30–31）

Interception 不改变：

```text
key 最终解析到哪个 provider
```

而是改变：

```text
调用 provider 时附加哪些 metadata / policy。
```

可以理解为：

```text
effective_metadata
    = component_declared_metadata
      merge
      context_enforced_metadata
```

外层 Context 的约束可以覆盖组件声明，例如：

```text
filesystem path allowlist
read-only database
token / cost budget
rate limit
audit tag
```

这是一种 capability mediation，不是恶意代码沙箱。组件若能绕过 Context 直接调用宿主 API，interception 无法阻止。

### A.9 D8：Unified Recursive Context（原 Definition 32）

论文把 effect accumulator 和 coeffect table 统一成递归 Context：

```text
Context =
    current_context_state
    × inverse_accumulator
    × coeffect_table
```

由于 `current_context_state` 自身也是 Context，因此结构可以递归形成父子树：

```text
root Context
├── plugin A Context
│   ├── plugin A1 Context
│   └── plugin A2 Context
└── plugin B Context
```

加载子组件是父 Context 上的 effect；卸载父组件会退休其子组件并回收它们的 effects。

### A.10 D9：Observational Equivalence（原 Definition 33–42）

物理状态通常无法逐字节恢复，例如：

```text
malloc 后 free，heap layout 不一定相同；
删除随机生成的 handle 后，计数器可能已经前进。
```

论文不要求物理相等，而要求正式 coeffect operations 无法区分：

```text
σ ≃ σ'
    iff
两者包含相同 keys，
且每个 key 上的 values 按 equivalence_k 等价。
```

因此“完全恢复”应准确表述为：

```text
恢复到系统正式观察接口下不可区分的状态。
```

选择什么 observation interface 会直接决定什么可以被称为恢复。Benchmark 如果只比较文件摘要，就不能据此声称进程、网络或外部数据库状态也已恢复。

### A.11 D10：Component（原 Definition 43）

组件定义为：

```text
Component = (
    d,
    p,
    e
)
```

其中：

```text
d：requires / coeffect specification
p：可能提供的 capability keys
e：带 witness 的 effect function / iterator
```

这与本文 Plugin Contract 的最小核心一致，但本文还需要补充 descriptor、版本、平台、权限、配置和成本，才能支持检索与现实部署。

### A.12 D11：Fiber、Registry 与 Target View（原 Definition 44–50）

Fiber 是 Component 的一次实例化，包含：

```text
requires d
provides p
effect e
parent π
local coeffect table σ
retirement flag τ
lifecycle state θ
accumulator g
committed view ω
```

`committed view` 记录组件激活时每个依赖实际绑定到哪个 provider identity。

`target view` 表示当前环境下它应该绑定到谁：

```text
如果组件已退休：
    target = inactive

如果任何 dependency 不满足：
    target = inactive

否则：
    target = {
        dependency key -> current provider fiber id
    }
```

生命周期由 `committed view` 与 `target view` 是否一致驱动：

```text
没有 committed view，但 target 可用：
    开始 activation

committed view 与 target 不同：
    开始 deactivation，之后按新 target 重载
```

记录 provider identity 而不是仅比较 provider value，保证“新旧 provider 返回相等对象”仍会被识别为 provider replacement。

### A.13 D12：Effect Iterator 与完整生命周期（原 Definition 49–53）

现实 activation 不是一个原子步骤。论文使用 effect iterator，让每个步骤返回：

```text
new_state
inverse_for_this_step
optional_continuation
```

完整 lifecycle states：

```text
INACTIVE
LOADING / RELOADING
ACTIVE
UNLOADING
```

十类 operational rules：

| 类别 | Rule | 含义 |
|---|---|---|
| Orchestration | O-Insert | 注册一个新 Fiber |
| Orchestration | O-Retire | 请求 Fiber 退出 |
| Orchestration | O-Remove | Fiber 完全 inactive 后删除记录 |
| Activation | L-Begin | 依赖满足后开始加载 |
| Activation | L-Iter | 执行一个 effect step 并累计 inverse |
| Activation | L-Finish | effect iterator 完成，进入 ACTIVE |
| Activation abort | L-Divert | target 变化，转入回滚 |
| Activation failure | L-Raise | effect 报错，转入回滚并记录错误 |
| Deactivation | L-Leave | 停止向新 consumer 提供服务 |
| Deactivation | L-Unload | dependents 排空后执行 accumulator |

异步步骤具有 inertia：

```text
一旦启动，不能假设它可以瞬间取消；
即使依赖在执行中变化，也要让当前步骤落地，
拿到 inverse 后再回滚。
```

### A.14 形式结论的假设矩阵

| 结论 | 原论文编号 | 关键假设 | 能支持的工程表述 | 不能推出 |
|---|---:|---|---|---|
| Registry Preservation | Theorem 59 | 每步遵守 calculus rules，registry 初始良构 | 生命周期转换不产生悬空 parent/provider 引用 | 任意手写插件代码都不会破坏 registry |
| Recovery Exactness | Theorem 61 | effects pairwise independent；inverse witness 成立 | 卸载一个 Fiber 只撤销它自己的贡献 | 非交换共享状态也能任意顺序卸载 |
| Terminal Recovery | Corollary 62 | 同上；episode 正常结束、转向或失败后执行 accumulator | 部分加载失败不会保留已跟踪 effects | 未经 Context 的外部 effects 会被回收 |
| Provider/Consumer Ordering | Theorem 63 | committed view、withdrawal guard、依赖解析合法 | provider 先启动后退出；consumer teardown 期间仍可读旧 binding | 网络 provider 永不失效或 teardown 一定及时完成 |
| Resolution Coherence | Theorem 64 | target view 检查、iterator boundaries、landing 后回滚 | 一次 activation 不会把两组 dependency resolution 混合为成功状态 | 异步步骤可以无条件取消 |
| Progress | Theorem 66 | dependency precedence 无环；Fiber 集有限；iterator 长度有界 | 生命周期不会因依赖排空协议永久无规则可走 | 外部 Future 一定返回；真实程序不会无限生成子组件 |
| Confluence | Theorem 73 | pairwise independence；total provision；无 failed Fiber；达到 quiescence | 最终稳定状态等价于按最终配置重新装配 | 失败调度、外部 emissions 或中间可见轨迹都相同 |

### A.15 全局假设清单

后续如果引用 Cordis 作为理论依据，至少需要逐项声明：

| 假设 | 含义 | 在数据/系统中如何检查 |
|---|---|---|
| A1 Context boundary | 所有需要保证的共享交互经 Context | 静态扫描、API wrapper、sandbox syscall/trace |
| A2 Correct inverse | 每个 atomic effect 的 disposer 能恢复该次 effect | property test、故障注入、前后状态比较 |
| A3 Confinement | 组件只读已声明 coeffects，只写自己的 state/provisions | capability mediation、scope audit |
| A4 Provision discipline | provider identity 和 key/realm 关系合法 | contract validator |
| A5 Effect independence | 跨组件正向和逆向变换可交换，inverse 选择稳定 | pairwise execution test；无法证明时显式排序 |
| A6 Acyclic precedence | dependency ordering 无环 | graph cycle detection |
| A7 Finiteness | Fiber 集和每次 effect iterator 有界 | task/plugin budget、depth limit |
| A8 Total provision | ACTIVE 组件实际提供其声明的全部 keys | post-activation contract check |
| A9 No failed Fiber | confluence 结论排除最终 failed Fiber | health check、failure-aware metric |
| A10 Defined equivalence | 明确哪些 observable states 必须恢复 | benchmark state schema、hash/checkpoint |
| A11 External emission policy | 不可逆外部操作被延迟、幂等化或补偿 | outbox、idempotency、approval、compensation log |
| A12 Runtime termination | teardown/future 有 timeout 与隔离策略 | deadline、kill boundary、sandbox reset |

其中 A12 是现实系统补充要求，不是论文 Progress 定理自动提供的保证。论文抽象假设异步步骤最终落地；真实网络调用可能永久挂起。

### A.16 从定义到本文任务变量

```text
Cordis Γ / Context
    -> 本文 (E, H)

Cordis Component
    -> Plugin Contract

Cordis Fiber registry
    -> current active plugin graph

Cordis target view
    -> verifier 对候选 ΔH 计算的期望 provider bindings

Cordis lifecycle trace
    -> activation/disposal supervision

Cordis observational equivalence
    -> Reversible Task Success 的 final-state 判定
```

这一映射需要通过实现和数据验证，不能只凭符号相似就认定成立。

---

## 附录 B. 相关论文归档清单

论文 PDF 下载到远程目录 `papers/`。本表给出官方来源和本地文件名。

| # | 论文 | 官方链接 | 本地 PDF |
|---|---|---|---|
| 01 | A Programming Paradigm for Spatiotemporal Composability | https://github.com/cordiverse/paper/blob/main/paper.pdf | `01-cordis-spatiotemporal-composability.pdf` |
| 02 | Skill Is Not Document | https://arxiv.org/abs/2606.03565 | `02-r3-skill-routing.pdf` |
| 03 | Compositional Skill Routing for LLM Agents | https://arxiv.org/abs/2606.18051 | `03-compositional-skill-routing.pdf` |
| 04 | Tool Graph Retriever | https://arxiv.org/abs/2508.05152 | `04-tool-graph-retriever.pdf` |
| 05 | Graph RAG-Tool Fusion | https://arxiv.org/abs/2502.07223 | `05-graph-rag-tool-fusion.pdf` |
| 06 | GTool: Graph Enhanced Tool Planning | https://arxiv.org/abs/2508.12725 | `06-gtool.pdf` |
| 07 | Dynamic Tool Dependency Retrieval | https://aclanthology.org/2026.findings-acl.1680/ | `07-dynamic-tool-dependency-retrieval.pdf` |
| 08 | Retrieval Models Aren't Tool-Savvy (ToolRet) | https://arxiv.org/abs/2503.01763 | `08-toolret.pdf` |
| 09 | ToolOmni | https://arxiv.org/abs/2604.13787 | `09-toolomni.pdf` |
| 10 | C-World / ToolGym | https://arxiv.org/abs/2601.06328 | `10-c-world-toolgym.pdf` |
| 11 | ToolSandbox | https://arxiv.org/abs/2408.04682 | `11-toolsandbox.pdf` |
| 12 | MCP-Atlas | https://arxiv.org/abs/2602.00933 | `12-mcp-atlas.pdf` |
| 13 | MCP-Bench | https://arxiv.org/abs/2508.20453 | `13-mcp-bench.pdf` |
| 14 | ETOM / MSC-Bench | https://arxiv.org/abs/2510.19423 | `14-etom-msc-bench.pdf` |
| 15 | DynamicMCPBench | https://arxiv.org/abs/2607.20531 | `15-dynamic-mcp-bench.pdf` |
| 16 | Harness-Bench | https://arxiv.org/abs/2605.27922 | `16-harness-bench.pdf` |
| 17 | ToolBench | https://arxiv.org/abs/2307.16789 | `17-toolbench.pdf` |

---

## 附录 C. 公开数据集与代码资源入口（当前不下载）

### C.1 Skill / Tool Retrieval

| 资源 | 规模与内容 | 官方入口 | 可用于本项目 |
|---|---|---|---|
| R3-Skill | 10,246 skills；41,592 WRITE queries；32,828 SKIP；中英四方向 | https://github.com/Tencent/R3-Skill | 语义兼容性预训练、Reject taxonomy |
| SkillRet | 10,123 train skills；6,660 test skills；63,259 train queries；4,997 test queries | https://github.com/ThakiCloud/SKILLRET | 大规模 Skill Retrieval baseline |
| SkillRet HF | Hugging Face 数据入口 | https://huggingface.co/datasets/ThakiCloud/SKILLRET | 数据下载入口，暂不下载 |
| ToolRet | 43K tools；7.6K eval tasks；200K+ train instances | https://github.com/mangopy/tool-retrieval-benchmark | 大规模 Tool Retrieval 预训练与 baseline |
| ToolRet HF collection | ToolRet 数据集合 | https://huggingface.co/collections/mangopy/tool-retrieval | 数据下载入口，暂不下载 |
| ToolLinkOS | 573 fictional tools；1,569 instances；平均 6.3 dependencies/tool | https://github.com/EliasLumer/Graph-RAG-Tool-Fusion-ToolLinkOS | 依赖图 baseline 与图指标 |
| TDI300K | 约 300K tool dependency pairs；论文中由代码函数和 LLM 生成 | https://arxiv.org/abs/2508.05152 | 依赖边识别预训练；需核实正式数据下载入口 |
| CompSkillBench | 2,209 MCP skills；300 compositional queries；GT chains | https://arxiv.org/abs/2606.18051 | 组合 query 与顺序种子；论文未给出可靠官方代码入口 |

### C.2 Executable Tool / MCP Benchmarks

| 资源 | 规模与内容 | 官方入口 | 可用于本项目 |
|---|---|---|---|
| MCP-Atlas | 36 real MCP servers；220 tools；1,000 tasks；500 public | https://arxiv.org/abs/2602.00933 | 容器化可执行核心、跨 server tasks |
| MCP-Atlas leaderboard | 公开评测入口 | https://labs.scale.com/leaderboard/mcp_atlas | 任务协议与基线信息 |
| MCP-Bench | 28 MCP servers；250 tools；104 single/multi-server tasks | https://github.com/accenture/mcp-bench | 第一版可执行 world，代码和 server 较完整 |
| DynamicMCPBench | 121 live servers；1,845 tasks；effect checkpoints；partial order | https://arxiv.org/abs/2607.20531 | 最接近 execution-grounded generation；代码/数据标注为 publication 时发布 |
| ETOM / MSC-Bench | 491 servers；2,375 tools；equal function sets | https://arxiv.org/abs/2510.19423 | 等价 provider 与多方案评测；需核实代码入口 |
| ToolGym | 204 applications；5,571 tools；状态/约束扰动；动态 MCP loading | https://github.com/Ziqiao-git/ToolGym | Counterfactual environment 与 robustness |
| ToolSandbox | 约 34 stateful tools；1,032 scenarios；milestones/minefields | https://github.com/apple/ToolSandbox | 状态依赖、执行里程碑和 minefield |
| ToolBench | 16,464 APIs；126K+ instances | https://github.com/OpenBMB/ToolBench | 大规模工具语义和调用链数据 |
| LiveMCPBench | 大规模 MCP toolset、真实任务和 Docker 环境 | https://github.com/icip-cas/LiveMCPBench | 补充大目录工具导航与执行 |

### C.3 Plugin Catalog / Marketplace

| 资源 | 可获得字段 | 官方入口 | 备注 |
|---|---|---|---|
| Official MCP Registry | server name/title/description/version/package/transport/env/auth/repository | https://registry.modelcontextprotocol.io/ | 主要真实 Plugin Catalog |
| MCP Registry API | `/v0.1/servers`、版本详情、增量同步 | https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/api/official-registry-api.md | 可做可重复抓取 |
| MCP `server.json` schema | package、transport、env variables、remote URL、repository | https://github.com/modelcontextprotocol/registry/blob/main/docs/reference/server-json/generic-server-json.md | 统一 Plugin manifest 的初始来源 |
| Koishi Plugin Registry mirror | npm package、版本、描述、manifest、publisher 等 | https://koishi-shangxue-plugins.github.io/koishi-registry-aggregator/market.json | 官方 `registry.koishi.chat/index.json` 当前不稳定；镜像同步官方索引。真实 Cordis 插件生态，任务标签缺失 |
| Koishi registry code | Registry 更新和部署逻辑 | https://github.com/koishi-actions/registry | 用于理解抓取与许可 |
| DeepSeek Harness | 230+ workspace packages；Cordis config/bundles/contracts | https://github.com/deepseek-ai/deepseek-harness | 最贴近 Harness Plugin，但目录规模较小 |
| dsh plugin topic | 社区 Harness 插件发现入口 | https://github.com/topics/dsh-plugin | 当前数量和质量需要后续抓取 |
| VS Code Marketplace | extension metadata、版本、平台、下载、依赖/extension packs | https://github.com/microsoft/vscode-vsce/blob/main/src/publicgalleryapi.ts | 实际查询端点为 POST `/_apis/public/gallery/extensionquery`；API 未正式文档化 |
| VS Code manifest spec | `extensionDependencies`、`extensionPack`、engines、contributes | https://code.visualstudio.com/api/references/extension-manifest | 可做外部生态依赖图 |

### C.4 软件依赖与版本图

| 资源 | 内容 | 官方入口 | 备注 |
|---|---|---|---|
| Libraries.io | 多生态 package metadata/dependency/license；站点当前索引近千万 packages | https://libraries.io/ | 依赖和许可分析，元数据未经人工验证 |
| Libraries.io open data | 历史数据下载入口 | https://libraries.io/data | 后续核实许可与最新快照 |
| npm-follower | npm 全量历史与已删除版本研究数据 | https://github.com/donald-pinckney/npm-follower | 数据站原入口 `dependencies.science` 当前 DNS 不稳定；先记录代码和论文入口 |
| deps.dev | package/version/dependency/advisory 数据 | https://deps.dev/ | 版本、漏洞、依赖边与来源仓库 |

### C.5 Harness 与运行时评测

| 资源 | 内容 | 官方入口 | 可用于本项目 |
|---|---|---|---|
| Harness-Bench | 106 sandboxed tasks；6 harnesses × 8 model backends；5,194 traces | https://arxiv.org/abs/2605.27922 | 证明 Harness 配置影响；可借鉴环境/安全/过程指标 |
| Cordis paper | Revertible effects、reactive coeffects、动态组合演算 | https://github.com/cordiverse/paper/blob/main/paper.pdf | 生命周期理论基础 |
| Cordis implementation | Context/effect/coeffect/fiber runtime | https://github.com/cordiverse/cordis | 可执行 Plugin composition runtime |
