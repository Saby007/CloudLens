<#
.SYNOPSIS
    Runs the entire CloudLens deployment on Azure Kubernetes Service - clone, azd provisioning with
    Terraform, sign-in registrations, and the per-subscription role assignments - as one script.

.DESCRIPTION
    This is the whole "Deploying to Azure" README flow in one file:

      1. Checks prerequisites (git, azd, az, terraform, kubectl, kubelogin) and clones the repository
         (skipped when already run from a checkout). Missing kubectl/kubelogin are installed with
         `az aks install-cli` once you agree. When they are not on your PATH, the run puts them there for
         itself only and prints how to add them, which azd commands you run yourself later need.
      2. Signs in with `azd` and `az` (Terraform authenticates through the Azure CLI).
      3. Creates the azd environment and applies the recommended `ai` profile settings, including the
         scheduled export processor.
      4. Previews the Terraform plan, then runs `azd up`: Terraform provisions the network, AKS cluster,
         registry, storage, Foundry account and identities; the postprovision hook installs cert-manager
         and the ingress controller; azd builds both images in ACR and applies the Kubernetes manifests.
         Failures are retried after a wait.
      5. Runs scripts/bootstrap-identity.ps1, feeds the two client IDs back into the environment, and
         runs `azd deploy` so the API pods pick them up. Skipped with -OperatorMode.
      6. Grants Reader / Cost Management Contributor on every subscription you want to assess.
      7. Waits for the certificate and checks /api/health over HTTPS. A private ingress (the default) has no
         public address, so this machine usually cannot reach it: instead the run prints the private address,
         the Private Link Service and what DNS and certificate trust the app needs. With -OperatorMode and no
         IP allow-list on a public ingress, it prints how to reach the app through `kubectl port-forward`.

    The app is private by default: it has no public address, an internal load balancer serves it on a private IP,
    and a Private Link Service lets a private endpoint in any virtual network reach it. -IngressVisibility public
    keeps the internet-facing address. An environment that already has a public address is never switched
    silently: say which you want.

    Every phase is idempotent and re-entrant: rerunning the script against an existing environment
    reapplies the current code once and skips whatever is already in place.

    The run never waits on a question you cannot see. azd's output is captured so failures can be
    recognised and retried, so every azd command runs with --no-prompt. Anything that genuinely needs an
    answer - a question azd asks, installing kubectl/kubelogin, or the Service Tree ID some tenants
    require on app registrations - is asked in this terminal instead.

.PARAMETER EnvironmentName
    azd environment name. Lowercase letters, digits and hyphens only - it is also used to name the
    resource group and the Entra ID app registrations created by scripts/bootstrap-identity.ps1.

.PARAMETER SubscriptionId
    The subscription to deploy into. Defaults to the Azure CLI's current subscription. It is pinned
    into the azd environment and every az lookup, so no azd command ever stops to prompt for it.

.PARAMETER TargetSubscriptionId
    One or more subscriptions to assess, as separate values or a single comma-separated string,
    for example -TargetSubscriptionId '1111...,2222...'. Defaults to the subscription you deploy into.

.PARAMETER ServiceManagementReference
    Service Tree ID put on the two sign-in app registrations, for tenants that refuse registrations
    without one. When it is omitted and the tenant asks for one, the script asks in the terminal and
    offers the ID your existing registrations use. The answer is kept in the azd environment for reruns.

.PARAMETER AcmeEmail
    Optional contact address registered with Let's Encrypt for the app's TLS certificate.

.PARAMETER OperatorMode
    Dev only, for operators who cannot create Entra app registrations. Deploys without Entra sign-in:
    every request acts as the signed-in Azure CLI user (their own Azure role assignments still decide
    which subscriptions the app shows). The network decides who reaches the app: a private ingress (the
    default) is reachable only privately; a public one is closed (reach it through `kubectl port-forward`)
    unless -AllowedIpRanges opens it to your addresses. Skips the sign-in bootstrap. A later run without
    this switch turns sign-in back on, which then needs the app registrations.

.PARAMETER IngressVisibility
    private: no public address. An internal load balancer serves the app on a private IP in the virtual network,
    and a Private Link Service publishes it so a private endpoint in any network can reach it. public: the
    internet-facing static IP and <label>.<region>.cloudapp.azure.com name. A new environment is private. An
    environment that already has a public address keeps it only if you say -IngressVisibility public; switching it
    to private removes the public address and the cloudapp.azure.com name, so the app's host name changes. The
    choice is kept in the azd environment.

.PARAMETER CustomDomain
    Host name for the app, for example cloudlens.contoso.com. Private: a private DNS zone of that name pointing at
    the private IP is created for the virtual network; point your own DNS at the private IP (or at the private
    endpoint's) for everything else. Without one a private ingress is named cloudlens-<token>.internal. Public: a
    CNAME to the cloudapp.azure.com name must exist first. Kept in the azd environment; pass '' to remove it.

.PARAMETER TlsClusterIssuer
    private-ca: a CA that cert-manager creates in the cluster signs the web certificate (the private default;
    browsers must trust the CA, see the README). byo: you create the web-tls secret from your own CA. letsencrypt and
    letsencrypt-staging need a public ingress. Without this the issuer follows the visibility.

.PARAMETER PrivateLinkSubscriptionIds
    Comma-separated subscription IDs, besides the deployment subscription, whose private endpoints may connect to
    the Private Link Service without manual approval. Kept in the azd environment; pass '' to remove them.

.PARAMETER NoPrivateLink
    Private ingress without the Private Link Service: only the private IP remains, reachable from this virtual
    network and from anything peered or connected to it.

.PARAMETER AllowedIpRanges
    Public ingress only: comma-separated IPv4 addresses or CIDR ranges (/8 or narrower) that may reach the app's
    public URL over HTTPS; everyone else is blocked by the network security group. With -OperatorMode this is what
    opens the public URL. The list is kept in the azd environment, so later runs keep it unless you pass this again;
    pass '' to remove it. When your address changes, scripts/allow-my-ip.ps1 updates it in seconds.

.PARAMETER InstallKubernetesTools
    Install kubectl and kubelogin with `az aks install-cli` without asking when they are missing.

.PARAMETER KubernetesToolsDirectory
    Where `az aks install-cli` puts kubectl and kubelogin (in .azure-kubectl and .azure-kubelogin).
    Defaults to your home directory.

.EXAMPLE
    # A private deployment (the default): reached through a private endpoint or the virtual network, with your own host name.
    pwsh ./scripts/deploy-end-to-end.ps1 -EnvironmentName my-environment -TargetSubscriptionId 'sub-a' -CustomDomain cloudlens.contoso.com

.EXAMPLE
    # The internet-facing deployment, as before.
    pwsh ./scripts/deploy-end-to-end.ps1 -EnvironmentName my-environment -TargetSubscriptionId 'sub-a,sub-b' -IngressVisibility public

.EXAMPLE
    # Dev environment without Entra app registrations: reached privately, with no sign-in.
    pwsh ./scripts/deploy-end-to-end.ps1 -EnvironmentName my-dev -TargetSubscriptionId 'sub-a' -OperatorMode

.EXAMPLE
    # The same on a public ingress, served at its public URL to your own address only (scripts/allow-my-ip.ps1 keeps it current).
    pwsh ./scripts/deploy-end-to-end.ps1 -EnvironmentName my-dev -TargetSubscriptionId 'sub-a' -IngressVisibility public -OperatorMode -AllowedIpRanges '203.0.113.7'

.EXAMPLE
    # Standalone: clones the cloudlensdev branch of the repository next to the current directory first.
    pwsh ./deploy-end-to-end.ps1 -EnvironmentName my-environment -RepoDirectory ./CloudLens
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')]
    [string] $EnvironmentName,
    [string] $Location = 'centralindia',
    [string] $SubscriptionId = '',
    [string[]] $TargetSubscriptionId = @(),
    [ValidatePattern('^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?$')]
    [string] $ServiceManagementReference = '',
    [ValidatePattern('^([^@\s]+@[^@\s]+\.[^@\s]+)?$')]
    [string] $AcmeEmail = '',
    [string] $RepoUrl = 'https://github.com/Saby007/CloudLens.git',
    [string] $RepoBranch = 'cloudlensdev',
    [string] $RepoDirectory = '',
    [ValidateRange(1, 10)]
    [int] $MaxAttempts = 3,
    [ValidateRange(0, 900)]
    [int] $SettleSeconds = 120,
    [ValidateRange(0, 3600)]
    [int] $HealthTimeoutSeconds = 600,
    [switch] $SkipLogin,
    [switch] $SkipPreview,
    [switch] $SkipProcessor,
    [switch] $SkipIdentityBootstrap,
    [switch] $SkipRoleAssignments,
    [switch] $IncludeLocalhostRedirects,
    [switch] $GrantAdminConsent,
    [switch] $OperatorMode,
    [ValidateSet('private', 'public')]
    [string] $IngressVisibility,
    [string] $CustomDomain = '',
    [ValidateSet('private-ca', 'byo', 'letsencrypt', 'letsencrypt-staging')]
    [string] $TlsClusterIssuer,
    [string] $PrivateLinkSubscriptionIds = '',
    [switch] $NoPrivateLink,
    [string] $AllowedIpRanges = '',
    [switch] $InstallKubernetesTools,
    [string] $KubernetesToolsDirectory = $HOME,
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.0') {
    throw 'PowerShell 7 or later is required. Run this script with `pwsh`, not Windows PowerShell 5.1.'
}

