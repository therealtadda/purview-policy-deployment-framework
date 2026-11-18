BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\PurviewIaC\PurviewIaC.psd1') -Force
}

Describe 'Threshold evaluation' {
    It 'applies the max, min and require conventions' {
        InModuleScope PurviewIaC {
            $checks = Test-PpdfThreshold -Thresholds ([ordered]@{ maxMatchesPerDay = 100; minPrecision = 0.9; requireDistributionSuccess = $true }) -Metrics @{ matchesPerDay = 150; precision = 0.95; distributionSuccess = $true }
            ($checks | Where-Object name -EQ 'maxMatchesPerDay').pass | Should -BeFalse
            ($checks | Where-Object name -EQ 'minPrecision').pass | Should -BeTrue
            ($checks | Where-Object name -EQ 'requireDistributionSuccess').pass | Should -BeTrue
        }
    }

    It 'fails a threshold whose metric is unavailable' {
        InModuleScope PurviewIaC {
            $checks = Test-PpdfThreshold -Thresholds @{ maxFalsePositives = 0 } -Metrics @{}
            $checks[0].pass | Should -BeFalse
            $checks[0].message | Should -BeLike '*unavailable*'
        }
    }

    It 'ignores thresholds set to null' {
        InModuleScope PurviewIaC {
            @(Test-PpdfThreshold -Thresholds @{ maxMatchesPerDay = $null } -Metrics @{ matchesPerDay = 5 }).Count | Should -Be 0
        }
    }
}

Describe 'Threshold precedence' {
    It 'layers kind defaults, then environment, then artifact' {
        InModuleScope PurviewIaC {
            $kind = @{ Name = 'DlpPolicy'; SimulationStrategy = 'mode'; DefaultThresholds = [ordered]@{ minSoakHours = 72; maxMatchesPerDay = 1000; maxUsers = 50 } }
            $ctx = @{ Env = @{ simulation = @{ minSoakHours = 24; thresholds = @{ DlpPolicy = @{ maxMatchesPerDay = 500 } } } } }
            $artifact = @{ Doc = @{ simulation = @{ thresholds = @{ maxUsers = 5 } } } }
            $t = Get-PpdfEffectiveThreshold -Artifact $artifact -Context $ctx -Kind $kind
            $t.minSoakHours | Should -Be 24
            $t.maxMatchesPerDay | Should -Be 500
            $t.maxUsers | Should -Be 5
        }
    }

    It 'does not apply the environment soak time to corpus-tested kinds' {
        InModuleScope PurviewIaC {
            $kind = @{ Name = 'SensitiveInfoTypeRulePackage'; SimulationStrategy = 'corpus'; DefaultThresholds = [ordered]@{ minPrecision = 0.9 } }
            $ctx = @{ Env = @{ simulation = @{ minSoakHours = 24 } } }
            $t = Get-PpdfEffectiveThreshold -Artifact @{ Doc = @{} } -Context $ctx -Kind $kind
            $t.Contains('minSoakHours') | Should -BeFalse
        }
    }
}
