# Project integration / 项目接入

`neuron-harness skill` keeps its skill ID and `.neuron-harness/` namespace. The public repository
is `neuron-harness-skill`; the checkout directory stays `neuron-harness`. Downloading a repository is not the same as activating a skill.

## Installation contract

1. Install Git and PowerShell 7 separately; no automatic dependency installation or privilege elevation.
2. Clone the skill outside the target project, keeping the checkout directory named `neuron-harness`.
3. Initialize the target project using `assemble.ps1 -Mode Init -Project <absolute-root>`.
4. Run `integrate.ps1 -Action Plan -Harness <harness> -Project <absolute-root>`.
5. Only after the user enables project integration, run the same command with `-Action Install`.
6. Start a new host session and test with a synthetic message. Existing sessions may not reload rules.

`Plan` is the default and writes nothing. A harness must be explicit; detection does not silently
choose or modify instruction files. Installation never modifies user-global rules.

| Harness | Entry | Capability |
|---|---|---|
| zcode / codex / generic | AGENTS.md managed block | Instruction-driven; actual rule loading must be verified |
| claude | CLAUDE.md managed block | Instruction-driven; optional UserPromptSubmit capture hook |
| cursor | AGENTS.md compatibility block | Instruction-driven; live Cursor support unverified |

Claude's optional `-EnablePromptHook` merges a synchronous command hook into the project's
`.claude/settings.json`. It uses a safely encoded invocation of the PowerShell script rather than
placing raw project paths in shell source. It does not grant permissions or bypass execution policy.
Existing permissions, hooks and unrelated JSON values are retained semantically; formatting may
change. Invalid JSON, duplicate keys, JSONC and incompatible structures are rejected.

## What runs each turn

- A model-guidance entry asks the agent to read the project `runtime.md`, keep a persistent task
  state, classify/archive new messages, select relevant evidence, assemble task packs and review
  staging. The native file does not guarantee compliance or force a tool call.
- Claude's prompt hook records the actual string supplied by the host and emits a message ID,
  task ID and the short protocol as additional context. It does not perform semantic classification
  or spawn agents. It must not be described as a fully automated memory loop.
- A stable `prompt_id`, when supplied, enables receipt-based retry deduplication. Without such an
  ID, identical submissions remain separate messages; there is no invented exactly-once guarantee.
- Task-switch/dependency signals use at-least-once compensation: replay repairs the window between
  a durable raw message and its signal. Duplicate signal rows are possible, including on a normal
  marked submission; they are not duplicate original messages. A completed event replay does not
  emit another compensation signal. This does not claim exactly-once signalling.
- Hook failures exit with a blocking error rather than claiming the message was saved. Reserved
  raw-log framing lines are rejected, not silently escaped. Full framing-format migration is not
  part of this release.
- Prompt text is JSON-decoded but not trimmed, summarized or newline-normalized. Originals may
  contain secrets. Stdout/stderr must not echo them; `.neuron-harness/` must stay local and excluded
  from source control. Files inherit the user's filesystem security; this is not encryption.

A hook session task ID is capture routing, not a semantic-task detector. Continuing an existing task
in a fresh session requires the main agent to relate it to the existing task state. Isolation of
subagents is also a host capability; do not claim it when a host cannot supply it.

## Ownership and recovery

The installer records the files and blocks it owns under `.neuron-harness/integration/`, with unique
backups and a journal written before applying changes. Runtime comes before instruction entry;
a native hook is enabled last. Same-configuration installation is idempotent.

- Original instruction bytes outside the managed block are preserved, including recognized BOM
  and line-ending style. An edited owned block, ambiguous markers or a different installation root
  stops modification rather than guessing.
- `Status` distinguishes absent, intact, changed and incomplete configuration. It does not certify
  that a live client invoked the hook.
- `Recover` checks current before/after hashes and backup hashes before restoring an incomplete
  transaction. Unknown edits stop recovery. It never overwrites new user changes from an old backup.
- `Uninstall` removes only the managed instruction region and owned runtime/configuration content.
  It preserves user text added outside the region and **all original memory history**. Changed
  Claude settings are handled conservatively rather than overwriting another tool's new configuration.
- Newly created instruction files may remain empty after recovery or uninstall. Originally absent
  Claude settings are restored to a valid empty JSON object instead of an invalid zero-byte file.
  No history deletion or cleanup is bundled with uninstall. If a killed installer leaves an orphaned
  lock, `Recover -RecoverStaleLock` explicitly verifies it can be opened exclusively before isolation;
  a live lock is never taken.
- Integration journal schema 2 rejects pre-release schema 1 records with an explicit manual-review
  message. No public schema-1 installer was released; test snapshots are not silently migrated.
- Local symlinks/reparse points are refused and paths are rechecked before writing. This is a
  cooperative local-project tool, not an OS-level defense against an adversary concurrently swapping
  directory entries. Network/shared filesystems remain unsupported.

Use the same explicit harness and root for Status, Uninstall and Recover. If the skill installation
moves, uninstall before moving and reinstall with the new root; do not silently retarget old hooks.
Do not edit generated runtime or owned blocks in place; keep custom project rules outside them.

## Verification

```powershell
pwsh -NoProfile -File tests/e2e.ps1
pwsh -NoProfile -File tests/integration.tests.ps1
pwsh -NoProfile -File tests/prompt-hook.tests.ps1
```

The first suite is the existing 28-group executor baseline. The other suites independently test
installation ownership, interrupted transactions, native-hook payloads and verbatim capture.
Mock payload/subprocess tests do not substitute for running Claude Code, Cursor, Codex or ZCode.
Native hooks can vary by host version and organizational policy; test your actual client before
relying on automatic capture.

Official mechanism reference: [Claude Code hooks](https://code.claude.com/docs/en/hooks) and
[Claude Code project instructions](https://code.claude.com/docs/en/memory). Other adapters expose
minimal instruction-file integration only and do not claim undocumented native hook support.
