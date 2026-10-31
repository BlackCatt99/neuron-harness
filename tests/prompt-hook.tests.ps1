#Requires -Version 7.0
<# Standalone integration tests. No Pester dependency. All hook invocations run
   pwsh -File with real stdin and separately captured stdout/stderr/exit status.
   -ScriptPath points to an alternate assemble.ps1 (e.g. pre-fix version) to
   regression-test empty/trailing-whitespace preservation; only temp files used.
   Test sandboxes are retained and printed; raw history is never auto-deleted. #>
[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/assemble.ps1'),
    [string]$HookPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/prompt-hook.ps1')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$skillRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('nh-prompt-hook-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$failures = [Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if (-not [object]::Equals($Actual, $Expected)) { throw $Message }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failures.Add($Name + ': ' + $_.Exception.Message); Write-Output "FAIL $Name -- $($_.Exception.Message)" }
}
function Run-Child([string[]]$Arguments, [string]$InputText = '', [hashtable]$Environment = @{}) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME ('pwsh' + $(if ($IsWindows) { '.exe' } else { '' }))
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardInputEncoding = $utf8
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    [void]$info.Environment.Remove('NH_HOOK_TEST_FAIL_AFTER_LOG')
    foreach ($key in $Environment.Keys) { $info.Environment[$key] = $Environment[$key] }
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-File') + $Arguments) { $info.ArgumentList.Add($arg) }
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $info
    try {
        [void]$child.Start()
        $stdoutTask = $child.StandardOutput.ReadToEndAsync()
        $stderrTask = $child.StandardError.ReadToEndAsync()
        $child.StandardInput.Write($InputText)
        $child.StandardInput.Close()
        if (-not $child.WaitForExit(90000)) { $child.Kill($true); $child.WaitForExit(); throw 'Child timeout.' }
        return @{ Code = $child.ExitCode; Out = $stdoutTask.GetAwaiter().GetResult(); Err = $stderrTask.GetAwaiter().GetResult() }
    } finally { $child.Dispose() }
}
function New-Project {
    $path = Join-Path $testRoot ('project-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    $result = Run-Child @($ScriptPath, '-Mode', 'Init', '-Project', $path)
    Assert-Equal $result.Code 0 'Isolated Init failed.'
    [IO.File]::WriteAllText((Join-Path $path '.neuron-harness/runtime.md'), 'TEST PROJECT RUNTIME — 项目指引', $utf8)
    return $path
}
function New-Payload([string]$Path, [AllowEmptyString()][string]$Prompt = 'hello', [string]$EventId = '') {
    $payload = @{ hook_event_name = 'UserPromptSubmit'; session_id = 'session 测试`literal'; prompt = $Prompt; cwd = $Path }
    if ($EventId -ne '') { $payload.prompt_id = $EventId }
    return $payload
}
function Invoke-Hook([string]$Path, $Payload, [hashtable]$Environment = @{}, [string]$RootOverride = $skillRoot, [switch]$DefaultSkill) {
    $json = if ($Payload -is [string]) { $Payload } else { ConvertTo-Json -InputObject $Payload -Depth 10 }
    $arguments = @($HookPath, '-Project', $Path)
    if (-not $DefaultSkill) { $arguments += @('-SkillRoot', $RootOverride) }
    return Run-Child $arguments $json $Environment
}
function Assert-Success($Result) {
    Assert-Equal $Result.Code 0 ('Hook exit was not zero. stderr=' + $Result.Err)
    Assert-Equal $Result.Err '' 'Successful hook wrote stderr.'
    $json = ConvertFrom-Json -InputObject $Result.Out -AsHashtable
    Assert-Equal $json.Count 1 'stdout contains non-contract fields.'
    Assert-Equal $json.hookSpecificOutput.hookEventName 'UserPromptSubmit' 'Wrong event output.'
    $context = $json.hookSpecificOutput.additionalContext
    Assert-True ($context -match 'raw MSG id M\d{5,}') 'Missing raw MSG id.'
    Assert-True ($context -match 'TaskId=session-[0-9a-f]{16}') 'Missing TaskId.'
    Assert-True ($context.Contains('Do not LogRaw')) 'Missing do-not-log notice.'
    Assert-True ($context.Contains('TEST PROJECT RUNTIME')) 'Project runtime missing.'
    return $context
}
function Assert-Blocked($Result) {
    Assert-Equal $Result.Code 2 'Invalid submission was not exit 2.'
    Assert-Equal $Result.Out '' 'Blocked hook produced stdout.'
    Assert-True ($Result.Err -match '\Aneuron-harness prompt hook failed; submission blocked\.\r?\n\z') 'Error was not generic.'
}
function Read-Raw([string]$Path) {
    return [IO.File]::ReadAllText((Join-Path $Path '.neuron-harness/raw.log'), $utf8)
}
function Get-Receipts([string]$Path) {
    return ,@(Get-ChildItem -LiteralPath (Join-Path $Path '.neuron-harness/integration/events') -Filter '*.json')
}
function Assert-NoTemp([string]$Path) {
    $events = Join-Path $Path '.neuron-harness/integration/events'
    Assert-Equal @(Get-ChildItem -LiteralPath $events -Filter '*.tmp').Count 0 'Owned content/receipt temp leaked.'
}
function Sha([string]$Text) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($Text))).ToLowerInvariant()
}