$modelRouter = '[{"name":"model-router","modelFormat":"OpenAI","modelName":"model-router","modelVersion":"2025-11-18","sku":"GlobalStandard","capacity":20}]'
$settings = [ordered]@{
    AZURE_LOCATION = $Location
    APP_PROFILE = 'ai'
    APP_EXPORT_TRUSTED_SERVICES = 'true'
    APP_MODEL_DEPLOYMENTS = $modelRouter
    MODEL_ROUTER_DEPLOYMENT_NAME = 'model-router'
    APP_ENABLE_CHAT_RUNTIME = 'true'
    APP_AI_VALIDATED = 'true'
    APP_ENABLE_AI_RUNTIME = 'false'
}
# Skipping leaves an existing environment's processor setting untouched instead of switching it off.
if (-not $SkipProcessor) { $settings.APP_ENABLE_PROCESSOR = 'true' }
if ($AcmeEmail) { $settings.APP_ACME_EMAIL = $AcmeEmail }
# Every run sets the sign-in mode explicitly, so operator mode never outlives the run that asked for it.
# The operator is the signed-in az user, resolved after sign-in.
$settings.MEGHKOSHA_AUTH_MODE = if ($OperatorMode) { 'operator' } else { 'entra' }
if (-not $OperatorMode) {
    $settings.MEGHKOSHA_OPERATOR_OBJECT_ID = ''
    $settings.MEGHKOSHA_OPERATOR_UPN = ''
}

# The same rules Terraform's web_allowed_ip_ranges validation applies: IPv4, /8 to /32, written with the network address.
function ConvertTo-IpAllowList {
    param([AllowEmptyString()][string] $Value)
    if (-not ('System.Net.IPNetwork' -as [type])) { throw '-AllowedIpRanges needs PowerShell 7.4 or later.' }
    $ranges = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @("$Value" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $text = if ($item.Contains('/')) { $item } else { "$item/32" }
        $network = [System.Net.IPNetwork]::new([System.Net.IPAddress]::Any, 0)
        if ($text -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' -or -not [System.Net.IPNetwork]::TryParse($text, [ref] $network) -or
            $network.PrefixLength -lt 8 -or "$($network.BaseAddress)/$($network.PrefixLength)" -cne $text) {
            throw "-AllowedIpRanges takes IPv4 addresses or CIDR ranges from /8 to /32 written with their network address, for example 203.0.113.7 or 198.51.100.0/24; '$item' is not one."
        }
        if (-not $ranges.Contains($text)) { $ranges.Add($text) }
    }
    return ($ranges -join ',')
}
# Kept in the azd environment between runs (scripts/allow-my-ip.ps1 updates it), so only an explicit value changes it.
if ($PSBoundParameters.ContainsKey('AllowedIpRanges')) { $settings.APP_WEB_ALLOWED_IP_RANGES = ConvertTo-IpAllowList $AllowedIpRanges }

# Ingress. Each value is kept in the azd environment, so only an explicit one changes it; the visibility itself is
# settled in section 3, once the environment (and any public address it already has) is known.
if ($PSBoundParameters.ContainsKey('IngressVisibility') -and $IngressVisibility -eq 'private' -and $settings.Contains('APP_WEB_ALLOWED_IP_RANGES') -and $settings.APP_WEB_ALLOWED_IP_RANGES) {
    throw '-AllowedIpRanges limits who can reach a public ingress; a private ingress has no public address. Drop it, or use -IngressVisibility public.'
}
if ($PSBoundParameters.ContainsKey('CustomDomain')) {
    $domain = $CustomDomain.Trim().ToLowerInvariant()
    if ($domain -and $domain -cnotmatch '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') { throw "-CustomDomain must be a host name such as cloudlens.contoso.com; '$CustomDomain' is not one." }
    $settings.APP_CUSTOM_DOMAIN = $domain
}
if ($PSBoundParameters.ContainsKey('TlsClusterIssuer')) {
    if ($TlsClusterIssuer -like 'letsencrypt*' -and $PSBoundParameters.ContainsKey('IngressVisibility') -and $IngressVisibility -eq 'private') {
        throw "-TlsClusterIssuer $TlsClusterIssuer validates the host over the public internet, which a private ingress does not accept. Use private-ca or byo, or -IngressVisibility public."
    }
    $settings.APP_TLS_CLUSTER_ISSUER = $TlsClusterIssuer
}
if ($PSBoundParameters.ContainsKey('PrivateLinkSubscriptionIds')) {
    $allowedSubscriptions = @($PrivateLinkSubscriptionIds -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($allowed in $allowedSubscriptions) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($allowed, [ref] $parsed)) { throw "-PrivateLinkSubscriptionIds takes subscription IDs (GUIDs) separated by commas; '$allowed' is not one." }
    }
    $settings.APP_PRIVATE_LINK_ALLOWED_SUBSCRIPTIONS = $allowedSubscriptions -join ','
}
if ($NoPrivateLink) { $settings.APP_PRIVATE_LINK_ENABLED = 'false' }
# azd's output is captured to classify failures, which would also hide any question azd asked, so azd
# always runs with --no-prompt. These are the errors it reports when it needed an answer instead; the
# command is then rerun attached to the terminal so the question can be answered there.
$azdNeedsInput = 'prompting (for|to) |interactive mode required|missing required inputs|no default response'
# Azure Cloud Shell sets ACC_CLOUD in every shell, and AZUREPS_HOST_ENVIRONMENT in PowerShell.
$inCloudShell = [bool]$env:ACC_CLOUD -or "$env:AZUREPS_HOST_ENVIRONMENT" -like 'cloud-shell*'

