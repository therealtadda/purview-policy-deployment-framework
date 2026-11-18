@{
    RootModule        = 'PurviewIaC.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '6b863c0e-8a6c-4bb1-8bc4-df40d56a4655'
    Author            = 'Purview Policy Deployment Framework contributors'
    CompanyName       = 'Community'
    Copyright         = '(c) Purview Policy Deployment Framework contributors. BSD 3-Clause License.'
    Description       = 'Orchestrator-agnostic infrastructure-as-code engine for Microsoft Purview: validate, plan, simulate, approve, promote and detect drift for DLP, retention, classifiers and role assignments.'
    PowerShellVersion = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Invoke-PpdfValidate'
        'Invoke-PpdfPlan'
        'Invoke-PpdfApply'
        'Invoke-PpdfSimulationReport'
        'Invoke-PpdfPromote'
        'Invoke-PpdfDrift'
        'Invoke-PpdfExport'
        'Invoke-PpdfRollback'
        'Get-PpdfKind'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Purview', 'Compliance', 'DLP', 'Retention', 'IaC', 'DevOps')
            ProjectUri = 'https://github.com/therealtadda/purview-policy-deployment-framework'
            LicenseUri = 'https://github.com/therealtadda/purview-policy-deployment-framework/blob/main/LICENSE'
            ExternalModuleDependencies = @('ExchangeOnlineManagement', 'Microsoft.Graph.Authentication', 'powershell-yaml')
        }
    }
}