# Alternate backend must have the templates/manifest next to it for real Init;
# stage just the necessary backend package in a disposable isolated directory.
if ([IO.Path]::GetFullPath($ScriptPath) -ne [IO.Path]::GetFullPath((Join-Path $skillRoot 'scripts/assemble.ps1'))) {
    $stagedRoot = Join-Path $testRoot 'alternate-skill'
    [void][IO.Directory]::CreateDirectory((Join-Path $stagedRoot 'scripts'))
    [IO.File]::Copy($ScriptPath, (Join-Path $stagedRoot 'scripts/assemble.ps1'))
    Copy-Item -LiteralPath (Join-Path $skillRoot 'templates') -Destination $stagedRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $skillRoot 'manifest.json') -Destination $stagedRoot
    $skillRoot = $stagedRoot
    $ScriptPath = Join-Path $skillRoot 'scripts/assemble.ps1'
}

Test-Case 'Unicode/newlines/backticks exact bytes and ignored executable fields' {
    $path = New-Project
    $secret = 'SECRET-DO-NOT-PRINT-7291'
    $marker = Join-Path $path 'must-not-exist'
    $prompt = "中文🙂`r`nline two ``literal`` `$(`$secret) $secret`n最后一行"
    $payload = New-Payload $path $prompt
    $payload.command = "New-Item '$marker'"
    $payload.transcript_path = "`$(New-Item '$marker')"
    $context = Assert-Success (Invoke-Hook $path $payload)
    $task = 'session-' + (Sha $payload.session_id).Substring(0, 16)
    $expected = "<<<MSG M00001 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} task=$task>>>`n" + [regex]::Escape($prompt) + "`n<<<END M00001>>>`n"
    Assert-True ((Read-Raw $path) -cmatch ('\A' + $expected + '\z')) 'Raw text was not preserved byte-for-byte.'
    Assert-True (-not $context.Contains($secret)) 'Prompt leaked into injected context.'
    Assert-True (-not [IO.File]::Exists($marker)) 'Payload command executed.'
    Assert-True ($context.Contains('No stable event id; no dedup guarantee')) 'Missing unstable-event warning.'
    Assert-Equal (Get-Receipts $path).Count 0 'No-id event created receipt.'
    Assert-NoTemp $path
}
foreach ($sample in @('', '   ', "tail `t`r`n`n", " `r`n  ")) {
    Test-Case ('empty/whitespace exact preservation length=' + $sample.Length) {
        $path = New-Project
        $payload = New-Payload $path $sample 'whitespace-event'
        [void](Assert-Success (Invoke-Hook $path $payload))
        [void](Assert-Success (Invoke-Hook $path $payload))
        $raw = Read-Raw $path
        Assert-True ($raw -cmatch ('>>>\n' + [regex]::Escape($sample) + '\n<<<END M00001>>>\n\z')) 'Whitespace content changed.'
        Assert-Equal ([regex]::Matches($raw, '(?m)^<<<MSG ').Count) 1 'Replay duplicated whitespace record.'
        Assert-NoTemp $path
    }
}
Test-Case 'stable receipt dedup, identity hashing, privacy and conflict rejection' {
    $path = New-Project
    $payload = New-Payload $path 'sensitive prompt UNIQUE-SECRET' 'prompt-id-NOT-RAW'
    $first = Assert-Success (Invoke-Hook $path $payload)
    $second = Assert-Success (Invoke-Hook $path $payload)
    Assert-Equal $first $second 'Stable replay changed context/id.'
    $raw = Read-Raw $path
    Assert-Equal ([regex]::Matches($raw, '(?m)^<<<MSG ').Count) 1 'Stable replay duplicated record.'
    $entries = Get-Receipts $path
    Assert-Equal $entries.Count 1 'Wrong receipt count.'
    Assert-Equal $entries[0].BaseName (Sha ($payload.session_id + [char]0 + $payload.prompt_id)) 'Wrong event key.'
    $receiptText = [IO.File]::ReadAllText($entries[0].FullName, $utf8)
    foreach ($private in @($payload.prompt, $payload.prompt_id, $payload.session_id)) { Assert-True (-not $receiptText.Contains($private)) 'Receipt kept sensitive input.' }
    $receipt = ConvertFrom-Json $receiptText -AsHashtable
    Assert-Equal $receipt.status 'done' 'Receipt not committed.'
    Assert-Equal $receipt.promptSha (Sha $payload.prompt) 'Receipt prompt hash mismatch.'
    Assert-True (-not $raw.Contains($payload.prompt_id)) 'prompt_id recorded as original text.'
    $payload.prompt = 'different content SECRET-REJECTED'
    Assert-Blocked (Invoke-Hook $path $payload)
    Assert-Equal (Read-Raw $path) $raw 'Conflicting event changed history.'
    $payload.prompt = 'sensitive prompt UNIQUE-SECRET'
    # A new stable event with the same text is legal. Replaying the first receipt
    # must locate its recorded rawId, not mistake later identical content for it.
    [void](Assert-Success (Invoke-Hook $path (New-Payload $path $payload.prompt 'second-legal-id')))
    [void](Assert-Success (Invoke-Hook $path $payload))
    $raw = Read-Raw $path
    Assert-Equal ([regex]::Matches($raw, '(?m)^<<<MSG ').Count) 2 'Different stable ids were content-deduplicated.'
    $payload.cwd = $testRoot
    Assert-Blocked (Invoke-Hook $path $payload)
    Assert-Equal (Read-Raw $path) $raw 'Wrong-cwd replay changed history.'
    Assert-NoTemp $path
}
Test-Case 'no prompt_id logs legal identical prompts twice; separate sessions remain separate' {
    $path = New-Project
    $payload = New-Payload $path 'same legal text'
    [void](Assert-Success (Invoke-Hook $path $payload))
    [void](Assert-Success (Invoke-Hook $path $payload))
    $payload.session_id = 'different session'
    [void](Assert-Success (Invoke-Hook $path $payload))
    Assert-Equal ([regex]::Matches((Read-Raw $path), '(?m)^<<<MSG ').Count) 3 'Content incorrectly deduplicated.'
    Assert-Equal ([regex]::Matches((Read-Raw $path), 'task=session-[0-9a-f]{16}') | ForEach-Object Value | Sort-Object -Unique).Count 2 'Sessions not separated.'
}
Test-Case 'cross-project separate receipts/raw databases and canonical cwd equality' {
    $first = New-Project
    $second = New-Project
    $payload1 = New-Payload $first 'project-specific' 'same event'
    $payload1.cwd = Join-Path $first '.'
    $payload2 = New-Payload $second 'project-specific' 'same event'
    [void](Assert-Success (Invoke-Hook $first $payload1))
    [void](Assert-Success (Invoke-Hook $second $payload2))
    Assert-Equal (Get-Receipts $first).Count 1 'First project receipt missing.'
    Assert-Equal (Get-Receipts $second).Count 1 'Second project receipt missing.'
    Assert-Equal ([regex]::Matches((Read-Raw $first), '(?m)^<<<MSG ').Count) 1 'First project raw count wrong.'
    Assert-Equal ([regex]::Matches((Read-Raw $second), '(?m)^<<<MSG ').Count) 1 'Second project raw count wrong.'
}
Test-Case 'missing, wrong-type and unsupported fields never leak secrets' {
    $path = New-Project
    foreach ($field in @('session_id', 'prompt', 'cwd')) {
        $payload = New-Payload $path 'SECRET-INPUT-891'
        [void]$payload.Remove($field)
        Assert-Blocked (Invoke-Hook $path $payload)
    }
    foreach ($field in @('session_id', 'prompt', 'cwd', 'hook_event_name', 'prompt_id')) {
        foreach ($value in @($null, 14, @('data'), @{ nested = 'SECRET-NESTED' })) {
            $payload = New-Payload $path 'SECRET-INPUT-891'
            $payload[$field] = $value
            Assert-Blocked (Invoke-Hook $path $payload)
        }
    }
    foreach ($field in @('session_id', 'prompt_id')) {
        $payload = New-Payload $path
        $payload[$field] = ''
        Assert-Blocked (Invoke-Hook $path $payload)
    }
    $payload = New-Payload $path
    $payload.hook_event_name = 'userpromptsubmit'
    Assert-Blocked (Invoke-Hook $path $payload)
    Assert-Blocked (Invoke-Hook $path '{SECRET-INVALID-JSON')
    Assert-Blocked (Invoke-Hook $path '["SECRET-ARRAY"]')
    Assert-Blocked (Invoke-Hook $path 'null')
    Assert-Equal (Read-Raw $path) '' 'Invalid payload wrote history.'
    [void]$payload.Remove('hook_event_name')
    [void](Assert-Success (Invoke-Hook $path $payload))
}
Test-Case 'cwd mismatch and non-initialized project block without logging' {
    $path = New-Project
    $payload = New-Payload $path
    $payload.cwd = $testRoot
    Assert-Blocked (Invoke-Hook $path $payload)
    Assert-Equal (Read-Raw $path) '' 'Wrong project logged.'
    $fresh = Join-Path $testRoot 'not-initialized'
    [void][IO.Directory]::CreateDirectory($fresh)
    Assert-Blocked (Invoke-Hook $fresh (New-Payload $fresh))
    Assert-True (-not [IO.Directory]::Exists((Join-Path $fresh '.neuron-harness'))) 'Hook initialized project itself.'
}
Test-Case 'missing and oversized runtime block; exact cap accepted' {
    $path = New-Project
    $runtime = Join-Path $path '.neuron-harness/runtime.md'
    # Move rather than delete retained test runtime/history.
    [IO.File]::Move($runtime, ($runtime + '.saved'))
    Assert-Blocked (Invoke-Hook $path (New-Payload $path))
    [IO.File]::WriteAllText($runtime, ('x' * 16001), $utf8)
    Assert-Blocked (Invoke-Hook $path (New-Payload $path))
    Assert-Equal (Read-Raw $path) '' 'Runtime failure logged prompt.'
    [IO.File]::WriteAllText($runtime, ('TEST PROJECT RUNTIME' + ('x' * (16000 - 20))), $utf8)
    [void](Assert-Success (Invoke-Hook $path (New-Payload $path)))
}
Test-Case 'after-LogRaw crash prepared receipt recovers once and blocks other events' {
    $path = New-Project
    $payload = New-Payload $path "崩溃测试`noriginal  `n" 'crash-id'
    Assert-Blocked (Invoke-Hook $path $payload @{ NH_HOOK_TEST_FAIL_AFTER_LOG = '1' })
    $raw = Read-Raw $path
    Assert-Equal ([regex]::Matches($raw, '(?m)^<<<MSG ').Count) 1 'Injected failure did not append once.'
    $entry = (Get-Receipts $path)[0]
    $receipt = ConvertFrom-Json ([IO.File]::ReadAllText($entry.FullName, $utf8)) -AsHashtable
    Assert-Equal $receipt.status 'prepared' 'Crash receipt not prepared.'
    Assert-Blocked (Invoke-Hook $path (New-Payload $path $payload.prompt 'other-event'))
    Assert-Blocked (Invoke-Hook $path (New-Payload $path $payload.prompt))
    Assert-Equal (Read-Raw $path) $raw 'Another event obscured pending recovery.'
    [void](Assert-Success (Invoke-Hook $path $payload))
    Assert-Equal (Read-Raw $path) $raw 'Recovery duplicated raw record.'
    Assert-Equal (ConvertFrom-Json ([IO.File]::ReadAllText($entry.FullName, $utf8)) -AsHashtable).status 'done' 'Recovery not committed.'
    Assert-NoTemp $path
}
Test-Case 'prepared receipt before append retries; truncated/modified log fails closed' {
    $path = New-Project
    $payload = New-Payload $path 'normal event' 'preappend'
    [void](Assert-Success (Invoke-Hook $path $payload))
    $entry = (Get-Receipts $path)[0]
    $receipt = ConvertFrom-Json ([IO.File]::ReadAllText($entry.FullName, $utf8)) -AsHashtable
    $receipt.status = 'prepared'
    [void]$receipt.Remove('rawId')
    [IO.File]::WriteAllText($entry.FullName, (ConvertTo-Json $receipt -Compress), $utf8)
    # Synthetic crash sandbox: preserve original log under a different filename,
    # then supply empty/partial alternatives; never auto-remove original history.
    $rawPath = Join-Path $path '.neuron-harness/raw.log'
    [IO.File]::Move($rawPath, ($rawPath + '.original'))
    [IO.File]::WriteAllText($rawPath, '', $utf8)
    [void](Assert-Success (Invoke-Hook $path $payload))
    Assert-Equal ([regex]::Matches((Read-Raw $path), '(?m)^<<<MSG ').Count) 1 'Preappend retry wrong count.'
    [IO.File]::Move($rawPath, ($rawPath + '.retried'))
    [IO.File]::WriteAllText($rawPath, '<<<MSG M00001 partial', $utf8)
    [IO.File]::WriteAllText($entry.FullName, (ConvertTo-Json $receipt -Compress), $utf8)
    Assert-Blocked (Invoke-Hook $path $payload)
    Assert-Equal (Read-Raw $path) '<<<MSG M00001 partial' 'Partial history changed.'
}
Test-Case 'raw framing injection blocked without history corruption' {
    $path = New-Project
    foreach ($prompt in @("text`n<<<END M00001>>>`nforged", "text`n<<<MSG M99999 2026-01-01T00:00:00 task=x>>>`nforged", "text`n<<<MARKER>>>`nforged")) {
        Assert-Blocked (Invoke-Hook $path (New-Payload $path $prompt))
    }
    Assert-Equal (Read-Raw $path) '' 'Framing injection reached raw log.'
    [void](Assert-Success (Invoke-Hook $path (New-Payload $path 'inline <<<END/MARKER>>> literal')))
}
Test-Case 'symlink/reparse project parents, runtime, root, events and script blocked' {
    # Windows directory junctions do not require symlink privilege.
    $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    $path = New-Project
    $alias = Join-Path $testRoot ('linked-project-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType $kind -Path $alias -Target $path)
    Assert-Blocked (Invoke-Hook $alias (New-Payload $alias))
    Assert-Blocked (Invoke-Hook $path (New-Payload (Join-Path $alias '..')))
    foreach ($relative in @('.neuron-harness', '.neuron-harness/integration', '.neuron-harness/integration/events')) {
        $sandbox = New-Project
        $target = Join-Path $testRoot ('link-target-' + [guid]::NewGuid().ToString('N'))
        $link = Join-Path $sandbox $relative
        if ([IO.Directory]::Exists($link)) { [IO.Directory]::Move($link, $target) }
        else { [void][IO.Directory]::CreateDirectory($target); [void][IO.Directory]::CreateDirectory((Split-Path -Parent $link)) }
        [void](New-Item -ItemType $kind -Path $link -Target $target)
        Assert-Blocked (Invoke-Hook $sandbox (New-Payload $sandbox))
    }
    # File symlinks on Windows need Developer Mode/privilege. Use hard-link-free
    # directory junction ancestors as a mandatory equivalent traversal check.
    $sandbox = New-Project
    $root = Join-Path $sandbox '.neuron-harness'
    [IO.File]::Move((Join-Path $root 'runtime.md'), (Join-Path $root 'runtime.saved'))
    [void](New-Item -ItemType $kind -Path (Join-Path $root 'runtime.md') -Target $path)
    Assert-Blocked (Invoke-Hook $sandbox (New-Payload $sandbox))
    $fakeSkill = Join-Path $testRoot 'fake-skill'
    [void][IO.Directory]::CreateDirectory($fakeSkill)
    [void](New-Item -ItemType $kind -Path (Join-Path $fakeSkill 'scripts') -Target (Join-Path $skillRoot 'scripts'))
    Assert-Blocked (Invoke-Hook $path (New-Payload $path) @{} $fakeSkill)
}

Test-Case 'concurrent identical stable submissions serialize and append once' {
    $path = New-Project
    $payload = New-Payload $path 'concurrent stable input' 'concurrent-id'
    $json = ConvertTo-Json $payload -Compress
    $children = [Collections.Generic.List[object]]::new()
    try {
        for ($i = 0; $i -lt 4; $i++) {
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = Join-Path $PSHOME ('pwsh' + $(if ($IsWindows) { '.exe' } else { '' }))
            $info.UseShellExecute = $false
            $info.RedirectStandardInput = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.StandardInputEncoding = $utf8
            $info.StandardOutputEncoding = $utf8
            $info.StandardErrorEncoding = $utf8
            [void]$info.Environment.Remove('NH_HOOK_TEST_FAIL_AFTER_LOG')
            foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $HookPath, '-Project', $path, '-SkillRoot', $skillRoot)) { $info.ArgumentList.Add($arg) }
            $child = [Diagnostics.Process]::new()
            $child.StartInfo = $info
            [void]$child.Start()
            $outTask = $child.StandardOutput.ReadToEndAsync()
            $errTask = $child.StandardError.ReadToEndAsync()
            $child.StandardInput.Write($json)
            $child.StandardInput.Close()
            $children.Add(@{ Process = $child; OutTask = $outTask; ErrTask = $errTask })
        }
        foreach ($entry in $children) {
            Assert-True ($entry.Process.WaitForExit(90000)) 'Concurrent hook timeout.'
            [void](Assert-Success @{ Code = $entry.Process.ExitCode; Out = $entry.OutTask.GetAwaiter().GetResult(); Err = $entry.ErrTask.GetAwaiter().GetResult() })
        }
    } finally {
        foreach ($entry in $children) {
            if (-not $entry.Process.HasExited) { $entry.Process.Kill($true); $entry.Process.WaitForExit() }
            $entry.Process.Dispose()
        }
    }
    Assert-Equal ([regex]::Matches((Read-Raw $path), '(?m)^<<<MSG ').Count) 1 'Concurrent event appended more than once.'
    Assert-NoTemp $path
}
Test-Case 'default SkillRoot and whitespace-only session id stay literal' {
    $path = New-Project
    $payload = New-Payload $path 'session literal'
    $payload.session_id = '  '
    $result = if ($skillRoot -eq (Split-Path -Parent $PSScriptRoot)) {
        Invoke-Hook $path $payload -DefaultSkill
    } else { Invoke-Hook $path $payload }
    $context = Assert-Success $result
    Assert-True ($context.Contains(('TaskId=session-' + (Sha '  ').Substring(0, 16)))) 'session_id was trimmed.'
}

