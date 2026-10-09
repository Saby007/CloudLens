<#
.SYNOPSIS
    Prepares the AKS cluster after `azd provision`: cert-manager, the ingress controller (private by default, or
    bound to the static public IP) and the certificate issuers. azure.yaml runs it as the postprovision hook; it
    is safe to rerun.

.DESCRIPTION
    1. Signs in to the cluster with Entra ID (az aks get-credentials + kubelogin) into a temporary kubeconfig,
       leaving your own kubeconfig untouched.
    2. Waits until the cluster-admin role Terraform granted has reached the API server.
    3. Installs cert-manager from its pinned release manifest after checking the file's SHA-256.
    4. Applies infra/k8s/cluster-bootstrap.yaml: an app-routing NGINX controller bound either to an internal load
       balancer at the private address Terraform reserved (published through a Private Link Service when enabled)
       or to the Terraform-owned public IP, the production/staging Let's Encrypt ClusterIssuers (public ingress
       only) and the cluster's private CA issuer.

    Values come from the azd environment, which azd exposes to hooks as environment variables.

.PARAMETER PlanOnly
    Print the rendered bootstrap manifest and the cert-manager release without contacting Azure or the cluster.
#>
[CmdletBinding()]
param(
    [string] $CertManagerVersion = 'v1.21.2',
    [ValidatePattern('^[a-f0-9]{64}$')]
    [string] $CertManagerSha256 = 'e03b668ec8675214af6b0a671699d088f2601fa3878e0dbe1b41d3feafd1879f',
    [ValidateRange(1, 3600)]
    [int] $RbacTimeoutSeconds = 900,
    [ValidateRange(1, 3600)]
    [int] $ReadyTimeoutSeconds = 600,
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.0') { throw 'PowerShell 7 or later is required.' }

$fieldManager = 'cloudlens-bootstrap'
$templatePath = Join-Path $PSScriptRoot '../infra/k8s/cluster-bootstrap.yaml'

function Get-Setting {
    param([Parameter(Mandatory)][string] $Name)
    $value = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if ($null -eq $value) { return '' }
    return $value.Trim()
}

function Get-CliText {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ((@($Value | Where-Object { $null -ne $_ }) -join "`n")).Trim()
}

function ConvertTo-BootstrapManifest {
    param([Parameter(Mandatory)][string] $Template, [Parameter(Mandatory)][hashtable] $Values, [string[]] $Optional = @())
    $lines = foreach ($line in ($Template -split "`r?`n")) {
        $names = @([regex]::Matches($line, '\$\{([A-Z0-9_]+)\}') | ForEach-Object { $_.Groups[1].Value })
        $skip = $false
        foreach ($name in $names) {
            if (-not $Values.ContainsKey($name)) { throw "cluster-bootstrap.yaml uses `${$name}, which this script does not provide." }
            if ([string]::IsNullOrEmpty($Values[$name])) {
                if ($name -notin $Optional) { throw "$name is empty in the azd environment; run azd provision first." }
                $skip = $true
            }
            if ($Values[$name] -match '["\\\r\n]') { throw "$name contains characters that cannot be placed in the manifest." }
        }
        if ($skip) { continue }
        [regex]::Replace($line, '\$\{([A-Z0-9_]+)\}', { param($match) $Values[$match.Groups[1].Value] })
    }
    return ($lines -join "`n")
}

function Invoke-Kubectl {
    # Returns kubectl's standard output only, so callers can parse it: kubectl also writes warnings to standard
    # error (for example "resource ... is not namespace scoped"). Throws with both streams when kubectl fails,
    # unless -AllowFailure; the standard error of the last call is kept in $script:KubectlError either way.
    param([Parameter(Mandatory)][string[]] $Arguments, [string] $InputText, [switch] $AllowFailure)
    $output = if ($PSBoundParameters.ContainsKey('InputText')) {
        $InputText | & kubectl @Arguments 2>&1
    } else {
        & kubectl @Arguments 2>&1
    }
    $exitCode = $LASTEXITCODE
    $standardOutput = Get-CliText @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $script:KubectlError = Get-CliText @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "kubectl $($Arguments -join ' ') failed: $(Get-CliText @($standardOutput, $script:KubectlError))"
    }
    $global:LASTEXITCODE = $exitCode
    return $standardOutput
}

