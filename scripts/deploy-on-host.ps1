<#
.SYNOPSIS
    Prepares a private cluster and deploys CloudLens to it from a machine inside its network: the deploy host that
    Terraform creates, or any machine connected to the cluster's virtual network.

.DESCRIPTION
    A private cluster's API server and a private registry cannot be reached from the internet, so the last part of a
    deployment runs here instead of on your laptop. deploy-end-to-end.ps1 provisions everything from anywhere and then
    runs this stage itself when it can reach the cluster; otherwise scripts/prepare-deploy-host.ps1 puts this
    environment's settings on the deploy host and prints how to run it:

      1. (-EnvFile) creates the azd environment from the settings the laptop exported.
      2. Runs the cluster bootstrap (the azd postprovision hook): cert-manager, the ingress controller, the issuers.
      3. Builds both container images with Docker on this machine, pushes them to the registry over its private
         endpoint, and applies the manifests (azd deploy). A private registry cannot be reached by ACR Tasks, so azure.yaml's
         remote build is switched off for this run and put back afterwards.

    Terraform does not run here; the infrastructure already exists. Every step is safe to rerun.

.PARAMETER EnvironmentName
    The azd environment to deploy.

.PARAMETER EnvFile
    Settings exported by prepare-deploy-host.ps1 (KEY="value" lines, the format of `azd env get-values`). The azd
    environment is created from them when it does not exist yet; an existing one is left as it is.

.PARAMETER SkipLogin
    Do not check that az and azd are signed in (the calling script has already).

.PARAMETER PlanOnly
    Print what would run without changing anything.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')]
    [string] $EnvironmentName,
    [string] $EnvFile = '',
    [ValidateRange(1, 10)]
    [int] $MaxAttempts = 3,
    [ValidateRange(0, 900)]
    [int] $SettleSeconds = 120,
    [switch] $SkipLogin,
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.0') { throw 'PowerShell 7 or later is required.' }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$azureYaml = Join-Path $repoRoot 'azure.yaml'

function Get-CliText {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ((@($Value | Where-Object { $null -ne $_ }) -join "`n")).Trim()
}

function Get-AzdValue {
    param([Parameter(Mandatory)][string] $Name)
    $value = & azd env get-value --environment $EnvironmentName $Name --no-prompt 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    $text = Get-CliText $value
    if ($text -like 'ERROR:*') { return '' }
    return $text
}

function Import-EnvironmentFile {
    # `azd env get-values` writes KEY="value" lines; a value may contain escaped quotes and backslashes.
    param([Parameter(Mandatory)][string] $Path)
    $imported = 0
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
        $name = $Matches[1]
        $value = $Matches[2]
        if ($value -match '^"(.*)"$') { $value = $Matches[1] -replace '\\(["\\])', '$1' }
        & azd env set --environment $EnvironmentName $name $value --no-prompt | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to set $name in azd environment '$EnvironmentName'." }
        $imported++
    }
    return $imported
}

function Set-RemoteBuild {
    # Returns the file's original text so it can be restored.
    param([Parameter(Mandatory)][bool] $Enabled)
    $original = [System.IO.File]::ReadAllText($azureYaml)
    $wanted = if ($Enabled) { 'true' } else { 'false' }
    $changed = [regex]::Replace($original, '(?m)^([ \t]*remoteBuild:[ \t]*)(true|false)(?=[ \t]*\r?$)', "`${1}$wanted")
    if ($changed -ne $original) { [System.IO.File]::WriteAllText($azureYaml, $changed) }
    return $original
}

function Invoke-WithRetry {
    param([Parameter(Mandatory)][string] $Description, [Parameter(Mandatory)][scriptblock] $Action)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host ''
        Write-Host "==> $Description (attempt $attempt of $MaxAttempts)" -ForegroundColor Cyan
        & $Action
        if ($LASTEXITCODE -eq 0) { return }
        if ($attempt -eq $MaxAttempts) { throw "$Description failed after $attempt attempt(s). Review the output above; rerunning this script resumes from here." }
        Write-Warning "$Description failed. Waiting $SettleSeconds seconds before the next attempt (a new role assignment or an earlier operation may still be settling)."
        if ($SettleSeconds -gt 0) { Start-Sleep -Seconds $SettleSeconds }
    }
}

