# DeepSeek Harness完整调研

> 源码版本：官方`master`提交`47f943859bef60e4160492346772ded9b24f765a`，`0.1.0-rc.5`，开发者预览阶段。
>
> 本文只记设计事实：每一条都给出"这里怎么设计的"加对应源码位置，关键处贴原始代码。不作展开解释，判断集中在最后一节。

## 一、定位与组装方式

**它不是模型，是模型外面的Agent运行框架。** 模型负责生成文本和Tool Call，Harness负责组装上下文、暴露能力、执行操作、记录状态、处理权限与恢复。

**一切皆插件，基于自带的Cordis。** Agent Loop、LLM Adapter、Tool、Session、文件系统、Shell、Skill、Sub-Agent、界面全部是插件，通过YAML配置组合。

**三级配置。**

| 层 | 是什么 | 位置 |
|---|---|---|
| Bundle | npm包携带的插件补丁清单 | `packages/bundle/base/cordis.patch.yml` |
| Profile | 用户目录下的部署形态，声明使用哪些Bundle | `$DSH_HOME/profiles/<name>/`，模板见`packages/boot/app-boot/src/profile.ts` |
| Preset | Agent级别的能力组合，可为不同Agent挂不同插件 | `apps/cli/config/agent-presets/*/agent.cordis.yml` |

默认Bundle列出**78个插件**，Profile模板只有两种：`web`（`dsh-base` + `dsh-web-app`）和`headless`（`dsh-base` + `dsh-headless`）。Profile根配置文件永远是一个空列表，注释里明确写"The tree is composed as patches"——形态差异全部靠补丁叠加，不靠改主配置。

## 二、一次请求的完整链路

### 2.1 事件序列

来自快照`examples/acp-agent/tests/snapshots/text-turn/session.jsonl`：

```text
agent/inbox/spliced → turn/start → step/start
→ user/message（用户原话）
→ user/message（运行时上下文快照）
→ session/title → request/header → request/context
→ assistant/chunk × N → assistant/message
→ step/end → turn/end
```

### 2.2 代码路径

| 阶段 | 做什么 | 位置 |
|---|---|---|
| `kick()` | `while (await this.turn()) {}` | `packages/core/agent-loop/src/agent.ts` |
| `turn()` | 追加`turn/start`，内层循环开Step | 同上 |
| `preStep()` | 认领收件箱消息、`systemPrompt.assemble()`、跑`agent/pre-step`瀑布 | 同上 |
| `step()` | `renderPrompt(assembly)`、`buildRequest()`、消费流、执行Tool Call | 同上 |
| `buildRequest()` | 解析模型配置、写`request/header`、`deepFreeze`请求 | 同上 |
| `executeToolCalls()` | 分组调度、并发控制、写`tool/result` | `packages/core/agent-loop/src/tool-calls.ts` |

### 2.3 Turn与Step

**Turn是用户输入的边界，Step是模型请求的边界。** 一个Step等于一次模型请求加上该请求产生的工具执行。

**Step没有上限。** 循环终止条件是`step()`返回非空的`StepEndReason`且`next-step`收件箱为空，不是计数器。

**Step返回值只有三种：** `null`（继续）、`{ kind: 'completed' }`（模型没再发Tool Call）、`{ kind: 'max-tokens' }`。`max-tokens`是粘性的，后续Step正常完成也不会把Turn结果降级。

**Turn结束原因是封闭枚举：** `completed`、`aborted`、`blocked`、`error`、`max-tokens`、`interrupted`（`packages/core/session/src/types.ts`的`TurnEndReasonMap`）。最后一个只在崩溃恢复时由持久化层补写，循环自己不会产生。

**收件箱是两条有序队列：** `next-turn`和`next-step`（`packages/core/agent/src/inbox.ts`）。`followup()`进前者、`steer()`进后者并唤醒、`inject()`进后者不唤醒。每次收件箱变动都写`agent/inbox/spliced`事件。

### 2.4 请求对象

```ts
const request = markAgentLoopRequest(deepFreeze({
  ...header.config,
  messages: boundaryMessages,
  ...header.system !== undefined ? { system: header.system } : {},
  ...header.tools !== undefined ? { tools: header.tools } : {},
  sessionId: this.session.id,
  signal,
}))
```

**请求发出前深冻结。** 本Step用的是一份不可变视图，插件之后再变也改不了它。