$subscriptionIds = @(
    $TargetSubscriptionId |
        Where-Object { $null -ne $_ } |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique
)
foreach ($subscription in $subscriptionIds) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($subscription, [ref] $parsed)) {
        throw "'$subscription' is not a subscription ID. Pass GUIDs, separated by commas."
    }
}
if ($SubscriptionId) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($SubscriptionId, [ref] $parsed)) { throw "-SubscriptionId '$SubscriptionId' is not a subscription ID." }
}

if ($PlanOnly) {
    [pscustomobject]@{
        environment = $EnvironmentName
        hosting = 'aks'
        repository = @{ url = $RepoUrl; branch = $RepoBranch; directory = $RepoDirectory }
        settings = $settings
        deploymentSubscription = $SubscriptionId
        preview = -not $SkipPreview
        enableProcessor = -not $SkipProcessor
        operatorMode = [bool] $OperatorMode
        ingressVisibility = $(if ($PSBoundParameters.ContainsKey('IngressVisibility')) { $IngressVisibility } else { '' })
        bootstrapIdentity = -not ($SkipIdentityBootstrap -or $OperatorMode)
        roleAssignments = -not $SkipRoleAssignments
        serviceManagementReference = $ServiceManagementReference
        assessedSubscriptions = $subscriptionIds
        maxAttempts = $MaxAttempts
        settleSeconds = $SettleSeconds
    } | ConvertTo-Json -Depth 5
    exit 0
}

# Resolved from the signed-in Azure CLI account when -SubscriptionId is omitted. Every az lookup
# below is pinned to it, so the helper never reads a different subscription's resource group.
$deploymentSubscription = $SubscriptionId

function Write-Step {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-CliText {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ((@($Value | Where-Object { $null -ne $_ }) -join "`n")).Trim()
}

function Wait-Settle {
    param([Parameter(Mandatory)][string] $Reason)
    if ($SettleSeconds -le 0) { return }
    Write-Host "Waiting $SettleSeconds seconds - $Reason." -ForegroundColor DarkGray
    Start-Sleep -Seconds $SettleSeconds
}

function Get-AzdValue {
    param([Parameter(Mandatory)][string] $Name)
    $value = & azd env get-value --environment $EnvironmentName $Name --no-prompt 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    $text = Get-CliText $value
    # azd prints the literal string "ERROR: ..." for keys the environment has never held.
    if ($text -like 'ERROR:*') { return '' }
    return $text
}

function Set-AzdValue {
    param([Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][AllowEmptyString()][string] $Value)
    & azd env set --environment $EnvironmentName $Name $Value --no-prompt | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Unable to set $Name in azd environment '$EnvironmentName'." }
}

function Get-ResourceGroupName {
    $resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
    if (-not $resourceGroup) { $resourceGroup = "rg-$EnvironmentName" }
    return $resourceGroup
}

function Get-SubscriptionArgument {
    if ($deploymentSubscription) { return @('--subscription', $deploymentSubscription) }
    return @()
}

function Read-YesNo {
    param([Parameter(Mandatory)][string] $Question, [Parameter(Mandatory)][string] $Refusal)
    try {
        $answer = "$(Read-Host "$Question [Y/n]")".Trim()
    } catch {
        throw $Refusal
    }
    return (-not $answer -or $answer -match '^(y|yes)$')
}

function Resolve-KubernetesTools {
    # azd applies the manifests with kubectl and signs in to the Entra-only cluster through kubelogin.
    $suffix = if ($IsWindows) { '.exe' } else { '' }
    $kubectlPath = Join-Path (Join-Path $KubernetesToolsDirectory '.azure-kubectl') "kubectl$suffix"
    $kubeloginPath = Join-Path (Join-Path $KubernetesToolsDirectory '.azure-kubelogin') "kubelogin$suffix"
    $directories = @((Split-Path -Parent $kubectlPath), (Split-Path -Parent $kubeloginPath))
    $separator = [System.IO.Path]::PathSeparator
    function Test-Missing { @('kubectl', 'kubelogin' | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }) }
    function Add-ToolPath {
        # Only for this run and the azd/hook processes it starts; Set-ToolPathHint covers everything after it.
        foreach ($directory in $directories) {
            if ((Test-Path -LiteralPath $directory) -and ($env:PATH -split [regex]::Escape($separator)) -notcontains $directory) {
                $env:PATH = "$directory$separator$env:PATH"
            }
        }
    }
    function Set-ToolPathHint {
        # azd looks kubectl and kubelogin up on PATH, so after this run a plain `azd deploy` would report kubectl
        # as not installed. az aks install-cli's own PATH advice is a warning, which --only-show-errors hides.
        $quoted = ($directories -join $separator).Replace("'", "''")
        $lines = @(
            "kubectl and kubelogin are in $($directories -join ' and '). Those folders aren't on your PATH, so this run added them for itself only."
            'Before running azd yourself (for example azd deploy after a code change), put them on PATH in that terminal:'
            "    `$env:PATH = '$quoted$separator' + `$env:PATH"
        )
        if ($IsWindows) {
            $lines += 'or add them to your user PATH once and open a new terminal (not with setx, which cuts a long PATH off at 1,024 characters):'
            $lines += "    [Environment]::SetEnvironmentVariable('Path', ([Environment]::GetEnvironmentVariable('Path', 'User') + ';$quoted').Trim(';'), 'User')"
        } else {
            $lines += 'or add this line to your shell profile:'
            $lines += "    export PATH=`"$($directories -join ':'):`$PATH`""
        }
        $script:kubernetesToolsPathHint = $lines -join [Environment]::NewLine
    }

    $missing = @(Test-Missing)
    if (-not $missing.Count) { return }
    Add-ToolPath
    $missing = @(Test-Missing)
    if (-not $missing.Count) {
        Write-Host 'Using kubectl and kubelogin from an earlier az aks install-cli.'
        Set-ToolPathHint
        return
    }
    if (-not $InstallKubernetesTools) {
        $install = Read-YesNo -Question "$($missing -join ' and ') not found. Install kubectl and kubelogin now with 'az aks install-cli'?" `
            -Refusal "$($missing -join ' and ') not found. Install them with 'az aks install-cli', or rerun with -InstallKubernetesTools."
        if (-not $install) { throw "$($missing -join ' and ') are required. Install them with 'az aks install-cli', then rerun." }
    }
    Write-Host 'Installing kubectl and kubelogin (az aks install-cli)...'
    # Not piped, so the download progress reaches the terminal as az prints it.
    & az aks install-cli --install-location $kubectlPath --kubelogin-install-location $kubeloginPath --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'az aks install-cli failed. Install kubectl and kubelogin manually, then rerun.' }
    Add-ToolPath
    $missing = @(Test-Missing)
    if ($missing.Count) { throw "$($missing -join ' and ') still cannot be found after installation." }
    Set-ToolPathHint
}

function Invoke-AzdCaptured {
    # Echoes azd's output and returns it, so failures can be classified. A question asked into captured
    # output would never be seen, so azd may not ask one here.
    param([Parameter(Mandatory)][string[]] $Arguments)
    $lines = [System.Collections.Generic.List[string]]::new()
    & azd @Arguments --environment $EnvironmentName --no-prompt 2>&1 | ForEach-Object {
        $line = $_.ToString()
        $lines.Add($line)
        Write-Host $line
    }
    return ($lines -join "`n")
}

function Invoke-AzdInTerminal {
    # Reruns an azd command that stopped because it needed an answer, attached to this terminal so its
    # question is shown and can be answered here. Call it as a statement: capturing its output would
    # hide the question again.
    param([Parameter(Mandatory)][string[]] $Arguments)
    Write-Host ''
    Write-Host "azd needs an answer to continue. Running 'azd $($Arguments -join ' ')' in this terminal - answer its question below." -ForegroundColor Yellow
    & azd @Arguments --environment $EnvironmentName
}

function Invoke-Azd {
    param([Parameter(Mandatory)][string[]] $Arguments, [Parameter(Mandatory)][string] $Reason)
    $command = "azd $($Arguments -join ' ')"
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Step "$command - $Reason (attempt $attempt of $MaxAttempts)"
        Write-Host 'This can take a while - creating a new AKS cluster alone takes 10-15 minutes; azd reports each step as it finishes.' -ForegroundColor DarkGray
        $text = Invoke-AzdCaptured $Arguments
        if ($LASTEXITCODE -eq 0) { return }
        if ($text -match $azdNeedsInput) {
            Invoke-AzdInTerminal $Arguments
            if ($LASTEXITCODE -eq 0) { return }
        }
        if ($text -match 'Error acquiring the state lock') {
            throw "Terraform's local state is still locked by an earlier run that was interrupted. Make sure no other azd run is active, delete .azure/$EnvironmentName/infra/.terraform.tfstate.lock.info, then rerun this script."
        }
        if ($attempt -eq $MaxAttempts) {
            throw "$command failed after $attempt attempt(s) while trying to $Reason. Review the output above; rerunning this script resumes from here."
        }
        if ($text -match 'Forbidden|AuthorizationFailed|does not have (authorization|access)|cannot (create|get|list|patch)') {
            Write-Warning 'A new role assignment had not reached Azure or the cluster yet. Retrying after a wait.'
        } elseif ($text -match 'AnotherOperationInProgress|OperationNotAllowed|AccountProvisioningStateInvalid|Another operation is in progress|RequestConflict|Conflict') {
            Write-Warning 'Azure was still finishing an earlier operation on the same resource. Retrying after a wait.'
        } elseif ($text -match 'context deadline exceeded|timed out|TLS handshake timeout|connection reset|i/o timeout') {
            Write-Warning 'A call timed out. Retrying after a wait.'
        } else {
            Write-Warning "$command failed. Waiting before the next attempt."
        }
        Wait-Settle "$command failed, retrying ($($attempt + 1) of $MaxAttempts)"
    }
}

