<!-- tpl:v3 -->
# 归档打标模板（注入主模型，逐条目判断；条目是归档单位，不是轮次）

## 四分类 → 命令
| 条目特征 | 分类 | 命令 |
|---|---|---|
| 目标/决策及理由/待办/产物引用/依赖图变化/未决问题增删 | 工作集修订 | SaveState（带 -BaseVer）|
| 禁令/铁律/技术选型/红线 | 硬约束 | Archive -Type constraint -Source <MSG id 或 CONFIRMED> |
| 素材/工具输出/结论依据/旧决策段冷存 | 证据 | Archive -Type evidence |
| 寒暄/措辞/被覆盖内容 | 可弃 | Archive -Type discard |

## summary 模板与词表
- 格式固定：`[对象|动作] 一句话`；对象从 config.json 的 obj_vocab 选，动作从 act_vocab 选
- **词表外新词**：需人工（用户/主对话）确认后写入 config 词表再用，不许随手造词——
  词表漂移会让 -Obj/-Act 检索退化成模糊匹配
- Verify 补归档的重建条目：分类判断走本模板，-Source 标 `REBUILT-<原 MSG id>`

## 超长输入拆分（harness 规则，指令永不裁的工程化出路）
用户消息超过 budget × 0.4 时，拆为「指令核心 + 附录」：
- 附录（大段日志/代码/贴文）→ `Archive -Type evidence`（tags 含 appendix），取 id
- 指令文件只写核心 + 一行锚点：「附录见 E####，已归档，可 Fetch」
- 该 id 作为 Evidence 传入 Assemble——不裁指令，也不逼用户手动拆

## 硬规则（脚本已强制，先自查免得白跑）
- 约束 -Source 必填：用户原话填 MSG id；仅主模型直接归档可 CONFIRMED；staging 禁 CONFIRMED
- 填充词丢措辞不丢状态：「继续」→更新待办；「挺好」→决策获认可
- 全线生效约束 -TaskId '*'；决策分期 tags 必含 decisions（初始层 t3 + kind="decision" 渲染依赖它）
- 决策分期条目 tags 必含 decisions（入包自动渲染 kind="decision"，下游不当普通素材）
- **依赖图节点名必须进 tags**：条目涉及工作集依赖图某节点时，把节点名原样作为一项 tag
  写入（如 `-Tags 接口,auth-service`）——relevance.md 的邻域召回按节点名 Search，
  节点名不进 tags 就搜不到（summary 对象侧是词表受限词，匹配不上自由命名的节点）