## 三、模型可见输入的三段

### 3.1 System Prompt

**注册接口五个：** `section()`静态段落、`context()`动态上下文、`tools()`工具提供器、`variable()`模板变量、`suppressRuntimeContext()`抑制器（`packages/core/system-prompt/src/index.ts`）。全部返回Disposer，随调用方的Fiber一起销毁。

**排序按数字`order`升序，约定分段：** `-100`是Harness身份、`0`是部署persona、`100–199`是工具指引。同`order`时按注册顺序，README明确指出这是插件加载产物，确定性靠"约定用不同order"来保证，和工具排序被显式规范化不同。

**渲染就三步：** 严格插值`{{variable}}`、丢掉空段、用空行连接。不加任何标题。未知变量、已注册但无值的变量、畸形`{{…}}`全部抛错，宁可失败也不发畸形Prompt。

**`complete: true`段落可以整个接管Prompt。** 兼容性部署用它自己写全文，此时其他段落全被抑制。多于一个则拒绝组装。

**有一个`system-prompt/assemble`瀑布事件，** 插件可以在最终交付前改写整份组装结果。

实际发出的顺序（native模式快照，共25行3,456字符）：身份句 → persona → `tool:read` → `tool:write` → `tool:edit` → `tool:bash` → `tool:jobs` → `tool:goal` → `tool:workflow` → `tool:ralph` → `tool:subagent`。

### 3.2 Tool Schema

**注册用`ctx.tools.register(defineTool({...}))`，** 每个作用域一个`NamedEntries<ToolDefinition>`（`Map`，插入序）。

**`ToolRuntime`不是被Agent Loop单独查询的，它把自己注册成System Prompt的一个Tool Provider。** 所以一次`assemble()`同时产出`{ sections, contexts, tools, variables }`，Prompt和Tools走同一条组装路径。

**排序是整个仓库对缓存最直接的一处设计：**

```ts
function orderTools(tools, toolOrder, knownNames) {
  ...
  if (toolOrder === undefined) return tools.sort(compareToolNames)
  ...
  const listed = new Set(toolOrder)
  const rest = tools.filter(tool => !listed.has(tool.name)).sort(compareToolNames)
  return toolOrder.flatMap(name =>
    name === TOOL_ORDER_REST ? rest : tools.filter(tool => tool.name === name))
}
/** Lexicographic (code-unit) name comparison — locale-independent, so the order is identical on every machine. */
function compareToolNames(a, b) {
  return a.name < b.name ? -1 : a.name > b.name ? 1 : 0
}
```

配置`toolOrder`时必须恰好包含一个`<unlisted-tools>`占位项，否则加载即失败；列了未注册的工具名则每次`assemble()`都拒绝。

**参数Schema不是zod也不是typert，是自带的DSL。** `packages/core/tools/src/schema.ts`的`ParameterSchemaSpec`在`defineTool`时编译成JSON Schema，键顺序沿用作者书写顺序，`required`为空时整个字段省略。配置Schema才用schemastery。

**过滤只有一条正规路径：** `tools.restrict({ allow, deny })`，对继承来的全局工具名做交集掩码，本作用域自己注册的不受影响，且`run_code`不能被点名。Sub-Agent的`toolFilter`就是转调它。权限预设不走这条路，它改的是运行时上下文而不是工具清单。

### 3.3 Messages

**Session Log只追加，事件信封是`{ type, seq, time, data }`，** 追加时`deepFreeze`。落盘两种后端：JSONL（默认zstd压缩）和SQLite。

**能进模型历史的事件只有三类：** `user/message`、`assistant/message`、`tool/result`。其余四十多种事件类型（见`packages/core/session/src/known-event-types.ts`）只进日志不进模型。

**投影是增量的：**

```ts
deriveMessages(): Message[] {
  const generation = surface.replaceGeneration
  if (generation !== this.derivedGeneration) {
    this.derived = []; this.derivedNodes = 0; this.derivedGeneration = generation
  }
  for (const seq of nodes.slice(this.derivedNodes)) {
    const msg = this.deriveEventMessage(this.log[seq]!)
    if (msg) this.derived.push(msg)
  }
  ...
}
```

