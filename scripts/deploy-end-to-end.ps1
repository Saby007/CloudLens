<#
.SYNOPSIS
    Runs the entire CloudLens deployment - clone, azd provisioning, sign-in registrations, and
    the per-subscription role assignments - as a single self-contained script.

.DESCRIPTION
    This is the whole "Deploying to Azure" README flow in one file:

      1. Checks prerequisites and clones the repository (skipped when already run from a checkout).
      2. Signs in with `azd` and `az`.
      3. Creates the azd environment and applies the recommended `ai` profile settings.
      4. Previews the infrastructure, then runs `azd up` until the deployment settles, retrying
         the known transient Foundry/image-handoff/ACR conditions with a wait in between.
      5. Enables the scheduled export processor using the image azd built for the API.
      6. Runs scripts/bootstrap-identity.ps1, feeds the two client IDs back into the environment,
         and redeploys so the app gets a real Microsoft sign-in screen.
      7. Grants Reader / Cost Management Contributor on every subscription you want to assess.

    Every phase is idempotent and re-entrant: rerunning the script against an existing environment
    only repeats the `azd up` calls that still have work to do, so a failed run can simply be rerun.

    The run never waits on a question you cannot see. azd's output is captured so known transient
    errors can be recognised and retried, so every azd command runs with --no-prompt. Anything that
    genuinely needs an answer - a question azd asks, or the Service Tree ID some tenants require on
    app registrations - is asked in this terminal instead.

.PARAMETER EnvironmentName
    azd environment name. Lowercase letters, digits and hyphens only - it is also used to name the
    Entra ID app registrations created by scripts/bootstrap-identity.ps1.

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

.EXAMPLE
    pwsh ./scripts/deploy-end-to-end.ps1 -EnvironmentName my-environment -TargetSubscriptionId 'sub-a,sub-b'

.EXAMPLE
    # Standalone: downloads nothing else - clones the repository next to the current directory first.
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
    [string] $RepoUrl = 'https://github.com/Saby007/CloudLens.git',
    [string] $RepoDirectory = '',
    [ValidateRange(1, 10)]
    [int] $MaxAttempts = 3,
    [ValidateRange(0, 900)]
    [int] $SettleSeconds = 120,
    [switch] $SkipLogin,
    [switch] $SkipPreview,
    [switch] $SkipProcessor,
    [switch] $SkipIdentityBootstrap,
    [switch] $SkipRoleAssignments,
    [switch] $IncludeLocalhostRedirects,
    [switch] $GrantAdminConsent,
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
# azd's output is captured to classify failures, which would also hide any question azd asked, so azd
# always runs with --no-prompt. These are the errors it reports when it needed an answer instead; the
# command is then rerun attached to the terminal so the question can be answered there.
$azdNeedsInput = 'prompting (for|to) |interactive mode required|missing required inputs|no default response'

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
        repository = @{ url = $RepoUrl; directory = $RepoDirectory }
        settings = $settings
        deploymentSubscription = $SubscriptionId
        preview = -not $SkipPreview
        enableProcessor = -not $SkipProcessor
        bootstrapIdentity = -not $SkipIdentityBootstrap
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

function Test-FoundryAccountExists {
    $resourceGroup = Get-ResourceGroupName
    $subscriptionArgs = Get-SubscriptionArgument
    $accounts = Get-CliText (& az cognitiveservices account list --resource-group $resourceGroup @subscriptionArgs --query '[].name' --output tsv --only-show-errors 2>$null)
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($accounts))
}

function Test-ContainerAppsExist {
    $resourceGroup = Get-ResourceGroupName
    $subscriptionArgs = Get-SubscriptionArgument
    $names = Get-CliText (& az containerapp list --resource-group $resourceGroup @subscriptionArgs --query "[?starts_with(name,'ca-api-') || starts_with(name,'ca-web-')].name" --output tsv --only-show-errors 2>$null)
    if ($LASTEXITCODE -ne 0) { return $false }
    $found = @($names -split "`n" | Where-Object { $_ })
    return (@($found | Where-Object { $_.StartsWith('ca-api-') }).Count -gt 0 -and
            @($found | Where-Object { $_.StartsWith('ca-web-') }).Count -gt 0)
}