Test-Case 'raw-only prepared recovery completes switch/dep signals before done' {
    foreach ($mark in @('[新任务]', '[切换]', '[switch]', '[改依赖]', '[依赖变更]', '[dep]')) {
        $path = New-Project
        $payload = New-Payload $path ($mark + ' signal crash fixture') 'signal-event'
        Assert-Blocked (Invoke-Hook $path $payload @{ NH_HOOK_TEST_FAIL_AFTER_LOG = '1' })
        $raw = Read-Raw $path
        $signalPath = Join-Path $path '.neuron-harness/pending-recheck.log'
        # Preserve the existing side effect, then reconstruct the real crash
        # window: durable raw append but no pending signal row at all.
        [IO.File]::Move($signalPath, ($signalPath + '.original'))
        [void](Assert-Success (Invoke-Hook $path $payload))
        Assert-Equal (Read-Raw $path) $raw 'Signal recovery duplicated raw.'
        $signal = [IO.File]::ReadAllText($signalPath, $utf8)
        Assert-True ($signal -match 'SIGNAL-(switch|dep)\t(session-[0-9a-f]{16})') 'Recovery lost mechanical signal.'
        [void](Assert-Success (Invoke-Hook $path $payload))
        Assert-Equal ([IO.File]::ReadAllText($signalPath, $utf8)) $signal 'Done replay duplicated signal.'
        # A distinct stable event with the same mark must emit a new signal.
        [void](Assert-Success (Invoke-Hook $path (New-Payload $path $payload.prompt 'later-signal-event')))
        Assert-True (([IO.File]::ReadAllText($signalPath, $utf8)).Length -gt $signal.Length) 'Later signal event wrongly deduplicated by task.'
    }
}
Test-Case 'leading FEFF and embedded FEFF remain literal original text' {
    foreach ($text in @(([string][char]0xfeff + '正文'), ([string][char]0xfeff + [char]0xfeff + 'two'), ('inside' + [char]0xfeff + 'value'))) {
        $path = New-Project
        [void](Assert-Success (Invoke-Hook $path (New-Payload $path $text 'feff-event')))
        Assert-True ((Read-Raw $path).Contains((">>>`n" + $text + "`n<<<END M00001>>>"))) 'Original FEFF was lost.'
        [void](Assert-Success (Invoke-Hook $path (New-Payload $path $text 'feff-event')))
    }
}

Write-Output "RESULT passed=$passed failed=$($failures.Count)"
Write-Output "SANDBOX $testRoot"
if ($failures.Count -gt 0) { foreach ($failure in $failures) { Write-Output $failure }; exit 1 }
exit 0