**Surface层是"只追加的日志"和"可以改写的模型视图"之间的桥。** `SurfaceOp`只有两个取值：`'append'`，或`{ op: 'replace', start, end }`。`replace`把一段区间从可见节点列表里换掉并递增`replaceGeneration`，投影缓存随之整体失效。全仓库只有Compaction使用`replace`。

## 四、request/header：把模型视图写进日志

**每个Step都算一次规范化Header，和上一次不同才落一条事件。**

```ts
const header = canonicalHeader({ config, ...adapterDefaults, ...system, ...tools })
const baseline = this.session.requestHeader()
if (!this.requestHeaderLogged) {
  this.session.append('request/header', { header, reason: baseline === undefined ? 'initial' : 'resume' })
  this.requestHeaderLogged = true
} else if (baseline === undefined || !headerEquals(baseline, header)) {
  this.session.append('request/header', { header, reason: 'change' })
}
```

**Header内容：** `{ config, adapterDefaults?, system?, tools? }`。`config`是provider、model、采样参数；`system`是渲染后的Prompt全文；`tools`是有序Schema数组。**不含**历史消息、API Key、Base URL、HTTP Header。

**`reason`只有三个值：** `initial`、`resume`、`change`。

**规范化规则：** 空Prompt和空工具列表变成缺失字段，让"没有"和"空"在比较时等价。

**比较是逐字段的，不是哈希。** 工具按序逐个`JSON.stringify`比较（`headerEquals`）。

**设计动机写在Agent Note里：** 任何人拿着一份Session Log就能重建任意一次请求当时的模型视图。`.agents/notes/implemented/architecture/2026-07-05-reconstructable-requests.md`里这句话是整套设计的核心："an append-only log projected by a per-node pure function yields requests that are append-extensions of their predecessors whenever the header is unchanged — stability is emergent, not managed."

## 五、动态内容为什么走消息而不走System Prompt

这是全仓库最一致的一条取舍：**变的东西一律追加到历史末尾，不去改前缀。**

### 5.1 运行时上下文快照

沙箱策略（`sandbox:policy`，order 110）、审批策略（`approval:policy`，order 115）、子Agent委派说明（`subagent:delegation`，order 120）都用`systemPrompt.context()`注册，但它们**不进System Prompt**。Agent Loop在`preStep`把它们渲染成一条`user/message`追加进历史：

```text
Current runtime context. This snapshot supersedes earlier runtime-context snapshots.
```

规则：文本没变不追加；任一部分变了追加完整新快照；从非空变空追加明确清除消息。设计笔记`2026-07-30-current-sandbox-policy-context.md`写明了动机："The snapshot is appended after existing history … so a changed policy preserves the preceding system-and-conversation cache prefix. … `request/header` remains byte-identical when only policy context changes."

也就是说，策略变化只往历史尾部加一条消息，System Prompt和Tool Schema一个字节都不动。

### 5.2 Skill目录

**Skill在磁盘上是`<root>/<name>/SKILL.md`或`<root>/<name>.md`，只扫一层。** 七个根目录按rank排优先级：项目`.dsh/skills`（100）、项目`.agents/skills`（200）、运行时注册（250）、自定义目录（300）、用户`$DSH_HOME/skills`（400）、用户`.agents/skills`（500）、内置（600）。

**Frontmatter字段：** `name`、`description`、`whenToUse?`、`metadata?`、`disable-model-invocation`、`user-invocable`。

**进模型的只有名字和描述，也是一条`user/message`，不是System Prompt段落。** 每次`agent/pre-step`重算一次sha256摘要：

```ts
function digestCatalogEntries(entries) {
  const canonical = entries.map(entry => JSON.stringify([entry.name, entry.description])).join('\n')
  return createHash('sha256').update(canonical).digest('hex')
}
```

摘要变了就追加一份**完整替换目录**，原文是"This complete catalog replaces every earlier available-skills list in this session"；一个都不剩时追加空目录加一句"Do not use names from earlier skill catalogs."

**Skill正文没有卸载协议。** 模型调`skill`工具后正文作为`tool/result`进历史，用户用`/name`调用则作为`user/message`进历史。删掉Skill文件只影响未来的发现和调用，已经进历史的正文留在那里。`packages/skill/tool-skill/README.md`自己写明："body-only edits do not change the catalog digest or notify the model; a later tool call reads the current provider content while earlier tool results remain historical facts."

## 六、Native、Code、Both三种暴露方式