function Wait-Until {
    param([Parameter(Mandatory)][scriptblock] $Condition, [Parameter(Mandatory)][int] $TimeoutSeconds,
          [Parameter(Mandatory)][string] $Activity, [int] $IntervalSeconds = 15, [scriptblock] $Status)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    while ($true) {
        $attempt++
        if (& $Condition) { return $true }
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { return $false }
        if ($attempt % 4 -eq 1) {
            $detail = if ($Status) { "$(& $Status)" -replace '\s+', ' ' } else { '' }
            if ($detail.Trim()) { $detail = " - last response: $($detail.Trim())" } else { $detail = '' }
            Write-Host "  $Activity ($([int]$clock.Elapsed.TotalSeconds)s so far, up to $TimeoutSeconds)$detail" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

$values = @{
    AZURE_SUBSCRIPTION_ID = Get-Setting 'AZURE_SUBSCRIPTION_ID'
    AZURE_RESOURCE_GROUP = Get-Setting 'AZURE_RESOURCE_GROUP'
    AZURE_AKS_CLUSTER_NAME = Get-Setting 'AZURE_AKS_CLUSTER_NAME'
    APP_INGRESS_CLASS = Get-Setting 'APP_INGRESS_CLASS'
    APP_INGRESS_PUBLIC_IP_NAME = Get-Setting 'APP_INGRESS_PUBLIC_IP_NAME'
    APP_INGRESS_SUBNET_NAME = Get-Setting 'APP_INGRESS_SUBNET_NAME'
    APP_INGRESS_PRIVATE_IP = Get-Setting 'APP_INGRESS_PRIVATE_IP'
    APP_PRIVATE_LINK_NAME = Get-Setting 'APP_PRIVATE_LINK_NAME'
    APP_PRIVATE_LINK_SUBNET_NAME = Get-Setting 'APP_PRIVATE_LINK_SUBNET_NAME'
    APP_PRIVATE_LINK_SUBSCRIPTIONS = Get-Setting 'APP_PRIVATE_LINK_SUBSCRIPTIONS'
    APP_ACME_EMAIL = Get-Setting 'APP_ACME_EMAIL'
}
# Exactly one front end exists. Terraform reports a public IP name or a private address, never both, and the lines
# of the other front end are dropped from the template because their values are empty.
if ([bool]$values.APP_INGRESS_PUBLIC_IP_NAME -eq [bool]$values.APP_INGRESS_PRIVATE_IP -and $values.AZURE_AKS_CLUSTER_NAME) {
    throw 'The azd environment must name either a public ingress IP (APP_INGRESS_PUBLIC_IP_NAME) or a private ingress address (APP_INGRESS_PRIVATE_IP), not both and not neither; run azd provision first.'
}
$privateIngress = [bool]$values.APP_INGRESS_PRIVATE_IP
$values.INGRESS_PUBLIC_IP_RESOURCE_GROUP = if ($privateIngress) { '' } else { $values.AZURE_RESOURCE_GROUP }
$values.INGRESS_INTERNAL = if ($privateIngress) { 'true' } else { '' }
$values.INGRESS_PRIVATE_LINK_CREATE = if ($privateIngress -and $values.APP_PRIVATE_LINK_NAME) { 'true' } else { '' }
if ($privateIngress -and (-not $values.APP_INGRESS_SUBNET_NAME)) {
    throw 'A private ingress needs APP_INGRESS_SUBNET_NAME from the azd environment; run azd provision first.'
}
if ($values.APP_PRIVATE_LINK_NAME -and (-not $values.APP_PRIVATE_LINK_SUBNET_NAME -or -not $values.APP_PRIVATE_LINK_SUBSCRIPTIONS)) {
    throw 'A Private Link Service needs APP_PRIVATE_LINK_SUBNET_NAME and APP_PRIVATE_LINK_SUBSCRIPTIONS from the azd environment; run azd provision first.'
}
$optionalValues = @('APP_ACME_EMAIL', 'APP_INGRESS_PUBLIC_IP_NAME', 'INGRESS_PUBLIC_IP_RESOURCE_GROUP', 'INGRESS_INTERNAL',
    'APP_INGRESS_SUBNET_NAME', 'APP_INGRESS_PRIVATE_IP', 'INGRESS_PRIVATE_LINK_CREATE', 'APP_PRIVATE_LINK_NAME',
    'APP_PRIVATE_LINK_SUBNET_NAME', 'APP_PRIVATE_LINK_SUBSCRIPTIONS')
$cluster = $values.AZURE_AKS_CLUSTER_NAME
if (-not $cluster) {
    Write-Host 'AZURE_AKS_CLUSTER_NAME is not set yet, so there is no cluster to prepare. Skipping the AKS bootstrap.'
    exit 0
}
if ($values.APP_ACME_EMAIL -and $values.APP_ACME_EMAIL -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw "APP_ACME_EMAIL '$($values.APP_ACME_EMAIL)' is not an email address."
}

$manifest = ConvertTo-BootstrapManifest -Template (Get-Content -LiteralPath $templatePath -Raw) -Values $values -Optional $optionalValues
$certManagerUrl = "https://github.com/cert-manager/cert-manager/releases/download/$CertManagerVersion/cert-manager.yaml"

if ($PlanOnly) {
    [ordered]@{
        cluster = $cluster
        resourceGroup = $values.AZURE_RESOURCE_GROUP
        certManager = [ordered]@{ version = $CertManagerVersion; url = $certManagerUrl; sha256 = $CertManagerSha256 }
        manifest = $manifest
    } | ConvertTo-Json -Depth 5
    exit 0
}

foreach ($tool in @('az', 'kubectl', 'kubelogin')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "'$tool' is required to prepare the cluster. Install kubectl and kubelogin with 'az aks install-cli' (and add them to PATH), then rerun 'azd provision'."
    }
}
foreach ($required in @('AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP')) {
    if (-not $values[$required]) { throw "$required is not set in the azd environment." }
}

$kubeconfig = Join-Path ([System.IO.Path]::GetTempPath()) "cloudlens-$cluster-$([guid]::NewGuid().ToString('n')).kubeconfig"
$hadKubeconfig = Test-Path Env:KUBECONFIG
$previousKubeconfig = $env:KUBECONFIG
$certManagerFile = ''
try {
    Write-Host "==> Connecting to AKS cluster $cluster" -ForegroundColor Cyan
    $output = & az aks get-credentials --resource-group $values.AZURE_RESOURCE_GROUP --name $cluster --subscription $values.AZURE_SUBSCRIPTION_ID --file $kubeconfig --overwrite-existing --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az aks get-credentials failed: $(Get-CliText $output)" }
    $output = & kubelogin convert-kubeconfig --login azurecli --kubeconfig $kubeconfig 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubelogin convert-kubeconfig failed: $(Get-CliText $output)" }
    $env:KUBECONFIG = $kubeconfig

    Write-Host '==> Waiting for the cluster-admin role to reach the Kubernetes API server' -ForegroundColor Cyan
    $script:rbacResponse = ''
    $ready = Wait-Until -TimeoutSeconds $RbacTimeoutSeconds -Activity 'Azure RBAC is still propagating' -Status { $script:rbacResponse } -Condition {
        # CRDs are cluster-scoped; --all-namespaces stops kubectl from checking (and warning about) a namespace.
        $answer = Invoke-Kubectl @('auth', 'can-i', 'create', 'customresourcedefinitions.apiextensions.k8s.io', '--all-namespaces') -AllowFailure
        $allowed = $LASTEXITCODE -eq 0 -and @($answer -split "`r?`n" | ForEach-Object { $_.Trim() }) -contains 'yes'
        $script:rbacResponse = Get-CliText @($answer, $script:KubectlError)
        return $allowed
    }
    if (-not $ready) {
        throw "The signed-in account still cannot administer $cluster after $RbacTimeoutSeconds seconds (last response from kubectl: $($script:rbacResponse -replace '\s+', ' ')). Confirm it holds 'Azure Kubernetes Service RBAC Cluster Admin' on the cluster (Terraform assigns it to the deploying principal), then rerun 'azd provision'."
    }

    $installed = Invoke-Kubectl @('get', 'deployment', 'cert-manager', '--namespace', 'cert-manager', '--ignore-not-found',
        '--output', 'jsonpath={.metadata.labels.app\.kubernetes\.io/version}') -AllowFailure
    if ($installed -eq $CertManagerVersion) {
        Write-Host "==> cert-manager $CertManagerVersion is already installed" -ForegroundColor Cyan
    } else {
        Write-Host "==> Installing cert-manager $CertManagerVersion" -ForegroundColor Cyan
        $certManagerFile = Join-Path ([System.IO.Path]::GetTempPath()) "cert-manager-$CertManagerVersion-$([guid]::NewGuid().ToString('n')).yaml"
        Invoke-WebRequest -Uri $certManagerUrl -OutFile $certManagerFile -UseBasicParsing -TimeoutSec 120 | Out-Null
        $actual = (Get-FileHash -LiteralPath $certManagerFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $CertManagerSha256) {
            throw "The downloaded cert-manager manifest has SHA-256 $actual, not the pinned $CertManagerSha256. Nothing was applied."
        }
        Invoke-Kubectl @('apply', '--server-side', '--force-conflicts', "--field-manager=$fieldManager", '-f', $certManagerFile) | Out-Null
    }
    foreach ($deployment in @('cert-manager', 'cert-manager-cainjector', 'cert-manager-webhook')) {
        Invoke-Kubectl @('rollout', 'status', "deployment/$deployment", '--namespace', 'cert-manager', "--timeout=$($ReadyTimeoutSeconds)s") | Out-Null
    }

    # cert-manager's webhook can refuse requests for a short while after it reports ready.
    Write-Host '==> Applying the ingress controller and the certificate issuers' -ForegroundColor Cyan
    $script:lastError = ''
    $applied = Wait-Until -TimeoutSeconds $ReadyTimeoutSeconds -Activity 'waiting for the cert-manager webhook' -Status { $script:lastError } -Condition {
        try {
            Invoke-Kubectl @('apply', '--server-side', '--force-conflicts', "--field-manager=$fieldManager", '-f', '-') -InputText $manifest | Out-Null
            return $true
        } catch {
            $script:lastError = $_.Exception.Message
            return $false
        }
    }
    if (-not $applied) { throw "The cluster bootstrap manifest could not be applied: $($script:lastError)" }

    $frontEnd = if ($privateIngress) { "the private address $($values.APP_INGRESS_PRIVATE_IP)" } else { "the static IP $(Get-Setting 'APP_INGRESS_PUBLIC_IP')" }
    Write-Host "==> Waiting for the ingress controller to take $frontEnd" -ForegroundColor Cyan
    $available = Invoke-Kubectl @('wait', 'nginxingresscontroller/cloudlens', '--for=condition=Available=True', "--timeout=$($ReadyTimeoutSeconds)s") -AllowFailure
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The ingress controller is not available yet: $(Get-CliText @($available, $script:KubectlError))"
        Write-Warning "Check it with: kubectl describe nginxingresscontroller cloudlens; kubectl get service --namespace app-routing-system"
    }
    Write-Host 'AKS bootstrap complete.' -ForegroundColor Green
} finally {
    if ($hadKubeconfig) { $env:KUBECONFIG = $previousKubeconfig } else { Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $kubeconfig -Force -ErrorAction SilentlyContinue
    if ($certManagerFile) { Remove-Item -LiteralPath $certManagerFile -Force -ErrorAction SilentlyContinue }
}