function Get-WebEndpointUrl {
    $url = Get-AzdValue 'APP_WEB_ORIGIN'
    if ($url) { return $url.TrimEnd('/') }
    return ''
}

function Wait-AppHealthy {
    # Let's Encrypt usually issues the certificate a minute or two after the first deployment; until then
    # the ingress serves a self-signed certificate and the HTTPS check fails.
    param([Parameter(Mandatory)][string] $Url)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = ''
    while ($true) {
        try {
            $health = Invoke-WebRequest -Uri "$Url/api/health" -UseBasicParsing -TimeoutSec 30
            if ($health.StatusCode -eq 200) { return $true }
            $lastError = "HTTP $($health.StatusCode)"
        } catch {
            $lastError = $_.Exception.Message
        }
        if ($clock.Elapsed.TotalSeconds -ge $HealthTimeoutSeconds) {
            Write-Warning "$Url/api/health is not healthy yet ($lastError). The TLS certificate may still be issuing: check 'kubectl get certificate --namespace cloudlens'."
            return $false
        }
        Write-Host "  Waiting for $Url to answer over HTTPS ($([int]$clock.Elapsed.TotalSeconds)s so far, up to $HealthTimeoutSeconds)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    }
}

function Get-RoleAssignmentSnapshot {
    param([Parameter(Mandatory)][string] $Scope)
    $json = Get-CliText (& az role assignment list --scope $Scope --query "[].{principalId:principalId,role:roleDefinitionName}" --output json --only-show-errors 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $null }
    try { return @($json | ConvertFrom-Json) } catch { return $null }
}

function Add-RoleAssignment {
    param(
        [Parameter(Mandatory)][string] $PrincipalId,
        [Parameter(Mandatory)][string] $Role,
        [Parameter(Mandatory)][string] $Scope,
        $Existing
    )
    if ($null -ne $Existing -and @($Existing | Where-Object { $_.principalId -eq $PrincipalId -and $_.role -eq $Role }).Count) {
        Write-Host "  already assigned: $Role -> $PrincipalId" -ForegroundColor DarkGray
        return $true
    }
    $output = & az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type ServicePrincipal --role $Role --scope $Scope --only-show-errors --output none 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  assigned: $Role -> $PrincipalId" -ForegroundColor Green
        return $true
    }
    $text = Get-CliText $output
    if ($text -match 'RoleAssignmentExists') {
        Write-Host "  already assigned: $Role -> $PrincipalId" -ForegroundColor DarkGray
        return $true
    }
    Write-Warning "Could not assign '$Role' on $Scope to $PrincipalId. $text"
    return $false
}

