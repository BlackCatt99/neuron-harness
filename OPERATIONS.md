# neuron-harness 运营备忘录（v0.1，2026-10-28）

本文件是运营注记，不是规格；规格以 SKILL.md 为准，版本以 manifest.json 为准。

## 版本血统

本 skill 由 **context-router v5.4** 重命名而来。版本号重新起算：`skill_version` 1、
`skill_semver` "0.1"。这不是回退——下表 v5.1–v5.4 是**前身**的实证修复记录，本基线原样
继承其全部代码与回归，`skill_version` 从 9 降到 1 不代表能力下降。manifest.json 的
`lineage` 字段机器可读地记录了这段血统。

重命名同步的改动（v0.1 相对前身 v5.4）：
1. skill 名 `context-router` → `neuron-harness`，数据目录 `.context-router` → `.neuron-harness`。
2. 去掉 6 处 `-replace '/', '\'` 硬编码：原代码把索引里的正斜杠路径转成反斜杠，在 Linux
   上是**字面字符**而非分隔符，会生成 `archive\t2\E0001.md` 这种单文件怪名——跨平台阻断点。
3. 测试去掉 Windows 专有耦合：`$env:TEMP` → `[IO.Path]::GetTempPath()`、
   `-WindowStyle Hidden` 仅在 Windows 可用已移除、子进程改用当前 `pwsh` 的实际路径
   （不假定 PATH 里有 `pwsh`，也不退回 Windows PowerShell 5）。
4. `Init` 新增旧目录只读告警：发现 `.context-router` 时明确提示「未迁移任何数据」，
   不迁移、不删除、不制造假成功（Step 23 锁定）。
5. 新增 Step 24 路径可移植断言：索引 file 列必须正斜杠、`Join-Path` 必须能定位、
   脚本不得再出现硬转反斜杠。

## 版本流程（冻结后生效）

- 下表 v5.x 属**前身 context-router**；本基线 v0.1 继承之：

  | 实证偏差 | 修复版本 | 修复内容 |
  |---|---|---|
  | 备份/归档文件名只到秒，同秒第二次 `Move-Item` 抛「文件已存在」；`Copy-Item` 无 `-Force` 时同毫秒静默覆盖旧备份 | v5.1 | 统一 `New-UniqueName`：时间戳（含毫秒）+ 8 位 GUID；覆盖 templates-history、index.tsv.bak-*、state-history、access-*、recheck-*、rejected 与锁改名入口 |
  | TierSweep 在「无层位变更」时提前 return，早于 access 轮转 → 无访问记录的 backfill 永不落盘 | v5.1 | 拆双闸门：索引提交看 `$indexChanged`；access 轮转看 `$indexChanged -or $backfilled -gt 0` |
  | legacy 平铺路径同层迁移：文件已搬入 t2，索引未提交，Verify 把自造悬空「修」回去 | v5.1 | legacy 同层迁移计入 `$indexChanged`，必定提交索引并留独立备份 |
  | 写锁用 `New-Item -ItemType Directory`，**并非原子互斥**：12 进程屏障竞争实测 8/12、12/12 同时抢到；5 进程并发 Archive 丢 2 条 | v5.2 | 改用 `FileMode::CreateNew`（O_EXCL），锁文件创建即写入 owner（pid + 时间） |
  | 陈旧锁分支 `[datetime]::TryParse($s, [ref]$null)` 抛「Cannot find an overload」→ 超时后直接崩，永不偷锁也不清理 | v5.2 | 改用带 `IFormatProvider`/`DateTimeStyles` 的三参重载 |
  | `Write-TextAtomic` 固定 `$path.tmp`、access 轮转固定 `access.log.tmp`：并发写同一路径互相踩踏，直接丢条目 | v5.2 | tmp 名加 8 位 GUID，并在 `finally` 清理残留 |
  | **陈旧锁判定顺序颠倒**：先按锁龄（≥30s）夺锁，pid 存活检查排在后面永不触发 → 长任务（TierSweep 扫大库）被并发进程夺锁，两进程同时重写索引，行数断言各自自洽，静默丢变更 | v5.3 | 存活检查前置：pid 存活 → 报错重试、绝不夺锁；pid 已消失且锁龄超阈值才隔离 |
  | 等锁上限统一 10s：pid 检查修好后，长任务锁会让并发请求在 10s 内直接失败；30s 陈旧阈值对正常长任务也太短 | v5.3 | 等锁上限按 Mode 区分（TierSweep 180s / Verify 60s / Supersede 30s / 其余 15s）；陈旧阈值提到 120s |
  | 解锁 `Remove-Item -ErrorAction SilentlyContinue`：其他进程正 `FileShare::Read` 读 owner 时 Windows 拒绝删除，错误被吞 → 锁残留 → 下个请求误走陈旧锁路径 | v5.3 | 删除重试 3 次（每次 20ms）；仍失败则保留原样等待陈旧锁隔离，不假装已解锁 |
  | 脚本头注释仍写「New-Item 单步建目录（原子）」：与实际实现（O_EXCL + pid 存活判定）不符，会误导维护者 | v5.4 | 头部注释改写为实际语义，并用 Step 22 断言锁死（禁止过时描述回流） |
  | 并发用例 `Wait-Process -Timeout 180` 超时后**不终止**子进程：残活写入者让后续读索引撞中间态，断言随机失败 | v5.4 | `Wait-OrKill` 兜底强制终止并显式 WARN；已用 120s 睡眠子进程实测 2s 内被杀、正常退出不误报 |
  | 版本号散落三处（脚本头、manifest、SKILL description），靠人记得同步 | v5.4 | Step 22 断言三处必须同源，漂移即测试失败 |

