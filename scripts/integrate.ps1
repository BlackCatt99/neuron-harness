#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [ValidateSet('Plan','Install','Status','Uninstall','Recover')][string]$Action = 'Plan',
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Project,
    [Parameter(Mandatory)][ValidateSet('zcode','codex','claude','cursor','generic')][string]$Harness,
    [string]$SkillRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$EnablePromptHook,
    [switch]$Init,
    [switch]$RecoverStaleLock,
    # Fault injection is inert unless both this explicit test switch and the environment variable are set.
    [switch]$TestFaultInjection
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Utf8 = [Text.UTF8Encoding]::new($false, $true)
$script:WriteCount = 0

function Assert-SafePath([string]$Target) {
    $checkPath = [IO.Path]::GetFullPath($Target)
    while ($checkPath) {
        $entryInfo = $null
        try { $entryInfo = Get-Item -LiteralPath $checkPath -Force -ErrorAction Stop }
        catch { if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound) { throw } }
        if ($null -ne $entryInfo -and ($entryInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Symlink/reparse point refused: $checkPath" }
        $parentPath = [IO.Path]::GetDirectoryName($checkPath)
        if ($parentPath -eq $checkPath) { break }
        $checkPath = $parentPath
    }
}
function Resolve-Root([string]$InputPath) {
    if (-not [IO.Path]::IsPathFullyQualified($InputPath)) { throw "Root must be an explicit absolute path: $InputPath" }
    # Check each lexical component before GetFullPath can hide link/../safe traversal.
    $lexicalRoot = [IO.Path]::GetPathRoot($InputPath)
    $walkPath = $lexicalRoot
    Assert-SafePath $walkPath
    foreach ($componentName in $InputPath.Substring($lexicalRoot.Length).Split([char[]]@([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),[StringSplitOptions]::RemoveEmptyEntries)) {
        $walkPath = [IO.Path]::Combine($walkPath,$componentName)
        Assert-SafePath $walkPath
    }
    $absolutePath = [IO.Path]::GetFullPath($InputPath)
    Assert-SafePath $absolutePath
    if (-not [IO.Directory]::Exists($absolutePath)) { throw "Root must already exist: $absolutePath" }
    return [IO.Path]::TrimEndingDirectorySeparator($absolutePath)
}
function Get-Hash([byte[]]$Data) {
    if ($null -eq $Data) { $Data = [byte[]]::new(0) }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$Data)).ToLowerInvariant()
}
function Read-Snapshot([string]$Target) {
    Assert-SafePath $Target
    if ([IO.Directory]::Exists($Target)) { throw "Expected file, found directory: $Target" }
    $fileExists = [IO.File]::Exists($Target)
    [byte[]]$fileData = [byte[]]::new(0)
    if ($fileExists) { $fileData = [IO.File]::ReadAllBytes($Target) }
    return @{ exists = $fileExists; hash = (Get-Hash $fileData); data = $fileData }
}
function Assert-Snapshot([string]$Target, $Expected) {
    $observed = Read-Snapshot $Target
    if ($observed.exists -ne $Expected.exists -or $observed.hash -cne $Expected.hash) { throw "File changed; refusing write: $Target" }
}
function Convert-Text([byte[]]$Data) {
    $encodingInfo = $script:Utf8; $skipBytes = 0
    if ($Data.Length -ge 4 -and (($Data[0] -eq 255 -and $Data[1] -eq 254 -and $Data[2] -eq 0 -and $Data[3] -eq 0) -or ($Data[0] -eq 0 -and $Data[1] -eq 0 -and $Data[2] -eq 254 -and $Data[3] -eq 255))) { throw 'Unsupported UTF-32 encoding' }
    if ($Data.Length -ge 3 -and $Data[0] -eq 239 -and $Data[1] -eq 187 -and $Data[2] -eq 191) { $skipBytes = 3; $encodingInfo = [Text.UTF8Encoding]::new($true,$true) }
    elseif ($Data.Length -ge 2 -and $Data[0] -eq 255 -and $Data[1] -eq 254) { $skipBytes = 2; $encodingInfo = [Text.UnicodeEncoding]::new($false,$true,$true) }
    elseif ($Data.Length -ge 2 -and $Data[0] -eq 254 -and $Data[1] -eq 255) { $skipBytes = 2; $encodingInfo = [Text.UnicodeEncoding]::new($true,$true,$true) }
    $decodedText = $encodingInfo.GetString($Data,$skipBytes,$Data.Length-$skipBytes)
    if ($decodedText.Contains([char]0)) { throw 'Unrecognized text encoding (NUL characters)' }
    return @{ text = $decodedText; encoding = $encodingInfo }
}
function Encode-Text($TextInfo, [string]$Value) { return ,([byte[]]($TextInfo.encoding.GetPreamble() + $TextInfo.encoding.GetBytes($Value))) }
function Assert-JsonKeys($Element) {
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $keySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($jsonProperty in $Element.EnumerateObject()) {
            if (-not $keySet.Add($jsonProperty.Name)) { throw "Duplicate JSON key: $($jsonProperty.Name)" }
            Assert-JsonKeys $jsonProperty.Value
        }
    } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($arrayElement in $Element.EnumerateArray()) { Assert-JsonKeys $arrayElement }
    }
}
function Read-StrictJson([byte[]]$Data) {
    $textInfo = Convert-Text $Data
    $jsonDocument = [Text.Json.JsonDocument]::Parse([string]$textInfo.text)
    try { Assert-JsonKeys $jsonDocument.RootElement } finally { $jsonDocument.Dispose() }
    $parsedValue = ConvertFrom-Json -InputObject $textInfo.text -AsHashtable -Depth 100 -NoEnumerate
    if ($parsedValue -isnot [Collections.IDictionary]) { throw 'Expected JSON object' }
    return $parsedValue
}
function Json-Bytes($Value) { return ,$script:Utf8.GetBytes(($Value | ConvertTo-Json -Depth 100) + "`n") }
function Write-Atomic([string]$Target, [byte[]]$Data) {
    Assert-SafePath $Target
    $directoryPath = [IO.Path]::GetDirectoryName($Target)
    [IO.Directory]::CreateDirectory($directoryPath) | Out-Null
    Assert-SafePath $Target
    $temporaryPath = Join-Path $directoryPath ('.nh-' + [guid]::NewGuid().ToString('N') + '.tmp')
    # Failed temp files are retained, never used as backups and never silently overwritten.
    $temporaryStream = [IO.File]::Open($temporaryPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $temporaryStream.Write($Data,0,$Data.Length); $temporaryStream.Flush($true) } finally { $temporaryStream.Dispose() }
    Assert-SafePath $Target
    [IO.File]::Move($temporaryPath,$Target,$true)
}
function Check-Markers([string]$Value, [bool]$Expected) {
    $beginCount = [regex]::Matches($Value,'BEGIN neuron-harness').Count
    $endCount = [regex]::Matches($Value,'END neuron-harness').Count
    if ($Expected) {
        if ($beginCount -ne 1 -or $endCount -ne 1) { throw 'Managed marker incomplete/duplicate; refusing write' }
    } elseif ($beginCount -ne 0 -or $endCount -ne 0) { throw 'Managed markers exist without an installed ownership manifest' }
}
function Get-TargetPath([string]$Relative) {
    if ($Relative -notin @('AGENTS.md','CLAUDE.md','.neuron-harness/runtime.md','.claude/settings.json')) { throw "Invalid journal target: $Relative" }
    if ($Relative -eq 'AGENTS.md' -and $Harness -eq 'claude') { throw 'Journal rule target/config mismatch' }
    if ($Relative -eq 'CLAUDE.md' -and $Harness -ne 'claude') { throw 'Journal rule target/config mismatch' }
    if ($Relative -eq '.claude/settings.json' -and $Harness -ne 'claude') { throw 'Journal hook target/config mismatch' }
    $targetPath = Join-Path $script:ProjectRoot $Relative
    Assert-SafePath $targetPath
    return $targetPath
}
function Get-BackupPath([string]$Relative) {
    if ($Relative -cnotmatch '^integration/backups/[0-9a-f]{32}/[0-9a-f]{32}\.bin$') { throw "Unsafe backup relative path: $Relative" }
    $backupPath = Join-Path $script:StateRoot $Relative
    Assert-SafePath $backupPath
    return $backupPath
}
function New-Change([string]$Relative, [byte[]]$AfterData, $BeforeSnapshot) {
    if ($null -eq $BeforeSnapshot) { throw 'Internal error: explicit source snapshot required' }
    return @{ path = $Relative; before = $BeforeSnapshot; after = @{ exists = $true; hash = (Get-Hash $AfterData); data = $AfterData } }
}
function Get-RestoreData($Item) {
    [byte[]]$backupData = [IO.File]::ReadAllBytes((Get-BackupPath $Item.backup))
    if ((Get-Hash $backupData) -cne $Item.before.hash) { throw "Backup changed before restore: $($Item.backup)" }
    if ($Item.path -eq '.claude/settings.json' -and -not $Item.before.exists) { return ,$script:Utf8.GetBytes("{}`n") }
    return ,$backupData
}
function Assert-Configuration($Record) {
    if ($Record.schema -ne 2 -or $Record.version -ne 2) { throw 'Unsupported legacy integration journal; manual review required (expected schema/version 2)' }
    if ($Record.config.harness -cne $Harness -or $Record.config.skill_root -cne $script:SkillRootPath -or $Record.config.project_root -cne $script:ProjectRoot -or [bool]$Record.config.prompt_hook -ne [bool]$EnablePromptHook) {
        throw 'Integration configuration conflict; use the recorded Harness/SkillRoot/EnablePromptHook, uninstall before changing configuration'
    }
}
function Validate-Items($Items) {
    $targetSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($journalItem in $Items) {
        $null = Get-TargetPath $journalItem.path
        if (-not $targetSet.Add($journalItem.path)) { throw 'Duplicate journal target' }
        foreach ($stateName in 'before','after') {
            if ($journalItem[$stateName].exists -isnot [bool] -or $journalItem[$stateName].hash -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid journal snapshot' }
        }
        $backupPath = Get-BackupPath $journalItem.backup
        if (-not [IO.File]::Exists($backupPath)) { throw "Backup missing: $backupPath" }
        [byte[]]$backupData = [IO.File]::ReadAllBytes($backupPath)
        if ((Get-Hash $backupData) -cne $journalItem.before.hash) { throw "Backup hash mismatch: $backupPath" }
        if (-not $journalItem.before.exists -and $backupData.Length -ne 0) { throw 'Absent before-state must have an empty backup' }
        $expectedRestoreHash = if ($journalItem.path -eq '.claude/settings.json' -and -not $journalItem.before.exists) { Get-Hash $script:Utf8.GetBytes("{}`n") } else { $journalItem.before.hash }
        if ($journalItem.restore_hash -cne $expectedRestoreHash) { throw 'Invalid journal restore fallback hash' }
    }
    if (-not $targetSet.Contains('.neuron-harness/runtime.md') -or -not $targetSet.Contains($script:RulesRelative)) { throw 'Journal target set incomplete' }
    if ($targetSet.Contains('.claude/settings.json') -ne [bool]$EnablePromptHook) { throw 'Journal hook target set mismatch' }
}
function Get-InstalledRecord($Record) {
    if ($null -eq $Record) { return $null }
    if ($Record.phase -eq 'installed') { return $Record }
    if ($Record.phase -eq 'recovered' -and $Record.restored_phase -eq 'installed') { return $Record.previous_installation }
    return $null
}
function Assert-OwnedBlock($Installation, $Snapshot) {
    $textInfo = Convert-Text $Snapshot.data
    Check-Markers $textInfo.text $true
    $ownedText = [string]$Installation.owned_block.text
    if ((Get-Hash $script:Utf8.GetBytes($ownedText)) -cne $Installation.owned_block.hash -or -not $ownedText.Contains('<!-- BEGIN neuron-harness -->') -or -not $ownedText.Contains('<!-- END neuron-harness -->')) { throw 'Invalid owned block manifest' }
    $blockIndex = $textInfo.text.IndexOf($ownedText,[StringComparison]::Ordinal)
    if ($blockIndex -lt 0) { throw 'Managed block modified; restore the recorded block before uninstall/reinstall' }
    return @{ info = $textInfo; index = $blockIndex; length = $ownedText.Length }
}
function Assert-Installed($Installation) {
    Validate-Items $Installation.items
    foreach ($installedItem in $Installation.items) {
        $installedPath = Get-TargetPath $installedItem.path
        $snapshot = Read-Snapshot $installedPath
        if ($installedItem.path -eq $script:RulesRelative) { $null = Assert-OwnedBlock $Installation $snapshot }
        elseif ($snapshot.exists -ne $installedItem.after.exists -or $snapshot.hash -cne $installedItem.after.hash) {
            throw "Installed file missing/modified: $installedPath. Restore recorded bytes or inspect backups; no overwrite performed."
        }
    }
}
function New-HookCommand {
    # No user path is interpolated into shell source without PowerShell literal escaping.
    $hookLiteral = (Join-Path $script:SkillRootPath 'scripts/prompt-hook.ps1').Replace("'","''")
    $projectLiteral = $script:ProjectRoot.Replace("'","''")
    $skillLiteral = $script:SkillRootPath.Replace("'","''")
    $invocation = "& '$hookLiteral' -Project '$projectLiteral' -SkillRoot '$skillLiteral'"
    return 'pwsh -NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
}
function Merge-Hook([byte[]]$Data, [bool]$Exists) {
    $settingsObject = if ($Exists) { Read-StrictJson $Data } else { [ordered]@{} }
    if (-not $settingsObject.Contains('hooks')) { $settingsObject['hooks'] = [ordered]@{} }
    if ($settingsObject['hooks'] -isnot [Collections.IDictionary]) { throw 'Incompatible settings hooks: expected object' }
    foreach ($eventKey in $settingsObject['hooks'].Keys) {
        $eventEntries = $settingsObject['hooks'][$eventKey]
        if ($eventEntries -isnot [System.Collections.IList]) { throw "Incompatible hooks.$eventKey : expected array" }
        foreach ($eventEntry in $eventEntries) {
            if ($eventEntry -isnot [Collections.IDictionary] -or -not $eventEntry.Contains('hooks') -or $eventEntry['hooks'] -isnot [System.Collections.IList]) { throw "Incompatible hooks.$eventKey entry" }
            foreach ($existingHook in $eventEntry['hooks']) {
                if ($existingHook -isnot [Collections.IDictionary] -or -not $existingHook.Contains('type') -or $existingHook['type'] -isnot [string]) { throw "Incompatible hooks.$eventKey hook" }
            }
        }
    }
    if (-not $settingsObject['hooks'].Contains('UserPromptSubmit')) { $settingsObject['hooks']['UserPromptSubmit'] = @() }
    $settingsObject['hooks']['UserPromptSubmit'] = @($settingsObject['hooks']['UserPromptSubmit']) + @(@{ hooks = @(@{ type = 'command'; command = (New-HookCommand); timeout = 30 }) })
    return ,(Json-Bytes $settingsObject)
}
function Save-Journal($Record) { Write-Atomic $script:ManifestPath (Json-Bytes $Record) }
function Begin-Transaction($Changes, [string]$Phase, $OwnedBlock, $PreviousInstallation) {
    if ($TestFaultInjection -and $env:NH_TEST_CHANGE_BEFORE_PREPARE) {
        $faultTarget = Get-TargetPath $env:NH_TEST_CHANGE_BEFORE_PREPARE
        Write-Atomic $faultTarget $script:Utf8.GetBytes('test external edit after source snapshot')
    }
    $transactionId = [guid]::NewGuid().ToString('N')
    foreach ($preflightChange in $Changes) { Assert-Snapshot (Get-TargetPath $preflightChange.path) $preflightChange.before }
    $journalItems = @()
    foreach ($changeItem in $Changes) {
        Assert-Snapshot (Get-TargetPath $changeItem.path) $changeItem.before
        $backupRelative = 'integration/backups/' + $transactionId + '/' + [guid]::NewGuid().ToString('N') + '.bin'
        Write-Atomic (Get-BackupPath $backupRelative) $changeItem.before.data
        $restoreHash = if ($changeItem.path -eq '.claude/settings.json' -and -not $changeItem.before.exists) { Get-Hash $script:Utf8.GetBytes("{}`n") } else { $changeItem.before.hash }
        $journalItems += @{ path = $changeItem.path; before = @{ exists = $changeItem.before.exists; hash = $changeItem.before.hash }; after = @{ exists = $true; hash = $changeItem.after.hash }; backup = $backupRelative; restore_hash = $restoreHash }
    }
    $previousJournalBackup = ''
    if ([IO.File]::Exists($script:ManifestPath)) {
        $previousJournalBackup = 'integration/backups/' + $transactionId + '/' + [guid]::NewGuid().ToString('N') + '.bin'
        Write-Atomic (Get-BackupPath $previousJournalBackup) ([IO.File]::ReadAllBytes($script:ManifestPath))
    }
    $preparedRecord = @{ schema = 2; version = 2; phase = $Phase; config = $script:Configuration; transaction = $transactionId; items = $journalItems; owned_block = $OwnedBlock; init = 'not requested'; previous_installation = $PreviousInstallation; previous_journal_backup = $previousJournalBackup; restored_phase = ''; notes = @('Original nonexistence is restored as an empty file (settings.json as valid {}); history is never deleted.') }
    Save-Journal $preparedRecord
    return $preparedRecord
}
function Apply-Changes($Changes) {
    # Preflight the entire transaction before the first effective write, then recheck each target.
    foreach ($changeItem in $Changes) { Assert-Snapshot (Get-TargetPath $changeItem.path) $changeItem.before }
    foreach ($changeItem in $Changes) {
        $targetPath = Get-TargetPath $changeItem.path
        Assert-Snapshot $targetPath $changeItem.before
        Write-Atomic $targetPath $changeItem.after.data
        $script:WriteCount++
        if ($TestFaultInjection -and $env:NH_TEST_FAIL_AFTER -and $script:WriteCount -eq [int]$env:NH_TEST_FAIL_AFTER) { throw "Test failure after effective write $script:WriteCount; journal remains prepared" }
    }
}

if ($RecoverStaleLock -and $Action -ne 'Recover') { throw '-RecoverStaleLock is only valid for Recover' }
if ($EnablePromptHook -and $Harness -ne 'claude') { throw '-EnablePromptHook is supported only for claude' }
if ($Init -and $Action -notin @('Install','Plan')) { throw '-Init is only valid for Install/Plan' }
$script:ProjectRoot = Resolve-Root $Project
$script:SkillRootPath = Resolve-Root $SkillRoot
$script:StateRoot = Join-Path $script:ProjectRoot '.neuron-harness'
$script:RulesRelative = if ($Harness -eq 'claude') { 'CLAUDE.md' } else { 'AGENTS.md' }
$script:ManifestPath = Join-Path $script:StateRoot 'integration/install-state.json'
$lockPath = Join-Path $script:StateRoot 'integration/install.lock'
$runtimeSourcePath = Join-Path $script:SkillRootPath 'integration/runtime.md'
$assemblePath = Join-Path $script:SkillRootPath 'scripts/assemble.ps1'
$script:Configuration = @{ harness = $Harness; skill_root = $script:SkillRootPath; project_root = $script:ProjectRoot; prompt_hook = [bool]$EnablePromptHook }
$capability = if ($Harness -eq 'cursor') { 'unverified instruction-only (no dedicated alwaysApply)' } elseif ($EnablePromptHook) { 'instruction + UserPromptSubmit event wiring; runtime actual execution unverified' } else { 'instruction-only; runtime actual execution unverified' }
foreach ($requiredPath in @($script:ManifestPath,$lockPath,$runtimeSourcePath,$assemblePath,(Join-Path $script:StateRoot 'index.tsv'),(Get-TargetPath $script:RulesRelative),(Get-TargetPath '.neuron-harness/runtime.md'))) { Assert-SafePath $requiredPath }
if ($EnablePromptHook) { Assert-SafePath (Join-Path $script:SkillRootPath 'scripts/prompt-hook.ps1'); $null = Get-TargetPath '.claude/settings.json' }

if ($Action -eq 'Plan') {
    Write-Output "PLAN (read-only): harness=$Harness; capability=$capability"
    foreach ($plannedPath in @((Get-TargetPath $script:RulesRelative),(Get-TargetPath '.neuron-harness/runtime.md'),$script:ManifestPath,$lockPath,(Join-Path $script:StateRoot 'integration/backups'),$runtimeSourcePath,$assemblePath)) { Write-Output $plannedPath }
    if ($EnablePromptHook) { Write-Output (Get-TargetPath '.claude/settings.json'); Write-Output (Join-Path $script:SkillRootPath 'scripts/prompt-hook.ps1'); Write-Output 'settings.json: strict JSON semantics preserved; formatting will change.' }
    if ($Init) { Write-Output "Init requested: may initialize state and templates under $script:StateRoot; retained through recovery/uninstall." }
    Write-Output 'Install requires user approval to enable project integration. No integration was enabled by Plan.'
    Write-Output 'Reparse checks are not an OS-level defense against malicious concurrent directory replacement.'
    return
}
$manifestRecord = if ([IO.File]::Exists($script:ManifestPath)) { Read-StrictJson ([IO.File]::ReadAllBytes($script:ManifestPath)) } else { $null }
if ($Action -eq 'Status') {
    try {
        if ($null -eq $manifestRecord) { Write-Output 'STATUS: not installed; configuration consistency unavailable; event wiring absent; runtime actual execution unverified'; return }
        Assert-Configuration $manifestRecord
        if ($manifestRecord.phase -in @('prepared','prepared_uninstall')) { throw "incomplete phase=$($manifestRecord.phase); run Recover with the recorded configuration" }
        $activeInstallation = Get-InstalledRecord $manifestRecord
        if ($null -eq $activeInstallation) { Write-Output "STATUS: $($manifestRecord.phase); configuration consistent; event wiring absent; runtime actual execution unverified"; return }
        Assert-Installed $activeInstallation
        Write-Output "STATUS: installed; configuration consistent; capability=$capability; event wiring $(if ($EnablePromptHook) {'present'} else {'absent'}); runtime actual execution unverified"
    } catch { Write-Output "STATUS: failed/incomplete; $($_.Exception.Message); runtime actual execution unverified"; throw }
    return
}
if (-not $PSCmdlet.ShouldProcess($script:ProjectRoot,"$Action neuron-harness project integration")) { return }
$lockStream = $null
try {
    Assert-SafePath $lockPath
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($lockPath)) | Out-Null
    Assert-SafePath $lockPath
    if ($RecoverStaleLock -and [IO.File]::Exists($lockPath)) {
        if ($null -eq $manifestRecord -or $manifestRecord.phase -notin @('prepared','prepared_uninstall')) { throw 'Stale lock recovery requires an incomplete journal' }
        $staleLockStream = $null
        try {
            # Deny every other reader/writer while retaining delete sharing for same-handle isolation.
            # An active installer holds FileShare.None, so this open MUST fail for a live lock.
            $staleLockStream = [IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Delete)
            Assert-SafePath $lockPath
            $isolatedLockPath = $lockPath + '.stale-' + [guid]::NewGuid().ToString('N')
            [IO.File]::Move($lockPath,$isolatedLockPath)
            Write-Output "RECOVER: explicitly isolated an unused stale lock: $isolatedLockPath"
        } catch { throw "Cannot exclusively open/isolate stale lock; active locks are never stolen: $lockPath. $($_.Exception.Message)" }
        finally { if ($null -ne $staleLockStream) { $staleLockStream.Dispose() } }
    }
    try { $lockStream = [IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch { throw "Integration lock exists or is unavailable; never stolen automatically: $lockPath" }
    # Re-read only after acquiring the exclusive lock.
    Assert-SafePath $script:ManifestPath
    $manifestRecord = if ([IO.File]::Exists($script:ManifestPath)) { Read-StrictJson ([IO.File]::ReadAllBytes($script:ManifestPath)) } else { $null }
    if ($null -ne $manifestRecord -and ($Action -ne 'Install' -or $manifestRecord.phase -in @('installed','prepared','prepared_uninstall') -or ($manifestRecord.phase -eq 'recovered' -and $manifestRecord.restored_phase -eq 'installed'))) { Assert-Configuration $manifestRecord }
    if ($null -ne $manifestRecord -and $manifestRecord.phase -in @('prepared','prepared_uninstall') -and $Action -ne 'Recover') { throw 'Incomplete transaction; only Recover may write' }
    $activeInstallation = Get-InstalledRecord $manifestRecord
    switch ($Action) {
        'Install' {
            if ($null -ne $activeInstallation) {
                Assert-Installed $activeInstallation
                Write-Output 'INSTALL: already installed; zero persistent writes; Init not rerun'
                return
            }
            if (-not $Init -and -not [IO.File]::Exists((Join-Path $script:StateRoot 'index.tsv'))) { throw 'Project state is not initialized; first run assemble.ps1 -Mode Init -Project <root>, or explicitly pass -Init' }
            if (-not [IO.File]::Exists($runtimeSourcePath) -or -not [IO.File]::Exists($assemblePath)) { throw 'Skill integration/runtime.md and scripts/assemble.ps1 are required' }
            if ($EnablePromptHook -and -not [IO.File]::Exists((Join-Path $script:SkillRootPath 'scripts/prompt-hook.ps1'))) { throw 'Skill scripts/prompt-hook.ps1 is required' }
            $ruleSnapshot = Read-Snapshot (Get-TargetPath $script:RulesRelative)
            $ruleText = Convert-Text $ruleSnapshot.data
            Check-Markers $ruleText.text $false
            $lineEnding = if ($ruleText.text.Contains("`r`n")) { "`r`n" } else { "`n" }
            $separator = if ($ruleText.text.Length -gt 0 -and -not $ruleText.text.EndsWith("`n")) { $lineEnding } else { '' }
            $ownedText = $separator + (@('<!-- BEGIN neuron-harness -->','neuron-harness: read the project runtime instructions before working.',("Runtime: " + (Get-TargetPath '.neuron-harness/runtime.md')),("Executor: " + $assemblePath),'<!-- END neuron-harness -->') -join $lineEnding) + $lineEnding
            $runtimeText = (Convert-Text ([IO.File]::ReadAllBytes($runtimeSourcePath))).text.Replace('{{SKILL_ROOT}}',$script:SkillRootPath).Replace('{{PROJECT_ROOT}}',$script:ProjectRoot)
            $runtimeBefore = Read-Snapshot (Get-TargetPath '.neuron-harness/runtime.md')
            if ($runtimeBefore.exists -and $runtimeBefore.data.Length -ne 0) { throw 'Unowned runtime.md exists; refusing overwrite' }
            $changes = @((New-Change '.neuron-harness/runtime.md' $script:Utf8.GetBytes($runtimeText) $runtimeBefore),(New-Change $script:RulesRelative (Encode-Text $ruleText ($ruleText.text + $ownedText)) $ruleSnapshot))
            if ($EnablePromptHook) {
                $settingsSnapshot = Read-Snapshot (Get-TargetPath '.claude/settings.json')
                $changes += New-Change '.claude/settings.json' (Merge-Hook $settingsSnapshot.data $settingsSnapshot.exists) $settingsSnapshot
                Write-Output 'settings.json: existing JSON semantics preserved, formatting changes.'
            }
            # Init is deliberately opt-in: its append-preserving state/template effects are outside the integration rollback.
            # Validate its existing tree before invoking the unchanged executor.
            if ($Init) {
                Assert-SafePath (Join-Path $script:SkillRootPath 'manifest.json')
                $templateSourceRoot = Join-Path $script:SkillRootPath 'templates'
                Assert-SafePath $templateSourceRoot
                if ([IO.Directory]::Exists($templateSourceRoot)) {
                    foreach ($templateEntry in Get-ChildItem -LiteralPath $templateSourceRoot -Force -Recurse) { Assert-SafePath $templateEntry.FullName }
                }
            }
            if ($Init -and [IO.Directory]::Exists($script:StateRoot)) {
                foreach ($stateEntry in Get-ChildItem -LiteralPath $script:StateRoot -Force -Recurse) { Assert-SafePath $stateEntry.FullName }
            }
            $preparedRecord = Begin-Transaction $changes 'prepared' @{ text = $ownedText; hash = (Get-Hash $script:Utf8.GetBytes($ownedText)) } $null
            if ($Init) {
                $preparedRecord.init = 'pending (state initialization is not rolled back)'; Save-Journal $preparedRecord
                $initOutput = & (Join-Path $PSHOME 'pwsh.exe').Replace('pwsh.exe',$(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})) -NoProfile -File $assemblePath -Mode Init -Project $script:ProjectRoot 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Init failed (journal prepared, state retained): $($initOutput -join [Environment]::NewLine)" }
                if (-not [IO.File]::Exists((Join-Path $script:StateRoot 'index.tsv'))) { throw 'Init reported success without index.tsv; journal remains prepared' }
                $preparedRecord.init = 'initialized; state/history retained by uninstall and recovery'; Save-Journal $preparedRecord
                Write-Output ($initOutput -join [Environment]::NewLine)
            }
            Apply-Changes $changes
            $preparedRecord.phase = 'installed'; Save-Journal $preparedRecord
            Write-Output "INSTALL: installed; capability=$capability; Init=$($preparedRecord.init)"
        }
        'Uninstall' {
            if ($null -eq $activeInstallation) { throw 'No installed integration to uninstall' }
            Assert-Installed $activeInstallation
            $changes = @()
            foreach ($installedItem in $activeInstallation.items) {
                $currentSnapshot = Read-Snapshot (Get-TargetPath $installedItem.path)
                if ($installedItem.path -eq $script:RulesRelative) {
                    $blockInfo = Assert-OwnedBlock $activeInstallation $currentSnapshot
                    $restoreData = Encode-Text $blockInfo.info ($blockInfo.info.text.Remove($blockInfo.index,$blockInfo.length))
                } else {
                    if ($currentSnapshot.exists -ne $installedItem.after.exists -or $currentSnapshot.hash -cne $installedItem.after.hash) { throw "Installed file changed during uninstall preflight: $(Get-TargetPath $installedItem.path)" }
                    $restoreData = Get-RestoreData $installedItem
                }
                $changes += New-Change $installedItem.path $restoreData $currentSnapshot
            }
            $preparedRecord = Begin-Transaction $changes 'prepared_uninstall' $activeInstallation.owned_block $activeInstallation
            Apply-Changes $changes
            $preparedRecord.phase = 'uninstalled'; Save-Journal $preparedRecord
            Write-Output 'UNINSTALL: managed block removed; original runtime/settings restored; originally absent files retained empty (settings.json as valid {}); state/history/backups retained.'
        }
        'Recover' {
            if ($null -eq $manifestRecord -or $manifestRecord.phase -notin @('prepared','prepared_uninstall')) { throw 'No incomplete transaction to recover' }
            Validate-Items $manifestRecord.items
            # Validate ALL current states and ALL backup hashes before restoring ANY target.
            $recoveryChanges = @()
            foreach ($journalItem in $manifestRecord.items) {
                $currentSnapshot = Read-Snapshot (Get-TargetPath $journalItem.path)
                $matchesBefore = $currentSnapshot.exists -eq $journalItem.before.exists -and $currentSnapshot.hash -ceq $journalItem.before.hash
                $matchesAfter = $currentSnapshot.exists -eq $journalItem.after.exists -and $currentSnapshot.hash -ceq $journalItem.after.hash
                # A previous recovery may have cleared an originally absent file before being interrupted.
                [byte[]]$restoreData = Get-RestoreData $journalItem
                $matchesClear = $manifestRecord.Contains('recovery_started') -and $manifestRecord.recovery_started -eq $true -and -not $journalItem.before.exists -and $currentSnapshot.exists -and $currentSnapshot.hash -ceq (Get-Hash $restoreData)
                if (-not ($matchesBefore -or $matchesAfter -or $matchesClear)) { throw "Recovery refused: current file is neither before nor after: $(Get-TargetPath $journalItem.path)" }
                $recoveryChanges += New-Change $journalItem.path $restoreData $currentSnapshot
            }
            if ($manifestRecord.phase -eq 'prepared_uninstall') {
                if ($null -eq $manifestRecord.previous_installation) { throw 'Missing previous installed record' }
                Assert-Configuration $manifestRecord.previous_installation
                Validate-Items $manifestRecord.previous_installation.items
            }
            $manifestRecord.recovery_started = $true
            Save-Journal $manifestRecord
            Apply-Changes $recoveryChanges
            $manifestRecord.restored_phase = if ($manifestRecord.phase -eq 'prepared_uninstall') { 'installed' } else { 'not installed' }
            $manifestRecord.phase = 'recovered'; Save-Journal $manifestRecord
            Write-Output "RECOVER: recovered; restored=$($manifestRecord.restored_phase); originally absent files cleared to empty (settings.json as valid {}), never deleted; Init state/history retained."
        }
    }
} finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
        # Only the process that successfully opened CreateNew removes its own lock.
        Assert-SafePath $lockPath
        Remove-Item -LiteralPath $lockPath -Force
    }
}