**模式枚举：** `'native' | 'code' | 'both'`，默认`native`，可在Preset里按Agent配置（`packages/core/agent-tool-presentation`）。

**决定原生暴露哪些工具的就这一段：**

```ts
private wireSchemas(scope?: ScopeKey): ToolProviderResult {
  const mode = this.modeFor(scope)
  if (mode === 'native') { ... return { schemas, knownNames: [...view.knownNames] } }
  this.requireCodeRuntime(mode)
  const schemas = [...view.visible.values()].map(d => this.schemaOf(d, false))
  if (mode === 'code') {
    return { schemas: schemas.filter(s => s.name === RUN_CODE_NAME), knownNames: [RUN_CODE_NAME] }
  }
  return { schemas, knownNames: [...view.knownNames, RUN_CODE_NAME] }
}
```

**Code Mode下真实工具没有消失，它们被渲染成SDK文本进了System Prompt。** 两个新增段落：`tools:code-only`（order 99）声明"`run_code` is the only tool you can call directly"，`tools:sdk`（order 150）是完整的TypeScript或Python类型声明。SDK同样按工具名字典序生成。

**顺序上有个细节值得注意：** 折叠声明的order是99，排在所有工具指引段（100–199）**之前**。源码注释解释了原因——否则模型先读到一堆"用bash做什么"的指引，再读到"只能调run_code"，会先发一个原生调用、拿到`UNKNOWN_TOOL`、然后认为部署配置有问题。

**仓库快照里的实测规模：**

| 模式 | 原生工具数 | Tool Schema字符 | System Prompt字符 | 合计 |
|---|---|---|---|---|
| Native | 19 | 21,456 | 3,456 | 24,912 |
| Code | 1 | 902 | 27,968 | 28,870 |
| Both | 20 | 22,358 | 27,809 | 50,167 |

**同一组工具加一个的代价：** 把native的19个工具和both的20个工具按DeepSeek线格式序列化，`run_code`字典序落在第12位（`read`和`send_message`之间），公共前缀10,739字符，占22,848字符的**47%**。

**Code Mode真正的收益在别处：** 一次`run_code`里可以连续调多个工具，嵌套调用逐条记日志但只有外层结果进模型历史，往返次数下降。子调用并发上限`maxParallelSubCalls`默认10。

## 七、插件生命周期

### 7.1 Fiber

**一次`ctx.plugin()`加载对应一个Fiber。** 状态是封闭的六态（`vendor/cordis/src/fiber.ts`）：

```ts
export const enum FiberState {
  PENDING,    // 等依赖
  LOADING,    // 回调执行中
  ACTIVE,     // 已加载
  FAILED,     // 抛错
  DISPOSED,   // uid已清，不可重启
  UNLOADING,  // 正在跑Disposer
}
```

### 7.2 Effect与Disposer

**插件做的每件有副作用的事都要通过`ctx.effect()`登记，** 立即执行，同时收集撤销函数。Fiber卸载时**逆序**执行全部Disposer，重复调用是幂等的。`systemPrompt.section()`、`tools.register()`、`ctx.provide()`都是Effect，所以插件卸载后它注册的Prompt段落和工具会自动消失。

### 7.3 依赖是反应式的

**`inject`里列的服务全是硬依赖，缺一个就不加载；可选依赖要用`ctx.get(name)`。**

**关键在于依赖满足与否会实时重算。** Fiber为自己的依赖算一个epoch字符串，内容是每个依赖提供者的`fiber.uid`拼接：

```ts
_refresh() {
  let epoch = ''
  for (const name of Object.keys(this.inject)) {
    const impl = this._store[name]
    if (!impl) { epoch = INACTIVE; break }
    epoch += ':' + impl.fiber.uid
  }
  this._setEpoch(epoch)
}
```

依赖出现就自动加载，依赖消失就自动卸载。**因为epoch里带了提供者的uid，提供者被换掉（哪怕服务名不变）也会触发依赖方重启。**

### 7.4 变化在什么时候进模型视图

`system-prompt/change`和`tools/change`两个事件由`ScopedLayers`的变更回调发出，**载荷为空，而且Agent Loop里没有任何监听者**（`packages/core/agent-loop/src`下检索不到这两个名字）。变化生效靠下一次`preStep`重新组装，不靠事件推动。所以插件在Agent空闲时增删，不会自己唤醒Agent，也不会立刻产生新Step。

