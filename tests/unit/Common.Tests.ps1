BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\PurviewIaC\PurviewIaC.psd1') -Force
}

Describe 'Canonical hashing' {
    It 'produces the same hash regardless of key order' {
        InModuleScope PurviewIaC {
            $a = [ordered]@{ b = 1; a = @{ y = 'x'; x = 'y' } }
            $b = [ordered]@{ a = @{ x = 'y'; y = 'x' }; b = 1 }
            Get-PpdfHash -InputObject $a | Should -Be (Get-PpdfHash -InputObject $b)
        }
    }

    It 'changes when a value changes' {
        InModuleScope PurviewIaC {
            Get-PpdfHash -InputObject @{ a = 1 } | Should -Not -Be (Get-PpdfHash -InputObject @{ a = 2 })
        }
    }
}

Describe 'Ownership tag' {
    It 'round-trips through a comment and preserves the human text' {
        InModuleScope PurviewIaC {
            $tag = Format-PpdfTag -Id 'DlpPolicy/Finance' -Sha '0123456789abcdef' -Stage 'simulate'
            $text = Join-PpdfTaggedText -Text 'Owned by finance.' -Tag $tag
            $parsed = Split-PpdfTaggedText -Text $text
            $parsed.Text | Should -Be 'Owned by finance.'
            $parsed.Tag.id | Should -Be 'DlpPolicy/Finance'
            $parsed.Tag.sha | Should -Be '01234567'
            $parsed.Tag.stage | Should -Be 'simulate'
            ConvertFrom-PpdfTagTimestamp $parsed.Tag.ts | Should -BeOfType [datetime]
        }
    }

    It 'returns no tag for unmanaged text' {
        InModuleScope PurviewIaC {
            $parsed = Split-PpdfTaggedText -Text 'Created by hand'
            $parsed.Tag | Should -BeNullOrEmpty
            $parsed.Text | Should -Be 'Created by hand'
        }
    }
}

Describe 'Risk tiers' {
    It 'returns the highest tier' {
        InModuleScope PurviewIaC {
            Get-PpdfMaxTier -Tier 'low', 'elevated', 'standard' | Should -Be 'elevated'
            Get-PpdfMaxTier -Tier @() | Should -Be 'low'
        }
    }

    It 'ranks tiers in order' {
        InModuleScope PurviewIaC {
            (Get-PpdfTierRank 'critical') | Should -BeGreaterThan (Get-PpdfTierRank 'elevated')
            (Get-PpdfTierRank 'standard') | Should -BeGreaterThan (Get-PpdfTierRank 'low')
        }
    }
}

Describe 'Variable substitution' {
    It 'replaces a whole-value placeholder with the raw value, including lists' {
        InModuleScope PurviewIaC {
            $r = Resolve-PpdfVariable -InputObject @{ loc = '${sites}' } -Variables @{ sites = @('a', 'b') }
            @($r.loc) | Should -Be @('a', 'b')
        }
    }

    It 'interpolates placeholders inside text and from the process environment' {
        InModuleScope PurviewIaC {
            $env:PPDF_TEST_VALUE = 'contoso'
            try {
                $r = Resolve-PpdfVariable -InputObject 'https://${env:PPDF_TEST_VALUE}.sharepoint.com/${site}' -Variables @{ site = 'fin' }
                $r | Should -Be 'https://contoso.sharepoint.com/fin'
            }
            finally { Remove-Item Env:\PPDF_TEST_VALUE }
        }
    }

    It 'fails on an undefined variable and names where it was used' {
        InModuleScope PurviewIaC {
            { Resolve-PpdfVariable -InputObject @{ x = '${missing}' } -Variables @{} -Path 'file.yml' } | Should -Throw '*missing*file.yml.x*'
        }
    }
}

Describe 'Desired-state comparison' {
    It 'compares scalar lists as case-insensitive sets' {
        InModuleScope PurviewIaC {
            Test-PpdfValueMatch -Desired @('B', 'a') -Current @('A', 'b') | Should -BeTrue
            Test-PpdfValueMatch -Desired @('a') -Current @('a', 'b') | Should -BeFalse
        }
    }

    It 'normalises booleans and only compares desired keys' {
        InModuleScope PurviewIaC {
            Test-PpdfValueMatch -Desired @{ Enabled = $true } -Current @{ Enabled = 'True'; Other = 1 } | Should -BeTrue
        }
    }

    It 'lists the properties that differ, skipping ignored ones' {
        InModuleScope PurviewIaC {
            $diff = Compare-PpdfProperty -Desired ([ordered]@{ Mode = 'Enable'; Comment = 'x'; Priority = 1 }) -Current @{ Mode = 'TestWithoutNotifications'; Comment = 'y'; Priority = 1 } -Ignore 'Comment'
            $diff | Should -Be @('Mode')
        }
    }
}
