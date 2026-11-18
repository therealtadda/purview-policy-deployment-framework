BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\PurviewIaC\PurviewIaC.psd1') -Force

    function New-TestPlanFile {
        param([string]$Path, [hashtable]$Override = @{})
        $plan = [ordered]@{
            type                 = 'ppdf-plan'
            environment          = 'dev'
            stage                = 'simulate'
            createdUtc           = (Get-Date).ToUniversalTime().ToString('o')
            requiredApprovalTier = 'standard'
            environmentSpec      = @{ approvals = @{ maxPlanAgeHours = 24 } }
            summary              = @{ blocked = 0 }
            actions              = @()
        }
        foreach ($k in $Override.Keys) { $plan[$k] = $Override[$k] }
        Set-Content -LiteralPath $Path -Value (ConvertTo-Json $plan -Depth 10) -Encoding utf8NoBOM
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$Path.sha256" -Value "$hash  $(Split-Path -Leaf $Path)" -Encoding utf8NoBOM
        return $hash
    }
}

Describe 'Document integrity' {
    It 'accepts a document that matches its sidecar and the approved hash' {
        $p = Join-Path $TestDrive 'ok.json'
        $hash = New-TestPlanFile -Path $p
        InModuleScope PurviewIaC -Parameters @{ p = $p; hash = $hash } {
            (Test-PpdfDocumentIntegrity -Path $p -ExpectedHash $hash).Valid | Should -BeTrue
        }
    }

    It 'rejects a document edited after it was hashed' {
        $p = Join-Path $TestDrive 'edited.json'
        $hash = New-TestPlanFile -Path $p
        Add-Content -LiteralPath $p -Value ' '
        InModuleScope PurviewIaC -Parameters @{ p = $p; hash = $hash } {
            $r = Test-PpdfDocumentIntegrity -Path $p -ExpectedHash $hash
            $r.Valid | Should -BeFalse
            ($r.Errors -join ' ') | Should -BeLike '*sidecar*'
        }
    }
}

Describe 'Plan exit codes' {
    It 'returns <Expected> for <Case>' -ForEach @(
        @{ Case = 'no changes'; Blocked = 0; Count = 0; Expected = 0 }
        @{ Case = 'changes'; Blocked = 0; Count = 2; Expected = 2 }
        @{ Case = 'blocked changes'; Blocked = 1; Count = 2; Expected = 3 }
    ) {
        InModuleScope PurviewIaC -Parameters @{ b = $Blocked; n = $Count; e = $Expected } {
            $plan = @{ summary = @{ blocked = $b }; actions = @(1..$n | Where-Object { $n -gt 0 }) }
            Get-PpdfPlanExitCode -Plan $plan | Should -Be $e
        }
    }
}

Describe 'Apply refusals' {
    It 'refuses a plan whose approved hash does not match' {
        $p = Join-Path $TestDrive 'plan-hash.json'
        New-TestPlanFile -Path $p | Out-Null
        $r = Invoke-PpdfApply -PlanPath $p -ExpectedPlanHash ('0' * 64) -OutputPath (Join-Path $TestDrive 'out-hash')
        $r.ExitCode | Should -Be 3
        $r.Refused | Should -BeTrue
    }

    It 'refuses when the approval tier is lower than the plan requires' {
        $p = Join-Path $TestDrive 'plan-tier.json'
        $hash = New-TestPlanFile -Path $p -Override @{ requiredApprovalTier = 'critical' }
        $r = Invoke-PpdfApply -PlanPath $p -ExpectedPlanHash $hash -ApprovedTier elevated -OutputPath (Join-Path $TestDrive 'out-tier')
        $r.ExitCode | Should -Be 3
        ($r.Errors -join ' ') | Should -BeLike "*requires 'critical'*"
    }

    It 'refuses a plan that contains blocked actions' {
        $p = Join-Path $TestDrive 'plan-blocked.json'
        $hash = New-TestPlanFile -Path $p -Override @{ summary = @{ blocked = 1 } }
        $r = Invoke-PpdfApply -PlanPath $p -ExpectedPlanHash $hash -ApprovedTier critical -OutputPath (Join-Path $TestDrive 'out-blocked')
        $r.ExitCode | Should -Be 3
        ($r.Errors -join ' ') | Should -BeLike '*blocked*'
    }

    It 'refuses a plan older than maxPlanAgeHours' {
        $p = Join-Path $TestDrive 'plan-old.json'
        $old = (Get-Date).ToUniversalTime().AddHours(-5).ToString('o')
        $hash = New-TestPlanFile -Path $p -Override @{ createdUtc = $old; environmentSpec = @{ approvals = @{ maxPlanAgeHours = 4 } } }
        $r = Invoke-PpdfApply -PlanPath $p -ExpectedPlanHash $hash -ApprovedTier critical -OutputPath (Join-Path $TestDrive 'out-old')
        $r.ExitCode | Should -Be 3
        ($r.Errors -join ' ') | Should -BeLike '*older than 4 hours*'
    }

    It 'succeeds with nothing to do for an empty, approved plan' {
        $p = Join-Path $TestDrive 'plan-empty.json'
        $hash = New-TestPlanFile -Path $p
        $out = Join-Path $TestDrive 'out-empty'
        $r = Invoke-PpdfApply -PlanPath $p -ExpectedPlanHash $hash -ApprovedTier standard -OutputPath $out
        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $out 'evidence\manifest.json') | Should -BeTrue
        Test-Path (Join-Path $out 'evidence\apply-result.json.sha256') | Should -BeTrue
    }
}

