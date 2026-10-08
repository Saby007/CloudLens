<#
.SYNOPSIS
    Offline preflight for the azd environment settings: checks the values Terraform and the Kubernetes
    manifests will receive, without contacting Azure. Prints a JSON summary of what would be deployed.
#>
[CmdletBinding()]
param(
    [ValidateSet('Local', 'Provision', 'Publish', 'Deploy', 'Down')]
    [string] $Operation = 'Local'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw 'PowerShell 7.4 or later is required.' }

function Get-Setting([string] $Name, [string] $Default = '') {
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Get-BooleanSetting([string] $Name) {
    $value = Get-Setting $Name 'false'
    if ($value -cnotin @('true', 'false')) { throw "$Name must be true or false (lowercase)." }
    return $value -eq 'true'
}

function Assert-Identifier([string] $Name) {
    $value = Get-Setting $Name
    $identifier = [guid]::Empty
    if (-not [guid]::TryParseExact($value, 'D', [ref]$identifier) -or $identifier -eq [guid]::Empty) {
        throw "$Name must contain a nonzero UUID."
    }
}

function Test-Overlap([System.Net.IPNetwork] $First, [System.Net.IPNetwork] $Second) {
    return $First.Contains($Second.BaseAddress) -or $Second.Contains($First.BaseAddress)
}

# The same rules Terraform's web_allowed_ip_ranges validation applies: IPv4, /8 to /32, written with the network address.
function ConvertTo-IpAllowList([string] $Name, [string] $Value) {
    $ranges = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @("$Value" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $text = if ($item.Contains('/')) { $item } else { "$item/32" }
        $network = [System.Net.IPNetwork]::new([System.Net.IPAddress]::Any, 0)
        if ($text -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' -or -not [System.Net.IPNetwork]::TryParse($text, [ref] $network) -or
            $network.PrefixLength -lt 8 -or "$($network.BaseAddress)/$($network.PrefixLength)" -cne $text) {
            throw "$Name must list IPv4 addresses or CIDR ranges from /8 to /32 written with their network address, for example 203.0.113.7 or 198.51.100.0/24; '$item' is not one."
        }
        if (-not $ranges.Contains($text)) { $ranges.Add($text) }
    }
    return , $ranges.ToArray()
}

if ($Operation -ne 'Local' -and -not (Get-BooleanSetting 'APP_ALLOW_AZURE_CHANGES')) {
    throw 'Azure changes are not approved. Complete the required approval gates and explicitly set APP_ALLOW_AZURE_CHANGES=true.'
}
if ($Operation -eq 'Down' -and -not (Get-BooleanSetting 'APP_ALLOW_DESTRUCTIVE_CHANGES')) {
    throw 'Destructive cleanup requires separate approval and APP_ALLOW_DESTRUCTIVE_CHANGES=true.'
}

$environmentName = Get-Setting 'AZURE_ENV_NAME'
if ($environmentName -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'AZURE_ENV_NAME must be a lowercase alphanumeric/hyphen name of at most 64 characters.' }
$profile = Get-Setting 'APP_PROFILE' 'core'
if ($profile -cnotin @('core', 'data', 'ai')) { throw 'APP_PROFILE must be core, data or ai.' }
$profileOrder = @{ core = 0; data = 1; ai = 2 }
$previousProfile = Get-Setting 'APP_PROVISIONED_PROFILE'
if ($Operation -ne 'Down' -and $previousProfile -and
    (-not $profileOrder.ContainsKey($previousProfile) -or $profileOrder[$profile] -lt $profileOrder[$previousProfile])) {
    throw 'Profile downgrade would delete the provisioned data or AI resources. Use azd down for the environment instead.'
}
foreach ($name in @('AZURE_LOCATION', 'FOUNDRY_LOCATION')) {
    $default = if ($name -eq 'AZURE_LOCATION') { 'centralindia' } else { 'eastus2' }
    if ((Get-Setting $name $default) -cnotmatch '^[a-z][a-z0-9]+$') { throw "$name must use an Azure location code." }
}

# Network: the node and private-endpoint subnets live in the VNet; the overlay pod range and the service
# range are cluster-internal but must not collide with the VNet (or each other).
$vnet = [System.Net.IPNetwork]::Parse((Get-Setting 'APP_VNET_PREFIX' '10.42.0.0/23'))
$nodes = [System.Net.IPNetwork]::Parse((Get-Setting 'APP_AKS_SUBNET_PREFIX' '10.42.0.0/24'))
$endpoints = [System.Net.IPNetwork]::Parse((Get-Setting 'APP_PRIVATE_ENDPOINT_SUBNET_PREFIX' '10.42.1.0/27'))
foreach ($subnet in @($nodes, $endpoints)) {
    if ($subnet.BaseAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        -not $vnet.Contains($subnet.BaseAddress) -or $subnet.PrefixLength -lt $vnet.PrefixLength -or $subnet.PrefixLength -gt 27) {
        throw 'Each subnet must be IPv4, within the VNet, and /27 or larger.'
    }
}
if (Test-Overlap $nodes $endpoints) { throw 'AKS node and private-endpoint subnets must not overlap.' }
$pods = [System.Net.IPNetwork]::Parse((Get-Setting 'APP_AKS_POD_CIDR' '10.244.0.0/16'))
$services = [System.Net.IPNetwork]::Parse((Get-Setting 'APP_AKS_SERVICE_CIDR' '10.0.0.0/16'))
foreach ($range in @(@{ Name = 'APP_AKS_POD_CIDR'; Value = $pods }, @{ Name = 'APP_AKS_SERVICE_CIDR'; Value = $services })) {
    if ($range.Value.BaseAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { throw "$($range.Name) must be IPv4." }
    if (Test-Overlap $range.Value $vnet) { throw "$($range.Name) must not overlap the VNet." }
}
if (Test-Overlap $pods $services) { throw 'APP_AKS_POD_CIDR and APP_AKS_SERVICE_CIDR must not overlap.' }
if ($services.PrefixLength -gt 28) { throw 'APP_AKS_SERVICE_CIDR must be /28 or larger.' }
$reserved = [System.Net.IPNetwork]::Parse('172.17.0.0/16')
foreach ($range in @($vnet, $pods, $services)) {
    if (Test-Overlap $range $reserved) { throw 'The VNet, pod and service ranges must not overlap Docker-reserved 172.17.0.0/16.' }
}

# Cluster, ingress and TLS settings that Terraform would otherwise reject only at plan time.
if ((Get-Setting 'APP_AKS_SKU_TIER' 'Standard') -cnotin @('Free', 'Standard', 'Premium')) { throw 'APP_AKS_SKU_TIER must be Free, Standard or Premium.' }
$zones = Get-Setting 'APP_AKS_ZONES' '1,2,3'
if ($zones -cne 'none' -and ($zones -replace '\s', '') -cnotmatch '^[1-3](,[1-3]){0,2}$') { throw 'APP_AKS_ZONES must be none or a comma-separated list of zones 1-3.' }
foreach ($name in @('APP_AKS_SYSTEM_VM_SIZE', 'APP_AKS_USER_VM_SIZE')) {
    $size = Get-Setting $name
    if ($size -and $size -cnotmatch '^Standard_[A-Z]+[0-9]+[a-z]*d[a-z]*_v[0-9]+$') {
        throw "$name must be a VM size with a local temp disk for the ephemeral OS disk, for example Standard_D4ds_v5."
    }
}
if ((Get-Setting 'APP_TLS_CLUSTER_ISSUER' 'letsencrypt') -cnotin @('letsencrypt', 'letsencrypt-staging')) {
    throw 'APP_TLS_CLUSTER_ISSUER must be letsencrypt or letsencrypt-staging.'
}
$label = Get-Setting 'APP_INGRESS_DNS_LABEL'
if ($label -and $label -cnotmatch '^[a-z][a-z0-9-]{1,61}[a-z0-9]$') { throw 'APP_INGRESS_DNS_LABEL must be 3-63 lowercase letters, digits or hyphens and start with a letter.' }
$domain = Get-Setting 'APP_CUSTOM_DOMAIN'
if ($domain -and $domain.ToLowerInvariant() -cnotmatch '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') { throw 'APP_CUSTOM_DOMAIN must be a host name such as cloudlens.contoso.com.' }
$email = Get-Setting 'APP_ACME_EMAIL'
if ($email -and $email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'APP_ACME_EMAIL must be an email address.' }

# Every node, plus the surge node each pool adds while it upgrades, takes its SNAT ports from the
# outbound IPs' 64,000 each. Terraform enforces the same rule, but only at plan time.
function Get-WholeNumber([string] $Name, [string] $Default, [int] $Minimum, [int] $Maximum) {
    $value = Get-Setting $Name $Default
    if ($value -cnotmatch '^[0-9]{1,6}$' -or [int]$value -lt $Minimum -or [int]$value -gt $Maximum) {
        throw "$Name must be a whole number between $Minimum and $Maximum."
    }
    return [int]$value
}
$outboundIps = Get-WholeNumber 'APP_AKS_OUTBOUND_IPS' '1' 1 100
$outboundPorts = Get-WholeNumber 'APP_AKS_OUTBOUND_PORTS' '6400' 1024 64000
if ($outboundPorts % 8) { throw 'APP_AKS_OUTBOUND_PORTS must be a multiple of 8.' }
[void] (Get-WholeNumber 'APP_AKS_OUTBOUND_IDLE_TIMEOUT' '4' 4 120)
$nodes = 0
foreach ($pool in @(@('APP_AKS_SYSTEM_MAX_NODES', '3', 20), @('APP_AKS_USER_MAX_NODES', '5', 50))) {
    $count = Get-WholeNumber $pool[0] $pool[1] 1 $pool[2]
    $nodes += $count + [Math]::Ceiling($count * 0.1)
}
if ($nodes * $outboundPorts -gt 64000 * $outboundIps) {
    throw "The node pools at their maximum size, plus one upgrade surge node per pool, need $($nodes * $outboundPorts) SNAT ports, but the outbound IPs provide $(64000 * $outboundIps). Lower APP_AKS_OUTBOUND_PORTS, raise APP_AKS_OUTBOUND_IPS, or lower the pools' maximum node counts."
}

if ($Operation -eq 'Publish' -and (Get-Setting 'AZURE_CONTAINER_REGISTRY_ENDPOINT') -cnotmatch '^[a-z0-9]+\.azurecr\.io$') {
    throw 'Publish requires the provisioned environment registry (run azd provision first).'
}
$signInConfigured = -not [string]::IsNullOrEmpty((Get-Setting 'MEGHKOSHA_API_CLIENT_ID')) -or -not [string]::IsNullOrEmpty((Get-Setting 'MEGHKOSHA_WEB_CLIENT_ID'))
if ($signInConfigured) {
    foreach ($name in @('AZURE_TENANT_ID', 'MEGHKOSHA_API_CLIENT_ID', 'MEGHKOSHA_WEB_CLIENT_ID')) { Assert-Identifier $name }
    if ((Get-Setting 'MEGHKOSHA_API_CLIENT_ID') -eq (Get-Setting 'MEGHKOSHA_WEB_CLIENT_ID')) { throw 'API and SPA must use separate registrations.' }
}
# Compared exactly, as the API and the web manifest do: a near miss must never switch only one of them.
$authMode = [Environment]::GetEnvironmentVariable('MEGHKOSHA_AUTH_MODE', 'Process')
if ($null -eq $authMode) { $authMode = '' }
if ($authMode -cnotin @('', 'entra', 'operator')) { throw 'MEGHKOSHA_AUTH_MODE must be entra or operator (lowercase, no spaces).' }
if ($authMode -ceq 'operator') { Assert-Identifier 'MEGHKOSHA_OPERATOR_OBJECT_ID' }
$webAllowedIpRanges = ConvertTo-IpAllowList 'APP_WEB_ALLOWED_IP_RANGES' ([Environment]::GetEnvironmentVariable('APP_WEB_ALLOWED_IP_RANGES', 'Process'))
if ($Operation -eq 'Deploy' -and (Get-Setting 'AZURE_AKS_CLUSTER_NAME') -cnotmatch '^aks-[a-f0-9]{13}$') {
    throw 'Deploy requires the provisioned AKS cluster (run azd provision first).'
}

$processor = Get-BooleanSetting 'APP_ENABLE_PROCESSOR'
if ($processor) {
    if ($profile -eq 'core') { throw 'The processor requires the data or ai stage.' }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot '../api/jobs/scheduler.py'))) {
        throw 'The scheduled processor is not implemented yet. Complete the processor implementation before enabling it.'
    }
}
$trustedExports = Get-BooleanSetting 'APP_EXPORT_TRUSTED_SERVICES'
if ($profile -eq 'core' -and $trustedExports) { throw 'Native export storage settings are not part of the core stage.' }

