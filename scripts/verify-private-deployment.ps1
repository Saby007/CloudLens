<#
.SYNOPSIS
    Verifies private networking, both rollouts and CA-validated HTTPS from inside the CloudLens VNet.
    invoke-private-deploy.ps1 runs this from ordinary Cloud Shell through Azure VM Run Command.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')]
    [string] $EnvironmentName,
    [ValidateRange(1, 3600)]
    [int] $HealthTimeoutSeconds = 600,
    [string] $ResultFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AzdValue {
    param([string] $Name)
    $value = & azd env get-value --environment $EnvironmentName $Name --no-prompt 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Required deployment output $Name is unavailable." }
    return (@($value) -join "`n").Trim()
}

function Invoke-Checked {
    param([string] $Tool, [string[]] $Arguments)
    $output = & $Tool @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$Tool $($Arguments -join ' ') failed: $(@($output) -join "`n")" }
    return (@($output) -join "`n").Trim()
}

$subscription = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
$resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
$cluster = Get-AzdValue 'AZURE_AKS_CLUSTER_NAME'
$origin = Get-AzdValue 'APP_WEB_ORIGIN'
$privateIp = Get-AzdValue 'APP_INGRESS_PRIVATE_IP'
$privateIngress = (Get-AzdValue 'APP_INGRESS_VISIBILITY') -eq 'private'
$registry = Get-AzdValue 'AZURE_CONTAINER_REGISTRY_NAME'
$issuer = Get-AzdValue 'APP_TLS_CLUSTER_ISSUER'
$temp = Join-Path ([IO.Path]::GetTempPath()) "cloudlens-verify-$([guid]::NewGuid().ToString('n'))"
$null = New-Item -ItemType Directory -Path $temp

try {
    $aks = Invoke-Checked az @('aks', 'show', '-g', $resourceGroup, '-n', $cluster, '--subscription', $subscription, '-o', 'json', '--only-show-errors') | ConvertFrom-Json
    if ($aks.apiServerAccessProfile.enablePrivateCluster -ne $true -or $aks.apiServerAccessProfile.enablePrivateClusterPublicFqdn -eq $true) {
        throw 'Verification refused: the Kubernetes API server is not private-only.'
    }
    $acr = Invoke-Checked az @('acr', 'show', '-n', $registry, '--subscription', $subscription, '-o', 'json', '--only-show-errors') | ConvertFrom-Json
    if ($acr.publicNetworkAccess -ne 'Disabled' -or $acr.adminUserEnabled -ne $false -or $acr.networkRuleBypassOptions -ne 'None') {
        throw 'Verification refused: the container registry permits public access, trusted-service bypass or admin credentials.'
    }
    $workspaceId = Get-AzdValue 'APP_LOG_ANALYTICS_WORKSPACE_ID'
    $workspace = Invoke-Checked az @('monitor', 'log-analytics', 'workspace', 'show', '--ids', $workspaceId, '-o', 'json', '--only-show-errors') | ConvertFrom-Json
    if ($workspace.publicNetworkAccessForIngestion -ne 'Disabled' -or $workspace.publicNetworkAccessForQuery -ne 'Disabled') {
        throw 'Verification refused: Log Analytics permits public ingestion or queries.'
    }
    $storageId = Get-AzdValue 'COST_EXPORT_STORAGE_RESOURCE_ID'
    if ($storageId) {
        $storage = Invoke-Checked az @('storage', 'account', 'show', '--ids', $storageId, '-o', 'json', '--only-show-errors') | ConvertFrom-Json
        if ($storage.publicNetworkAccess -ne 'Disabled' -or $storage.allowSharedKeyAccess -ne $false -or $storage.allowBlobPublicAccess -ne $false) {
            throw 'Verification refused: export storage is not private and key-less.'
        }
    }
    if ($privateIngress) {
        $addresses = [Net.Dns]::GetHostAddresses(([uri]$origin).Host) | ForEach-Object IPAddressToString
        if (-not $privateIp -or $privateIp -notin $addresses) {
            throw "Private DNS for $origin does not resolve to the reserved ingress address $privateIp."
        }
    }

    $kubeconfig = Join-Path $temp 'kubeconfig'
    $null = Invoke-Checked az @('aks', 'get-credentials', '-g', $resourceGroup, '-n', $cluster, '--subscription', $subscription, '--file', $kubeconfig, '--overwrite-existing', '--only-show-errors')
    $null = Invoke-Checked kubelogin @('convert-kubeconfig', '--login', 'azurecli', '--kubeconfig', $kubeconfig)
    $null = Invoke-Checked kubectl @('--kubeconfig', $kubeconfig, 'rollout', 'status', 'deployment/api', '-n', 'cloudlens', "--timeout=${HealthTimeoutSeconds}s")
    $null = Invoke-Checked kubectl @('--kubeconfig', $kubeconfig, 'rollout', 'status', 'deployment/web', '-n', 'cloudlens', "--timeout=${HealthTimeoutSeconds}s")
    $caCertificate = ''
    $curlArguments = @('--fail', '--silent', '--show-error', '--connect-timeout', '10', '--max-time', '30')
    if ($issuer -eq 'private-ca') {
        $null = Invoke-Checked kubectl @('--kubeconfig', $kubeconfig, 'wait', '--for=condition=Ready', 'certificate/web-tls', '-n', 'cloudlens', "--timeout=${HealthTimeoutSeconds}s")
        $caCertificate = Invoke-Checked kubectl @('--kubeconfig', $kubeconfig, 'get', 'secret', 'cloudlens-private-ca', '-n', 'cert-manager', '-o', 'jsonpath={.data.tls\.crt}')
        $caFile = Join-Path $temp 'cloudlens-ca.crt'
        [IO.File]::WriteAllBytes($caFile, [Convert]::FromBase64String($caCertificate))
        $curlArguments += @('--cacert', $caFile)
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $response = & curl @curlArguments "$origin/api/health" 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) { break }
        if ($clock.Elapsed.TotalSeconds -ge $HealthTimeoutSeconds) {
            throw "Private HTTPS health check failed (TLS validation was not bypassed): $(@($response) -join "`n")"
        }
        Start-Sleep -Seconds 10
    } while ($true)
    $health = (@($response) -join "`n") | ConvertFrom-Json
    if ($health.status -ne 'ok') { throw 'The API did not return status=ok over private HTTPS.' }
    $null = Invoke-Checked curl ($curlArguments + @($origin))

    $result = [ordered]@{
        environment = $EnvironmentName
        healthy = $true
        webUrl = $origin
        privateIp = $privateIp
        apiImage = Get-AzdValue 'SERVICE_API_IMAGE_NAME'
        webImage = Get-AzdValue 'SERVICE_WEB_IMAGE_NAME'
        caCertificateBase64 = $caCertificate
        requestId = $env:CLOUDLENS_DEPLOY_REQUEST_ID
        sourceRevision = $env:CLOUDLENS_SOURCE_REVISION
    }
    if ($ResultFile) {
        [IO.File]::WriteAllText($ResultFile, ($result | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    }
    Write-Host "Deployment verified inside the VNet: private data planes, both rollouts and trusted HTTPS at $origin." -ForegroundColor Green
    [pscustomobject]$result
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
