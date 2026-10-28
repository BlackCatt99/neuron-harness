#Requires -Version 7
<#
neuron-harness 集成测试基线（P0 主链 + 回归路径）。
用法：pwsh -NoProfile -File tests/e2e.ps1
退出码 0 = 全绿。改 scripts/assemble.ps1 后必须本脚本全绿再交付（见 OPERATIONS.md）。
#>
param(
    [string]$ScriptPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'scripts' 'assemble.ps1')),
    [switch]$KeepArtifacts
)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

$S = (Resolve-Path -LiteralPath $ScriptPath).Path
# 测试缩短等锁窗口：默认 15s/deadline、120s/stale 会让锁用例跑几分钟；语义不变，只调时长。
$env:CR_LOCK_DEADLINE_SECONDS = '2'
$env:CR_LOCK_STALE_AFTER_SECONDS = '1'
$proj = Join-Path ([System.IO.Path]::GetTempPath()) ('cr-e2e-' + [guid]::NewGuid().ToString('N'))
# 子进程必须用当前这份 PowerShell 的可执行路径：Windows 是 pwsh.exe，Linux/macOS 是 pwsh，
# 但不保证 PATH 里叫 pwsh，也不能退回 powershell（Windows PowerShell 5 不满足 #Requires 7）。
$pwshExe = (Get-Process -Id $PID).Path
if (-not $pwshExe) { $pwshExe = 'pwsh' }
$root = Join-Path $proj '.neuron-harness'
$passed = 0; $failed = 0

function Assert-True([bool]$cond, [string]$why) { if (-not $cond) { throw ('断言失败: ' + $why) } }
function Assert-Throw([scriptblock]$sb, [string]$mustContain) {
    $hit = $false
    try { & $sb | Out-Null } catch { if ("$_" -match [regex]::Escape($mustContain)) { $hit = $true } }
    Assert-True $hit ('应报错含「' + $mustContain + '」')
}
function Step([string]$testName, [scriptblock]$testAction) {
    try { & $testAction; $script:passed++; Write-Output ('PASS ' + $testName) }
    catch {
        $script:failed++
        Write-Output ('FAIL ' + $testName + ' :: ' + $_)
        Write-Output $_.InvocationInfo.PositionMessage
        Write-Output $_.ScriptStackTrace
    }
}
function Read-IndexRows {
    $indexLines = @(Get-Content -Encoding utf8 (Join-Path $root 'index.tsv'))
    foreach ($indexLine in @($indexLines | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($indexLine)) { continue }
        $indexFields = $indexLine -split "`t"
        Assert-True ($indexFields.Count -eq 7) '索引数据必须恰好七列'
        [pscustomobject]@{ id=$indexFields[0]; task=$indexFields[1]; tags=$indexFields[2]; type=$indexFields[3]; summary=$indexFields[4]; file=$indexFields[5]; src=$indexFields[6] }
    }
}
function Wait-OrKill([object[]]$processes, [int]$timeoutSeconds) {
    # Wait-Process 超时不会终止子进程：残活的写入者会在后续读索引时造成中间态，
    # 被测断言就变成随机失败。超时后强制清理，并把这一事实显式报出来。
    if ($null -eq $processes -or @($processes).Count -eq 0) { return }
    $processes | Wait-Process -Timeout $timeoutSeconds -ErrorAction SilentlyContinue
    $stuck = @($processes | Where-Object { -not $_.HasExited })
    foreach ($stuckProcess in $stuck) {
        try { Stop-Process -Id $stuckProcess.Id -Force -ErrorAction Stop } catch { }
    }
    if ($stuck.Count -gt 0) {
        Write-Output ('WARN: ' + $stuck.Count + ' 个子进程在 ' + $timeoutSeconds + 's 内未退出，已强制终止（其断言结果不可信）')
    }
}
function W([string]$t) { # 临时内容文件
    $p = Join-Path $proj ('tmp-' + (Get-Random) + '.txt')
    [System.IO.File]::WriteAllText($p, $t, [System.Text.UTF8Encoding]::new($false)); return $p
}

