#Requires -Version 7.0
<#
Claude UserPromptSubmit adapter. stdin is data, never PowerShell source.
Only the installed project runtime is injected. No prompt/session/prompt_id copies
are kept in receipts. Local-filesystem atomic rename/CreateNew semantics required.

LogRaw must preserve ContentFile verbatim (including empty/trailing whitespace).
The legacy raw format does not escape log delimiters: fail closed for delimiter
lines rather than claim a safe record that the backend cannot make.
A crashed, incomplete raw block is ambiguous and requires operator repair; the
hook never deletes/truncates raw history or silently appends a second copy.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Project,
    [string]$SkillRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [System.Text.UTF8Encoding]::new($false, $true)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$hookLockHandle = $null
$inputTemp = $null
$receiptTemp = $null
$exitCode = 2
$responseJson = $null

function Get-Sha([string]$Text) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($Text))).ToLowerInvariant()
}

# Walk every existing component, not Resolve-Path (which follows junctions).
# Checking the uncollapsed spelling too prevents parent/link/../safe bypasses.
function Assert-NoReparse([string]$Path) {
    $candidate = $Path
    while (-not [string]::IsNullOrEmpty($candidate)) {
        try {
            $attributes = [IO.File]::GetAttributes($candidate)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Unsafe path.' }
        } catch [IO.FileNotFoundException] {
        } catch [IO.DirectoryNotFoundException] {
        }
        $parent = [IO.Path]::GetDirectoryName($candidate)
        if ($parent -eq $candidate) { break }
        $candidate = $parent
    }
}
function Get-SafePath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Absolute path required.' }
    Assert-NoReparse $Path
    $full = [IO.Path]::GetFullPath($Path)
    Assert-NoReparse $full
    return [IO.Path]::TrimEndingDirectorySeparator($full)
}
function Assert-File([string]$Path) {
    Assert-NoReparse $Path
    if (-not [IO.File]::Exists($Path)) { throw 'Required file missing.' }
}
function Read-Runtime([string]$Path) {
    Assert-File $Path
    $reader = [IO.StreamReader]::new($Path, $utf8, $false)
    try {
        $buffer = [char[]]::new(16001)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $reader.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt 16000 -or $count -eq 0) { throw 'Invalid runtime length.' }
        return [string]::new($buffer, 0, $count)
    } finally { $reader.Dispose() }
}

# Holding the CreateNew handle without FileShare.Delete prevents stale-lock
# reclamation while an owner is alive, including concurrent reclaimers. A killed
# owner leaves an unlocked file; one reclaimer opens it exclusively and removes
# it before all contenders retry CreateNew. No PID reuse or time-based stealing.
function Enter-HookLock([string]$Path) {
    $deadline = [datetime]::UtcNow.AddSeconds(30)
    while ($true) {
        Assert-NoReparse $Path
        try {
            return [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        } catch [IO.IOException] {
            if ([IO.File]::Exists($Path)) {
                $staleHandle = $null
                try {
                    $staleHandle = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Delete)
                    [IO.File]::Delete($Path)
                } catch [IO.IOException] {
                    # A live owner (or a reclaimer) still has the file open.
                } finally {
                    if ($null -ne $staleHandle) { $staleHandle.Dispose() }
                }
            }
            if ([datetime]::UtcNow -ge $deadline) { throw 'Hook lock timeout.' }
            Start-Sleep -Milliseconds 40
        }
    }
}

