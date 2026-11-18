$script:ModuleRoot = $PSScriptRoot
$script:Kinds = @{}
$script:ObjectTypes = @{}
$script:Run = $null
$script:Connection = $null
$script:SkipConnect = $false

foreach ($folder in 'Private', 'Providers', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Filter '*.ps1' -Recurse | Sort-Object FullName | ForEach-Object { . $_.FullName }
    }
}

Export-ModuleMember -Function (Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1').BaseName