function Wait-ActiveDeployment {
    # ARM keeps executing the previous deployment graph after azd reports an error; retrying into
    # a still-running deployment fails with DeploymentActive.
    $resourceGroup = Get-ResourceGroupName
    $subscriptionArgs = Get-SubscriptionArgument
    for ($attempt = 1; $attempt -le 40; $attempt++) {
        $active = Get-CliText (& az deployment group list --resource-group $resourceGroup @subscriptionArgs --query "[?properties.provisioningState=='Running' || properties.provisioningState=='Accepted'].name" --output tsv --only-show-errors 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($active)) { return }
        if ($attempt % 4 -eq 1) {
            Write-Host "  Waiting for the earlier Azure deployment to finish ($(($attempt - 1) / 4) min so far, up to 10)..." -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 15
    }
    Write-Warning 'A previous deployment is still running on Azure; continuing anyway.'
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

function Invoke-AzdUp {
    param([Parameter(Mandatory)][string] $Reason)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Step "azd up - $Reason (attempt $attempt of $MaxAttempts)"
        Write-Host 'This can take several minutes; azd reports each resource as it finishes.' -ForegroundColor DarkGray
        $text = Invoke-AzdCaptured @('up')
        if ($LASTEXITCODE -eq 0) { return }
        if ($text -match $azdNeedsInput) {
            Invoke-AzdInTerminal @('up')
            if ($LASTEXITCODE -eq 0) { return }
        }
        if ($attempt -eq $MaxAttempts) {
            throw "azd up failed after $attempt attempt(s) while trying to $Reason. Review the output above; rerunning this script resumes from here."
        }
        if ($text -match 'AccountProvisioningStateInvalid|Another operation is in progress') {
            Write-Warning 'The AI Foundry account is still settling. Reusing the existing account on the retry.'
            Set-AzdValue 'APP_REUSE_AI_ACCOUNT' 'true'
        } elseif ($text -match "resource not found: unable to find a resource with name 'ca-(api|web)-") {
            Write-Warning 'The container images were published after infrastructure planning. Retrying so Bicep can create the Container Apps.'
        } elseif ($text -match 'unable to pull image using Managed identity') {
            Write-Warning 'The registry data plane has not picked up the new AcrPull assignment yet. Retrying after a wait.'
        } elseif ($text -match 'DeploymentActive') {
            Write-Warning 'A previous deployment operation was still finishing on Azure.'
        } else {
            Write-Warning 'azd up failed. Waiting before the next attempt.'
        }
        Wait-Settle "azd up failed, retrying ($($attempt + 1) of $MaxAttempts)"
        Wait-ActiveDeployment
    }
}

function Get-WebEndpointUrl {
    $url = Get-AzdValue 'SERVICE_WEB_ENDPOINT_URL'
    if ($url) { return $url.TrimEnd('/') }
    $resourceGroup = Get-ResourceGroupName
    $subscriptionArgs = Get-SubscriptionArgument
    $fqdn = Get-CliText (& az containerapp list --resource-group $resourceGroup @subscriptionArgs --query "[?starts_with(name,'ca-web-')].properties.configuration.ingress.fqdn | [0]" --output tsv --only-show-errors 2>$null)
    if ([string]::IsNullOrWhiteSpace($fqdn)) { return '' }
    return "https://$fqdn"
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
Write-Host 'git, azd and az are available.'

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
    Write-Step "Cloning $RepoUrl into $repoRoot"
    & git clone $RepoUrl $repoRoot
    if ($LASTEXITCODE -ne 0) { throw "git clone of $RepoUrl failed." }
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
Push-Location -LiteralPath $repoRoot
try {
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
    foreach ($entry in $settings.GetEnumerator()) {
        Set-AzdValue $entry.Key $entry.Value
        Write-Host "  $($entry.Key) set."
    }

    # An environment that already has a Foundry account must reference it instead of re-declaring
    # it, otherwise every azd up resets the account into Accepted and fails the dependent resources.
    if (Test-FoundryAccountExists) {
        Set-AzdValue 'APP_REUSE_AI_ACCOUNT' 'true'
        Write-Host '  APP_REUSE_AI_ACCOUNT set (an AI Foundry account already exists in the resource group).'
    }

    # -----------------------------------------------------------------------
    # 4. Provision and deploy
    # -----------------------------------------------------------------------
    if ($SkipPreview) {
        Write-Step 'Skipping the infrastructure preview (-SkipPreview)'
    } else {
        Write-Step 'Previewing the infrastructure (azd provision --preview)'
        $previewText = Invoke-AzdCaptured @('provision', '--preview')
        if ($LASTEXITCODE -ne 0 -and $previewText -match $azdNeedsInput) { Invoke-AzdInTerminal @('provision', '--preview') }
        if ($LASTEXITCODE -ne 0) { throw 'Infrastructure preview failed. Nothing was deployed.' }
    }

    Invoke-AzdUp 'provision infrastructure and publish the container images'
    Wait-Settle 'letting the first deployment settle'

    Set-AzdValue 'APP_REUSE_AI_ACCOUNT' 'true'
    Write-Host 'APP_REUSE_AI_ACCOUNT is now true, so later deployments reference the Foundry account instead of re-declaring it.'

    Write-Step 'Verifying the container image handoff'
    $apiImage = Get-AzdValue 'SERVICE_API_IMAGE_NAME'
    $webImage = Get-AzdValue 'SERVICE_WEB_IMAGE_NAME'
    Write-Host "SERVICE_API_IMAGE_NAME = $(if ($apiImage) { $apiImage } else { '<not set>' })"
    Write-Host "SERVICE_WEB_IMAGE_NAME = $(if ($webImage) { $webImage } else { '<not set>' })"
    if (-not $apiImage -or -not $webImage -or -not (Test-ContainerAppsExist)) {
        # The first pass builds the images in parallel with provisioning, so Bicep usually cannot
        # create ca-api-*/ca-web-* until a second pass sees the published image names.
        Invoke-AzdUp 'create the Container Apps from the published images'
        Wait-Settle 'letting the Container Apps settle'
        $apiImage = Get-AzdValue 'SERVICE_API_IMAGE_NAME'
        $webImage = Get-AzdValue 'SERVICE_WEB_IMAGE_NAME'
    }
    if (-not $apiImage -or -not $webImage) {
        throw 'azd did not publish both container images. Rerun this script once the remote build completes.'
    }

    # -----------------------------------------------------------------------
    # 5. Scheduled processor
    # -----------------------------------------------------------------------
    if ($SkipProcessor) {
        Write-Step 'Skipping the scheduled processor (-SkipProcessor)'
    } else {
        Write-Step 'Enabling the scheduled export processor'
        $processorEnabled = Get-AzdValue 'APP_ENABLE_PROCESSOR'
        $processorImage = Get-AzdValue 'SERVICE_PROCESSOR_IMAGE_NAME'
        Set-AzdValue 'APP_ENABLE_PROCESSOR' 'true'
        Set-AzdValue 'SERVICE_PROCESSOR_IMAGE_NAME' $apiImage
        Write-Host "The processor runs the API image: $apiImage"
        if ($processorEnabled -ne 'true' -or $processorImage -ne $apiImage) {
            Invoke-AzdUp 'deploy the scheduled processor'
            Wait-Settle 'letting the processor job settle'
        } else {
            Write-Host 'The processor is already deployed with this image; no redeploy needed.'
        }
    }

    # -----------------------------------------------------------------------
    # 6. Sign-in registrations
    # -----------------------------------------------------------------------
    if ($SkipIdentityBootstrap) {
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
            Invoke-AzdUp 'publish the sign-in configuration'
            Wait-Settle 'letting the sign-in configuration roll out'
        } else {
            Write-Host 'The deployment already carries these client IDs; no redeploy needed.'
        }
    }

    # -----------------------------------------------------------------------
    # 7. Subscription role assignments
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
            throw "No id-processor-* managed identity was found in $resourceGroup. Rerun after the processor deploys, or pass -SkipProcessor."
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
    # 8. Summary
    # -----------------------------------------------------------------------
    Write-Step 'Deployment summary'
    $url = Get-WebEndpointUrl
    if ($url) {
        try {
            $health = Invoke-WebRequest -Uri "$url/api/health" -UseBasicParsing -TimeoutSec 30
            if ($health.StatusCode -ne 200) { Write-Warning "The API health endpoint returned HTTP $($health.StatusCode)." }
        } catch {
            Write-Warning "The API health endpoint could not be reached yet: $($_.Exception.Message)"
        }
    }
    $deployed = [ordered]@{
        environment = $EnvironmentName
        subscription = $deploymentSubscription
        resourceGroup = Get-ResourceGroupName
        webUrl = $url
        apiImage = Get-AzdValue 'SERVICE_API_IMAGE_NAME'
        processorEnabled = (Get-AzdValue 'APP_ENABLE_PROCESSOR') -eq 'true'
        apiClientId = Get-AzdValue 'MEGHKOSHA_API_CLIENT_ID'
        webClientId = Get-AzdValue 'MEGHKOSHA_WEB_CLIENT_ID'
        assessedSubscriptions = @($grantedSubscriptions)
    }
} finally {
    Pop-Location
    $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = $previousDynamicInstall
}

$deployed | ConvertTo-Json -Depth 5
if ($deployed.webUrl) { Write-Host "Open the app: $($deployed.webUrl)" -ForegroundColor Green }