三个时间点：

| 变化时机 | 结果 |
|---|---|
| Assembly之前 | 本Step直接生效 |
| Assembly之后、请求发出前 | 请求已冻结，下一Step才生效 |
| 模型已产生Tool Call、工具尚未执行 | **执行层查实时注册表** |

第三种是真正的竞态。执行路径不用请求里那份冻结Schema，而是调`resolveExecution()`重新查：

```ts
const tool = this.resolveExecution(exec.name, exec.agent, exec.parent !== undefined)
if (!tool) throw new ToolNotFoundError(exec.name)   // code: 'UNKNOWN_TOOL'
```

并行批次里**尚未启动**的调用还会在启动前重新分类，源码注释："Commit before classifying again so registry changes affect unstarted calls."

**并发规则：** 工具自己声明`isConcurrencySafe(args)`，返回`true`才能并行，否则独占执行。并行上限`DEFAULT_MAX_PARALLEL_TOOL_CALLS = 10`。

### 7.5 模型可以自己改插件图

`packages/extensions/tool-cordis`（只挂在`cordis`这个Preset上，不在默认Bundle里）给模型开了七个工具：`cordis_inspect_list`、`cordis_inspect_query`、`cordis_inspect_self`、`cordis_define`、`cordis_run`、`cordis_stop`、`cordis_undefine`。模型可以自己写一个插件、跑起来、停掉、删掉。作用域限制在`dynamicCordisRunner`管理的动态包，改不了宿主的`cordis.yml`。

### 7.6 热更新

`vendor/hmr`用chokidar盯文件，改动后清ESM和CJS缓存、重新import、`registry.delete(旧插件)`、用旧Fiber的`_config`重新`plugin()`。**保留**配置和Entry关联，**重建**模块、Runtime和全部Fiber。失败时回滚缓存并恢复旧插件。

## 八、Sub-Agent与Preset

### 8.1 Spawn与Fork

两者都走`startInProcessRun`，唯一区别是种子：

| | spawn | fork |
|---|---|---|
| `inheritsParentContext` | `false` | `true` |
| 种子 | 无 | `completedTurnPrefix(parent)`，即到最后一个`turn/end`为止的全部事件 |

**Fork的边界是最近一个完整Turn，** 不允许在Turn中间切。子Session复用父Session的事件序列作为种子，`seq`不重写。

**子Agent的组合逻辑集中在一处**（`packages/subagent/subagent/src/child-agent.ts`的`applyChildComposition`）：加入父Preset的常驻组合、注入`subagent:delegation`运行时上下文、可选覆盖persona（order 0的`deployment:persona`）、可选`tools.restrict(toolFilter)`。子Agent的审批策略被强制置为`never`。

**回传两条路：** 一次性子Agent返回`{ output, structured?, stopReason }`；可续子Agent用`report`工具，把内容作为`source.kind: 'subagent-report'`的`user/message`送回父Session，`delivery`可选`wakeup`或`quiet`。

**缓存上没有父子命名空间。** 是否跨Session命中完全由模型服务按Token前缀决定。设计笔记`2026-07-08-interactive-side-sessions.md`里明确否决了改子Agent System Prompt的方案："rejected by default because any byte change invalidates the prefix cache from token zero."

### 8.2 Preset

**磁盘格式：** 目录名匹配`/^[a-z0-9][a-z0-9-]*$/`，内含`agent.cordis.yml`（插件组合）和可选`preset.yml`（`name`、`description`、`order`）。

**只有空白Session能切Preset。** 判定条件精确到一句：

```ts
function sessionBlank(session: Session): boolean {
  return !session.events.some(event => event.type === 'turn/start')
}
```

已经开过Turn就返回`agent-preset-locked`错误。检查在API层（`packages/host/apiproxy`），`recompose()`自己不读历史。

**Resume时无条件写一条`reason: 'resume'`的Header。** 进程重启前后同名Preset如果内容变了，恢复后的Header就跟着变，是否命中缓存取决于最终Token前缀而不是Session ID。

## 九、Compaction

**三个触发口：** `agent/pre-step`时的压力检查、`agent/request-error`收到`CONTEXT_WINDOW_EXCEEDED`时的溢出兜底、`/compact`命令。