try {
    New-Item -ItemType Directory -Force $proj | Out-Null

    Step '01 Init：结构+七列索引+config+模板' {
        & $S -Mode Init -Project $proj | Out-Null
        Assert-True (Test-Path (Join-Path $root 'archive\t4')) 't4 目录'
        $head = (Get-Content -Encoding utf8 (Join-Path $root 'index.tsv') -TotalCount 1) -split "`t"
        Assert-True ($head.Count -ge 7) ('索引头 ' + $head.Count + ' 列')
        Assert-True ((Get-Content -Raw (Join-Path $root 'config.json')) -match 't2_days') 'config 含 t2_days'
        Assert-True ((Get-ChildItem (Join-Path $root 'templates') -Filter '*.md').Count -eq 4) '四份模板'
    }

    $script:m1 = $null; $script:m2 = $null; $script:m3 = $null
    Step '02 LogRaw：id 返回 + raw 块结构' {
        $script:m1 = & $S -Mode LogRaw -TaskId t1 -ContentFile (W '第一条消息') -Project $proj
        Assert-True ($script:m1 -eq 'M00001') ('期望 M00001 实得 ' + $script:m1)
        Assert-True ((Select-String -Path (Join-Path $root 'raw.log') -Pattern '^<<<END M00001').Count -eq 1) 'END 标记'
    }
    Step '03 首行标记硬触发：[切换] 自动落信号' {
        $script:m2 = & $S -Mode LogRaw -TaskId t1 -ContentFile (W '[切换] 换子任务') -Project $proj
        Assert-True (@(& $S -Mode RecheckList -Project $proj | Where-Object { $_ -match 'SIGNAL-switch' -and $_ -match "`tt1" }).Count -eq 1) 'SIGNAL-switch 落盘'
    }
    Step '04 Signal 独立补落命令' {
        & $S -Mode Signal -Signal dep -TaskId t1 -Project $proj | Out-Null
        Assert-True (@(& $S -Mode RecheckList -Project $proj | Where-Object { $_ -match 'SIGNAL-dep' -and $_ -match "`tt1" }).Count -eq 1) 'SIGNAL-dep 补落'
        & $S -Mode ClearRecheck -Project $proj | Out-Null
    }

    $script:c1 = $null; $script:ed = $null; $script:ex = $null; $script:ea = $null
    Step '05 归档四分类初始层 + access 基准' {
        $script:c1 = & $S -Mode Archive -Type constraint -TaskId t1 -Source $script:m1 -Summary '[脚本|选定] c' -ContentFile (W '约束原文') -Project $proj
        $script:ed = & $S -Mode Archive -Type evidence -TaskId t1 -Tags 'decisions,节点A' -Source $script:m1 -Summary '[决策|归档] d' -ContentFile (W '决策原文') -Project $proj
        $script:ex = & $S -Mode Archive -Type discard -TaskId t1 -Source $script:m1 -Summary '[流程|删除] x' -ContentFile (W '可弃原文') -Project $proj
        $script:ea = & $S -Mode Archive -Type evidence -TaskId t1 -Tags '节点A' -Source $script:m2 -Summary '[数据|新增] a' -ContentFile (W '证据原文') -Project $proj
        $idx = Get-Content -Encoding utf8 (Join-Path $root 'index.tsv')
        Assert-True (@($idx | Where-Object { $_ -match ('^' + $script:ed + '\tt1\t.*\tarchive/t3/' + $script:ed + '\.md') }).Count -eq 1) 'decisions 应 t3'
        Assert-True (@($idx | Where-Object { $_ -match ('^' + $script:ex + '\t.*\tarchive/t4/' + $script:ex + '\.md') }).Count -eq 1) 'discard 应 t4'
        Assert-True (@($idx | Where-Object { $_ -match ('^' + $script:ea + '\t.*\tarchive/t2/' + $script:ea + '\.md') }).Count -eq 1) 'evidence 应 t2'
        $acc = Get-Content -Encoding utf8 (Join-Path $root 'access.log')
        Assert-True (@($acc | Where-Object { $_ -match "`t$script:ed`tarchive" }).Count -eq 1) 'access archive 基准'
    }
    Step '06 来源校验三态' {
        Assert-Throw { & $S -Mode Archive -Type constraint -TaskId t1 -ContentFile (W 'x') -Project $proj } '来源必填'
        Assert-Throw { & $S -Mode Archive -Type constraint -TaskId t1 -Source M99999 -ContentFile (W 'x') -Project $proj } '不存在于 raw.log'
        Assert-Throw { & $S -Mode Archive -Type constraint -TaskId t1 -Source CONFIRMED -ContentFile (W 'x') -Staging -Project $proj } '禁止 CONFIRMED'
    }
    Step '07 工作集乐观锁' {
        & $S -Mode SaveState -TaskId t1 -ContentFile (W "# 工作集`n## 架构视图`n节点A -> 节点B") -BaseVer 0 -Project $proj | Out-Null
        Assert-Throw { & $S -Mode SaveState -TaskId t1 -ContentFile (W 'v') -BaseVer 0 -Project $proj } '已被并发修订'
        & $S -Mode SaveState -TaskId t1 -ContentFile (W "# 工作集`n## 架构视图`n节点A -> 节点B -> 节点C") -BaseVer 1 -Project $proj | Out-Null
    }

    $script:c2 = $null
    Step '08 Supersede：历史区 + 旧文落 t3 + 信号带 task' {
        $script:m3 = & $S -Mode LogRaw -TaskId t1 -ContentFile (W '第二条消息') -Project $proj
        $script:c2 = & $S -Mode Archive -Type constraint -TaskId t1 -Source $script:m3 -Summary '[脚本|修改] c2' -ContentFile (W '新约束') -Project $proj
        & $S -Mode Supersede -Id $script:c1 -By $script:c2 -Project $proj | Out-Null
        $idx = Get-Content -Encoding utf8 (Join-Path $root 'index.tsv')
        Assert-True (@($idx | Where-Object { $_ -match ('^' + $script:c1 + '\t.*\tarchive/t3/' + $script:c1 + '\.md') }).Count -eq 1) '旧约束落 t3'
        Assert-True (Test-Path (Join-Path $root ('archive\t3\' + $script:c1 + '.md'))) '旧约束文件在 t3'
        $cst = Get-Content -Raw -Encoding utf8 (Join-Path $root 'constraints.md')
        Assert-True ($cst -match ('~~.*~~ → 被 ' + $script:c2 + ' 取代')) '历史区链'
        Assert-True (@(& $S -Mode RecheckList -Project $proj | Where-Object { $_ -match ($script:c1 + "`t" + $script:c2 + "`tt1") }).Count -eq 1) '信号带 task'
        & $S -Mode ClearRecheck -Project $proj | Out-Null
    }

    $script:sc = $null
    Step '09 staging 全链：不写索引→增量Review→Approve 校验+入库' {
        $script:sc = & $S -Mode Archive -Type constraint -TaskId t1 -Source $script:m3 -Summary '[角色|确认] s' -ContentFile (W 'staging 约束') -Staging -Project $proj
        $script:sc = $script:sc -replace '^STAGED ', ''
        $idx = Get-Content -Encoding utf8 (Join-Path $root 'index.tsv')
        Assert-True (-not (@($idx | Where-Object { $_ -match ('^' + $script:sc + "`t") }).Count -gt 0)) 'staging 不写索引'
        Assert-True (@(& $S -Mode ReviewStaging -Project $proj | Where-Object { $_ -match $script:sc }).Count -gt 0) '增量 Review 可见'
        Assert-True (@(& $S -Mode ReviewStaging -Project $proj | Where-Object { $_ -match ('===== ' + $script:sc) }).Count -eq 0) '二次 Review 折叠滞留'
        $badFile = Join-Path $root ('staging\' + $script:sc + '.md')
        $body = Get-Content -Raw -Encoding utf8 $badFile
        $forged = $body -replace 'src: M\d+', 'src: CONFIRMED'
        [System.IO.File]::WriteAllText($badFile, $forged, [System.Text.UTF8Encoding]::new($false))
        Assert-Throw { & $S -Mode ApproveStaging -Id $script:sc -Project $proj } '禁止 CONFIRMED'
        & $S -Mode RejectStaging -Id $script:sc -Project $proj | Out-Null
        $script:sc2 = & $S -Mode Archive -Type constraint -TaskId t1 -Source $script:m3 -Summary '[角色|确认] s2' -ContentFile (W 'staging 约束2') -Staging -Project $proj
        $script:sc2 = $script:sc2 -replace '^STAGED ', ''
        & $S -Mode ReviewStaging -Project $proj | Out-Null
        & $S -Mode ApproveStaging -Id $script:sc2 -Project $proj | Out-Null
        $approvedRows = @(Read-IndexRows | Where-Object { $_.id -eq $script:sc2 })
        Assert-True ($approvedRows.Count -eq 1) 'Approve 入索引且 id 唯一'
    }

    Step '10 Assemble：顺序/标注/反问协议/白名单/过载' {
        $packF = Join-Path $proj 'pack.md'
        & $S -Mode Assemble -TaskId t1 -InstructionFile (W '干活') -Evidence ($script:ed + ',' + $script:ea + ',' + $script:c2) -Project $proj -OutFile $packF | Out-Null
        $pk = Get-Content -Raw -Encoding utf8 $packF
        $secNames = @([regex]::Matches($pk, '(?m)^## (.+)$') | ForEach-Object { $_.Groups[1].Value })
        Assert-True ($secNames -contains '反问协议') '反问协议在包'
        Assert-True ($pk -match '<evidence id="' + $script:ea + '" task="t1" tier="t2">') 't2 标注'
        Assert-True ($pk -match '<evidence id="' + $script:ed + '"[^>]*tier="t3" kind="decision">') 't3+decision 标注'
        Assert-True ($pk -match '类型为 constraint，非 evidence，拒绝入包') '约束 id 拒入包'
        $iInstr = $secNames.IndexOf('本次指令'); $iEv = $secNames.IndexOf('相关证据')
        Assert-True ($iInstr -gt $iEv) '指令压轴'
        Assert-Throw { & $S -Mode Assemble -TaskId t1 -InstructionFile (W '干活') -Budget 300 -Project $proj } '任务过载'
    }

    Step '11 Search：默认仅 evidence；无 TaskId 拒绝；-Tsv 纯 TSV' {
        $def = & $S -Mode Search -TaskId t1 -Project $proj
        Assert-True (@($def | Where-Object { $_ -match '^' + $script:ea + "`t" }).Count -eq 1) '默认命中 evidence'
        Assert-True (-not (@($def | Where-Object { $_ -match '^C\d' }).Count -gt 0)) '默认不含 constraint'
        Assert-Throw { & $S -Mode Search -Project $proj } '需要 -TaskId'
        $one = @(& $S -Mode Search -TaskId t1 -Type constraint -Tsv -Project $proj | Where-Object { $_ -notmatch '^（' })[0]
        Assert-True (($one -split "`t").Count -ge 7) 'Tsv 纯 7 列'
    }
    Step '12 discard 全模式隐身' {
        $patterns = @(@(), @('-Tier', 'all'), @('-Type', 'all'), @('-Tier', 'all', '-Type', 'all'))
        foreach ($extra in $patterns) {
            $r = & $S -Mode Search -TaskId t1 @extra -Project $proj
            Assert-True (-not (@($r | Where-Object { $_ -match ('^' + $script:ex + "`t") }).Count -gt 0)) ('discard 隐身: ' + ($extra -join ' '))
        }
    }
    Step '13 Verify 悬空修复（finally 归位，不污染后续）' {
        $originalFile = Join-Path $root ('archive\t2\' + $script:ea + '.md')
        $relocatedFile = Join-Path $root ('archive\t9\' + $script:ea + '.md')
        New-Item -ItemType Directory -Force (Split-Path $relocatedFile) | Out-Null
        Move-Item $originalFile $relocatedFile
        try {
            $backupCount = @(Get-ChildItem $root -Filter 'index.tsv.bak-*').Count
            $out = @(& $S -Mode Verify -Project $proj)
            Assert-True (@($out | Where-Object { $_ -match 'FIXED: 1 条' }).Count -eq 1) 'FIXED 输出'
            $fixedRows = @(Read-IndexRows | Where-Object { $_.id -eq $script:ea })
            Assert-True ($fixedRows.Count -eq 1 -and $fixedRows[0].file -eq ('archive/t9/' + $script:ea + '.md')) '索引指向实际位置'
            Assert-True (@(Get-ChildItem $root -Filter 'index.tsv.bak-*').Count -gt $backupCount) '本次修复新增备份'
        } finally {
            if (Test-Path $relocatedFile) { Move-Item $relocatedFile $originalFile }
            & $S -Mode Verify -Project $proj | Out-Null
        }
        $restoredRows = @(Read-IndexRows | Where-Object { $_.id -eq $script:ea })
        Assert-True ($restoredRows.Count -eq 1 -and $restoredRows[0].file -eq ('archive/t2/' + $script:ea + '.md')) '归位复原'
    }
    Step '14 TierSweep 新鲜访问记录：dry-run 不移动；Execute 层位不变' {
        $before = (Get-ChildItem (Join-Path $root 'archive') -Recurse -Filter 'E*.md' | Sort-Object FullName).FullName -join '|'
        $indexBefore = Get-FileHash (Join-Path $root 'index.tsv')
        & $S -Mode TierSweep -Project $proj | Out-Null
        $after = (Get-ChildItem (Join-Path $root 'archive') -Recurse -Filter 'E*.md' | Sort-Object FullName).FullName -join '|'
        Assert-True ($before -eq $after) 'dry-run 不动文件'
        Assert-True ($indexBefore.Hash -eq (Get-FileHash (Join-Path $root 'index.tsv')).Hash) 'dry-run 不改索引'
        $sweepOutput = @(& $S -Mode TierSweep -Execute -Project $proj)
        Assert-True (@($sweepOutput | Where-Object { $_ -match 'SWEEP DONE|NOTHING' }).Count -ge 1) 'Execute 完成'
        Assert-True (@($sweepOutput | Where-Object { $_ -match 'T2\s*->\s*T[34]' }).Count -eq 0) '新鲜记录无降档'
        $afterExecute = (Get-ChildItem (Join-Path $root 'archive') -Recurse -Filter 'E*.md' | Sort-Object FullName).FullName -join '|'
        Assert-True ($before -eq $afterExecute) 'Execute 文件层位不变'
    }
    Step '15 无访问记录：dry-run 不回填；Execute 持久化；重跑基准不漂移' {
        $backfillProject = Join-Path $proj 'backfill-fixture'
        New-Item -ItemType Directory $backfillProject | Out-Null
        & $S -Mode Init -Project $backfillProject | Out-Null
        $backfillRoot = Join-Path $backfillProject '.neuron-harness'
        $backfillId = & $S -Mode Archive -Type evidence -TaskId inactive -Summary '[数据|新增] backfill' -ContentFile (W 'backfill original') -Project $backfillProject
        $accessPath = Join-Path $backfillRoot 'access.log'
        Clear-Content -LiteralPath $accessPath
        $accessHash = (Get-FileHash -LiteralPath $accessPath).Hash
        $indexHash = (Get-FileHash (Join-Path $backfillRoot 'index.tsv')).Hash
        & $S -Mode TierSweep -Project $backfillProject | Out-Null
        Assert-True ($accessHash -eq (Get-FileHash -LiteralPath $accessPath).Hash) 'dry-run 不写 backfill'
        & $S -Mode TierSweep -Execute -Project $backfillProject | Out-Null
        $persisted = @(Get-Content -Encoding utf8 $accessPath | Where-Object { $_ -match ("`t" + $backfillId + "`tbackfill$") })
        Assert-True ($persisted.Count -eq 1) '无层位变更也必须写入 backfill 基准'
        $baseline = $persisted[0]
        Assert-True ($indexHash -eq (Get-FileHash (Join-Path $backfillRoot 'index.tsv')).Hash) '纯 backfill 不改索引内容'
        Assert-True (Test-Path (Join-Path $backfillRoot ('archive/t2/' + $backfillId + '.md'))) '首次回填留在 T2'
        & $S -Mode TierSweep -Execute -Project $backfillProject | Out-Null
        $persistedAgain = @(Get-Content -Encoding utf8 $accessPath | Where-Object { $_ -match ("`t" + $backfillId + "`tbackfill$") })
        Assert-True ($persistedAgain.Count -eq 1 -and $persistedAgain[0] -eq $baseline) '重跑不得重置 backfill 时间'
    }
    Step '16 legacy 同层迁移：保留原文、更新索引、单独新增备份' {
        $legacyProject = Join-Path $proj 'legacy-fixture'
        New-Item -ItemType Directory $legacyProject | Out-Null
        & $S -Mode Init -Project $legacyProject | Out-Null
        $legacyRoot = Join-Path $legacyProject '.neuron-harness'
        $legacyId = & $S -Mode Archive -Type evidence -TaskId inactive -Summary '[数据|新增] legacy' -ContentFile (W 'legacy original') -Project $legacyProject
        $tierFile = Join-Path $legacyRoot ('archive/t2/' + $legacyId + '.md')
        $flatFile = Join-Path $legacyRoot ('archive/' + $legacyId + '.md')
        $originalHash = (Get-FileHash -LiteralPath $tierFile).Hash
        Move-Item $tierFile $flatFile
        $legacyIndex = Join-Path $legacyRoot 'index.tsv'
        $legacyText = [IO.File]::ReadAllText($legacyIndex).Replace(('archive/t2/' + $legacyId + '.md'), ('archive/' + $legacyId + '.md'))
        [IO.File]::WriteAllText($legacyIndex, $legacyText, [Text.UTF8Encoding]::new($false))
        $dryOutput = @(& $S -Mode TierSweep -Project $legacyProject)
        Assert-True (@($dryOutput | Where-Object { $_ -match 'LEGACY' }).Count -eq 1) 'dry-run 列出 legacy 提案'
        Assert-True (Test-Path $flatFile) 'dry-run 不移动 legacy 文件'
        & $S -Mode TierSweep -Execute -Project $legacyProject | Out-Null
        Assert-True (Test-Path $tierFile) 'Execute 完成同层路径迁移'
        Assert-True ($originalHash -eq (Get-FileHash -LiteralPath $tierFile).Hash) '迁移后原文逐字保留'
        $legacyRow = @(Get-Content -Encoding utf8 $legacyIndex | Where-Object { $_ -match ('^' + $legacyId + "`t") })
        Assert-True ($legacyRow.Count -eq 1 -and ($legacyRow[0] -split "`t")[5] -eq ('archive/t2/' + $legacyId + '.md')) '同层迁移必须提交索引'
        Assert-True (@(Get-ChildItem $legacyRoot -Filter 'index.tsv.bak-*').Count -eq 1) '本次迁移留单独备份'
    }
    Step '17 固定时钟两次 ClearRecheck：不碰撞且归档原文完整' {
        $collisionProject = Join-Path $proj 'collision-fixture'
        New-Item -ItemType Directory $collisionProject | Out-Null
        & $S -Mode Init -Project $collisionProject | Out-Null
        $collisionRoot = Join-Path $collisionProject '.neuron-harness'
        & {
            function Get-Date {
                param([string]$Format)
                $fixedClock = [datetime]'2026-01-02T03:04:05.000'
                if ($Format) { return $fixedClock.ToString($Format) }
                return $fixedClock
            }
            foreach ($signalKind in @('switch', 'dep')) {
                & $S -Mode Signal -Signal $signalKind -TaskId collision -Project $collisionProject | Out-Null
                & $S -Mode ClearRecheck -Project $collisionProject | Out-Null
            }
        }
        $clearedLogs = @(Get-ChildItem (Join-Path $collisionRoot 'archive') -Filter 'recheck-*.log')
        Assert-True ($clearedLogs.Count -eq 2) '相同毫秒也必须保留两份独立归档'
        $clearedLines = @($clearedLogs | ForEach-Object { Get-Content -LiteralPath $_.FullName -Encoding utf8 })
        Assert-True (@($clearedLines | Where-Object { $_ -match 'SIGNAL-switch' }).Count -eq 1) 'switch 原记录完整且不重复'
        Assert-True (@($clearedLines | Where-Object { $_ -match 'SIGNAL-dep' }).Count -eq 1) 'dep 原记录完整且不重复'
        Assert-True (-not (Test-Path (Join-Path $collisionRoot 'pending-recheck.log'))) '两次清理后无残留 pending'
    }
    Step '18 并发写入：多进程 Archive 不丢条目、索引七列、无残留锁' {
        $concProject = Join-Path $proj 'concurrent-fixture'
        New-Item -ItemType Directory $concProject | Out-Null
        & $S -Mode Init -Project $concProject | Out-Null
        $concRoot = Join-Path $concProject '.neuron-harness'
        $workers = 4
        $launched = @()
        for ($i = 1; $i -le $workers; $i++) {
            $contentFile = Join-Path $concProject ("input-$i.txt")
            [System.IO.File]::WriteAllText($contentFile, "concurrent $i", [System.Text.UTF8Encoding]::new($false))
            $launched += Start-Process $pwshExe -ArgumentList @(
                '-NoProfile', '-File', $S, '-Mode', 'Archive', '-Type', 'evidence',
                '-TaskId', 'conc', '-ContentFile', $contentFile, '-Project', $concProject
            ) -PassThru `
              -RedirectStandardOutput (Join-Path $concProject "out-$i.txt") `
              -RedirectStandardError (Join-Path $concProject "err-$i.txt")
        }
        Wait-OrKill $launched 180
        $rows = @(Get-Content -Encoding utf8 (Join-Path $concRoot 'index.tsv') | Where-Object { $_ -notmatch '^#' -and $_ -ne '' })
        Assert-True ($rows.Count -eq $workers) ('并发 Archive 应得 ' + $workers + ' 行，实得 ' + $rows.Count)
        $parsed = @($rows | ForEach-Object { , @($_ -split "`t") })
        $ids = @($parsed | ForEach-Object { $_[0] })
        Assert-True (@($ids | Select-Object -Unique).Count -eq $workers) 'id 不得重复'
        Assert-True (@($parsed | Where-Object { $_.Count -ne 7 }).Count -eq 0) '并发后索引仍为七列'
        Assert-True (@($parsed | Where-Object { -not (Test-Path (Join-Path $concRoot ($_[5] -replace '/', '\'))) }).Count -eq 0) '每条索引指向的文件都存在'
        Assert-True (-not (Test-Path (Join-Path $concRoot '.lock'))) '全部退出后不得残留锁文件'
        $strayTmp = @(Get-ChildItem $concRoot -Recurse -Force -Filter '*.tmp*' -ErrorAction SilentlyContinue)
        Assert-True ($strayTmp.Count -eq 0) '不得残留临时文件'
        $errors = @(for ($i = 1; $i -le $workers; $i++) {
            $e = Get-Content -Raw -Encoding utf8 (Join-Path $concProject "err-$i.txt") -ErrorAction SilentlyContinue
            if ($e -and $e.Trim() -ne '') { "worker $i : $($e.Trim())" }
        })
        Assert-True ($errors.Count -eq 0) ('并发工作进程不得报错：' + ($errors -join ' | '))
    }
    Step '19 陈旧锁：超龄锁被隔离并自动重取，不阻塞不崩溃' {
        $staleProject = Join-Path $proj 'stale-lock-fixture'
        New-Item -ItemType Directory $staleProject | Out-Null
        & $S -Mode Init -Project $staleProject | Out-Null
        $staleRoot = Join-Path $staleProject '.neuron-harness'
        $staleLock = Join-Path $staleRoot '.lock'
        # 伪造 1 小时前的 owner 记录（含已退出的 pid），模拟持锁进程崩溃
        [System.IO.File]::WriteAllText(
            $staleLock,
            ("999999`t" + (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')),
            [System.Text.UTF8Encoding]::new($false)
        )
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $staleOutput = @(& $S -Mode Archive -Type evidence -TaskId stale -Summary '[数据|新增] stale' -ContentFile (W 'after stale lock') -Project $staleProject)
        $clock.Stop()
        $staleIds = @($staleOutput | Where-Object { $_ -match '^E\d+$' })
        Assert-True ($staleIds.Count -eq 1) ('陈旧锁不应阻断写入；输出: ' + ($staleOutput -join ' | '))
        $staleId = $staleIds[0]
        Assert-True (@($staleOutput | Where-Object { $_ -match '陈旧锁' }).Count -eq 1) '应明确报告陈旧锁被隔离'
        Assert-True ($clock.Elapsed.TotalSeconds -lt 30) ('陈旧锁应在阈值后快速隔离，实际耗时 ' + [int]$clock.Elapsed.TotalSeconds + 's')
        Assert-True (-not (Test-Path $staleLock)) '完成后原锁文件解除'
        $isolated = @(Get-ChildItem $staleRoot -Filter '.lock-stale-*')
        Assert-True ($isolated.Count -eq 1) '陈旧锁应被改名隔离而非删除'
        $staleRow = @(Get-Content -Encoding utf8 (Join-Path $staleRoot 'index.tsv') | Where-Object { $_ -match ('^' + $staleId + "`t") })
        Assert-True ($staleRow.Count -eq 1) '陈旧锁之后的写入完整入索引'
    }
    Step '20 并发 TierSweep：索引重写不丢行、备份不互相覆盖' {
        $multiProject = Join-Path $proj 'multi-sweep-fixture'
        New-Item -ItemType Directory $multiProject | Out-Null
        & $S -Mode Init -Project $multiProject | Out-Null
        $multiRoot = Join-Path $multiProject '.neuron-harness'
        $seedCount = 6
        for ($i = 1; $i -le $seedCount; $i++) {
            & $S -Mode Archive -Type evidence -TaskId 'multi' -Summary "[数据|新增] seed$i" -ContentFile (W "seed $i") -Project $multiProject | Out-Null
        }
        # 制造需要层位变更的条件：把 t2 文件手工挪到平铺路径，触发 legacy 归一化
        foreach ($seedFile in @(Get-ChildItem (Join-Path $multiRoot 'archive\t2') -Filter 'E*.md')) {
            Move-Item $seedFile.FullName (Join-Path $multiRoot ('archive\' + $seedFile.Name))
        }
        $multiIndex = Join-Path $multiRoot 'index.tsv'
        $text = [System.IO.File]::ReadAllText($multiIndex)
        foreach ($seedFile in @(Get-ChildItem (Join-Path $multiRoot 'archive') -Filter 'E*.md')) {
            $text = $text.Replace(('archive/t2/' + $seedFile.Name), ('archive/' + $seedFile.Name))
        }
        [System.IO.File]::WriteAllText($multiIndex, $text, [System.Text.UTF8Encoding]::new($false))
        $rowsBefore = @(Get-Content -Encoding utf8 $multiIndex | Where-Object { $_ -notmatch '^#' -and $_ -ne '' }).Count
        $sweepers = 1..3 | ForEach-Object {
            Start-Process $pwshExe -ArgumentList @('-NoProfile', '-File', $S, '-Mode', 'TierSweep', '-Execute', '-Project', $multiProject) -PassThru `
              -RedirectStandardOutput (Join-Path $multiProject "sweep-$_.txt") -RedirectStandardError (Join-Path $multiProject "sweeperr-$_.txt")
        }
        Wait-OrKill $sweepers 180
        $rowsAfter = @(Get-Content -Encoding utf8 $multiIndex | Where-Object { $_ -notmatch '^#' -and $_ -ne '' })
        Assert-True ($rowsAfter.Count -eq $rowsBefore) ('并发 TierSweep 后索引行数必须不变：' + $rowsBefore + ' -> ' + $rowsAfter.Count)
        Assert-True (@($rowsAfter | Where-Object { ($_ -split "`t").Count -ne 7 }).Count -eq 0) '并发后仍为七列'
        Assert-True (@($rowsAfter | Where-Object { -not (Test-Path (Join-Path $multiRoot ($_ -split "`t")[5].Replace('/', '\'))) }).Count -eq 0) '并发后无悬空索引'
        $backups = @(Get-ChildItem $multiRoot -Filter 'index.tsv.bak-*')
        Assert-True ($backups.Count -ge 1) '至少一份索引备份'
        Assert-True (@($backups | Select-Object -ExpandProperty Name | Select-Object -Unique).Count -eq $backups.Count) '备份文件名不得重复'
        Assert-True (@($backups | Where-Object { $_.Length -eq 0 }).Count -eq 0) '备份文件不得为空'
        $sweepErrors = @(1..3 | ForEach-Object {
            $e = Get-Content -Raw -Encoding utf8 (Join-Path $multiProject "sweeperr-$_.txt") -ErrorAction SilentlyContinue
            if ($e -and $e.Trim() -ne '') { "sweeper $_ : $($e.Trim())" }
        })
        Assert-True ($sweepErrors.Count -eq 0) ('并发 TierSweep 不得报错：' + ($sweepErrors -join ' | '))
        Assert-True (-not (Test-Path (Join-Path $multiRoot '.lock'))) '并发结束后不残留锁'
    }
    Step '21 超龄但持锁进程存活：必须报错且不得夺锁（长任务保护）' {
        $liveProject = Join-Path $proj 'live-lock-fixture'
        New-Item -ItemType Directory $liveProject | Out-Null
        & $S -Mode Init -Project $liveProject | Out-Null
        $liveRoot = Join-Path $liveProject '.neuron-harness'
        $liveLock = Join-Path $liveRoot '.lock'
        # 伪造「锁龄 1 小时、但持锁 pid 就是当前存活进程」——模拟 TierSweep 扫大库超过 30s 的正常长任务。
        # 正确行为：报错让调用方重试；不得改名夺锁（否则两个进程同时持锁，索引静默互相覆盖）。
        [System.IO.File]::WriteAllText(
            $liveLock,
            ("$PID`t" + (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')),
            [System.Text.UTF8Encoding]::new($false)
        )
        $lockBefore = (Get-FileHash -LiteralPath $liveLock).Hash
        $threw = $false
        $message = ''
        try { & $S -Mode Archive -Type evidence -TaskId live -ContentFile (W 'must not write') -Project $liveProject | Out-Null }
        catch { $threw = $true; $message = "$_" }
        Assert-True $threw ('持锁进程存活时必须报错，实际写入了：' + $message)
        Assert-True ($message -match '存活') ('报错应指明持锁进程存活，实得：' + $message)
        Assert-True (Test-Path $liveLock) '不得夺走存活进程的锁'
        Assert-True ($lockBefore -eq (Get-FileHash -LiteralPath $liveLock).Hash) '锁文件内容不得被改动'
        Assert-True (@(Get-ChildItem $liveRoot -Filter '.lock-stale-*' -Force).Count -eq 0) '不得产生陈旧锁隔离文件'
        $liveRows = @(Get-Content -Encoding utf8 (Join-Path $liveRoot 'index.tsv') | Where-Object { $_ -notmatch '^#' -and $_ -ne '' })
        Assert-True ($liveRows.Count -eq 0) '未取得锁时不得写入索引'
        Remove-Item -LiteralPath $liveLock -Force
    }
    Step '22 脚本头注释与锁实现一致（防文档-代码漂移）' {
        $scriptText = [System.IO.File]::ReadAllText($S, [System.Text.UTF8Encoding]::new($false))
        Assert-True ($scriptText -match 'FileMode::CreateNew') '头注释须写明锁用 FileMode::CreateNew'
        Assert-True ($scriptText -notmatch 'New-Item 单步建目录（原子）') '不得残留「New-Item 建目录即原子」的过时说法'
        Assert-True ($scriptText -match 'pid 存活则绝不夺锁') '头注释须写明 pid 存活不夺锁'
        Assert-True ($scriptText -notmatch 'Write-LockOwner') '不得残留已删除的空函数引用'
        $manifestJson = Get-Content -Raw -Encoding utf8 (Join-Path $PSScriptRoot '..\manifest.json') | ConvertFrom-Json
        $semver = $manifestJson.skill_semver
        Assert-True ($scriptText -match [regex]::Escape('skill v' + $semver)) ('脚本头版本须为 v' + $semver)
        $skillText = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\SKILL.md'), [System.Text.UTF8Encoding]::new($false))
        Assert-True ($skillText -match [regex]::Escape('v' + $semver)) ('SKILL description 版本须为 v' + $semver)
        # frontmatter name 必须等于 manifest.name（规范名）；仅在安装到 skills 路径时
        # 才额外要求等于目录名——否则 git 克隆到任意目录（如 nh-clone-xxxx）会误报。
        $pkgRoot = Split-Path $PSScriptRoot -Parent
        $dirName = Split-Path $pkgRoot -Leaf
        $declaredName = if ($skillText -match '(?m)^name:\s*(\S+)\s*$') { $Matches[1] } else { '' }
        $manifestName = (Get-Content -Raw -Encoding utf8 (Join-Path $pkgRoot 'manifest.json') | ConvertFrom-Json).name
        Assert-True ($declaredName -eq $manifestName) ('SKILL name「' + $declaredName + '」须等于 manifest.name「' + $manifestName + '」')
        $parentDir = Split-Path $pkgRoot -Parent
        if ((Split-Path $parentDir -Leaf) -match '^skills') {
            Assert-True ($declaredName -eq $dirName) ('安装到 skills 路径时 name 须等于目录名：「' + $declaredName + '」vs「' + $dirName + '」')
        }
    }
    Step '23 旧目录只读告警：不迁移、不删除、不假成功' {
        $legacyProject = Join-Path $proj 'legacy-root-fixture'
        New-Item -ItemType Directory $legacyProject | Out-Null
        $legacyState = Join-Path $legacyProject '.context-router'
        New-Item -ItemType Directory $legacyState | Out-Null
        $legacyIndexText = "#id`ttask`ttags`ttype`tsummary`tfile`nE0001`tt1`t`tevidence`told`tarchive/E0001.md`n"
        [System.IO.File]::WriteAllText((Join-Path $legacyState 'index.tsv'), $legacyIndexText, [System.Text.UTF8Encoding]::new($false))
        $legacyHash = (Get-FileHash -LiteralPath (Join-Path $legacyState 'index.tsv')).Hash
        $initOut = @(& $S -Mode Init -Project $legacyProject)
        Assert-True (@($initOut | Where-Object { $_ -match 'WARN.*\.context-router' }).Count -ge 1) 'Init 必须提示发现旧目录'
        Assert-True (@($initOut | Where-Object { $_ -match '未迁移' }).Count -ge 1) 'Init 必须说明未迁移数据'
        Assert-True (Test-Path -LiteralPath $legacyState) '旧目录必须原样保留'
        Assert-True ($legacyHash -eq (Get-FileHash -LiteralPath (Join-Path $legacyState 'index.tsv')).Hash) '旧索引不得被改动'
        Assert-True (Test-Path -LiteralPath (Join-Path $legacyProject '.neuron-harness\index.tsv')) '新目录照常初始化'
        $newIdx = Get-Content -Raw -Encoding utf8 (Join-Path $legacyProject '.neuron-harness\index.tsv')
        Assert-True ($newIdx -notmatch 'E0001') '新索引不得混入旧数据'
    }
    Step '24 路径可移植：索引内文件列可解析且不含平台分隔符' {
        $portableRow = @(Get-Content -Encoding utf8 (Join-Path $root 'index.tsv') | Where-Object { $_ -notmatch '^#' -and $_ -ne '' })
        Assert-True ($portableRow.Count -gt 0) '需要有已归档条目供检查'
        $badSep = @($portableRow | Where-Object { ($_ -split "`t")[5] -match '\\' })
        Assert-True ($badSep.Count -eq 0) ('索引 file 列必须用正斜杠（跨平台），违规 ' + $badSep.Count + ' 条')
        foreach ($row in $portableRow) {
            $fileCol = ($row -split "`t")[5]
            Assert-True ($fileCol -match '^archive/') ('file 列应为 archive/ 相对路径，实得 ' + $fileCol)
            # Join-Path 拼出的路径必须能被 Test-Path 解析（反斜杠硬转在 Linux 上会失败）
            Assert-True (Test-Path -LiteralPath (Join-Path $root $fileCol)) ('Join-Path 应能定位 ' + $fileCol)
        }
        $scriptText = [System.IO.File]::ReadAllText($S, [System.Text.UTF8Encoding]::new($false))
        Assert-True ($scriptText -notmatch "replace '/', '\\\\'") '脚本不得把正斜杠硬转成反斜杠（Linux 上会变字面文件名）'
    }
    Step '25 许可证一致性：LICENSE/NOTICE/manifest/README 四处对齐' {
        $pkgRoot = Split-Path $PSScriptRoot -Parent
        $licPath = Join-Path $pkgRoot 'LICENSE'
        $noticePath = Join-Path $pkgRoot 'NOTICE'
        $readmePath = Join-Path $pkgRoot 'README.md'
        Assert-True (Test-Path -LiteralPath $licPath) 'LICENSE 必须存在'
        Assert-True (Test-Path -LiteralPath $noticePath) 'NOTICE 必须存在（Apache-2.0 要求保留）'
        $licText = [System.IO.File]::ReadAllText($licPath, [System.Text.UTF8Encoding]::new($false))
        Assert-True ($licText -match 'Apache License') 'LICENSE 须为 Apache 全文'
        Assert-True ($licText -match 'Version 2\.0') 'LICENSE 须标明 Version 2.0'
        Assert-True ($licText -match 'END OF TERMS AND CONDITIONS') 'LICENSE 须含完整条款（非摘要）'
        Assert-True ($licText -match 'Copyright \d{4} neuron-harness contributors') 'LICENSE 须含版权行'
        $mani = Get-Content -Raw -Encoding utf8 (Join-Path $pkgRoot 'manifest.json') | ConvertFrom-Json
        Assert-True ($mani.license -eq 'Apache-2.0') ('manifest.license 须为 Apache-2.0，实得 ' + $mani.license)
        Assert-True ($mani.name -eq 'neuron-harness') 'manifest.name 须为 neuron-harness'
        $readme = [System.IO.File]::ReadAllText($readmePath, [System.Text.UTF8Encoding]::new($false))
        Assert-True ($readme -match 'Apache License 2\.0') 'README 须声明 Apache-2.0'
        Assert-True ($readme -notmatch '尚未选择') 'README 不得残留「尚未选择许可证」'
    }
}
finally {
    if ($KeepArtifacts -or $failed -gt 0) {
        Write-Output ('ARTIFACTS=' + $proj)
    } else {
        Remove-Item -LiteralPath $proj -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ('==== E2E: ' + $passed + ' passed, ' + $failed + ' failed ====')
if ($failed -gt 0) { exit 1 } else { exit 0 }