function Read-ServiceTreeId {
    # Some tenants (Microsoft's among them) refuse new app registrations without a Service Tree ID.
    # The ID the signed-in user's own registrations already carry is offered, so Enter accepts it.
    $used = @((Get-CliText (& az ad app list --show-mine --query '[?serviceManagementReference].serviceManagementReference' --output tsv --only-show-errors 2>$null)) -split "`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $suggested = ''
    if ($used.Count) { $suggested = (@($used | Group-Object -NoElement | Sort-Object Count -Descending))[0].Name }
    Write-Host ''
    Write-Host 'This tenant requires a Service Tree ID (serviceManagementReference) on new app registrations.' -ForegroundColor Yellow
    if ($suggested) { Write-Host "Your existing app registrations use $suggested - press Enter to use it." }
    $prompt = if ($suggested) { "Service Tree ID [$suggested]" } else { 'Service Tree ID' }
    for ($try = 1; $try -le 3; $try++) {
        try {
            $answer = "$(Read-Host $prompt)".Trim()
        } catch {
            throw 'This tenant requires a Service Tree ID for the sign-in app registrations, and this session cannot ask for one. Rerun with -ServiceManagementReference <id>.'
        }
        if (-not $answer) { $answer = $suggested }
        $parsed = [guid]::Empty
        if ([guid]::TryParse($answer, [ref] $parsed)) { return $parsed.ToString() }
        Write-Warning "'$answer' is not a Service Tree ID. It is a GUID, for example 00000000-0000-0000-0000-000000000000."
    }
    throw 'No valid Service Tree ID was entered. Rerun with -ServiceManagementReference <id>.'
}

# ---------------------------------------------------------------------------
# 1. Prerequisites and repository
# ---------------------------------------------------------------------------
Write-Step 'Checking prerequisites'
foreach ($tool in @('git', 'azd', 'az')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' is required and was not found on PATH." }
}
if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw "'terraform' (1.11 or later) is required: azd provisions this app with Terraform. Install it (for example 'winget install Hashicorp.Terraform'), then rerun."
}
Write-Host 'git, azd, az and terraform are available.'
if ($inCloudShell) {
    Write-Warning 'Azure Cloud Shell ends a session after 20 minutes without keyboard input, and a first deployment takes 30-45 minutes: interact with this tab now and then, and if the session ends, rerun this command. azd keeps the Terraform state under your home directory, so use a Cloud Shell session with storage, not an ephemeral one.'
}

$repoRoot = $RepoDirectory
if (-not $repoRoot) {
    $checkout = Split-Path -Parent $PSScriptRoot
    if (Test-Path -LiteralPath (Join-Path $checkout 'azure.yaml')) {
        $repoRoot = $checkout
    } else {
        $repoRoot = Join-Path (Get-Location).Path ([System.IO.Path]::GetFileNameWithoutExtension($RepoUrl))
    }
}
if (Test-Path -LiteralPath (Join-Path $repoRoot 'azure.yaml')) {
    Write-Host "Using the existing checkout at $repoRoot."
} else {
    if ((Test-Path -LiteralPath $repoRoot) -and @(Get-ChildItem -LiteralPath $repoRoot -Force).Count -gt 0) {
        throw "'$repoRoot' already exists, is not empty, and is not a checkout of $RepoUrl."
    }
    Write-Step "Cloning the $RepoBranch branch of $RepoUrl into $repoRoot"
    & git clone --branch $RepoBranch $RepoUrl $repoRoot
    if ($LASTEXITCODE -ne 0) { throw "git clone of $RepoUrl ($RepoBranch) failed." }
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'azure.yaml'))) {
        throw "$RepoUrl was cloned but contains no azure.yaml, so azd cannot deploy it."
    }
}
$repoRoot = (Resolve-Path -LiteralPath $repoRoot).Path