**默认参数**（`packages/compaction/compaction-basic/src/config.ts`）：`thresholdRatio` 0.8、`retainRatio` 0.16、`maxTokens` 8192、`compactionRetries` 1、`maxOverflowRetries` 1、`auto` true。阈值Token数 = `floor(contextWindow × 0.8)`。

**摘要请求本身是为缓存复用设计的。** 它复用原请求的System Prompt和Tool Schema，把压缩指令追加到对话最后：

```ts
const messages = [...input.messages, createUserMessage({ content: [{ type: 'text', text: COMPACTION_INSTRUCTION }], ... })]
const options: GenerateOptions = {
  provider: target.provider, model: target.model, messages,
  ...input.system === undefined ? {} : { system: input.system },
  ...input.tools === undefined ? {} : { tools: [...input.tools] },
  maxTokens: config.maxTokens, purpose: 'compaction',
}
```

修复笔记`.agents/notes/implemented/bug-fix/2026-07-21-compaction-summary-prefix-cache-reuse.md`记录了改动前后的差别：旧实现用一份全新的摘要System Prompt，"a first token that differs — a different system prompt — invalidates the entire cached prefix"；新实现把指令从请求开头搬到对话末尾，使辅助调用成为上一次请求的真前缀。即使摘要调用根本不会执行工具，也必须带上原Tool Schema，否则Token序列从tools位置就对不齐。

**产出事件：** `compaction/start` → `compaction/summary`（只进日志）→ 一条带`surfaceOp: { op: 'replace', start, end }`的`user/message` → `compaction/end`。这条`replace`是全仓库唯一改写模型可见历史中段的操作。

**还有一份未实施的提案** `.agents/notes/proposed/feature/2026-07-06-recallable-compaction.md`，里面点评了业界做法："none of the surveyed implementations makes compaction prefix-cache-aware"。

## 十、Token与缓存统计

### 10.1 DeepSeek的用量映射

```ts
export function mapUsage(usage: WireUsage): TokenUsage {
  const cacheRead = usage.prompt_tokens_details?.cached_tokens ?? usage.prompt_cache_hit_tokens
  const reasoning = usage.completion_tokens_details?.reasoning_tokens
  return {
    inputTokens: usage.prompt_tokens - (cacheRead ?? 0),
    outputTokens: usage.completion_tokens,
    ...cacheRead !== undefined ? { cacheReadTokens: cacheRead } : {},
    ...reasoning !== undefined ? { reasoningTokens: reasoning } : {},
  }
}
```

**`inputTokens`表示未命中的输入，不是总输入。** DeepSeek这条链路不产生`cacheWriteTokens`，未命中部分留在`inputTokens`里。线协议里还有个`prompt_cache_miss_tokens`字段没被使用。

### 10.2 请求侧没有缓存控制

`serializeRequest()`产出的字段只有：`model`、`messages`、`stream`、`stream_options`、可选`thinking`、`reasoning_effort`、`tools`、`temperature`、`max_tokens`、`stop`。**没有任何缓存标记字段**，也没有Anthropic式的`cache_control`。System Prompt作为`messages[0]`的`system`角色，Tool Schema走独立的`tools`字段。

### 10.3 别把几种Cache混为一谈

| 名字 | 用途 | 是模型KV Cache吗 |
|---|---|---|
| Session派生消息缓存 | 增量算当前历史 | 否 |
| Surface Manager | 维护可见消息与替换 | 否 |
| Skill目录Cache | 缓存技能发现结果 | 否 |
| Session Projection Cache | 持久化投影检查点 | 否 |
| Token Meter | 估上下文压力与累计用量 | 否 |
| DeepSeek Prefix Cache | 复用模型前缀K/V | **是** |

**Harness不保存、不删除、不迁移KV Cache，** 它只能把前缀做稳、从usage里读命中数、通过真实请求观察延迟。

**Token Meter统计的是Agent Loop的逻辑Step，不是全部HTTP请求。** 同一Step重试取最后一次，Compaction辅助请求不一定进同一个累计投影。做实验必须同时保存Provider原始usage。

### 10.4 默认模型

`provider = deepseek-official`，默认模型`deepseek-v4-flash`和`deepseek-v4-pro`，上下文窗口默认`1_000_000`，`maxTokens`默认`256_000`，Base URL `https://api.deepseek.com`。适配器只有两个：`llm-deepseek`和`llm-pi-ai`（后者接第三方目录），没有第一方OpenAI或Anthropic适配器。

