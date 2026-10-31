# neuron-harness skill v0.2.0 — project integration

**neuron-harness is an Agent Skill**, not another agent framework. It adds external, file-backed
memory and task-focused context routing to a compatible harness.

## Get started

```powershell
git clone https://github.com/BlackCatt99/neuron-harness-skill.git neuron-harness
Set-Location neuron-harness
$project = 'C:/work/my-project'
pwsh -NoProfile -File ./scripts/assemble.ps1 -Mode Init -Project $project
pwsh -NoProfile -File ./scripts/integrate.ps1 -Action Plan -Harness zcode -Project $project
pwsh -NoProfile -File ./scripts/integrate.ps1 -Action Install -Harness zcode -Project $project
pwsh -NoProfile -File ./scripts/integrate.ps1 -Action Status -Harness zcode -Project $project
```

Choose `zcode`, `codex`, `claude`, `cursor` or `generic` explicitly. Start a new session and verify
with synthetic data. These examples require Git and PowerShell 7. A release archive alone does not
activate the skill in a host.

For Claude Code, add `-EnablePromptHook` to both Plan and Install to configure the project-level
`UserPromptSubmit` capture hook. This automatically captures submitted text and injects a short
protocol; semantic archive/selection/assembly/review still belong to the main agent. Other adapters
are instruction-driven; actual host compliance is not guaranteed. Cursor live-client validation is
still unverified.

## Included

- Safe managed blocks in project AGENTS.md or CLAUDE.md, without replacing existing rules.
- Read-only Plan, integrity Status, history-preserving Uninstall and interrupted-transaction Recover.
- Original-byte preservation outside managed instruction blocks, backups and conflict rejection.
- Claude prompt receipts and crash-aware replay when stable event IDs are supplied.
- LogRaw verbatim trailing-whitespace and empty-string preservation.
- Separate installer and prompt-hook regression suites, alongside the existing executor tests.
- Bilingual brand media: Chinese and English covers, separate architecture diagrams, a social
  preview, motion GIFs with static fallbacks, and a silent 24-second film under `docs/brand/`.

## Naming and compatibility

The public repository is `neuron-harness-skill`. The skill ID, checkout directory name and
`.neuron-harness/` state namespace remain `neuron-harness`, so existing installations and memory
history keep working. Only display and public repository naming changed.

Memory history is never removed by uninstall. The state directory may contain sensitive messages:
do not commit or publish it.

## Boundaries

- Instruction-driven integration depends on the host loading and following project rules; being
  listed in an instruction file is not per-turn execution.
- The Claude prompt hook is a native event adapter; other harnesses are instruction-only. Cursor
  and other live clients are not validated in this release.
- Visual assets are delivered as technical-checked drafts. `check_visuals.py` verifies dimensions,
  text bounds, media decoding and link resolution — it is **not** an aesthetic acceptance pass, and
  no independent visual approval is claimed.

See [installation and recovery](../integration/README.md). Live-client execution must be verified
separately from mock-payload and subprocess tests.