Describe 'Apply execution' {
    BeforeAll {
        $script:Plan = @{
            environment     = 'dev'
            environmentSpec = @{}
            stage           = 'enforce'
            actions         = @(
                @{ id = 1; op = 'update'; type = 'T'; name = 'a'; workload = 'rbac'; identityRole = 'rbac'; service = 'scc'; order = 1 }
                @{ id = 2; op = 'update'; type = 'T'; name = 'b'; workload = 'rbac'; identityRole = 'rbac'; service = 'scc'; order = 2 }
                @{ id = 3; op = 'create'; type = 'T'; name = 'c'; workload = 'retention'; identityRole = 'zz-retention'; service = 'scc'; order = 1 }
            )
        }
    }

    It 'stops at the first failure and marks the rest, including later identity groups, as not-run' {
        InModuleScope PurviewIaC -Parameters @{ plan = $script:Plan } {
            Mock Connect-PpdfIdentity {}
            Mock Disconnect-PpdfIdentity {}
            Mock Write-PpdfLog {}
            Mock Test-PpdfActionFresh { @{ Fresh = $true; State = @{ Exists = $true } } }
            Mock Invoke-PpdfAction { if ($Action.id -eq 1) { throw 'boom' } }
            $r = Invoke-PpdfPlanApply -Plan $plan
            $r.ExitCode | Should -Be 1
            $status = @{}
            foreach ($x in $r.Results) { $status[$x.id] = $x.status }
            $status[1] | Should -Be 'failed'
            $status[2] | Should -Be 'not-run'
            $status[3] | Should -Be 'not-run'
            Should -Invoke Connect-PpdfIdentity -Times 1 -Exactly
        }
    }

    It 'changes nothing in a group where any action is stale' {
        InModuleScope PurviewIaC -Parameters @{ plan = $script:Plan } {
            Mock Connect-PpdfIdentity {}
            Mock Disconnect-PpdfIdentity {}
            Mock Write-PpdfLog {}
            Mock Test-PpdfActionFresh { if ($Action.id -eq 2) { @{ Fresh = $false; State = @{}; Reason = 'object changed since plan' } } else { @{ Fresh = $true; State = @{} } } }
            Mock Invoke-PpdfAction {}
            $r = Invoke-PpdfPlanApply -Plan $plan
            $r.ExitCode | Should -Be 3
            @($r.Results | Where-Object { $_.workload -eq 'rbac' } | ForEach-Object { $_.status }) | Should -Be @('skipped-stale', 'skipped-stale')
            @($r.Results | Where-Object { $_.id -eq 3 })[0].status | Should -Be 'succeeded'
            Should -Invoke Invoke-PpdfAction -Times 1 -Exactly
        }
    }
}

Describe 'Rollback actions' {
    It 'inverts only succeeded actions and always needs elevated approval' {
        InModuleScope PurviewIaC {
            Register-PpdfObjectType -Name 'PpdfTestType' -Workload 'dlp' -Service 'scc' -TagProperty 'Comment' -Get { } -Create { } -Update { } -Remove { }
            $plan = @{
                actions = @(
                    @{ id = 1; op = 'create'; type = 'PpdfTestType'; name = 'new'; tagId = 'K/new'; stage = 'simulate'; desired = @{ Mode = 'Enable'; Comment = 'c [ppdf:v1 id=K/new]' } }
                    @{ id = 2; op = 'update'; type = 'PpdfTestType'; name = 'upd'; tagId = 'K/upd'; stage = 'enforce'; diffKeys = @('Mode'); desired = @{ Mode = 'Enable' }; expected = @{ Mode = 'TestWithNotifications'; Comment = 'old' }; currentTag = @{ id = 'K/upd'; stage = 'simulate' } }
                    @{ id = 3; op = 'delete'; type = 'PpdfTestType'; name = 'gone'; tagId = 'K/gone'; stage = 'enforce'; desired = @{}; expected = @{ Mode = 'Enable' } }
                    @{ id = 4; op = 'create'; type = 'PpdfTestType'; name = 'failed'; tagId = 'K/failed'; stage = 'simulate'; desired = @{ Mode = 'Enable' } }
                )
            }
            $applied = @{ results = @(
                    @{ id = 1; status = 'succeeded' }, @{ id = 2; status = 'succeeded' }, @{ id = 3; status = 'succeeded' }, @{ id = 4; status = 'failed' }
                ) }
            $inv = @(New-PpdfRollbackAction -Plan $plan -ApplyResult $applied)
            $inv.Count | Should -Be 3
            @($inv | ForEach-Object { $_.tier } | Select-Object -Unique) | Should -Be @('elevated')
            $c = @($inv | Where-Object { $_.id -eq 1 })[0]
            $c.op | Should -Be 'delete'
            $c.expected.Contains('Comment') | Should -BeFalse
            $u = @($inv | Where-Object { $_.id -eq 2 })[0]
            $u.op | Should -Be 'update'
            $u.desired.Mode | Should -Be 'TestWithNotifications'
            $u.expected.Mode | Should -Be 'Enable'
            $u.stage | Should -Be 'simulate'
            $u.desired.Comment | Should -Be 'old'
            $d = @($inv | Where-Object { $_.id -eq 3 })[0]
            $d.op | Should -Be 'create'
            $d.expectAbsent | Should -BeTrue
            $d.desired.Mode | Should -Be 'Enable'
        }
    }
}