## 十一、周边机制

**权限。** 沙箱模式三档：`read-only`、`workspace-write`、`danger-full-access`；审批策略两档：`ask`、`never`。执行前走`tools/pre-execute`瀑布，决策是`allow` / `deny` / `ask`。模型通过运行时上下文（不是System Prompt）得知当前策略。

**Hook。** 兼容Claude Code和Codex两套配置。事件点：`SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`SubagentStart`、`SubagentStop`。桥接到`tools/pre-execute`、`tools/post-execute`、`agent/pre-step`，审计写`hook/invoked`和`hook/result`。

**MCP。** 两种传输：`stdio`和`streamable-http`。**在插件激活时急切连接**，`apply()`会`await connection.ready`，不是懒加载。工具名规范化为`mcp__<serverName>__<rawName>`，超长或含非法字符时追加12位sha256。断连按退避重连，重试耗尽则注销全部工具；重新同步时先取全量再整体换掉旧的注册。

**Spill。** 工具结果文本超过`maxInlineBytes`时落盘成文件，模型只看到首尾预览加一条定位提示"Use read with offset/limit, or grep this path to search within it."

**重试。** 默认策略`maxRetries: 2`、`initialDelayMs: 500`、`maxDelayMs: 10_000`、`jitterRatio: 0.1`，重试码为`EMPTY_RESPONSE`、`RATE_LIMIT`、`SERVER`、`TIMEOUT`、`TRANSPORT`。

**工程约定。** 仓库要求每个包的README都写一节Model Experience，说明"这个包有什么会进模型请求、在什么条件下进、这些Token会停留多久、后续请求还能不能复用KV Cache前缀"（`.agents/notes/implemented/process/2026-07-12-package-model-experience-contract.md`）。这条约定本身就说明缓存前缀在这套代码里是包级契约，不是某个模块的局部优化。

## 十二、结论与待验证

### 12.1 源码支持的判断

1. **动态改工具一定会改模型请求头。** Native改`tools`字段，Code改System Prompt里的SDK，Both两处都改。
2. **改动位置决定代价。** 字典序意味着新工具按名字插在中间，实测加一个工具只保住47%的公共前缀。
3. **每Step一份冻结视图，但执行查实时注册表。** 卸载时存在Schema与执行状态短暂不一致，表现为`UNKNOWN_TOOL`。
4. **"变的东西追加在末尾"是一条贯穿全仓库的规则。** 运行时上下文和Skill目录用追加式完整替换，子Agent回报也是追加，都不动请求前缀。
5. **Compaction是唯一的例外，也是唯一被专门做过缓存优化的地方。**
6. **Code Mode不解决动态工具的缓存问题。** 它把成本从`tools`字段搬到了更靠前的System Prompt，收益在减少往返和缩小历史。
7. **缓存成本应当进入能力选择的目标函数。** 相关性接近时，复用当前工具集大概率比切换更便宜。

### 12.2 不要外推的部分

现有实践只证明了**Tool和Skill的渐进式加载有价值**，没有证明"系统应该自动检索并安装Plugin"。Plugin在这套代码里更接近安装、分发和作用域管理单元，运行时选择停在Plugin、Skill还是Tool层，要由真实产品流程和数据决定。

### 12.3 第一轮实验

| 方案 | 主要变量 |
|---|---|
| Native静态全集 | Schema大、集合稳定 |
| Native动态集合 | Schema小、集合变化 |
| Code动态集合 | `run_code`稳定、SDK变化 |
| 阶段内固定集合 | 每阶段只失效一次 |
| 统一Router Tool | Schema稳定、调用间接 |
| Spawn子Agent | 独立短历史 |
| Fork子Agent | 尝试复用父历史前缀 |

每次请求需要记录：

```text
System Prompt摘要 / Tool Schema摘要 / Plugin Set摘要
request/header reason
inputTokens / cacheReadTokens / TTFT
任务成功率 / 无效Tool Call数
```

### 12.4 只能靠真实运行确认的三件事

1. DeepSeek服务端如何把独立的`tools`字段编码进实际的缓存Token前缀；
2. 不同模式和不同插件切换频率下，命中率、TTFT和任务成功率的真实变化；
3. 插件卸载与Prompt组装并发时，会不会出现混合代际的System与Tool视图。
