# Contributing to neuron-harness

感谢你愿意花时间。这个项目对贡献的要求不高，但有几条硬规则必须遵守——它们来自实际踩过的坑，
不是形式主义。

## 快速开始

```bash
git clone https://github.com/BlackCatt99/neuron-harness.git
cd neuron-harness
pwsh -NoProfile -File tests/e2e.ps1     # 应该全绿（27 组）
```

需要 **PowerShell 7+**。CI 在 `windows-latest` 与 `ubuntu-latest` 双平台跑同一套测试，
所以任何提交都不能假定只在 Windows 上工作。

## 提交前必须做的三件事

### 1. 测试全绿，并且新用例要能抓住旧缺陷

```bash
pwsh -NoProfile -File tests/e2e.ps1
```

如果你**新增**了回归用例，必须用 `-ScriptPath` 指向修复前的脚本，确认它在旧代码上**确实失败**：

```bash
pwsh -NoProfile -File tests/e2e.ps1 -ScriptPath <修复前的 assemble.ps1>
```

这条规则的由来：项目历史上写过「看起来在测、实际永远为绿」的假阳性断言，掩盖了真实缺陷。
没有反向验证过的用例，我们会要求补上。

### 2. 文档里的测试组数要同步

添加或删除 `Step` 之后，`README.md`、`README.en.md`、`OPERATIONS.md`、`CHANGELOG.md`、
`.github/workflows/ci.yml` 里写的「N 组」必须一起改。忘了的话 Step 27 会直接失败并告诉你
哪份文件写错了。

### 3. 版本三处同源

改版本号时，`manifest.json` 的 `skill_semver`、`scripts/assemble.ps1` 头注释、
`SKILL.md` 的 description 三处必须一致。Step 22 会校验。

## 代码约定

- **PowerShell 7 语法**，UTF-8 无 BOM。
- **路径一律用 `Join-Path` 分段传入，不要写字面反斜杠。** `'archive\t2'` 在 Linux 上是单个
  文件名而非路径。Step 25 会静态检查这一点。
- **枚举以点开头的文件必须带 `-Force`**。`.lock`、`.lock-stale-*` 在 Linux/macOS 上是隐藏
  文件，不加 `-Force` 枚举结果为空。
- **不修改已发布的 git tag**。补丁走新版本号，旧版本的代码位置保持可复现。
- **原文永不删除**。这是项目的核心承诺：任何改动都不得引入物理删除原始日志或归档内容的路径。
- **索引整表重写只有三个合法入口**：`TierSweep -Execute`、`Supersede` 旧约束落层、
  `Verify` 悬空修复。每个都必须自带备份与行数断言。新增路径需要充分理由。

## 改判据模板时

`templates/*.md` 是运行时注入模型的短判据，改动会影响所有使用者的行为：

1. 升模板头部的 `<!-- tpl:vN -->`；
2. 同步 `manifest.json` 的 `tpl_min`；
3. 说明为什么不兼容旧版（若确实不兼容）。

模板内容的变更属于行为变更，请在 PR 里写清楚影响面。

## 提交信息

用 `type: 简短说明` 的形式，常见 type：

```
feat:  新功能
fix:   修缺陷
docs:  文档
ci:    CI 配置
chore: 版本、依赖等杂项
test:  只改测试
```

正文里如果有「为什么」，比「做了什么」更有价值。尤其是修 bug 时，**请写清根因和复现方式**——
这个项目的 OPERATIONS.md 就是靠这类记录积累起来的。

## Pull Request

- 一个 PR 做一件事。混着改文档、改逻辑、升版本会很难审。
- 描述里说明：动机、方案、如何验证（跑了什么命令、看到什么结果）。
- 如果改变了脚本行为，请同步更新 `SKILL.md` 或 `OPERATIONS.md` 中对应的描述——
  **规格与实现不一致视为缺陷**，这个项目曾因文档-代码漂移吃过亏。

## 报告缺陷

请附上：

1. 复现命令（含 `-Project` 路径结构，不要贴你的真实项目内容）；
2. 预期与实际输出；
3. `pwsh -NoProfile -File tests/e2e.ps1 -KeepArtifacts` 的失败输出（它保留临时项目路径，
   便于对照现场）；
4. 操作系统与 PowerShell 版本。

如果是与并发相关的问题，请注明是否多进程同时写入。

## 不做的事

以下方向已明确排除，提 PR 前请先开 issue 讨论：

- 引入向量检索 / embedding 服务（检索刻意保持为标签与关键词匹配）；
- 让 agent 自编辑记忆（当前设计是主模型按判据归档，脚本兑现硬规则）；
- 引入常驻服务或数据库依赖；
- 物理删除原始日志或归档内容。

## License

提交即表示你同意以 [Apache-2.0](LICENSE) 授权你的贡献。