$deployed = $null
# A missing az extension would otherwise be offered through a yes/no question that the captured az
# calls below never show, so it installs without asking for the duration of the run.
$previousDynamicInstall = $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'yes_without_prompt'
$previousPath = $env:PATH
# Set when kubectl and kubelogin had to be put on PATH for this run; shown now and again after the summary.
$kubernetesToolsPathHint = ''
Push-Location -LiteralPath $repoRoot
try {
    Resolve-KubernetesTools
    Write-Host 'kubectl and kubelogin are available.'
    if ($kubernetesToolsPathHint) { Write-Host $kubernetesToolsPathHint -ForegroundColor Yellow }

    # -----------------------------------------------------------------------
    # 2. Sign in
    # -----------------------------------------------------------------------
    if ($SkipLogin) {
        Write-Step 'Skipping sign-in (-SkipLogin)'
    } else {
        Write-Step 'Signing in'
        & azd auth login --check-status | Out-Null
        if ($LASTEXITCODE -ne 0) {
            # Not piped: the sign-in instructions must reach the terminal as azd prints them.
            & azd auth login
            if ($LASTEXITCODE -ne 0) { throw 'azd auth login failed.' }
        }
        # Terraform authenticates through the Azure CLI, not azd's token cache.
        & az account show --output none --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) {
            & az login --output none --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
        }
        Write-Host 'Signed in to azd and az.'
    }

    if (-not $deploymentSubscription) {
        $deploymentSubscription = Get-CliText (& az account show --query id --output tsv --only-show-errors 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $deploymentSubscription) {
            throw 'Unable to determine which subscription to deploy into. Sign in with `az login`, or pass -SubscriptionId.'
        }
    }
    $subscriptionName = Get-CliText (& az account show --subscription $deploymentSubscription --query name --output tsv --only-show-errors 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "The signed-in account cannot access subscription $deploymentSubscription." }
    Write-Host "Deploying into subscription $deploymentSubscription ($subscriptionName)."

    # -----------------------------------------------------------------------
    # 3. Environment and settings
    # -----------------------------------------------------------------------
    Write-Step "Preparing azd environment '$EnvironmentName'"
    $environmentList = Get-CliText (& azd env list --output json --no-prompt 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to list azd environments.' }
    $environments = @()
    if (-not [string]::IsNullOrWhiteSpace($environmentList)) { $environments = @($environmentList | ConvertFrom-Json) }
    $environmentExists = @($environments | Where-Object {
        $null -ne $_ -and $null -ne $_.PSObject.Properties['Name'] -and $_.Name -eq $EnvironmentName
    }).Count -gt 0
    if ($environmentExists) {
        & azd env select $EnvironmentName --no-prompt | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Unable to select azd environment '$EnvironmentName'." }
        Write-Host "Reusing the existing environment '$EnvironmentName'."
    } else {
        # Without --no-prompt azd asks whether the new environment should become the default, and that
        # question never reaches the terminal through the pipe. It becomes the default either way, the
        # same as selecting an existing one.
        & azd env new $EnvironmentName --location $Location --subscription $deploymentSubscription --no-prompt | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Unable to create azd environment '$EnvironmentName'." }
    }
    # azd otherwise stops mid-deployment to prompt for these interactively, which strands an
    # unattended run; setting them explicitly keeps every later azd call non-interactive.
    Set-AzdValue 'AZURE_SUBSCRIPTION_ID' $deploymentSubscription
    Write-Host '  AZURE_SUBSCRIPTION_ID set.'

    # Ingress visibility: an explicit choice wins, otherwise the environment keeps what it has, and a new one is private.
    # An environment that already has a public address is never switched without being asked: going private removes the
    # address and its cloudapp.azure.com name, so the app's host name (and its sign-in redirect URI) changes.
    $storedVisibility = Get-AzdValue 'APP_INGRESS_VISIBILITY'
    $hadPublicAddress = [bool](Get-AzdValue 'APP_INGRESS_PUBLIC_IP')
    $previousVisibility = if ($storedVisibility) { $storedVisibility } elseif ($hadPublicAddress) { 'public' } else { '' }
    if ($PSBoundParameters.ContainsKey('IngressVisibility')) {
        $visibility = $IngressVisibility
    } elseif ($storedVisibility) {
        $visibility = $storedVisibility
    } elseif ($hadPublicAddress) {
        throw "Environment '$EnvironmentName' already has a public address, and the app is private by default now. Say which you want: -IngressVisibility public keeps the internet-facing address as it is; -IngressVisibility private removes it (the app's host name and its sign-in redirect URI change) and serves the app privately."
    } else {
        $visibility = 'private'
    }
    $settings.APP_INGRESS_VISIBILITY = $visibility
    if ($previousVisibility -and $previousVisibility -ne $visibility) {
        Write-Warning "Switching '$EnvironmentName' from a $previousVisibility to a $visibility ingress. Settings that only make sense for the old one are reset unless you passed them again."
        if (-not $PSBoundParameters.ContainsKey('TlsClusterIssuer')) { $settings.APP_TLS_CLUSTER_ISSUER = '' }
        if ($visibility -eq 'private' -and -not $PSBoundParameters.ContainsKey('AllowedIpRanges')) { $settings.APP_WEB_ALLOWED_IP_RANGES = '' }
        if ($visibility -eq 'private' -and -not $OperatorMode -and -not $SkipIdentityBootstrap) {
            Write-Warning "The sign-in registrations still list the old host as a redirect URI, and bootstrap-identity.ps1 refuses to replace it silently. Remove the old SPA redirect URI in the Entra admin center (or delete the registrations $EnvironmentName-api and $EnvironmentName-web-spa) before the sign-in step."
        }
    }
    if ($visibility -eq 'private' -and $settings.Contains('APP_WEB_ALLOWED_IP_RANGES') -and $settings.APP_WEB_ALLOWED_IP_RANGES) {
        throw '-AllowedIpRanges limits who can reach a public ingress; this environment is private. Drop it, or use -IngressVisibility public.'
    }
    if ($visibility -eq 'private' -and $settings.Contains('APP_TLS_CLUSTER_ISSUER') -and $settings.APP_TLS_CLUSTER_ISSUER -like 'letsencrypt*') {
        throw "-TlsClusterIssuer $($settings.APP_TLS_CLUSTER_ISSUER) validates the host over the public internet, which a private ingress does not accept. Use private-ca or byo, or -IngressVisibility public."
    }
    Write-Host "Ingress: $visibility."
    if ($OperatorMode) {
        # Every request will act as this user, so the API authorizes against their own object ID.
        $operatorJson = Get-CliText (& az ad signed-in-user show --query '{id:id,upn:userPrincipalName}' --output json --only-show-errors 2>$null)
        $operatorId = ''
        $operatorUpn = ''
        if ($LASTEXITCODE -eq 0 -and $operatorJson) {
            try {
                $operatorAccount = $operatorJson | ConvertFrom-Json -AsHashtable
                if ($operatorAccount -is [System.Collections.IDictionary]) {
                    $operatorId = "$($operatorAccount['id'])"
                    $operatorUpn = "$($operatorAccount['upn'])".Trim()
                }
            } catch {
                $operatorId = ''
            }
        }
        $operatorObjectId = [guid]::Empty
        if (-not [guid]::TryParse($operatorId, [ref] $operatorObjectId) -or $operatorObjectId -eq [guid]::Empty) {
            throw "-OperatorMode acts as the signed-in Azure CLI user, but 'az ad signed-in-user show' returned no user object ID. Sign in to az with your own user account (not a service principal), then rerun."
        }
        $settings.MEGHKOSHA_OPERATOR_OBJECT_ID = $operatorObjectId.ToString()
        $settings.MEGHKOSHA_OPERATOR_UPN = $operatorUpn
        Write-Host "Operator mode (Dev only): Entra sign-in is off and every request acts as $(if ($operatorUpn) { $operatorUpn } else { $settings.MEGHKOSHA_OPERATOR_OBJECT_ID })." -ForegroundColor Yellow
    }
    foreach ($entry in $settings.GetEnumerator()) {
        Set-AzdValue $entry.Key $entry.Value
        Write-Host "  $($entry.Key) set."
    }

    # -----------------------------------------------------------------------
    # 4. Provision and deploy
    # -----------------------------------------------------------------------
    if ($SkipPreview) {
        Write-Step 'Skipping the infrastructure preview (-SkipPreview)'
    } else {
        Write-Step 'Previewing the infrastructure (azd provision --preview runs terraform plan)'
        $previewText = Invoke-AzdCaptured @('provision', '--preview')
        if ($LASTEXITCODE -ne 0 -and $previewText -match $azdNeedsInput) { Invoke-AzdInTerminal @('provision', '--preview') }
        if ($LASTEXITCODE -ne 0) { throw 'Infrastructure preview failed. Nothing was deployed.' }
    }

    Invoke-Azd @('up') 'provision the cluster and deploy both services'

    Write-Step 'Verifying the deployment'
    $apiImage = Get-AzdValue 'SERVICE_API_IMAGE_NAME'
    $webImage = Get-AzdValue 'SERVICE_WEB_IMAGE_NAME'
    Write-Host "AKS cluster            = $(Get-AzdValue 'AZURE_AKS_CLUSTER_NAME')"
    Write-Host "SERVICE_API_IMAGE_NAME = $(if ($apiImage) { $apiImage } else { '<not set>' })"
    Write-Host "SERVICE_WEB_IMAGE_NAME = $(if ($webImage) { $webImage } else { '<not set>' })"
    if (-not $apiImage -or -not $webImage) {
        throw 'azd did not publish both container images. Review the azd output above, then rerun this script.'
    }
    if ($SkipProcessor) {
        Write-Host 'Scheduled processor: left as configured (-SkipProcessor).'
    } else {
        Write-Host "Scheduled processor: $(if ((Get-AzdValue 'APP_PROCESSOR_DEPLOYED') -eq 'true') { 'active (CronJob processor, every 5 minutes)' } else { 'suspended' })"
    }

    # -----------------------------------------------------------------------
    # 5. Sign-in registrations
    # -----------------------------------------------------------------------
    if ($OperatorMode) {
        Write-Step 'Skipping the Entra ID sign-in bootstrap (-OperatorMode has no sign-in)'
    } elseif ($SkipIdentityBootstrap) {
        Write-Step 'Skipping the Entra ID sign-in bootstrap (-SkipIdentityBootstrap)'
    } else {
        Write-Step 'Configuring sign-in (scripts/bootstrap-identity.ps1)'
        $bootstrap = Join-Path $repoRoot 'scripts/bootstrap-identity.ps1'
        if (-not (Test-Path -LiteralPath $bootstrap)) { throw "bootstrap-identity.ps1 was not found under $repoRoot." }
        $tenantId = Get-AzdValue 'AZURE_TENANT_ID'
        $subscriptionId = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
        $azdEnvName = Get-AzdValue 'AZURE_ENV_NAME'
        if (-not $azdEnvName) { $azdEnvName = $EnvironmentName }
        $webOrigin = Get-AzdValue 'APP_WEB_ORIGIN'
        $oboIdentityId = Get-AzdValue 'MEGHKOSHA_OBO_MANAGED_IDENTITY_RESOURCE_ID'
        foreach ($required in @(
            @{ Name = 'AZURE_TENANT_ID'; Value = $tenantId },
            @{ Name = 'AZURE_SUBSCRIPTION_ID'; Value = $subscriptionId },
            @{ Name = 'APP_WEB_ORIGIN'; Value = $webOrigin },
            @{ Name = 'MEGHKOSHA_OBO_MANAGED_IDENTITY_RESOURCE_ID'; Value = $oboIdentityId })) {
            if (-not $required.Value) { throw "$($required.Name) is not available from the azd environment yet, so sign-in cannot be configured." }
        }

        $parameters = @{
            TenantId = $tenantId
            SubscriptionId = $subscriptionId
            EnvironmentName = $azdEnvName
            WebOrigin = $webOrigin
            OboManagedIdentityResourceId = $oboIdentityId
            Apply = $true
            Confirm = $false
        }
        if ($IncludeLocalhostRedirects) { $parameters.IncludeLocalhostRedirects = $true }
        if ($GrantAdminConsent) { $parameters.GrantAdminConsent = $true }

        $serviceTreeId = if ($ServiceManagementReference) { $ServiceManagementReference } else { Get-AzdValue 'APP_SERVICE_MANAGEMENT_REFERENCE' }
        $hadApproval = Test-Path Env:APP_ALLOW_AZURE_CHANGES
        $previousApproval = [Environment]::GetEnvironmentVariable('APP_ALLOW_AZURE_CHANGES', 'Process')
        try {
            $env:APP_ALLOW_AZURE_CHANGES = 'true'
            for ($pass = 1; $pass -le 2; $pass++) {
                if ($serviceTreeId) { $parameters.ServiceManagementReference = $serviceTreeId }
                try {
                    $bootstrapOutput = & $bootstrap @parameters
                    break
                } catch {
                    # A missing Service Tree ID is the one refusal the operator can answer here.
                    if ($pass -eq 2 -or $serviceTreeId -or "$($_.Exception.Message) $_" -notmatch 'serviceManagementReference') { throw }
                    $serviceTreeId = Read-ServiceTreeId
                }
            }
        } finally {
            if ($hadApproval) { [Environment]::SetEnvironmentVariable('APP_ALLOW_AZURE_CHANGES', $previousApproval, 'Process') }
            else { Remove-Item Env:APP_ALLOW_AZURE_CHANGES -ErrorAction SilentlyContinue }
        }
        if ($serviceTreeId) { Set-AzdValue 'APP_SERVICE_MANAGEMENT_REFERENCE' $serviceTreeId }
        $identity = Get-CliText $bootstrapOutput | ConvertFrom-Json -AsHashtable
        if ($null -eq $identity -or -not $identity.ContainsKey('MEGHKOSHA_API_CLIENT_ID') -or -not $identity.ContainsKey('MEGHKOSHA_WEB_CLIENT_ID')) {
            throw 'bootstrap-identity.ps1 did not report the API and SPA client IDs.'
        }
        $apiClientId = $identity['MEGHKOSHA_API_CLIENT_ID']
        $webClientId = $identity['MEGHKOSHA_WEB_CLIENT_ID']
        Write-Host "API client ID: $apiClientId"
        Write-Host "Web client ID: $webClientId"

        $currentApiClientId = Get-AzdValue 'MEGHKOSHA_API_CLIENT_ID'
        $currentWebClientId = Get-AzdValue 'MEGHKOSHA_WEB_CLIENT_ID'
        Set-AzdValue 'MEGHKOSHA_API_CLIENT_ID' $apiClientId
        Set-AzdValue 'MEGHKOSHA_WEB_CLIENT_ID' $webClientId
        if ($currentApiClientId -ne $apiClientId -or $currentWebClientId -ne $webClientId) {
            # The client IDs only feed the pods' environment, so redeploying the services is enough.
            Invoke-Azd @('deploy') 'roll out the sign-in configuration'
        } else {
            Write-Host 'The deployment already carries these client IDs; no redeploy needed.'
        }
    }

    # -----------------------------------------------------------------------
    # 6. Subscription role assignments
    # -----------------------------------------------------------------------
    $grantedSubscriptions = @()
    if ($SkipRoleAssignments) {
        Write-Step 'Skipping the subscription role assignments (-SkipRoleAssignments)'
    } else {
        Write-Step 'Granting access to the subscriptions to assess'
        $resourceGroup = Get-ResourceGroupName
        $subscriptionArgs = Get-SubscriptionArgument
        & az identity list -g $resourceGroup @subscriptionArgs --query "[].{name:name, principalId:principalId}" --output table --only-show-errors | Out-Host
        $apiPrincipalId = Get-CliText (& az identity list -g $resourceGroup @subscriptionArgs --query "[?starts_with(name,'id-api-')].principalId | [0]" --output tsv --only-show-errors 2>$null)
        $processorPrincipalId = Get-CliText (& az identity list -g $resourceGroup @subscriptionArgs --query "[?starts_with(name,'id-processor-')].principalId | [0]" --output tsv --only-show-errors 2>$null)
        if (-not $apiPrincipalId) { throw "No id-api-* managed identity was found in $resourceGroup, so its subscription access cannot be granted." }
        if (-not $processorPrincipalId -and -not $SkipProcessor) {
            throw "No id-processor-* managed identity was found in $resourceGroup. Rerun after the data/ai profile is provisioned, or pass -SkipProcessor."
        }

        $targets = $subscriptionIds
        if (-not $targets.Count) {
            Write-Warning "No -TargetSubscriptionId was supplied; granting access to the deployment subscription $deploymentSubscription only."
            $targets = @($deploymentSubscription)
        }

        $failures = @()
        foreach ($subscription in $targets) {
            $scope = "/subscriptions/$subscription"
            Write-Host "Subscription $subscription" -ForegroundColor Cyan
            $existing = Get-RoleAssignmentSnapshot $scope
            $grants = @(
                @{ PrincipalId = $apiPrincipalId; Role = 'Reader' },
                @{ PrincipalId = $apiPrincipalId; Role = 'Cost Management Contributor' }
            )
            if ($processorPrincipalId) {
                $grants += @{ PrincipalId = $processorPrincipalId; Role = 'Cost Management Contributor' }
            }
            $granted = $true
            foreach ($grant in $grants) {
                if (-not (Add-RoleAssignment -PrincipalId $grant.PrincipalId -Role $grant.Role -Scope $scope -Existing $existing)) {
                    $granted = $false
                    $failures += "$($grant.Role) on $scope"
                }
            }
            if ($granted) { $grantedSubscriptions += $subscription }
        }
        if ($failures.Count) {
            throw "The deployment is live, but these role assignments failed and need an Owner or User Access Administrator on the target subscription: $($failures -join '; ')."
        }
        Write-Host 'Role assignments complete. Allow a few minutes for RBAC to propagate, then use Refresh schedules in the app.' -ForegroundColor Green
    }

    # -----------------------------------------------------------------------
    # 7. Summary
    # -----------------------------------------------------------------------
    Write-Step 'Deployment summary'
    $url = Get-WebEndpointUrl
    $privateIngress = $visibility -eq 'private'
    # Terraform reports the restriction only once the network has been changed to enforce it.
    $restricted = (Get-AzdValue 'APP_WEB_INGRESS_RESTRICTED') -eq 'true'
    $allowedIpRanges = if ($privateIngress) { '' } else { Get-AzdValue 'APP_WEB_ALLOWED_IP_RANGES' }
    $publicUrlOpen = -not $privateIngress -and (-not $OperatorMode -or $restricted)
    $healthy = $false
    if ($privateIngress) {
        Write-Host 'The ingress is private: it has no public address, so this machine can reach the app only from inside the network, and the HTTPS health check is skipped.' -ForegroundColor Yellow
    } elseif (-not $publicUrlOpen) {
        Write-Host 'Operator mode without an IP allow-list closes the public URL, so the HTTPS health check is skipped.' -ForegroundColor Yellow
    } elseif ($restricted -and $inCloudShell) {
        # Cloud Shell's address is not one to allow-list (other people's sessions share it), so the check could only time out.
        Write-Host "Cloud Shell's address is not on the IP allow-list, so the public URL is not checked from here. Open it from an allowed address." -ForegroundColor Yellow
    } elseif ($url) {
        $healthy = Wait-AppHealthy $url
        if (-not $healthy -and $restricted) {
            Write-Warning "The public URL answers only $allowedIpRanges. If this machine's address is not among them - on a VPN that carries Azure traffic the app sees the VPN's exit address - run scripts/allow-my-ip.ps1 -EnvironmentName $EnvironmentName, which checks for that."
        }
    }
    $deployed = [ordered]@{
        environment = $EnvironmentName
        subscription = $deploymentSubscription
        resourceGroup = Get-ResourceGroupName
        cluster = Get-AzdValue 'AZURE_AKS_CLUSTER_NAME'
        authMode = $settings.MEGHKOSHA_AUTH_MODE
        ingressVisibility = $visibility
        webUrl = $(if ($privateIngress -or $publicUrlOpen) { $url } else { '' })
        privateIp = $(if ($privateIngress) { Get-AzdValue 'APP_INGRESS_PRIVATE_IP' } else { '' })
        privateLinkServiceId = $(if ($privateIngress) { Get-AzdValue 'APP_PRIVATE_LINK_ID' } else { '' })
        tlsIssuer = Get-AzdValue 'APP_TLS_CLUSTER_ISSUER'
        allowedIpRanges = $(if ($restricted -and -not $privateIngress) { $allowedIpRanges } else { '' })
        portForward = $(if ($OperatorMode) { 'kubectl port-forward --namespace cloudlens service/web 8080:8080' } else { '' })
        healthy = $healthy
        apiImage = Get-AzdValue 'SERVICE_API_IMAGE_NAME'
        processorEnabled = (Get-AzdValue 'APP_PROCESSOR_DEPLOYED') -eq 'true'
        apiClientId = Get-AzdValue 'MEGHKOSHA_API_CLIENT_ID'
        webClientId = Get-AzdValue 'MEGHKOSHA_WEB_CLIENT_ID'
        assessedSubscriptions = @($grantedSubscriptions)
    }
} finally {
    Pop-Location
    $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = $previousDynamicInstall
    $env:PATH = $previousPath
}

