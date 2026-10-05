<#
.SYNOPSIS
    Provisions and deploys CloudLens on AKS with the recommended ai profile, and stops once the app runs.

.DESCRIPTION
    Runs scripts/deploy-end-to-end.ps1 without its sign-in registration and subscription role-assignment
    phases, for operators who do those separately (README steps 4 and 5): prerequisites, environment
    settings, the Terraform preview, `azd up` with retries, and the scheduled processor.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')]
    [string] $EnvironmentName,
    [string] $Location = 'centralindia',
    [string] $SubscriptionId = '',
    [ValidateRange(1, 5)]
    [int] $MaxAttempts = 3,
    [switch] $SkipPreview,
    [switch] $SkipProcessor,
    [switch] $InstallKubernetesTools,
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$parameters = @{
    EnvironmentName = $EnvironmentName
    Location = $Location
    MaxAttempts = $MaxAttempts
    SkipIdentityBootstrap = $true
    SkipRoleAssignments = $true
}
if ($SubscriptionId) { $parameters.SubscriptionId = $SubscriptionId }
foreach ($name in @('SkipPreview', 'SkipProcessor', 'InstallKubernetesTools', 'PlanOnly')) {
    if ($PSBoundParameters.ContainsKey($name)) { $parameters[$name] = $PSBoundParameters[$name] }
}

& (Join-Path $PSScriptRoot 'deploy-end-to-end.ps1') @parameters
