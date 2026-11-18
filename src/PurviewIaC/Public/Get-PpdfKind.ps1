function Get-PpdfKind {
    <#
    .SYNOPSIS
    Lists the artifact kinds PPDF can manage, which identity deploys each one, and how each is simulated.

    .DESCRIPTION
    Use this to find the right 'kind:' for an artifact file and to understand what a change will need.
    Properties returned:
      Name                        value for 'kind:' in artifact files
      Workload                    dlp, retention, classifier or rbac (used by -Workload filters)
      IdentityRole                which spec.identities.<role> deploys it
      SimulationStrategy          mode   - deployed in the product's own simulation/test mode, measured, then promoted
                                  corpus - deployed inert and tested against a labelled corpus
                                  whatif - no simulation exists; the plan itself is the preview, gated by approval
                                  none   - inert until another artifact references it; no simulation needed
      RequiresSimulationEvidence  enforcement is blocked until a passing simulation report exists
      SupportsShadow              can simulate changes to an already-enforced object via a '-ppdfsim' copy
      Exportable                  supported by Invoke-PpdfExport
      Description                 short summary

    .PARAMETER Name
    Kind name, wildcards allowed (for example 'Dlp*'). Default '*'.

    .INPUTS
    None.

    .OUTPUTS
    PSCustomObject per kind (see Description).

    .NOTES
    Offline. CLI: pwsh ./cli/ppdf.ps1 kinds

    .EXAMPLE
    Get-PpdfKind | Format-Table Name, Workload, IdentityRole, SimulationStrategy, RequiresSimulationEvidence

    Overview of every supported kind.

    .EXAMPLE
    Get-PpdfKind -Name Retention*

    Details of the retention kinds.

    .LINK
    about_PurviewIaC
    #>
    [CmdletBinding()]
    param([string]$Name = '*')
    $script:Kinds.Values | Where-Object { $_.Name -like $Name } | Sort-Object { $_.Name } | ForEach-Object {
        [pscustomobject]@{
            Name                       = $_.Name
            Workload                   = $_.Workload
            IdentityRole               = $_.IdentityRole
            SimulationStrategy         = $_.SimulationStrategy
            RequiresSimulationEvidence = $_.RequiresSimulationEvidence
            SupportsShadow             = $_.SupportsShadow
            Exportable                 = [bool]$_.Export
            Description                = $_.Description
        }
    }
}
