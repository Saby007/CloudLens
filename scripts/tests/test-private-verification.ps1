Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$subject = Join-Path $PSScriptRoot '../verify-private-deployment.ps1'
$global:verificationTest = @{}
$originalRequestId = $env:CLOUDLENS_DEPLOY_REQUEST_ID
$originalRevision = $env:CLOUDLENS_SOURCE_REVISION
$env:CLOUDLENS_DEPLOY_REQUEST_ID = 'b' * 32
$env:CLOUDLENS_SOURCE_REVISION = 'a' * 40

function azd {
    $global:LASTEXITCODE = 0
    switch ($args[4]) {
        'AZURE_SUBSCRIPTION_ID' { 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
        'AZURE_RESOURCE_GROUP' { 'rg-test' }
        'AZURE_AKS_CLUSTER_NAME' { 'aks-test' }
        'APP_WEB_ORIGIN' { 'https://localhost' }
        'APP_INGRESS_PRIVATE_IP' { '127.0.0.1' }
        'APP_INGRESS_VISIBILITY' { 'private' }
        'AZURE_CONTAINER_REGISTRY_NAME' { 'acrtest' }
        'APP_TLS_CLUSTER_ISSUER' { 'private-ca' }
        'COST_EXPORT_STORAGE_RESOURCE_ID' { '/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttest' }
        'APP_LOG_ANALYTICS_WORKSPACE_ID' { '/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test' }
        'SERVICE_API_IMAGE_NAME' { 'acrtest.azurecr.io/api:revision' }
        'SERVICE_WEB_IMAGE_NAME' { 'acrtest.azurecr.io/web:revision' }
        default { throw "Unexpected deployment output: $($args -join ' ')" }
    }
}

function az {
    $global:LASTEXITCODE = 0
    $mode = $global:verificationTest.mode
    switch ($args[0]) {
        'aks' {
            if ($args[1] -eq 'get-credentials') {
                $index = [array]::IndexOf(@($args), '--file')
                $global:verificationTest.kubeconfig = $args[$index + 1]
                return
            }
            return @{ apiServerAccessProfile = @{ enablePrivateCluster = $mode -ne 'public-aks'; enablePrivateClusterPublicFqdn = $false } } | ConvertTo-Json
        }
        'acr' { return @{ publicNetworkAccess = if ($mode -eq 'public-acr') { 'Enabled' } else { 'Disabled' }; adminUserEnabled = $false; networkRuleBypassOptions = if ($mode -eq 'registry-bypass') { 'AzureServices' } else { 'None' } } | ConvertTo-Json }
        'storage' { return @{ publicNetworkAccess = if ($mode -eq 'public-storage') { 'Enabled' } else { 'Disabled' }; allowSharedKeyAccess = $false; allowBlobPublicAccess = $false } | ConvertTo-Json }
        'monitor' { return @{ publicNetworkAccessForIngestion = 'Disabled'; publicNetworkAccessForQuery = if ($mode -eq 'public-logs') { 'Enabled' } else { 'Disabled' } } | ConvertTo-Json }
        default { throw "Unexpected Azure command: $($args -join ' ')" }
    }
}

function kubelogin { $global:LASTEXITCODE = 0 }

function kubectl {
    $global:LASTEXITCODE = 0
    $global:verificationTest.kubectl.Add(($args -join ' '))
    if ($args -contains 'get') {
        if ($args -notcontains 'jsonpath={.data.tls\.crt}') { throw 'Only the public CA certificate may be exported.' }
        return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('synthetic public CA'))
    }
    if ($global:verificationTest.mode -eq 'rollout-failed') {
        $global:LASTEXITCODE = 1
        return 'synthetic rollout failed'
    }
}

function curl {
    $global:LASTEXITCODE = 0
    $a = @($args)
    if ($a -notcontains '--cacert' -or $a -contains '--insecure' -or $a -contains '-k') { throw 'HTTPS verification must trust the CA, not bypass TLS.' }
    $index = [array]::IndexOf($a, '--cacert')
    if (-not (Test-Path -LiteralPath $a[$index + 1])) { throw 'The verification CA file was not written.' }
    if ($a[-1] -like '*/api/health') {
        return @{ status = if ($global:verificationTest.mode -eq 'unhealthy') { 'failed' } else { 'ok' } } | ConvertTo-Json
    }
    return '<html>synthetic web application</html>'
}

try {
    foreach ($mode in @('success', 'public-aks', 'public-acr', 'registry-bypass', 'public-storage', 'public-logs', 'rollout-failed', 'unhealthy')) {
        $global:verificationTest = @{ mode = $mode; kubectl = [Collections.Generic.List[string]]::new(); kubeconfig = '' }
        $threw = $false
        try { $result = & $subject -EnvironmentName test -HealthTimeoutSeconds 1 } catch { $threw = $true }
        if ($mode -eq 'success') {
            if ($threw -or $result.healthy -ne $true -or $result.requestId -ne ('b' * 32)) { throw 'A private, healthy deployment was not verified.' }
            if (-not ($global:verificationTest.kubectl -match 'rollout status deployment/api') -or -not ($global:verificationTest.kubectl -match 'rollout status deployment/web')) { throw 'Both deployments must be checked.' }
            if (Test-Path -LiteralPath (Split-Path -Parent $global:verificationTest.kubeconfig)) { throw 'Verification must remove its temporary kubeconfig and CA file.' }
        } elseif (-not $threw) {
            throw "$mode must fail private verification."
        }
        Write-Host "PASS: $mode"
    }
} finally {
    $env:CLOUDLENS_DEPLOY_REQUEST_ID = $originalRequestId
    $env:CLOUDLENS_SOURCE_REVISION = $originalRevision
}
@{ result = 'passed'; privateDataPlanes = $true; bothRollouts = $true; validatesTls = $true; rejectsUnhealthyResults = $true } | ConvertTo-Json -Compress