$models = ConvertFrom-Json -InputObject (Get-Setting 'APP_MODEL_DEPLOYMENTS' '[]') -AsHashtable -NoEnumerate
if ($models -isnot [System.Collections.IList]) { throw 'APP_MODEL_DEPLOYMENTS must be a JSON array.' }
if ($models.Count -and $profile -ne 'ai') { throw 'Model deployments require the ai stage.' }
$modelNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$modelRouterNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($model in $models) {
    if ($model -isnot [System.Collections.IDictionary]) { throw 'Each model must be an object.' }
    foreach ($field in @('name', 'modelFormat', 'modelName', 'modelVersion', 'sku', 'capacity')) {
        if (-not $model.Contains($field)) { throw "Model deployment is missing $field." }
    }
    if ($model.Count -ne 6) { throw 'A model deployment contains unsupported fields.' }
    if (-not $modelNames.Add([string]$model.name) -or $model.name -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$') { throw 'Model deployment names must be valid and unique.' }
    if ($model.sku -cnotin @('Standard', 'GlobalStandard', 'DataZoneStandard') -or
        $model.capacity -isnot [long] -and $model.capacity -isnot [int] -or $model.capacity -lt 1) { throw 'Model SKU or capacity is invalid.' }
    foreach ($field in @('modelFormat', 'modelName', 'modelVersion')) {
        if ($model[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($model[$field])) { throw "Model $field must be specified." }
    }
    if ($model.modelName -eq 'model-router') {
        if ($model.modelFormat -ne 'OpenAI' -or $model.modelVersion -ne '2025-11-18' -or
            $model.sku -ne 'GlobalStandard' -or $model.capacity -ne 20) {
            throw 'Model Router must use the approved OpenAI 2025-11-18 GlobalStandard deployment at capacity 20.'
        }
        [void] $modelRouterNames.Add([string]$model.name)
    }
}
$aiRuntime = Get-BooleanSetting 'APP_ENABLE_AI_RUNTIME'
if ($aiRuntime -and ($profile -ne 'ai' -or -not $models.Count -or -not (Get-BooleanSetting 'APP_AI_VALIDATED'))) {
    throw 'AI runtime requires the ai stage, configured models and explicit validation (APP_AI_VALIDATED=true).'
}
$chatRuntime = Get-BooleanSetting 'APP_ENABLE_CHAT_RUNTIME'
$modelRouterDeploymentName = Get-Setting 'MODEL_ROUTER_DEPLOYMENT_NAME'
if ($chatRuntime -and ($profile -ne 'ai' -or -not (Get-BooleanSetting 'APP_AI_VALIDATED') -or
    [string]::IsNullOrWhiteSpace($modelRouterDeploymentName) -or -not $modelRouterNames.Contains($modelRouterDeploymentName))) {
    throw 'Foundry chat requires the ai stage, explicit validation and MODEL_ROUTER_DEPLOYMENT_NAME matching an approved model-router deployment.'
}

[pscustomobject]@{
    operation = $Operation
    environment = $environmentName
    hosting = 'aks'
    profile = $profile
    signInConfigured = $signInConfigured
    authMode = $(if ($authMode) { $authMode } else { 'entra' })
    webAllowedIpRanges = @($webAllowedIpRanges)
    processorEnabled = $processor
    aiRuntimeEnabled = $aiRuntime
    chatRuntimeEnabled = $chatRuntime
    nativeExportNetworkException = $trustedExports
    tlsIssuer = Get-Setting 'APP_TLS_CLUSTER_ISSUER' 'letsencrypt'
    customDomain = $domain
    cloudPreflightStillRequired = $true
} | ConvertTo-Json -Compress