- 判据模板始终未变，`tpl_min` 沿用前身取值；当前 `skill_version` 1、`skill_semver` "0.1"。
- **v0.1 定位：重命名后的开源基线**。此后版本从 0.1 正常递增；`skill_version` 是单调计数，
  与 `skill_semver` 并行维护，两者由 Step 22 校验同源。
- 后续任何改动继续走版本流程，**不在已发布版本上打补丁**：
  1. `manifest.json` 的 `skill_version` 递增（`skill_semver` 记可读版本）；
  2. 同步 SKILL.md 头部 description（版本号 + 本版修复摘要）；
  3. 判据模板变更同步 `tpl_min`，模板头部 `<!-- tpl:vN -->` 升版；
  4. 改动前先跑 `tests/e2e.ps1` 确认基线绿，改完再跑一次，行为偏差不混入当前版本。
- 新回归必须用**旧脚本反向验证**：确认新用例在修复前的脚本上确实失败，否则是假阳性
  （Step 21 用 v5.2 快照验证；Step 23/24 用前身 v5.4 快照验证，均如期失败）。

## 运营养成注记

1. **首次 TierSweep 是建基线，不是遗忘**：无访问记录条目一律 backfill 为当前时间
   （v5.1 起真正落盘，即使当次 0 层位变更），首次 `-Execute` 变更 0 条是预期行为
   （Init 输出已提示）；真正降档从第二次起算。
2. **三条索引重写路径的备份一起清**：TierSweep -Execute / Supersede 落层 / Verify 悬空
   修复都会写 `index.tsv.bak-<时间戳>-<guid>`。清理按通配 `index.tsv.bak-*` 统一处理、
   保留最近 N 个——不要按路径分别清，否则 bak 新旧混态，回滚时不知道对哪个时间点。
3. **staging 语义校验只能靠真实对话**：脚本层只校验 src 格式与存在性；
   「约束正文能在 src 原话中找到依据」的语义判断在 `templates/review.md`，需要主模型
   参与——P0 脚本测不到这条路径，接入真实项目后头几轮 staging 回写要人工盯。
4. **多子代理并发回写（v5.2 起可用）**：锁已是原子互斥且不会误夺长任务的锁，但仍是
   **单全局写锁**——并发保证正确性，不保证吞吐。若出现明显排队（大量超时告警），
   再评估按任务线分锁，不要因为「并发安全了」就假设写入能并行跑满。
5. **长任务会阻塞其他写入（v5.3 起显式报错）**：TierSweep 全量重算期间，其他写命令会等到
   自己的 deadline 后报「锁持有进程存活」，这是正确行为，不是故障。遇到就稍后重试，
   不要手工删 `.lock`。
6. **陈旧锁隔离文件可安全清理**：`.lock-stale-<guid>` 是崩溃现场的取证留存，确认无异常后
   可直接删除，不影响任何索引或归档原文。

## 已知限制（不阻塞交付，长线或低概率才显形）

- **`Next-Id` 每次 O(n) 递归扫 archive 全树**：条目到几百条后 `Archive` 编号计算会变慢。
  可行方向是索引里缓存 max id，或按类型分文件。当前规模无感，未做。
- **`last-review` 只追加不清理**：`ReviewStaging` 的已展示 id 集合每轮只增不减，长期膨胀。
  可在 `ClearRecheck` 或归档收尾时滚动裁剪。
- **锁语义只在本机文件系统验证过**：UNC/NFS 等共享目录上的 rename 与 O_EXCL 行为未测，
  `Init` 仅警告不保证。跨机器共享 `.neuron-harness` 不在支持范围内。
- **等锁上限与陈旧阈值可用环境变量覆盖**（`CR_LOCK_DEADLINE_SECONDS`、
  `CR_LOCK_STALE_AFTER_SECONDS`），仅供测试缩短等待；生产不要设置。

## 测试

- `tests/e2e.ps1` 是集成测试基线，当前 28 组（P0 主链 + 回归 + 跨平台），必须全绿再交付。
  `-KeepArtifacts` 保留临时项目；失败时自动保留并打印 `ARTIFACTS=<路径>`；
  `-ScriptPath <path>` 可对指定（含历史快照）脚本运行同一套用例，用于反向验证。
- 回归重点（历史踩坑点，最容易复发）：Verify 悬空修复、Search 默认不命中 constraint、
  discard 任何 Search 模式不出现、TierSweep 各类提案不丢（NOTHING TO DO 计数同族 bug
  曾连踩三次）、无访问记录 backfill 是否真落盘、legacy 同层迁移是否提交索引、
  备份文件名同秒同毫秒是否碰撞、多进程并发是否丢条目、**陈旧锁隔离是否只在 pid 已死时发生**、
  **脚本头注释与版本三处是否同源**。
- 独立 fixture：15 backfill、16 legacy、17 固定时钟、18 并发 Archive、19 死进程陈旧锁、
  20 并发 TierSweep、21 活进程长任务锁；22 为静态一致性检查（无需 fixture）。
  Verify 用例的文件归位在 `finally` 中执行。
- **Step 19 与 Step 21 是一对反向用例**：19 验「pid 已死 → 隔离」，21 验「pid 存活 →
  拒绝」；只写 19 会让顺序颠倒的 bug 完全隐身（两版代码下 19 都通过）。
- **Step 22 防的是文档漂移**：它不测行为，测「注释/版本说的等于代码做的」。这类漂移不会让
  功能出错，但会让后续维护者按错前提改代码，是 v5.3 实际发生过的教训。
