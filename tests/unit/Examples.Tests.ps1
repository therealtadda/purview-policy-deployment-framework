BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\PurviewIaC\PurviewIaC.psd1') -Force
    $script:Commands = @(Get-Command -Module PurviewIaC -CommandType Function | ForEach-Object { @{ Name = $_.Name } })
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\src\PurviewIaC\PurviewIaC.psd1') -Force
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:Contoso = Join-Path $script:RepoRoot 'examples\contoso'
}

Describe 'Kind catalogue' {
    It 'lists every supported kind with its simulation strategy' {
        $kinds = @{}
        Get-PpdfKind | ForEach-Object { $kinds[$_.Name] = $_ }
        $kinds.Count | Should -Be 7
        $kinds['DlpPolicy'].SimulationStrategy | Should -Be 'mode'
        $kinds['DlpPolicy'].RequiresSimulationEvidence | Should -BeTrue
        $kinds['DlpPolicy'].SupportsShadow | Should -BeTrue
        $kinds['RetentionPolicy'].SimulationStrategy | Should -Be 'mode'
        $kinds['RetentionLabel'].SimulationStrategy | Should -Be 'none'
        $kinds['RetentionLabelPolicy'].SimulationStrategy | Should -Be 'whatif'
        $kinds['SensitiveInfoTypeRulePackage'].SimulationStrategy | Should -Be 'corpus'
        $kinds['RoleGroup'].SimulationStrategy | Should -Be 'whatif'
        $kinds['EntraRoleAssignment'].SimulationStrategy | Should -Be 'whatif'
    }
}

Describe 'Contoso example configuration' {
    It 'validates every environment without errors' {
        $r = Invoke-PpdfValidate -ConfigRoot $script:Contoso -OutputPath (Join-Path $TestDrive 'validate')
        $r.ErrorCount | Should -Be 0
        $r.ExitCode | Should -Be 0
        @($r.Environments.Keys) | Should -Contain 'prod'
        Test-Path $r.Path | Should -BeTrue
    }

    It 'reports an unknown kind as a validation error' {
        $root = Join-Path $TestDrive 'broken'
        Copy-Item -Path $script:Contoso -Destination $root -Recurse
        $bad = @'
apiVersion: ppdf.purview/v1
kind: NotARealKind
metadata:
  name: broken
spec: {}
'@
        Set-Content -LiteralPath (Join-Path $root 'artifacts\dlp\broken.yml') -Value $bad -Encoding utf8NoBOM
        $r = Invoke-PpdfValidate -ConfigRoot $root -Environment dev -OutputPath (Join-Path $TestDrive 'validate-broken')
        $r.ExitCode | Should -Be 1
        $r.ErrorCount | Should -BeGreaterThan 0
    }
}

Describe 'Operator help' {
    It 'finds the nine public commands' {
        @(Get-Command -Module PurviewIaC -CommandType Function).Count | Should -Be 9
    }

    It '<Name> has a synopsis, description and example' -ForEach $script:Commands {
        $help = Get-Help $Name -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match "^\s*$Name\s"
        ($help.Description | Out-String).Trim() | Should -Not -BeNullOrEmpty
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }
}
