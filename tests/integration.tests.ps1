#requires -Version 7.0
[CmdletBinding()]
param([string]$IntegrationScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/integrate.ps1'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Skipped = 0
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("neuron integration space ' " + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($script:TestRoot) | Out-Null
$script:FixtureSkill = Join-Path $script:TestRoot "fixture skill ' root"
foreach ($relativeDirectory in 'scripts','integration') { [IO.Directory]::CreateDirectory((Join-Path $script:FixtureSkill $relativeDirectory)) | Out-Null }
[IO.File]::WriteAllText((Join-Path $script:FixtureSkill 'integration/runtime.md'),"Runtime root {{PROJECT_ROOT}}`nSkill root {{SKILL_ROOT}}`n")
[IO.File]::WriteAllText((Join-Path $script:FixtureSkill 'scripts/assemble.ps1'),@'
param([string]$Mode,[string]$Project)
$ErrorActionPreference = 'Stop'
if ($env:NH_FIXTURE_INIT_FAIL -eq '1') { throw 'fixture Init failure' }
if ($Mode -ne 'Init') { throw 'Unexpected fixture executor invocation' }
[IO.Directory]::CreateDirectory((Join-Path $Project '.neuron-harness')) | Out-Null
if (-not [IO.File]::Exists((Join-Path $Project '.neuron-harness/index.tsv'))) { [IO.File]::WriteAllText((Join-Path $Project '.neuron-harness/index.tsv'),'fixture index') }
if (-not [IO.File]::Exists((Join-Path $Project '.neuron-harness/raw.log'))) { [IO.File]::WriteAllText((Join-Path $Project '.neuron-harness/raw.log'),'history retained') }
Write-Output 'INIT OK (fixture)'
'@)
[IO.File]::WriteAllText((Join-Path $script:FixtureSkill 'scripts/prompt-hook.ps1'),@'
param([string]$Project,[string]$SkillRoot)
@{ project = $Project; skill = $SkillRoot } | ConvertTo-Json -Compress
'@)
$script:PwshPath = (Get-Process -Id $PID).Path
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "ASSERT: $Message" } }
function Case([string]$Name,[scriptblock]$Work) { & $Work; $script:Passed++; Write-Output "PASS $Name" }
function New-Project([string]$Name,[switch]$Uninitialized) {
    $fixturePath = Join-Path $script:TestRoot $Name
    [IO.Directory]::CreateDirectory($fixturePath) | Out-Null
    if (-not $Uninitialized) {
        [IO.Directory]::CreateDirectory((Join-Path $fixturePath '.neuron-harness')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $fixturePath '.neuron-harness/index.tsv'),'existing index')
        [IO.File]::WriteAllText((Join-Path $fixturePath '.neuron-harness/raw.log'),'original historical log')
    }
    return $fixturePath
}
function Invoke-Integration([string]$Fixture,[string]$Operation='Plan',[string]$Kind='generic',[string[]]$Extra=@(),[switch]$Fail) {
    $argumentsList = @('-NoProfile','-File',$IntegrationScript,'-Project',$Fixture,'-Harness',$Kind,'-SkillRoot',$script:FixtureSkill,'-Action',$Operation) + $Extra
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $commandOutput = & $script:PwshPath @argumentsList 2>&1
        $commandExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    $outputText = $commandOutput -join "`n"
    if ($Fail) { Assert ($commandExit -ne 0) "Expected refusal for $Operation; output=$outputText" }
    else { Assert ($commandExit -eq 0) "Unexpected exit $commandExit for $Operation; output=$outputText" }
    return $outputText
}
function Read-State([string]$Fixture) { return (Get-Content -LiteralPath (Join-Path $Fixture '.neuron-harness/integration/install-state.json') -Raw | ConvertFrom-Json -AsHashtable) }
function Hash([string]$Target) { return (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash }
function Tree-Hash([string]$Fixture) {
    return (@(Get-ChildItem -LiteralPath $Fixture -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($Fixture.Length) + ':' + (Hash $_.FullName) }) -join "`n")
}
function Read-Utf8([string]$Target) { return [IO.File]::ReadAllText($Target) }
Write-Output "Fixtures retained at: $script:TestRoot"
Case 'Plan is read-only and WhatIf never prepares installation' {
    $fixturePath = New-Project 'plan' -Uninitialized
    $beforeTree = Tree-Hash $fixturePath
    $planOutput = Invoke-Integration $fixturePath
    Assert ($planOutput.Contains([IO.Path]::GetFullPath((Join-Path $fixturePath 'AGENTS.md')))) 'Plan must expose absolute rule path'
    Assert ((Tree-Hash $fixturePath) -ceq $beforeTree) 'Plan wrote files'
    $null = Invoke-Integration $fixturePath Install generic @('-WhatIf')
    Assert ((Tree-Hash $fixturePath) -ceq $beforeTree) 'WhatIf wrote files'
    Assert (-not [IO.Directory]::Exists((Join-Path $fixturePath '.neuron-harness'))) 'Read-only operation created directories'
    $cursorOutput = Invoke-Integration $fixturePath Plan cursor
    Assert ($cursorOutput.Contains('unverified instruction-only') -and $cursorOutput.Contains('no dedicated alwaysApply')) 'Cursor capability claim incorrect'
}
Case 'Uninitialized install refuses and explicit Init succeeds without discarding history' {
    $fixturePath = New-Project 'init' -Uninitialized
    $failureOutput = Invoke-Integration $fixturePath Install -Fail
    Assert ($failureOutput.Contains('not initialized')) 'Missing Init guidance'
    $null = Invoke-Integration $fixturePath Install generic @('-Init')
    Assert ((Read-State $fixturePath).phase -eq 'installed') 'Init/install did not complete'
    $historicalHash = Hash (Join-Path $fixturePath '.neuron-harness/raw.log')
    $null = Invoke-Integration $fixturePath Uninstall
    Assert ((Hash (Join-Path $fixturePath '.neuron-harness/raw.log')) -ceq $historicalHash) 'Uninstall modified history'
}
Case 'Chinese UTF-8 BOM CRLF bytes preserved, repeat install is byte-idempotent' {
    $script:MainFixture = New-Project "中文 space ' project"
    $script:MainRulePath = Join-Path $script:MainFixture 'AGENTS.md'
    [byte[]]$script:OriginalRuleBytes = [Text.UTF8Encoding]::new($true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes("# 原有规则`r`n中文与路径 ' 保留`r`n")
    [IO.File]::WriteAllBytes($script:MainRulePath,$script:OriginalRuleBytes)
    $null = Invoke-Integration $script:MainFixture Install
    $installedBytes = [IO.File]::ReadAllBytes($script:MainRulePath)
    Assert ([Convert]::ToBase64String($installedBytes[0..($script:OriginalRuleBytes.Length-1)]) -ceq [Convert]::ToBase64String($script:OriginalRuleBytes)) 'Existing byte prefix changed'
    $runtimeText = Read-Utf8 (Join-Path $script:MainFixture '.neuron-harness/runtime.md')
    Assert ($runtimeText.Contains($script:MainFixture) -and $runtimeText.Contains($script:FixtureSkill) -and -not $runtimeText.Contains('{{')) 'Runtime placeholders not literal substituted'
    $beforeTree = Tree-Hash $script:MainFixture
    $null = Invoke-Integration $script:MainFixture Install
    Assert ((Tree-Hash $script:MainFixture) -ceq $beforeTree) 'Repeated install changed bytes or created backups'
    $statusOutput = Invoke-Integration $script:MainFixture Status
    Assert ($statusOutput.Contains('configuration consistent') -and $statusOutput.Contains('actual execution unverified')) 'Status overstated or omitted checks'
}
Case 'Uninstall retains external appended text and raw.log' {
    $rawPath = Join-Path $script:MainFixture '.neuron-harness/raw.log'
    $historicalHash = Hash $rawPath
    [IO.File]::AppendAllText($script:MainRulePath,"新增外围规则`r`n",[Text.UTF8Encoding]::new($false))
    $null = Invoke-Integration $script:MainFixture Uninstall
    [byte[]]$expectedBytes = $script:OriginalRuleBytes + [Text.Encoding]::UTF8.GetBytes("新增外围规则`r`n")
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($script:MainRulePath)) -ceq [Convert]::ToBase64String($expectedBytes)) 'Outer appended bytes not preserved'
    Assert ((Hash $rawPath) -ceq $historicalHash) 'raw.log changed'
    Assert ([IO.File]::Exists((Join-Path $script:MainFixture '.neuron-harness/runtime.md'))) 'Runtime physically deleted'
    Assert ((Read-State $script:MainFixture).phase -eq 'uninstalled') 'Uninstall phase missing'
    $null = Invoke-Integration $script:MainFixture Install codex
}
Case 'UTF-16 LE and BE plus no trailing newline restore byte-for-byte' {
    foreach ($bigEndian in @($false,$true)) {
        $fixturePath = New-Project ('utf16-' + $bigEndian)
        $rulesPath = Join-Path $fixturePath 'AGENTS.md'
        $encodingInfo = [Text.UnicodeEncoding]::new($bigEndian,$true,$true)
        [byte[]]$originalBytes = $encodingInfo.GetPreamble() + $encodingInfo.GetBytes('原文无末尾换行')
        [IO.File]::WriteAllBytes($rulesPath,$originalBytes)
        $null = Invoke-Integration $fixturePath Install
        $null = Invoke-Integration $fixturePath Uninstall
        Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($rulesPath)) -ceq [Convert]::ToBase64String($originalBytes)) 'UTF-16 original bytes changed'
    }
}
Case 'Modified owned block refuses reinstall and uninstall with zero effective writes' {
    $fixturePath = New-Project 'modified-block'
    $null = Invoke-Integration $fixturePath Install
    $rulesPath = Join-Path $fixturePath 'AGENTS.md'
    [IO.File]::WriteAllText($rulesPath,(Read-Utf8 $rulesPath).Replace('read the project','tamper the project'))
    $beforeTree = Tree-Hash $fixturePath
    $null = Invoke-Integration $fixturePath Uninstall -Fail
    $null = Invoke-Integration $fixturePath Install -Fail
    Assert ((Tree-Hash $fixturePath) -ceq $beforeTree) 'Modified block refusal changed files'
}
Case 'Unowned partial or duplicate markers reject before transaction' {
    foreach ($markerText in @('<!-- BEGIN neuron-harness -->',"<!-- BEGIN neuron-harness -->`n<!-- END neuron-harness -->",'BEGIN neuron-harness BEGIN neuron-harness END neuron-harness')) {
        $fixturePath = New-Project ([guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText((Join-Path $fixturePath 'AGENTS.md'),$markerText)
        $null = Invoke-Integration $fixturePath Install -Fail
        Assert (-not [IO.File]::Exists((Join-Path $fixturePath '.neuron-harness/integration/install-state.json'))) 'Invalid markers prepared transaction'
        Assert (-not [IO.File]::Exists((Join-Path $fixturePath '.neuron-harness/runtime.md'))) 'Invalid markers wrote runtime'
    }
}
Case 'Claude preserves permissions and hooks, encoded invocation handles quote/space paths' {
    $script:ClaudeFixture = New-Project "claude quote ' space"
    [IO.Directory]::CreateDirectory((Join-Path $script:ClaudeFixture '.claude')) | Out-Null
    $script:ClaudeSettingsPath = Join-Path $script:ClaudeFixture '.claude/settings.json'
    $script:OriginalSettings = '{"permissions":{"allow":["Read(*)"],"deny":[]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing stop"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"existing prompt"}]}]},"extra":{"大小写":true}}'
    [IO.File]::WriteAllText($script:ClaudeSettingsPath,$script:OriginalSettings)
    $null = Invoke-Integration $script:ClaudeFixture Install claude @('-EnablePromptHook')
    $settingsObject = Read-Utf8 $script:ClaudeSettingsPath | ConvertFrom-Json -AsHashtable
    Assert ($settingsObject.permissions.allow[0] -eq 'Read(*)' -and $settingsObject.extra['大小写']) 'Settings semantics changed'
    Assert ($settingsObject.hooks.Stop[0].hooks[0].command -eq 'existing stop') 'Existing Stop hook changed'
    Assert ($settingsObject.hooks.UserPromptSubmit.Count -eq 2 -and $settingsObject.hooks.UserPromptSubmit[0].hooks[0].command -eq 'existing prompt') 'Existing prompt hook lost'
    $newHook = $settingsObject.hooks.UserPromptSubmit[1].hooks[0]
    Assert ($newHook.timeout -eq 30 -and -not $newHook.Contains('async')) 'Hook timing invalid'
    Assert ($newHook.command -match '^pwsh -NoProfile -EncodedCommand ([A-Za-z0-9+/=]+)$') 'Hook command is not fixed encoded invocation'
    $encodedPayload = $Matches[1]
    $hookOutput = & $script:PwshPath -NoProfile -EncodedCommand $encodedPayload | ConvertFrom-Json
    Assert ($hookOutput.project -ceq $script:ClaudeFixture -and $hookOutput.skill -ceq $script:FixtureSkill) 'Literal quoting failed'
    $beforeTree = Tree-Hash $script:ClaudeFixture
    $null = Invoke-Integration $script:ClaudeFixture Install claude @('-EnablePromptHook')
    Assert ((Tree-Hash $script:ClaudeFixture) -ceq $beforeTree) 'Claude repeat install wrote settings or journal'
    $statusOutput = Invoke-Integration $script:ClaudeFixture Status claude @('-EnablePromptHook')
    Assert ($statusOutput.Contains('event wiring present')) 'Status omitted event wiring'
    $null = Invoke-Integration $script:ClaudeFixture Uninstall claude @('-EnablePromptHook')
    Assert ((Read-Utf8 $script:ClaudeSettingsPath) -ceq $script:OriginalSettings) 'Original settings bytes not restored'
}
Case 'Non-Claude hook switch rejected and configuration changes require uninstall' {
    $fixturePath = New-Project 'nonclaude'
    foreach ($kind in 'generic','cursor','zcode','codex') { $null = Invoke-Integration $fixturePath Install $kind @('-EnablePromptHook') -Fail }
    $null = Invoke-Integration $fixturePath Install zcode
    $beforeTree = Tree-Hash $fixturePath
    $null = Invoke-Integration $fixturePath Install codex -Fail
    Assert ((Tree-Hash $fixturePath) -ceq $beforeTree) 'Conflicting harness changed state'
}
Case 'Strict JSON rejects duplicate keys, comments, trailing comma, bad hook shapes before writes' {
    foreach ($jsonText in @('{"a":1,"a":2}','{"hooks":{"Stop":[],"Stop":[]}}',"{`n// comment`n}",'{"a":1,}','{"hooks":[]}','{"hooks":{"Stop":{}}}','{"hooks":{"UserPromptSubmit":[{"hooks":{}}]}}','{"a":{"x":1,"x":2}}')) {
        $fixturePath = New-Project ([guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory((Join-Path $fixturePath '.claude')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $fixturePath '.claude/settings.json'),$jsonText)
        $beforeTree = Tree-Hash $fixturePath
        $null = Invoke-Integration $fixturePath Install claude @('-EnablePromptHook') -Fail
        Assert ((Tree-Hash $fixturePath) -ceq $beforeTree) 'JSON rejection changed effective files or journal'
    }
}
Case 'Modified settings refuse uninstall without erasing others changes' {
    $fixturePath = New-Project 'changed-settings'
    $null = Invoke-Integration $fixturePath Install claude @('-EnablePromptHook')
    $settingsPath = Join-Path $fixturePath '.claude/settings.json'
    [IO.File]::AppendAllText($settingsPath,"`n")
    $beforeTree = Tree-Hash $fixturePath
    $failureOutput = Invoke-Integration $fixturePath Uninstall claude @('-EnablePromptHook') -Fail
    Assert ($failureOutput.Contains('settings.json')) 'No actionable changed file reported'
    Assert ((Tree-Hash $fixturePath) -ceq $beforeTree) 'Uninstall overwrote changed settings'
}
Case 'Missing runtime Status fails; modified runtime uninstall refuses' {
    $fixturePath = New-Project 'runtime-missing'
    $null = Invoke-Integration $fixturePath Install
    $runtimePath = Join-Path $fixturePath '.neuron-harness/runtime.md'
    # Only this generated fixture is moved, no project history is removed.
    [IO.File]::Move($runtimePath,($runtimePath + '.fixture-away'))
    $statusOutput = Invoke-Integration $fixturePath Status -Fail
    Assert ($statusOutput.Contains('failed/incomplete') -and $statusOutput.Contains('runtime.md')) 'Missing runtime not reported as failed'
    [IO.File]::WriteAllText($runtimePath,'user modified runtime')
    $null = Invoke-Integration $fixturePath Uninstall -Fail
}
Case 'Fault injection requires explicit test switch' {
    $fixturePath = New-Project 'fault-not-enabled'
    $env:NH_TEST_FAIL_AFTER = '1'
    try { $null = Invoke-Integration $fixturePath Install } finally { $env:NH_TEST_FAIL_AFTER = $null }
    Assert ((Read-State $fixturePath).phase -eq 'installed') 'Environment alone enabled fault injection'
}
Case 'Prepared install recovers all before states and retains new empty files' {
    foreach ($failurePoint in 1,2,3) {
        $fixturePath = New-Project ('recover-' + $failurePoint)
        $rulesPath = Join-Path $fixturePath 'CLAUDE.md'
        [IO.File]::WriteAllText($rulesPath,'existing rule')
        $env:NH_TEST_FAIL_AFTER = [string]$failurePoint
        try { $null = Invoke-Integration $fixturePath Install claude @('-EnablePromptHook','-TestFaultInjection') -Fail } finally { $env:NH_TEST_FAIL_AFTER = $null }
        Assert ((Read-State $fixturePath).phase -eq 'prepared') 'Crash did not leave prepared journal'
        $null = Invoke-Integration $fixturePath Status claude @('-EnablePromptHook') -Fail
        $null = Invoke-Integration $fixturePath Uninstall claude @('-EnablePromptHook') -Fail
        $null = Invoke-Integration $fixturePath Recover claude @('-EnablePromptHook')
        Assert ((Read-State $fixturePath).phase -eq 'recovered') 'Recovery did not finish'
        Assert ((Read-Utf8 $rulesPath) -ceq 'existing rule') 'Recovery did not restore original rules'
        Assert ([IO.File]::Exists((Join-Path $fixturePath '.neuron-harness/runtime.md')) -and (Get-Item -LiteralPath (Join-Path $fixturePath '.neuron-harness/runtime.md')).Length -eq 0) 'New runtime not retained empty'
        Assert ((Read-Utf8 (Join-Path $fixturePath '.neuron-harness/raw.log')) -ceq 'original historical log') 'Recovery changed historical raw.log'
        Assert ((Read-Utf8 (Join-Path $fixturePath '.claude/settings.json') | ConvertFrom-Json -AsHashtable).Count -eq 0) 'Recovered new settings not valid JSON'
        $null = Invoke-Integration $fixturePath Install claude @('-EnablePromptHook')
    }
}
Case 'Uninstall transaction crash recovers installed state including external appended rules' {
    $fixturePath = New-Project 'recover-uninstall'
    $null = Invoke-Integration $fixturePath Install
    [IO.File]::AppendAllText((Join-Path $fixturePath 'AGENTS.md'),"outside added`n")
    $ruleHash = Hash (Join-Path $fixturePath 'AGENTS.md')
    $runtimeHash = Hash (Join-Path $fixturePath '.neuron-harness/runtime.md')
    $env:NH_TEST_FAIL_AFTER = '1'
    try { $null = Invoke-Integration $fixturePath Uninstall generic @('-TestFaultInjection') -Fail } finally { $env:NH_TEST_FAIL_AFTER = $null }
    Assert ((Read-State $fixturePath).phase -eq 'prepared_uninstall') 'Uninstall crash journal missing'
    $null = Invoke-Integration $fixturePath Recover
    Assert ((Read-State $fixturePath).restored_phase -eq 'installed') 'Recover did not restore installed phase'
    Assert ((Hash (Join-Path $fixturePath 'AGENTS.md')) -ceq $ruleHash -and (Hash (Join-Path $fixturePath '.neuron-harness/runtime.md')) -ceq $runtimeHash) 'Recover did not restore installed files'
    $null = Invoke-Integration $fixturePath Status
    $null = Invoke-Integration $fixturePath Uninstall
}
Case 'Pending user modifications or corrupted backup refuse entire recovery' {
    foreach ($corruptBackup in @($false,$true)) {
        $fixturePath = New-Project ('recover-refuse-' + $corruptBackup)
        $env:NH_TEST_FAIL_AFTER = '1'
        try { $null = Invoke-Integration $fixturePath Install generic @('-TestFaultInjection') -Fail } finally { $env:NH_TEST_FAIL_AFTER = $null }
        $pendingRecord = Read-State $fixturePath
        if ($corruptBackup) { [IO.File]::WriteAllText((Join-Path (Join-Path $fixturePath '.neuron-harness') $pendingRecord.items[1].backup),'corrupt backup') }
        else { [IO.File]::WriteAllText((Join-Path $fixturePath 'AGENTS.md'),'user pending changes') }
        $beforeTree = Tree-Hash $fixturePath
        $null = Invoke-Integration $fixturePath Recover -Fail
        Assert ((Tree-Hash $fixturePath) -ceq $beforeTree) 'Refused recovery partially restored files'
    }
}
Case 'Malicious backup relative path never reads or writes outside backup root' {
    $fixturePath = New-Project 'backup-traversal'
    $env:NH_TEST_FAIL_AFTER = '1'
    try { $null = Invoke-Integration $fixturePath Install generic @('-TestFaultInjection') -Fail } finally { $env:NH_TEST_FAIL_AFTER = $null }
    $pendingRecord = Read-State $fixturePath
    $pendingRecord.items[0].backup = '../raw.log'
    [IO.File]::WriteAllText((Join-Path $fixturePath '.neuron-harness/integration/install-state.json'),($pendingRecord | ConvertTo-Json -Depth 100))
    $beforeTree = Tree-Hash $fixturePath
    $null = Invoke-Integration $fixturePath Recover -Fail
    Assert ((Tree-Hash $fixturePath) -ceq $beforeTree) 'Unsafe backup path changed files'
}
Case 'CreateNew lock refuses concurrent owner and never removes another lock' {
    $fixturePath = New-Project 'lock'
    $lockDirectory = Join-Path $fixturePath '.neuron-harness/integration'
    [IO.Directory]::CreateDirectory($lockDirectory) | Out-Null
    $lockPath = Join-Path $lockDirectory 'install.lock'
    $fixtureLock = [IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $failureOutput = Invoke-Integration $fixturePath Install -Fail
        Assert ($failureOutput.Contains('never stolen')) 'Lock conflict not reported'
        Assert ([IO.File]::Exists($lockPath)) 'Another owner lock removed'
        Assert (-not [IO.File]::Exists((Join-Path $fixturePath '.neuron-harness/runtime.md'))) 'Concurrent install wrote runtime'
    } finally { $fixtureLock.Dispose() }
}
Case 'Symlink and reparse ancestors rejected when platform supports link fixture' {
    $fixturePath = New-Project 'symlink-project'
    $externalPath = New-Project 'symlink-external'
    $linkPath = Join-Path $fixturePath '.claude'
    $linkCreated = $false
    try {
        $null = New-Item -ItemType SymbolicLink -Path $linkPath -Target $externalPath -ErrorAction Stop
        $linkCreated = $true
    } catch {
        if ($IsWindows) {
            try { $null = New-Item -ItemType Junction -Path $linkPath -Target $externalPath -ErrorAction Stop; $linkCreated = $true } catch { }
        }
    }
    if ($linkCreated) {
        $beforeTree = Tree-Hash $externalPath
        $null = Invoke-Integration $fixturePath Install claude @('-EnablePromptHook') -Fail
        Assert ((Tree-Hash $externalPath) -ceq $beforeTree) 'Linked external path modified'
        $rootLinkPath = Join-Path $script:TestRoot 'root-link'
        if ($IsWindows) { $null = New-Item -ItemType Junction -Path $rootLinkPath -Target $externalPath }
        else { $null = New-Item -ItemType SymbolicLink -Path $rootLinkPath -Target $externalPath }
        $null = Invoke-Integration $rootLinkPath Plan -Fail
    } else { $script:Skipped++; Write-Output 'SKIP link creation unavailable' }
}
Case 'Init failure remains incomplete and never claims installed' {
    $fixturePath = New-Project 'init-fails' -Uninitialized
    $env:NH_FIXTURE_INIT_FAIL = '1'
    try { $failureOutput = Invoke-Integration $fixturePath Install generic @('-Init') -Fail } finally { $env:NH_FIXTURE_INIT_FAIL = $null }
    Assert ($failureOutput.Contains('Init failed')) 'Init failure not reported'
    Assert ((Read-State $fixturePath).phase -eq 'prepared') 'Init failure journal not prepared'
    Assert (-not [IO.File]::Exists((Join-Path $fixturePath 'AGENTS.md'))) 'Init failure enabled rules'
    $null = Invoke-Integration $fixturePath Recover
}
Case 'Absolute roots mandatory before canonicalization' {
    $null = Invoke-Integration '.' Plan -Fail
    $fixturePath = New-Project 'relative-skill'
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $relativeOutput = & $script:PwshPath -NoProfile -File $IntegrationScript -Project $fixturePath -Harness generic -SkillRoot '.' 2>&1
        $relativeExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    Assert ($relativeExit -ne 0 -and ($relativeOutput -join "`n").Contains('explicit absolute path')) 'Relative SkillRoot accepted'
}
Case 'Explicit stale-lock recovery isolates abandoned lock but refuses live handle' {
    $fixturePath = New-Project 'stale-lock-recover'
    $env:NH_TEST_FAIL_AFTER = '1'
    try { $null = Invoke-Integration $fixturePath Install generic @('-TestFaultInjection') -Fail } finally { $env:NH_TEST_FAIL_AFTER = $null }
    $lockPath = Join-Path $fixturePath '.neuron-harness/integration/install.lock'
    $fixtureLock = [IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $null = Invoke-Integration $fixturePath Recover generic @('-RecoverStaleLock') -Fail
        Assert ([IO.File]::Exists($lockPath)) 'Live lock was stolen'
    } finally { $fixtureLock.Dispose() }
    $null = Invoke-Integration $fixturePath Recover -Fail
    $null = Invoke-Integration $fixturePath Recover generic @('-RecoverStaleLock')
    Assert ((Read-State $fixturePath).phase -eq 'recovered') 'Stale lock blocked explicit recovery'
    Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $lockPath) -Filter 'install.lock.stale-*').Count -eq 1) 'Stale lock not retained as history'
    $null = Invoke-Integration $fixturePath Install generic @('-RecoverStaleLock') -Fail
}
Case 'Lexical symlink traversal before dot-dot normalization is refused' {
    $linkPath = Join-Path $script:TestRoot 'root-link'
    if (Test-Path -LiteralPath $linkPath) {
        $hiddenTraversal = $linkPath + [IO.Path]::DirectorySeparatorChar + '..' + [IO.Path]::DirectorySeparatorChar + 'plan'
        $null = Invoke-Integration $hiddenTraversal Plan -Fail
    } else { $script:Skipped++; Write-Output 'SKIP lexical link fixture unavailable' }
}
Case 'Recovered Claude empty settings can be reinstalled without weakening strict JSON for unowned files' {
    $fixturePath = New-Project 'claude-reinstall-empty'
    $null = Invoke-Integration $fixturePath Install claude @('-EnablePromptHook')
    $null = Invoke-Integration $fixturePath Uninstall claude @('-EnablePromptHook')
    Assert ((Read-Utf8 (Join-Path $fixturePath '.claude/settings.json') | ConvertFrom-Json -AsHashtable).Count -eq 0) 'New settings did not restore to valid empty JSON object'
    $null = Invoke-Integration $fixturePath Install claude @('-EnablePromptHook')
    $null = Invoke-Integration $fixturePath Uninstall claude @('-EnablePromptHook')
    $unownedFixture = New-Project 'claude-unowned-empty'
    [IO.Directory]::CreateDirectory((Join-Path $unownedFixture '.claude')) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $unownedFixture '.claude/settings.json'),[byte[]]::new(0))
    $null = Invoke-Integration $unownedFixture Install claude @('-EnablePromptHook') -Fail
}
Case 'Interrupted Recover can restart but a user-created empty pending file is refused' {
    $fixturePath = New-Project 'recover-interrupted'
    $env:NH_TEST_FAIL_AFTER = '1'
    try { $null = Invoke-Integration $fixturePath Install generic @('-TestFaultInjection') -Fail } finally { $env:NH_TEST_FAIL_AFTER = $null }
    [IO.File]::WriteAllBytes((Join-Path $fixturePath 'AGENTS.md'),[byte[]]::new(0))
    $null = Invoke-Integration $fixturePath Recover -Fail
    # Return this generated file to the explicit absent-before state by moving it, never deleting.
    [IO.File]::Move((Join-Path $fixturePath 'AGENTS.md'),(Join-Path $fixturePath 'empty.fixture-away'))
    $env:NH_TEST_FAIL_AFTER = '1'
    try { $null = Invoke-Integration $fixturePath Recover generic @('-TestFaultInjection') -Fail } finally { $env:NH_TEST_FAIL_AFTER = $null }
    Assert ((Read-State $fixturePath).phase -eq 'prepared') 'Interrupted recovery cleared journal early'
    $null = Invoke-Integration $fixturePath Recover
    Assert ((Read-State $fixturePath).phase -eq 'recovered') 'Interrupted recovery did not restart'
}
Case 'A changed source snapshot is never rebased into a permitted overwrite' {
    foreach ($relativePath in @('CLAUDE.md','.neuron-harness/runtime.md','.claude/settings.json')) {
        $fixturePath = New-Project ('snapshot-race-' + [guid]::NewGuid().ToString('N'))
        $env:NH_TEST_CHANGE_BEFORE_PREPARE = $relativePath
        try { $failureOutput = Invoke-Integration $fixturePath Install claude @('-EnablePromptHook','-TestFaultInjection') -Fail } finally { $env:NH_TEST_CHANGE_BEFORE_PREPARE = $null }
        Assert ($failureOutput.Contains('File changed; refusing write')) 'Changed source snapshot accepted'
        Assert ((Read-Utf8 (Join-Path $fixturePath $relativePath)) -ceq 'test external edit after source snapshot') 'External edit overwritten'
        Assert (-not [IO.File]::Exists((Join-Path $fixturePath '.neuron-harness/integration/install-state.json'))) 'Changed source prepared a transaction'
    }
    $fixturePath = New-Project 'snapshot-race-uninstall'
    $null = Invoke-Integration $fixturePath Install
    $runtimeHash = Hash (Join-Path $fixturePath '.neuron-harness/runtime.md')
    $env:NH_TEST_CHANGE_BEFORE_PREPARE = 'AGENTS.md'
    try { $null = Invoke-Integration $fixturePath Uninstall generic @('-TestFaultInjection') -Fail } finally { $env:NH_TEST_CHANGE_BEFORE_PREPARE = $null }
    Assert ((Hash (Join-Path $fixturePath '.neuron-harness/runtime.md')) -ceq $runtimeHash) 'Uninstall source race partially applied'
}
Case 'Legacy journal explicitly refuses writes pending manual review' {
    $fixturePath = New-Project 'legacy-journal'
    $null = Invoke-Integration $fixturePath Install
    $legacyRecord = Read-State $fixturePath
    $legacyRecord.schema = 1; $legacyRecord.version = 1
    [IO.File]::WriteAllText((Join-Path $fixturePath '.neuron-harness/integration/install-state.json'),($legacyRecord | ConvertTo-Json -Depth 100))
    $beforeTree = Tree-Hash $fixturePath
    $failureOutput = Invoke-Integration $fixturePath Uninstall -Fail
    Assert ($failureOutput.Contains('Unsupported legacy integration journal') -and $failureOutput.Contains('manual review')) 'Legacy journal not explained'
    Assert ((Tree-Hash $fixturePath) -ceq $beforeTree) 'Legacy journal changed files'
}
Write-Output "RESULT passed=$script:Passed skipped=$script:Skipped"
Write-Output "Fixtures retained at: $script:TestRoot"
exit 0