if ($PlanOnly) {
    [pscustomobject]@{
        environment = $EnvironmentName
        importsSettingsFrom = $EnvFile
        steps = @('azd env select', 'azd hooks run postprovision', 'azd deploy (local Docker build when the registry is private)')
        remoteBuildSwitchedOff = $true
    } | ConvertTo-Json
    exit 0
}

foreach ($tool in @('az', 'azd', 'kubectl', 'kubelogin')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' is required. The deploy host has it installed once its setup has finished (/var/lib/cloudlens/tools-ready exists); on another machine install it first (az aks install-cli installs kubectl and kubelogin)."
    }
}

Push-Location $repoRoot
$originalYaml = $null
try {
    if (-not $SkipLogin) {
        & az account show --output none 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'az is not signed in. Run: az login --use-device-code' }
        & azd auth login --check-status 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'azd is not signed in. Run: azd auth login --use-device-code' }
    }

    $existing = Get-CliText (& azd env list --output json --no-prompt 2>$null)
    $known = @(if ($existing) { $existing | ConvertFrom-Json } else { @() }) | Where-Object { $null -ne $_ -and $_.Name -eq $EnvironmentName }
    if (-not $known) {
        if (-not $EnvFile) { throw "The azd environment '$EnvironmentName' does not exist on this machine. Pass -EnvFile with the settings that prepare-deploy-host.ps1 exported." }
        if (-not (Test-Path -LiteralPath $EnvFile)) { throw "-EnvFile '$EnvFile' was not found." }
        & azd env new $EnvironmentName --no-prompt | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Unable to create azd environment '$EnvironmentName'." }
        $count = Import-EnvironmentFile -Path $EnvFile
        Write-Host "Imported $count settings into the azd environment '$EnvironmentName'."
    }
    & azd env select $EnvironmentName --no-prompt | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to select azd environment '$EnvironmentName'." }

    if ((Get-AzdValue 'APP_AKS_PRIVATE_CLUSTER') -ne 'true' -and (Get-AzdValue 'APP_PRIVATE_REGISTRY') -ne 'true') {
        Write-Warning "'$EnvironmentName' has a public cluster and registry; deploy-end-to-end.ps1 or azd up deploys it from anywhere. Continuing anyway."
    }
    $privateRegistry = (Get-AzdValue 'APP_PRIVATE_REGISTRY') -eq 'true'
    if ($privateRegistry) {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker is required to build the images for a private registry.' }
        & docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'docker is installed but this user cannot use it. Sign out and in again (the deploy host adds its admin user to the docker group), or start the docker service.' }
        # ACR Tasks cannot reach a registry with no public access; build here and push over the private endpoint instead.
        $originalYaml = Set-RemoteBuild -Enabled $false
        Write-Host 'The registry is private: images are built with local Docker and pushed over its private endpoint.' -ForegroundColor Yellow
    }

    Invoke-WithRetry 'Preparing the cluster (azd hooks run postprovision)' { & azd hooks run postprovision --environment $EnvironmentName }
    Invoke-WithRetry 'Deploying both services (azd deploy)' { & azd deploy --environment $EnvironmentName --no-prompt }

    $apiImage = Get-AzdValue 'SERVICE_API_IMAGE_NAME'
    $webImage = Get-AzdValue 'SERVICE_WEB_IMAGE_NAME'
    if (-not $apiImage -or -not $webImage) { throw 'azd did not publish both container images. Review the azd output above, then rerun this script.' }
    Write-Host ''
    Write-Host "Deployed. api: $apiImage" -ForegroundColor Green
    Write-Host "          web: $webImage" -ForegroundColor Green
    $origin = Get-AzdValue 'APP_WEB_ORIGIN'
    if ($origin) { Write-Host "The app is served at $origin (private; open it from inside the network or through the Private Link service)." -ForegroundColor Green }
    $issuer = Get-AzdValue 'APP_TLS_CLUSTER_ISSUER'
    if ($issuer -eq 'private-ca') {
        Write-Host 'The certificate comes from the cluster''s own CA; browsers must trust it (see the README, "Private ingress").' -ForegroundColor Yellow
    }
} finally {
    if ($null -ne $originalYaml) { [System.IO.File]::WriteAllText($azureYaml, $originalYaml) }
    Pop-Location
}
