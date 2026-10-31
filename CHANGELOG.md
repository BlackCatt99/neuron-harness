# Changelog

本项目的版本记录。格式参考 [Keep a Changelog](https://keepachangelog.com/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [0.2.0] - 2026-11-01

### Added

- Project integration installer with read-only Plan, explicit harness selection, managed instruction blocks,
  ownership checks, transaction journals, recovery, and history-preserving uninstall.
- Short per-turn runtime protocol; optional Claude Code UserPromptSubmit hook for verbatim prompt capture.
- Independent installer and hook regression suites; explicit distinction between instruction-driven activation
  and event wiring, without claiming live-client validation.
- Bilingual clone/install/status/recovery examples and prominent Agent Skill identification.
- Redesigned bilingual covers and architecture diagrams, dynamic memory and quickstart previews,
  a 24-second silent film, and an offline interactive brand page.

### Fixed

- LogRaw no longer trims trailing whitespace or rejects an empty readable input file; original prompt strings
  remain intact. Hook inputs containing reserved legacy log framing are rejected rather than rewritten.

### Naming

- Display name: **neuron-harness skill**. Public repository: **neuron-harness-skill**.
  Skill ID, checkout directory convention and `.neuron-harness/` data namespace remain unchanged.

## [0.1.1] - 2026-10-29

首个公开版本后的补丁版。`v0.1.0` 打在了加入 CI 之前的提交上，本版使版本号与实际代码对齐。
无 API 变更，不影响已有数据。

### 新增

- **GitHub Actions CI**：`windows-latest` 与 `ubuntu-latest` 双平台执行全部集成测试。
  README 顶部加入 CI / License / PowerShell 徽章，状态为真实运行结果。
- **README「为什么不用现成方案」**：按五个维度（记忆存放位置、谁决定放入上下文、
  是否压缩历史、运行依赖、可审计性）对比 Letta / MemGPT 与 LangChain memory，
  并说明各自适用场景，不给优劣排序。
- **Step 25**：静态检查测试代码——不得含字面反斜杠路径，枚举点文件必须带 `-Force`。
- **Step 27**：文档与 CI 中写的测试组数必须等于 `Step` 声明数，防止手改测试后文档漂移。

### 修复

- **跨平台测试缺陷（由首轮 CI 在 ubuntu 暴露）**：`Get-ChildItem -Filter '.lock-stale-*'`
  缺 `-Force`。以点开头的文件在 Linux/macOS 上属隐藏文件，枚举为空导致 Step 19 误报
  「陈旧锁未被隔离」。Windows 无此差异，故本地测试一直为绿。
- **Step 20 字面反斜杠路径**：`'archive\t2'` 改为 `Join-Path` 分段传入，
  避免 Linux 上被解析为单个文件名。

### 变更

- 测试组数 25 → 27。
- 平台支持表述改为以 CI 实测为准：Linux 由 `ubuntu-latest` 实际执行；macOS 仍未覆盖。

## [0.1.0] - 2026-10-29

首个公开版本。由 `context-router` v5.4 重命名而来，版本号重新起算。

### 核心能力

- **外置记忆**：工作集（working set）持久化在 `.neuron-harness/state/`，六节结构
  （架构视图 / 依赖图 / 决策日志 / 硬约束指针 / 未决问题 / 产物锚点），每轮增量修订。
- **上下文路由**：主代理只负责归档、选取、组装；实际工作交给短生命周期子代理，
  子代理只接收预算内的小任务包，不继承主会话历史。
- **T1–T4 分层功能性遗忘**：T1 工作集与活跃约束（每轮注入）、T2 近期证据（默认检索面）、
  T3 长期证据与决策分期、T4 遗忘层。**原文永不删除**，遗忘只降低检索可见性。
- **三档检索**：档 1 连续推进不检索；档 2 沿依赖图邻域召回；档 3 全量重估并跑层级重算。
- **staging 缓冲**：子代理产出先进缓冲，经来源校验后才写入正式索引。

### 可靠性

以下每一项都由集成测试里的独立 fixture 复现并锁定：

- 写锁改用 `FileMode::CreateNew`（内核 O_EXCL 语义）实现原子互斥。原实现用
  `New-Item -ItemType Directory`，12 进程屏障同步竞争实测出现 8/12、12/12 同时「抢到」，
  5 进程并发归档直接丢 2 条。
- 陈旧锁判定先查持锁 pid 是否存活：pid 存活则报错重试、绝不夺锁，避免长任务
  （如全量层级重算）被并发进程抢锁后两进程同时重写索引。
- 所有备份/归档文件名采用「时间戳（含毫秒）+ 8 位 GUID」，同毫秒不再互相覆盖。
- `TierSweep` 拆双闸门：索引提交与 access 轮转分离，无层位变更时的 backfill 基线也会落盘。
- legacy 平铺路径同层迁移同样提交索引，不再出现「文件已搬而索引悬空」。
- 等锁上限按命令类型区分（重算 180s / 校验 60s / 覆盖 30s / 其余 15s）。
- 解锁删除带重试，避免读锁竞态导致锁残留。

### 测试

- 28 组集成测试，覆盖主链、回归、并发、陈旧锁、跨平台路径与许可证一致性。
- `-ScriptPath <旧版脚本>` 可对历史版本运行同一套用例，用于**反向验证**新用例确实能
  抓到旧缺陷——防止写出永远为绿的假阳性断言。

### 已知限制

- 语义来源校验（约束正文能否在原始消息中找到依据）需要模型参与，脚本只校验格式与存在性。
- 单全局写锁：并发保证正确性，不保证吞吐。
- 编号计算每次递归扫描归档目录，条目到数百后会有可感知延迟。
- 仅在 Windows 上实测；Linux/macOS 的代码路径已去除平台专有依赖，但未经真实环境验证。
  （v0.1.1 起 Linux 已由 CI 的 `ubuntu-latest` 实际执行全部测试；macOS 仍未覆盖。）

[0.2.0]: https://github.com/BlackCatt99/neuron-harness-skill/releases/tag/v0.2.0
[0.1.1]: https://github.com/BlackCatt99/neuron-harness-skill/releases/tag/v0.1.1
[0.1.0]: https://github.com/BlackCatt99/neuron-harness-skill/releases/tag/v0.1.0