$deployed | ConvertTo-Json -Depth 5
if ($deployed.ingressVisibility -eq 'private') {
    $appHost = $deployed.webUrl -replace '^https://', ''
    Write-Host ''
    Write-Host "Private ingress: the app has no public address. It is served at $($deployed.webUrl) on the private address $($deployed.privateIp)." -ForegroundColor Yellow
    Write-Host "  DNS         $appHost must resolve to that address for whoever opens the app. A private DNS zone of that name in the app's virtual network already does."
    Write-Host "              A peered, VPN or ExpressRoute network needs a record $appHost -> $($deployed.privateIp) in its own DNS."
    if ($deployed.privateLinkServiceId) {
        Write-Host "  Private Link  $($deployed.privateLinkServiceId)"
        Write-Host '              A private endpoint in any virtual network connects to it; that network needs a record for the host that points at the private endpoint''s address:'
        Write-Host "                az network private-endpoint create --resource-group <rg> --name pe-cloudlens --vnet-name <vnet> --subnet <subnet> --connection-name cloudlens --private-connection-resource-id $($deployed.privateLinkServiceId)"
        Write-Host '              Connections from the deployment subscription (and any in -PrivateLinkSubscriptionIds) are approved automatically; others wait for approval on the service.'
    }
    if ($deployed.tlsIssuer -eq 'private-ca') {
        Write-Host '  Certificate  Signed by a CA that lives in the cluster, so browsers must trust it. Export it, then install it on the machines that open the app:'
        Write-Host '                [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((kubectl get secret cloudlens-private-ca --namespace cert-manager --output jsonpath=''{.data.tls\.crt}''))) | Set-Content cloudlens-ca.crt'
        Write-Host '                certutil -addstore -f Root cloudlens-ca.crt        (Windows, as administrator)'
    } elseif ($deployed.tlsIssuer -eq 'byo') {
        Write-Host '  Certificate  Create the secret from your own CA, in the cloudlens namespace, or the ingress serves a placeholder certificate:'
        Write-Host '                kubectl create secret tls web-tls --namespace cloudlens --cert=<chain.pem> --key=<key.pem>'
    }
    Write-Host "  To test from a jump box inside a virtual network (a VM behind Bastion, nothing exposed): pwsh ./scripts/deploy-test-jumpbox.ps1 -EnvironmentName $($deployed.environment)"
}
if ($deployed.portForward) {
    if ($deployed.ingressVisibility -eq 'private') {
        Write-Host 'Operator mode has no sign-in. Besides the private address, kubectl can forward the web service:' -ForegroundColor Yellow
    } elseif ($deployed.webUrl) {
        Write-Host "Operator mode: open $($deployed.webUrl) from an allowed address ($($deployed.allowedIpRanges -replace ',', ', '))." -ForegroundColor Yellow
        Write-Host "When your IP address changes: pwsh ./scripts/allow-my-ip.ps1 -EnvironmentName $($deployed.environment)"
        Write-Host 'From any other address, connect to the cluster and forward the web service:'
    } else {
        Write-Host 'Operator mode: the public URL is closed. Connect to the cluster and forward the web service:' -ForegroundColor Yellow
    }
    Write-Host "    az aks get-credentials --resource-group $($deployed.resourceGroup) --name $($deployed.cluster) --subscription $($deployed.subscription)"
    Write-Host '    kubelogin convert-kubeconfig --login azurecli'
    Write-Host "    $($deployed.portForward)"
    Write-Host 'then open http://localhost:8080. Everyone who reaches the app acts as the operator.' -ForegroundColor Yellow
} elseif ($deployed.webUrl -and $deployed.ingressVisibility -ne 'private') { Write-Host "Open the app: $($deployed.webUrl)" -ForegroundColor Green }
if ($kubernetesToolsPathHint) {
    Write-Host ''
    Write-Host $kubernetesToolsPathHint -ForegroundColor Yellow
}