# Fingerprint the entire pre-existing byte prefix. On replay, consume only bytes
# appended after the durable prepared receipt; never content-dedup old messages.
function Read-RawSnapshot([string]$Path, [long]$Before = -1) {
    Assert-File $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $length = $stream.Length
        if ($Before -lt 0) {
            $Before = $length
            if ($length -gt 0) {
                $tailLength = [int][Math]::Min(100, $length)
                [void]$stream.Seek(-$tailLength, [IO.SeekOrigin]::End)
                $endBytes = [byte[]]::new($tailLength)
                $stream.ReadExactly($endBytes, 0, $tailLength)
                if ([Text.Encoding]::ASCII.GetString($endBytes) -notmatch '<<<END M\d{5,}>>>\n\z') { throw 'Incomplete raw log.' }
                [void]$stream.Seek(0, [IO.SeekOrigin]::Begin)
            }
        }
        if ($Before -gt $length) { throw 'Raw history changed.' }
        $buffer = [byte[]]::new(65536)
        $remaining = $Before
        while ($remaining -gt 0) {
            $read = $stream.Read($buffer, 0, [int][Math]::Min($remaining, $buffer.Length))
            if ($read -eq 0) { throw 'Raw history changed.' }
            $hasher.AppendData($buffer, 0, $read)
            $remaining -= $read
        }
        $prefixSha = [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
        $reader = [IO.StreamReader]::new($stream, $utf8, $false, 4096, $true)
        try { $tail = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return @{ beforeLength = $Before; prefixSha = $prefixSha; tail = $tail }
    } finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}
function Find-LoggedMessage($Receipt, [string]$Prompt) {
    $snapshot = Read-RawSnapshot $rawPath ([long]$Receipt.rawLogBeforeByteLength)
    if ($snapshot.prefixSha -cne $Receipt.rawPrefixSha) { throw 'Raw history changed.' }
    $tail = $snapshot.tail
    $pattern = '\G<<<MSG (?<id>M\d{5,}) \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} task=(?<task>[A-Za-z0-9._*-]+)>>>\n(?<body>.*?)\n<<<END \k<id>>>>\n'
    $offset = 0
    $found = ''
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($offset -lt $tail.Length) {
        # Parse only complete frames, anchored at the last byte boundary.
        $parser = [regex]::new($pattern, [Text.RegularExpressions.RegexOptions]::Singleline, [timespan]::FromSeconds(5))
        $block = $parser.Match($tail, $offset)
        if (-not $block.Success -or $block.Index -ne $offset) { throw 'Ambiguous partial raw append.' }
        $id = $block.Groups['id'].Value
        if (-not $seen.Add($id)) { throw 'Duplicate raw ID.' }
        if ($block.Groups['task'].Value -ceq $Receipt.taskId -and
            (Get-Sha $block.Groups['body'].Value) -ceq $Receipt.promptSha -and
            [string]::Equals($block.Groups['body'].Value, $Prompt, [StringComparison]::Ordinal) -and
            ($Receipt.status -cne 'done' -or $id -ceq $Receipt.rawId)) {
            if ($found -ne '') { throw 'Ambiguous repeated raw append.' }
            $found = $id
        }
        $offset += $block.Length
    }
    return $found
}
function Write-Receipt([string]$Path, $Receipt) {
    Assert-NoReparse $Path
    $script:receiptTemp = Join-Path $eventsPath ([guid]::NewGuid().ToString('N') + '.tmp')
    $file = [IO.File]::Open($script:receiptTemp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = $utf8.GetBytes((ConvertTo-Json -InputObject $Receipt -Depth 8 -Compress))
        $file.Write($bytes, 0, $bytes.Length)
        $file.Flush($true)
    } finally { $file.Dispose() }
    [IO.File]::Move($script:receiptTemp, $Path, $true)
    $script:receiptTemp = $null
}
function Read-Receipt([string]$Path) {
    Assert-File $Path
    $receipt = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path, $utf8)) -AsHashtable
    if ($receipt -isnot [Collections.IDictionary] -or $receipt.version -ne 1 -or
        $receipt.status -cnotin @('prepared', 'done') -or
        $receipt.taskId -cnotmatch '^session-[0-9a-f]{16}$' -or
        $receipt.promptSha -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.rawPrefixSha -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.projectSha -cnotmatch '^[0-9a-f]{64}$' -or
        $receipt.rawLogBeforeByteLength -isnot [long] -and $receipt.rawLogBeforeByteLength -isnot [int]) { throw 'Invalid receipt.' }
    if ($receipt.rawLogBeforeByteLength -lt 0) { throw 'Invalid receipt.' }
    if ($receipt.status -ceq 'done' -and $receipt.rawId -cnotmatch '^M\d{5,}$') { throw 'Invalid receipt.' }
    return $receipt
}
function Invoke-LogRaw([string]$ContentPath) {
    # Same-process invocation is essential: killing this hook must also stop
    # LogRaw. A child process could outlive the hook lock and append after the
    # next replay's scan. Capture every PowerShell stream; only verified JSON
    # from the adapter is allowed on stdout, never backend diagnostics.
    $captured = @(& $assemblePath -Mode LogRaw -Project $projectPath -TaskId $taskId -ContentFile $ContentPath *>&1)
    if ($captured.Count -ne 1 -or $captured[0] -isnot [string] -or $captured[0] -cnotmatch '\AM\d{5,}\z') { throw 'Log failed.' }
    return $captured[0]
}
function Complete-Signal([string]$Prompt) {
    # LogRaw appends raw then signal under its own lock, so a process crash can
    # leave only raw. Complete this side effect before committing a receipt.
    # Existing signal rows have no event ID: deliberately at-least-once, never
    # deduplicate by task+signal (that would discard later distinct events).
    $firstLine = (@($Prompt -split "`n")[0]).Trim()
    $signal = ''
    if ($firstLine -match '^\[(新任务|切换|switch)\]') { $signal = 'switch' }
    elseif ($firstLine -match '^\[(改依赖|依赖变更|dep)\]') { $signal = 'dep' }
    if ($signal -eq '') { return }
    $signalPath = Join-Path $rootPath 'pending-recheck.log'
    Assert-NoReparse $signalPath
    $captured = @(& $assemblePath -Mode Signal -Project $projectPath -TaskId $taskId -Signal $signal *>&1)
    if ($captured.Count -ne 1 -or $captured[0] -isnot [string] -or $captured[0] -cne "SIGNAL: $signal ($taskId)") { throw 'Signal failed.' }
    Assert-File $signalPath
    $signalFile = [IO.File]::Open($signalPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try { $signalFile.Flush($true) } finally { $signalFile.Dispose() }
}

try {
    # ReadToEnd is deliberate: embedded newlines and empty string are valid JSON
    # string content. No pipeline line splitting, trimming or normalization.
    $inputJson = [Console]::In.ReadToEnd()
    $payload = ConvertFrom-Json -InputObject $inputJson -AsHashtable
    if ($payload -isnot [Collections.IDictionary]) { throw 'Invalid payload.' }
    if ($payload.Contains('hook_event_name') -and $payload.hook_event_name -cne 'UserPromptSubmit') { throw 'Unsupported event.' }
    if (-not $payload.Contains('session_id') -or $payload.session_id -isnot [string] -or $payload.session_id.Length -eq 0) { throw 'Invalid session.' }
    if (-not $payload.Contains('prompt') -or $payload.prompt -isnot [string]) { throw 'Invalid prompt.' }
    if (-not $payload.Contains('cwd') -or $payload.cwd -isnot [string]) { throw 'Invalid cwd.' }
    $prompt = $payload.prompt
    $stableId = $payload.Contains('prompt_id')
    if ($stableId -and ($payload.prompt_id -isnot [string] -or $payload.prompt_id.Length -eq 0)) { throw 'Invalid event ID.' }

    $projectPath = Get-SafePath $Project
    $cwdPath = Get-SafePath $payload.cwd
    $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not [IO.Directory]::Exists($projectPath) -or -not [string]::Equals($cwdPath, $projectPath, $pathComparison)) { throw 'Wrong project.' }
    $skillPath = Get-SafePath $SkillRoot
    [void](Get-SafePath $PSCommandPath)
    $assemblePath = Join-Path $skillPath 'scripts/assemble.ps1'
    Assert-File $assemblePath
    $rootPath = Join-Path $projectPath '.neuron-harness'
    Assert-NoReparse $rootPath
    $rawPath = Join-Path $rootPath 'raw.log'
    Assert-File $rawPath
    Assert-File (Join-Path $rootPath 'index.tsv')
    $runtime = Read-Runtime (Join-Path $rootPath 'runtime.md')
    foreach ($leaf in @('.lock', 'pending-recheck.log')) { Assert-NoReparse (Join-Path $rootPath $leaf) }
    $eventsPath = Join-Path $rootPath 'integration/events'
    Assert-NoReparse $eventsPath
    [void][IO.Directory]::CreateDirectory($eventsPath)
    Assert-NoReparse $eventsPath
    $hookLockPath = Join-Path $rootPath '.hook.lock'
    $hookLockHandle = Enter-HookLock $hookLockPath

    $taskId = 'session-' + (Get-Sha $payload.session_id).Substring(0, 16)
    $promptSha = Get-Sha $prompt
    $projectIdentity = if ($IsWindows) { $projectPath.ToUpperInvariant() } else { $projectPath }
    $projectSha = Get-Sha $projectIdentity
    $receiptPath = $null
    $receipt = $null
    if ($stableId) {
        $eventKey = Get-Sha ($payload.session_id + [char]0 + $payload.prompt_id)
        $receiptPath = Join-Path $eventsPath ($eventKey + '.json')
        if ([IO.File]::Exists($receiptPath)) {
            $receipt = Read-Receipt $receiptPath
            if ($receipt.taskId -cne $taskId -or $receipt.promptSha -cne $promptSha -or $receipt.projectSha -cne $projectSha) { throw 'Event ID conflict.' }
        }
    }
    # A different unfinished event must be replayed first. Otherwise an identical
    # later prompt could be mistaken for the pending append during crash recovery.
    foreach ($entry in [IO.Directory]::EnumerateFiles($eventsPath, '*.json')) {
        $other = Read-Receipt $entry
        if ($other.status -ceq 'prepared' -and -not [string]::Equals($entry, $receiptPath, $pathComparison)) { throw 'Pending event requires replay.' }
    }

    # The backend format cannot distinguish injected framing lines from records.
    # Do not encode an alternate representation and advertise it as raw text.
    if ($prompt -match '(?:\A|[\r\n])<<<(?:MSG(?:\s|>)|END(?:\s|>)|MARKER>>>)') { throw 'Unsafe raw framing.' }

    $rawId = ''
    if ($null -ne $receipt) {
        $rawId = Find-LoggedMessage $receipt $prompt
        if ($receipt.status -ceq 'done' -and $rawId -cne $receipt.rawId) { throw 'Receipt does not match raw history.' }
    } else {
        $snapshot = Read-RawSnapshot $rawPath
        $receipt = [ordered]@{
            version = 1; status = 'prepared'; taskId = $taskId
            promptSha = $promptSha; projectSha = $projectSha
            rawLogBeforeByteLength = [long]$snapshot.beforeLength
            rawPrefixSha = $snapshot.prefixSha
        }
        if ($stableId) { Write-Receipt $receiptPath $receipt }
    }
    if ($rawId -eq '') {
        $inputTemp = Join-Path $eventsPath ([guid]::NewGuid().ToString('N') + '.tmp')
        $inputFile = [IO.File]::Open($inputTemp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            # A transport BOM is consumed by assemble's ReadAllText. A literal
            # first U+FEFF in the prompt is then a second FEFF and is preserved.
            # Receipts/raw remain UTF-8 without a BOM; only this transient input
            # uses one, deliberately matching the backend's decoding contract.
            $preamble = [byte[]]@(0xef, 0xbb, 0xbf)
            $inputFile.Write($preamble, 0, $preamble.Length)
            $bytes = $utf8.GetBytes($prompt)
            $inputFile.Write($bytes, 0, $bytes.Length)
            $inputFile.Flush($true)
        } finally { $inputFile.Dispose() }
        $reportedId = Invoke-LogRaw $inputTemp
        if ($env:NH_HOOK_TEST_FAIL_AFTER_LOG -ceq '1') { throw 'Injected failure after LogRaw.' }
        $rawId = Find-LoggedMessage $receipt $prompt
        if ($rawId -cne $reportedId) { throw 'Raw append verification failed.' }
    }
    # Flush raw bytes before the durable done receipt and success output.
    Assert-File $rawPath
    $rawDurability = [IO.File]::Open($rawPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try { $rawDurability.Flush($true) } finally { $rawDurability.Dispose() }
    if ($receipt.status -cne 'done') { Complete-Signal $prompt }
    if ($stableId -and $receipt.status -cne 'done') {
        $receipt.status = 'done'
        $receipt['rawId'] = $rawId
        Write-Receipt $receiptPath $receipt
    }
    $dedup = if ($stableId) { 'Stable event receipt verified.' } else { 'No stable event id; no dedup guarantee. Identical messages are recorded independently.' }
    $context = "neuron-harness: message already recorded as raw MSG id $rawId; TaskId=$taskId. Do not LogRaw this message again. $dedup`n`n$runtime"
    $response = @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $context } }
    $responseJson = ConvertTo-Json -InputObject $response -Depth 5 -Compress
    $exitCode = 0
} catch {
    # Never print $_, script stack traces, arguments, paths, original JSON, or
    # child stderr: all may contain secrets from user-controlled input.
    [Console]::Error.WriteLine('neuron-harness prompt hook failed; submission blocked.')
} finally {
    foreach ($ownedTemp in @($inputTemp, $receiptTemp)) {
        if ($null -ne $ownedTemp) {
            try {
                Assert-NoReparse $ownedTemp
                [IO.File]::Delete($ownedTemp)
            } catch {
                $exitCode = 2
                [Console]::Error.WriteLine('neuron-harness prompt hook cleanup failed; submission blocked.')
            }
        }
    }
    if ($null -ne $hookLockHandle) {
        # Dispose then delete has a create/open race. Keep the handle open with
        # FileShare.None throughout ownership; close only after all work is done.
        # The next caller reclaims the now-unlocked file under an exclusive open.
        $hookLockHandle.Dispose()
    }
}
if ($exitCode -eq 0) {
    try { [Console]::Out.WriteLine($responseJson) }
    catch {
        [Console]::Error.WriteLine('neuron-harness prompt hook failed; submission blocked.')
        $exitCode = 2
    }
}
exit $exitCode
