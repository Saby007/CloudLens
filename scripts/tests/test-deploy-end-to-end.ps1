Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The helper behaves differently in Azure Cloud Shell; clear its markers so results never depend on where tests run.
$cloudShellMarkers = @{}
foreach ($name in 'ACC_CLOUD', 'AZUREPS_HOST_ENVIRONMENT') {
    $cloudShellMarkers[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}

$tenantId = '11111111-1111-1111-1111-111111111111'
$subscriptionId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$targetOne = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
$targetTwo = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
$environmentName = 'app-test'
$resourceGroup = "rg-$environmentName"
$apiPrincipalId = '22222222-2222-2222-2222-222222222222'
$processorPrincipalId = '33333333-3333-3333-3333-333333333333'
$apiClientId = '44444444-4444-4444-4444-444444444444'
$webClientId = '55555555-5555-5555-5555-555555555555'

$global:deployTestState = @{
    environments = @{}
    # Every azd provisioning/deployment call, as '<command>:<outcome>'.
    azdCalls = [System.Collections.Generic.List[string]]::new()
    previewCalls = 0
    authChecks = 0
    interactiveLogins = 0
    cloneCalls = 0
    failNextUp = 'Error: creating Kubernetes Cluster: AnotherOperationInProgress: Another operation (Update) is in progress'
    roleAssignments = [System.Collections.Generic.List[object]]::new()
    roleCreates = [System.Collections.Generic.List[object]]::new()
    bootstrapCalls = 0
    installCliCalls = [System.Collections.Generic.List[string]]::new()
    # azd calls made without --no-prompt (sign-in excepted); only the deliberate rerun in the terminal may appear.
    interactiveAzd = [System.Collections.Generic.List[string]]::new()
    needsAnswer = $false
    requireServiceTree = $false
    serviceTreeId = '88888888-8888-8888-8888-888888888888'
    serviceTreeIds = [System.Collections.Generic.List[string]]::new()
    answers = [System.Collections.Generic.List[string]]::new()
    questions = [System.Collections.Generic.List[string]]::new()
    # PowerShell resolves a function's unqualified variables through the runtime caller chain, so a
    # stub reading $subscriptionId would silently pick up the script's own -SubscriptionId parameter.
    # Every fixture the stubs need therefore lives here and is read through $global:deployTestState.
    tenantId = $tenantId
    subscriptionId = $subscriptionId
    environmentName = $environmentName
    resourceGroup = $resourceGroup
    apiPrincipalId = $apiPrincipalId
    processorPrincipalId = $processorPrincipalId
    operatorObjectId = '66666666-6666-6666-6666-666666666666'
    healthProbes = 0
    webOrigin = ''
}

function Get-StubArgument {
    param([string[]] $Arguments, [string] $Name)
    $index = [array]::IndexOf($Arguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $Arguments.Count) { return '' }
    return $Arguments[$index + 1]
}

function Start-Sleep { param([int] $Seconds) }

function Read-Host {
    param([string] $Prompt)
    $state = $global:deployTestState
    $state.questions.Add($Prompt)
    if (-not $state.answers.Count) { throw 'The helper asked a question the test did not expect.' }
    $answer = $state.answers[0]
    $state.answers.RemoveAt(0)
    return $answer
}

function Invoke-WebRequest {
    param($Uri, [switch] $UseBasicParsing, [int] $TimeoutSec)
    if ("$Uri" -ne 'https://web.example.test/api/health') { throw "Unexpected health probe: $Uri" }
    $global:deployTestState.healthProbes++
    return [pscustomobject]@{ StatusCode = 200 }
}

function git {
    $global:LASTEXITCODE = 0
    $global:deployTestState.cloneCalls++
    throw 'The test checkout already exists; cloning must be skipped.'
}

# Present on PATH as far as the helper can tell; the helper itself never runs them (azd and the hook do).
function terraform { throw 'The helper must leave Terraform to azd.' }
function Install-KubernetesToolStubs {
    Set-Item -Path function:global:kubectl -Value { throw 'The helper must leave kubectl to azd and the hook.' }
    Set-Item -Path function:global:kubelogin -Value { throw 'The helper must leave kubelogin to azd and the hook.' }
}
Install-KubernetesToolStubs

function azd {
    $raw = @($args)
    $global:LASTEXITCODE = 0
    $state = $global:deployTestState
    # The positional parsing below works on the arguments without the flag.
    $noPrompt = $raw -contains '--no-prompt'
    $a = @($raw | Where-Object { $_ -ne '--no-prompt' })
    if (-not $noPrompt -and -not ($a[0] -eq 'auth' -and $a[1] -eq 'login')) { $state.interactiveAzd.Add($a -join ' ') }
    $environment = Get-StubArgument $a '--environment'
    if ($a[0] -eq 'auth' -and $a[1] -eq 'login') {
        if ($a -contains '--check-status') {
            $state.authChecks++
            $global:LASTEXITCODE = 0
            return
        }
        $state.interactiveLogins++
        return
    }
    if ($a[0] -eq 'env') {
        switch ($a[1]) {
            'list' { return (ConvertTo-Json -InputObject @($state.environments.Keys | ForEach-Object { @{ Name = $_ } }) -Depth 3) }
            'new' {
                $name = $a[2]
                if ((Get-StubArgument $a '--subscription') -ne $state.subscriptionId -or (Get-StubArgument $a '--location') -ne 'centralindia') {
                    throw 'azd env new must pin the subscription and location, otherwise azd prompts for them interactively.'
                }
                $state.environments[$name] = [ordered]@{
                    AZURE_ENV_NAME = $name
                    AZURE_TENANT_ID = $state.tenantId
                }
                return
            }
            'select' {
                if (-not $state.environments.ContainsKey($a[2])) { throw "Unknown environment $($a[2])." }
                return
            }
            'set' {
                if (-not $state.environments.ContainsKey($environment)) { throw "azd env set targeted an unknown environment '$environment'." }
                $state.environments[$environment][$a[4]] = $a[5]
                return
            }
            'get-value' {
                if (-not $state.environments.ContainsKey($environment)) { throw "azd env get-value targeted an unknown environment '$environment'." }
                $name = $a[-1]
                if (-not $state.environments[$environment].Contains($name)) {
                    $global:LASTEXITCODE = 1
                    return "ERROR: key '$name' not found"
                }
                return $state.environments[$environment][$name]
            }
        }
        throw "Unexpected azd env call: $($a -join ' ')"
    }
    if ($a[0] -eq 'provision') {
        if ($a -notcontains '--preview') { throw 'The helper must only ever call azd provision in preview mode.' }
        $state.previewCalls++
        return
    }
    if ($a[0] -eq 'up') {
        $values = $state.environments[$environment]
        if ($state.needsAnswer) {
            # With --no-prompt azd reports the question it could not ask; the terminal rerun answers it.
            if ($noPrompt) {
                $state.azdCalls.Add('up:needs-answer')
                Write-Output "ERROR: prompting for location: no default response for prompt 'Select an Azure location to use'"
                $global:LASTEXITCODE = 1
                return
            }
            $state.needsAnswer = $false
            $state.azdCalls.Add('up:answered')
        }
        if ($state.failNextUp) {
            $message = $state.failNextUp
            $state.failNextUp = ''
            $state.azdCalls.Add('up:failed')
            Write-Output $message
            $global:LASTEXITCODE = 1
            return
        }
        # One azd up provisions with Terraform, runs the hook, builds both images and applies the manifests.
        $values['SERVICE_API_IMAGE_NAME'] = 'acrtest.azurecr.io/cost-assessment-app/api-app-test:azd-deploy-1'
        $values['SERVICE_WEB_IMAGE_NAME'] = 'acrtest.azurecr.io/cost-assessment-app/web-app-test:azd-deploy-1'
        $values['AZURE_RESOURCE_GROUP'] = $state.resourceGroup
        $values['AZURE_AKS_CLUSTER_NAME'] = 'aks-0123456789abc'
        # As Terraform reports them. The visibility defaults to private, as the azd parameter file does, and Terraform
        # refuses what only works in public: an allow-list, or Let's Encrypt.
        $visibility = if ($values.Contains('APP_INGRESS_VISIBILITY') -and $values['APP_INGRESS_VISIBILITY']) { $values['APP_INGRESS_VISIBILITY'] } else { 'private' }
        $values['APP_INGRESS_VISIBILITY'] = $visibility
        $customDomain = if ($values.Contains('APP_CUSTOM_DOMAIN')) { $values['APP_CUSTOM_DOMAIN'] } else { '' }
        $allowList = if ($values.Contains('APP_WEB_ALLOWED_IP_RANGES')) { $values['APP_WEB_ALLOWED_IP_RANGES'] } else { '' }
        $issuer = if ($values.Contains('APP_TLS_CLUSTER_ISSUER') -and $values['APP_TLS_CLUSTER_ISSUER']) { $values['APP_TLS_CLUSTER_ISSUER'] } elseif ($visibility -eq 'private') { 'private-ca' } else { 'letsencrypt' }
        if ($visibility -eq 'private' -and $allowList) { throw 'Terraform refuses an IP allow-list on a private ingress.' }
        if ($visibility -eq 'private' -and $issuer -like 'letsencrypt*') { throw 'Terraform refuses Let''s Encrypt on a private ingress.' }
        $values['APP_TLS_CLUSTER_ISSUER'] = $issuer
        $values['APP_INGRESS_NSG_NAME'] = 'nsg-aks-nodes-0123456789abc'
        if ($visibility -eq 'private') {
            $appHost = if ($customDomain) { $customDomain } else { 'cloudlens-test.internal' }
            $privateLinkOn = -not ($values.Contains('APP_PRIVATE_LINK_ENABLED') -and $values['APP_PRIVATE_LINK_ENABLED'] -eq 'false')
            $values['APP_INGRESS_PUBLIC_IP'] = ''
            $values['APP_INGRESS_PRIVATE_IP'] = '10.42.1.36'
            $values['APP_PRIVATE_LINK_ID'] = if ($privateLinkOn) { "/subscriptions/$($state.subscriptionId)/resourceGroups/$($state.resourceGroup)-aks-nodes/providers/Microsoft.Network/privateLinkServices/pls-cloudlens-test" } else { '' }
            $values['APP_WEB_INGRESS_RESTRICTED'] = 'true'
        } else {
            $appHost = if ($customDomain) { $customDomain } else { 'web.example.test' }
            $values['APP_INGRESS_PUBLIC_IP'] = '192.0.2.10'
            $values['APP_INGRESS_PRIVATE_IP'] = ''
            $values['APP_PRIVATE_LINK_ID'] = ''
            # Restricted once the NSG limits HTTPS to the stored allow-list.
            $values['APP_WEB_INGRESS_RESTRICTED'] = if ($allowList) { 'true' } else { 'false' }
        }
        $values['APP_WEB_ORIGIN'] = "https://$appHost"
        $state.webOrigin = $values['APP_WEB_ORIGIN']
        $values['APP_PROCESSOR_DEPLOYED'] = if ($values.Contains('APP_ENABLE_PROCESSOR') -and $values['APP_ENABLE_PROCESSOR'] -eq 'true') { 'true' } else { 'false' }
        $values['MEGHKOSHA_OBO_MANAGED_IDENTITY_RESOURCE_ID'] = "/subscriptions/$($state.subscriptionId)/resourceGroups/$($state.resourceGroup)/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obo"
        $state.azdCalls.Add('up:succeeded')
        return
    }
    if ($a[0] -eq 'deploy') {
        $values = $state.environments[$environment]
        if (-not $values.Contains('SERVICE_API_IMAGE_NAME')) { throw 'azd deploy ran before azd up provisioned the environment.' }
        $state.azdCalls.Add("deploy:succeeded:$($values['MEGHKOSHA_API_CLIENT_ID'])")
        return
    }
    throw "Unexpected azd call: $($a -join ' ')"
}

function az {
    $a = @($args)
    $global:LASTEXITCODE = 0
    $state = $global:deployTestState
    if ($a[0] -eq 'account' -and $a[1] -eq 'show') {
        $query = Get-StubArgument $a '--query'
        if ($query -eq 'id') { return $state.subscriptionId }
        if ($query -eq 'name') {
            if ((Get-StubArgument $a '--subscription') -ne $state.subscriptionId) { throw 'The subscription must be verified by ID, not by whatever az happens to default to.' }
            return 'Contoso Subscription'
        }
        return
    }
    if ($a[0] -eq 'login') { $state.interactiveLogins++; return }
    if ($a[0] -eq 'aks' -and $a[1] -eq 'install-cli') {
        $state.installCliCalls.Add("$(Get-StubArgument $a '--install-location')|$(Get-StubArgument $a '--kubelogin-install-location')")
        Install-KubernetesToolStubs
        return
    }
    if ($a[0] -eq 'identity' -and (Get-StubArgument $a '--subscription') -ne $state.subscriptionId) {
        throw 'az identity must be pinned to the deployment subscription, otherwise it reads the wrong one.'
    }
    if ($a[0] -eq 'identity' -and $a[1] -eq 'list') {
        if ((Get-StubArgument $a '-g') -ne $state.resourceGroup) { throw 'Managed identities must be listed from the deployment resource group.' }
        $query = Get-StubArgument $a '--query'
        if ($query -match "id-api-") { return $state.apiPrincipalId }
        if ($query -match "id-processor-") { return $state.processorPrincipalId }
        return "name              principalId`nid-api-x          $($state.apiPrincipalId)"
    }
    if ($a[0] -eq 'role' -and $a[1] -eq 'assignment' -and $a[2] -eq 'list') {
        $scope = Get-StubArgument $a '--scope'
        return (ConvertTo-Json -InputObject @($state.roleAssignments |
            Where-Object { $_.scope -eq $scope } |
            ForEach-Object { @{ principalId = $_.principalId; role = $_.role } }) -Depth 3)
    }
    if ($a[0] -eq 'role' -and $a[1] -eq 'assignment' -and $a[2] -eq 'create') {
        if ((Get-StubArgument $a '--assignee-principal-type') -ne 'ServicePrincipal') { throw 'Role assignments must declare the ServicePrincipal principal type.' }
        $assignment = @{
            principalId = Get-StubArgument $a '--assignee-object-id'
            role = Get-StubArgument $a '--role'
            scope = Get-StubArgument $a '--scope'
        }
        if (@($state.roleAssignments | Where-Object {
                $_.principalId -eq $assignment.principalId -and $_.role -eq $assignment.role -and $_.scope -eq $assignment.scope }).Count) {
            Write-Output 'ERROR: (RoleAssignmentExists) The role assignment already exists.'
            $global:LASTEXITCODE = 1
            return
        }
        $state.roleAssignments.Add($assignment)
        $state.roleCreates.Add($assignment)
        return
    }
    if ($a[0] -eq 'ad' -and $a[1] -eq 'app' -and $a[2] -eq 'list') {
        if ($a -notcontains '--show-mine') { throw "Only the operator's own registrations may suggest a Service Tree ID." }
        return "$($state.serviceTreeId)`n$($state.serviceTreeId)`n99999999-9999-9999-9999-999999999999"
    }
    if ($a[0] -eq 'ad' -and $a[1] -eq 'signed-in-user' -and $a[2] -eq 'show') {
        return (@{ id = $state.operatorObjectId; upn = 'operator@example.test' } | ConvertTo-Json -Compress)
    }
    throw "Unexpected az call: $($a -join ' ')"
}

$repoRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cloudlens-deploy-test-$([guid]::NewGuid().ToString('n'))"
$toolsHome = Join-Path $repoRoot 'tools-home'
New-Item -ItemType Directory -Path (Join-Path $repoRoot 'scripts') -Force | Out-Null
New-Item -ItemType Directory -Path $toolsHome -Force | Out-Null
try {
    Set-Content -LiteralPath (Join-Path $repoRoot 'azure.yaml') -Value 'name: cloudlens-test'
    Set-Content -LiteralPath (Join-Path $repoRoot 'scripts/bootstrap-identity.ps1') -Value @"
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][guid] `$TenantId,
    [Parameter(Mandatory)][guid] `$SubscriptionId,
    [Parameter(Mandatory)][string] `$EnvironmentName,
    [Parameter(Mandatory)][uri] `$WebOrigin,
    [Parameter(Mandatory)][string] `$OboManagedIdentityResourceId,
    [string] `$ServiceManagementReference = '',
    [switch] `$IncludeLocalhostRedirects,
    [switch] `$GrantAdminConsent,
    [switch] `$Apply
)
if (-not `$Apply) { throw 'The helper must apply the identity configuration.' }
if (`$env:APP_ALLOW_AZURE_CHANGES -ne 'true') { throw 'The helper must set the explicit approval flag.' }
if ("`$WebOrigin" -ne "`$(`$global:deployTestState.webOrigin)/") { throw "The sign-in redirect must use the ingress origin, not `$WebOrigin." }
`$global:deployTestState.bootstrapCalls++
if (`$global:deployTestState.requireServiceTree -and -not `$ServiceManagementReference) {
    throw 'Microsoft Graph POST /v1.0/applications was refused because this tenant requires a Service Tree ID (serviceManagementReference) on new app registrations. Rerun with -ServiceManagementReference <id>.'
}
`$global:deployTestState.serviceTreeIds.Add(`$ServiceManagementReference)
[ordered]@{
    action = 'Configured'
    AZURE_TENANT_ID = `$TenantId.ToString()
    MEGHKOSHA_API_CLIENT_ID = '$apiClientId'
    MEGHKOSHA_WEB_CLIENT_ID = '$webClientId'
    liveValidationRequired = `$true
} | ConvertTo-Json -Depth 5
"@

    $script = Join-Path $PSScriptRoot '../deploy-end-to-end.ps1'
    $parameters = @{
        EnvironmentName = $environmentName
        RepoDirectory = $repoRoot
        TargetSubscriptionId = "$targetOne, $targetTwo"
        SettleSeconds = 0
        MaxAttempts = 3
        KubernetesToolsDirectory = $toolsHome
        # The scenarios below that predate the private ingress describe the internet-facing one.
        IngressVisibility = 'public'
    }

    $plan = & $script @parameters -PlanOnly | ConvertFrom-Json -AsHashtable
    if (@($plan.assessedSubscriptions) -join ',' -ne "$targetOne,$targetTwo") { throw 'Comma-separated target subscriptions were not split into separate subscriptions.' }
    if ($plan.hosting -ne 'aks' -or $plan.repository.branch -ne 'cloudlensdev') { throw 'The plan must describe the AKS deployment from the cloudlensdev branch.' }
    if ($plan.operatorMode -or $plan.settings.MEGHKOSHA_AUTH_MODE -cne 'entra') { throw 'Entra sign-in must stay the default.' }
    $operatorPlan = & $script @parameters -PlanOnly -OperatorMode | ConvertFrom-Json -AsHashtable
    if (-not $operatorPlan.operatorMode -or $operatorPlan.bootstrapIdentity -or $operatorPlan.settings.MEGHKOSHA_AUTH_MODE -cne 'operator') {
        throw '-OperatorMode must plan operator mode without the sign-in bootstrap.'
    }
    if ($plan.settings.ContainsKey('APP_WEB_ALLOWED_IP_RANGES')) { throw 'Without -AllowedIpRanges the stored allow-list must be left alone.' }
    $allowPlan = & $script @parameters -PlanOnly -OperatorMode -AllowedIpRanges '203.0.113.7' | ConvertFrom-Json -AsHashtable
    if ($allowPlan.settings.APP_WEB_ALLOWED_IP_RANGES -ne '203.0.113.7/32') { throw 'The planned allow-list must be normalized to CIDR ranges.' }
    if ($global:deployTestState.azdCalls.Count -ne 0) { throw '-PlanOnly must not deploy anything.' }

    $summary = & $script @parameters
    if (@($summary).Count -ne 1) { throw 'The helper must return only its deployment summary; progress output belongs on the host.' }
    $summary = $summary | ConvertFrom-Json -AsHashtable
    $state = $global:deployTestState
    $values = $state.environments[$environmentName]

    $expected = @{
        AZURE_LOCATION = 'centralindia'
        AZURE_SUBSCRIPTION_ID = $subscriptionId
        APP_PROFILE = 'ai'
        APP_EXPORT_TRUSTED_SERVICES = 'true'
        MODEL_ROUTER_DEPLOYMENT_NAME = 'model-router'
        APP_ENABLE_CHAT_RUNTIME = 'true'
        APP_AI_VALIDATED = 'true'
        APP_ENABLE_AI_RUNTIME = 'false'
        APP_ENABLE_PROCESSOR = 'true'
        MEGHKOSHA_AUTH_MODE = 'entra'
        MEGHKOSHA_API_CLIENT_ID = $apiClientId
        MEGHKOSHA_WEB_CLIENT_ID = $webClientId
    }
    foreach ($key in $expected.Keys) {
        if (-not $values.Contains($key) -or $values[$key] -ne $expected[$key]) {
            throw "Environment value $key is '$(if ($values.Contains($key)) { $values[$key] } else { '<unset>' })' instead of '$($expected[$key])'."
        }
    }
    foreach ($retired in @('APP_REUSE_AI_ACCOUNT', 'APP_RESTORE_AI_ACCOUNT', 'SERVICE_PROCESSOR_IMAGE_NAME')) {
        if ($values.Contains($retired)) { throw "$retired belongs to the Container Apps flow and must not be set on AKS." }
    }
    if ($values['APP_MODEL_DEPLOYMENTS'] -notmatch '"modelName":"model-router"' -or $values['APP_MODEL_DEPLOYMENTS'] -notmatch '"capacity":20\}') { throw 'The approved Model Router deployment definition was not applied.' }
    if ($state.previewCalls -ne 1) { throw "azd provision --preview ran $($state.previewCalls) times instead of once." }
    if ($state.authChecks -ne 1 -or $state.interactiveLogins -ne 0) { throw 'Sign-in must be checked once and must not prompt when already authenticated.' }
    if ($state.cloneCalls -ne 0) { throw 'An existing checkout must not be cloned again.' }
    if ($state.installCliCalls.Count -ne 0 -or $state.questions.Count -ne 0) { throw 'kubectl and kubelogin were available, so nothing may be installed or asked.' }
    if ($state.bootstrapCalls -ne 1) { throw "bootstrap-identity.ps1 ran $($state.bootstrapCalls) times instead of once." }
    if (($state.azdCalls -join ',') -ne "up:failed,up:succeeded,deploy:succeeded:$apiClientId") {
        throw "Unexpected azd sequence: $($state.azdCalls -join ',')"
    }
    if ($state.roleCreates.Count -ne 6) { throw "Expected six role assignments, got $($state.roleCreates.Count)." }
    foreach ($scope in @("/subscriptions/$targetOne", "/subscriptions/$targetTwo")) {
        $roles = @($state.roleCreates | Where-Object { $_.scope -eq $scope })
        if (@($roles | Where-Object { $_.principalId -eq $apiPrincipalId -and $_.role -eq 'Reader' }).Count -ne 1 -or
            @($roles | Where-Object { $_.principalId -eq $apiPrincipalId -and $_.role -eq 'Cost Management Contributor' }).Count -ne 1 -or
            @($roles | Where-Object { $_.principalId -eq $processorPrincipalId -and $_.role -eq 'Cost Management Contributor' }).Count -ne 1) {
            throw "The three documented role assignments were not all made on $scope."
        }
    }
    if ($summary.webUrl -ne 'https://web.example.test' -or -not $summary.healthy -or -not $summary.processorEnabled -or
        $summary.cluster -ne 'aks-0123456789abc' -or $summary.apiClientId -ne $apiClientId -or $summary.subscription -ne $subscriptionId -or
        @($summary.assessedSubscriptions).Count -ne 2) {
        throw 'The deployment summary misreports the delivered environment.'
    }

    # A rerun against a settled environment must deploy the current code once and nothing more:
    # no repeated sign-in rollout and no duplicated role assignments.
    $state.azdCalls.Clear()
    $state.roleCreates.Clear()
    $state.previewCalls = 0
    $rerunOutput = (& $script @parameters -SkipPreview 6>&1 | ForEach-Object { "$_" }) -join "`n"
    if ($rerunOutput -match 'on your PATH') { throw 'kubectl and kubelogin were already on PATH, so the run must not suggest adding them.' }
    if (($state.azdCalls -join ',') -ne 'up:succeeded') { throw "A rerun made these azd calls instead of one azd up: $($state.azdCalls -join ',')" }
    if ($state.roleCreates.Count -ne 0) { throw 'A rerun duplicated role assignments instead of detecting the existing ones.' }
    if ($state.previewCalls -ne 0) { throw '-SkipPreview still ran the infrastructure preview.' }
    if ($state.bootstrapCalls -ne 2) { throw 'The sign-in bootstrap must be re-verified on every run.' }

    # azd must never wait on a question nobody can see: every call except sign-in runs with --no-prompt,
    # and when azd reports that it needed an answer, that same command reruns attached to the terminal.
    if ($state.interactiveAzd.Count) { throw "azd ran without --no-prompt, so a question it asked would be invisible: $($state.interactiveAzd -join '; ')" }
    $state.azdCalls.Clear()
    $state.needsAnswer = $true
    & $script @parameters -SkipPreview | Out-Null
    if (($state.azdCalls -join ',') -ne 'up:needs-answer,up:answered,up:succeeded') {
        throw "A question azd needed answered was not handed to the terminal: $($state.azdCalls -join ',')"
    }
    if (($state.interactiveAzd -join '; ') -ne "up --environment $environmentName") {
        throw "Only the azd command that needed an answer may run interactively; got: $($state.interactiveAzd -join '; ')"
    }
    $state.interactiveAzd.Clear()

    # A tenant that requires a Service Tree ID: the helper asks in the terminal, offers the ID the
    # operator's own registrations use (Enter accepts it), asks again after an invalid answer, and
    # remembers the answer so a rerun does not ask again.
    $state.requireServiceTree = $true
    $state.answers.AddRange([string[]]@('not-a-guid', ''))
    & $script @parameters -SkipPreview | Out-Null
    if ($state.questions.Count -ne 2 -or $state.questions[0] -notmatch [regex]::Escape($state.serviceTreeId)) {
        throw "The Service Tree ID question must offer the ID in use and ask again after an invalid answer. Asked: $($state.questions -join ' | ')"
    }
    if (@($state.serviceTreeIds)[-1] -ne $state.serviceTreeId -or $values['APP_SERVICE_MANAGEMENT_REFERENCE'] -ne $state.serviceTreeId) {
        throw 'The accepted Service Tree ID was not passed to the sign-in bootstrap and remembered.'
    }
    $state.questions.Clear()
    & $script @parameters -SkipPreview | Out-Null
    if ($state.questions.Count -or @($state.serviceTreeIds)[-1] -ne $state.serviceTreeId) {
        throw 'A remembered Service Tree ID must be reused without asking again.'
    }
    $state.requireServiceTree = $false
    if ($state.interactiveAzd.Count) { throw "azd ran without --no-prompt: $($state.interactiveAzd -join '; ')" }

    # Operator mode (Dev only): the signed-in az user becomes the operator, the sign-in bootstrap and the
    # public health probe are skipped because the public URL is closed, and the summary points at
    # port-forward. A later run without the switch returns the environment to Entra sign-in.
    $state.azdCalls.Clear()
    $bootstrapsBefore = $state.bootstrapCalls
    $probesBefore = $state.healthProbes
    $operatorSummary = & $script @parameters -SkipPreview -OperatorMode | ConvertFrom-Json -AsHashtable
    if ($state.bootstrapCalls -ne $bootstrapsBefore) { throw 'Operator mode must not run the Entra sign-in bootstrap.' }
    if ($state.healthProbes -ne $probesBefore) { throw 'Operator mode closes the public URL, so it must not probe it.' }
    if (($state.azdCalls -join ',') -ne 'up:succeeded') { throw "Operator mode made these azd calls: $($state.azdCalls -join ',')" }
    if ($values['MEGHKOSHA_AUTH_MODE'] -cne 'operator' -or $values['MEGHKOSHA_OPERATOR_OBJECT_ID'] -ne $state.operatorObjectId -or
        $values['MEGHKOSHA_OPERATOR_UPN'] -ne 'operator@example.test') {
        throw 'Operator mode must pin the signed-in user as the operator in the azd environment.'
    }
    if ($operatorSummary.authMode -ne 'operator' -or $operatorSummary.webUrl -or $operatorSummary.healthy -or
        $operatorSummary.portForward -ne 'kubectl port-forward --namespace cloudlens service/web 8080:8080') {
        throw 'The operator-mode summary must point at port-forward instead of the closed public URL.'
    }
    $entraSummary = & $script @parameters -SkipPreview | ConvertFrom-Json -AsHashtable
    if ($values['MEGHKOSHA_AUTH_MODE'] -cne 'entra' -or $values['MEGHKOSHA_OPERATOR_OBJECT_ID'] -or $values['MEGHKOSHA_OPERATOR_UPN']) {
        throw 'A run without -OperatorMode must return the environment to Entra sign-in.'
    }
    if ($state.bootstrapCalls -ne $bootstrapsBefore + 1 -or $entraSummary.authMode -ne 'entra' -or $entraSummary.portForward -or
        $entraSummary.webUrl -ne 'https://web.example.test' -or -not $entraSummary.healthy) {
        throw 'Entra mode must configure sign-in again and check the public URL.'
    }

    # An IP allow-list opens the operator-mode public URL once Terraform reports the restriction. The list is
    # stored normalized, kept by later runs that do not pass it, removed with '', and never internet-wide.
    $probesBefore = $state.healthProbes
    $allowSummary = & $script @parameters -SkipPreview -OperatorMode -AllowedIpRanges ' 203.0.113.7, 198.51.100.0/24,203.0.113.7/32' | ConvertFrom-Json -AsHashtable
    if ($values['APP_WEB_ALLOWED_IP_RANGES'] -ne '203.0.113.7/32,198.51.100.0/24') { throw 'The allow-list must be stored normalized and without duplicates.' }
    if ($allowSummary.webUrl -ne 'https://web.example.test' -or -not $allowSummary.healthy -or $allowSummary.allowedIpRanges -ne '203.0.113.7/32,198.51.100.0/24' -or
        $allowSummary.portForward -ne 'kubectl port-forward --namespace cloudlens service/web 8080:8080' -or $state.healthProbes -ne $probesBefore + 1) {
        throw 'An allow-listed operator deployment must serve and check its public URL, with port-forward as the fallback.'
    }
    & $script @parameters -SkipPreview -OperatorMode | Out-Null
    if ($values['APP_WEB_ALLOWED_IP_RANGES'] -ne '203.0.113.7/32,198.51.100.0/24') { throw 'A run without -AllowedIpRanges must keep the stored allow-list.' }

    # In Cloud Shell, whose own address is not one to allow-list, an allow-listed URL is not probed (that could only
    # time out), and the run warns up front about Cloud Shell's session limits.
    [Environment]::SetEnvironmentVariable('ACC_CLOUD', 'AzureCloud', 'Process')
    try {
        $probesBefore = $state.healthProbes
        $cloudShellOutput = @(& $script @parameters -SkipPreview -OperatorMode 3>&1)
    } finally {
        [Environment]::SetEnvironmentVariable('ACC_CLOUD', $null, 'Process')
    }
    $cloudShellWarnings = @($cloudShellOutput | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    $cloudShellSummary = (@($cloudShellOutput | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }) -join "`n") | ConvertFrom-Json -AsHashtable
    if ($state.healthProbes -ne $probesBefore -or $cloudShellSummary.healthy -or $cloudShellSummary.webUrl -ne 'https://web.example.test' -or
        -not @($cloudShellWarnings | Where-Object { "$_" -match '20 minutes' -and "$_" -match 'ephemeral' }).Count) {
        throw 'In Cloud Shell the helper must warn about the session limits and must not probe an allow-listed URL.'
    }

    # ---- The private ingress: the default for a new environment -------------------------------------------------
    # No public address, so nothing is probed from here; the run reports the private address, the Private Link Service and
    # the certificate, and the sign-in still registers the private host.
    $privateParameters = $parameters.Clone()
    $privateParameters.Remove('IngressVisibility')
    $privateParameters.EnvironmentName = 'priv-test'
    $probesBefore = $state.healthProbes
    $bootstrapsBefore = $state.bootstrapCalls
    $privateSummary = & $script @privateParameters -SkipPreview | ConvertFrom-Json -AsHashtable
    $privateValues = $state.environments['priv-test']
    if ($privateValues['APP_INGRESS_VISIBILITY'] -cne 'private') { throw 'A new environment must be private without being asked.' }
    if ($privateSummary.ingressVisibility -ne 'private' -or $privateSummary.webUrl -ne 'https://cloudlens-test.internal' -or $privateSummary.privateIp -ne '10.42.1.36' -or
        $privateSummary.privateLinkServiceId -notlike '*/providers/Microsoft.Network/privateLinkServices/pls-cloudlens-test' -or $privateSummary.tlsIssuer -ne 'private-ca' -or
        $privateSummary.healthy -or $privateSummary.allowedIpRanges -or $privateSummary.portForward) {
        throw "The private summary misreports the deployment: $($privateSummary | ConvertTo-Json -Compress)"
    }
    if ($state.healthProbes -ne $probesBefore) { throw 'A private ingress has no public address, so it must not be probed.' }
    if ($state.bootstrapCalls -ne $bootstrapsBefore + 1) { throw 'Entra sign-in must still be configured, against the private host.' }
    $state.azdCalls.Clear()
    & $script @privateParameters -SkipPreview | Out-Null
    if ($privateValues['APP_INGRESS_VISIBILITY'] -cne 'private' -or ($state.azdCalls -join ',') -ne 'up:succeeded') { throw 'A rerun must keep the stored visibility.' }

    # A custom domain, no Private Link Service and another subscription: normalized and kept.
    $domainSummary = & $script @privateParameters -SkipPreview -CustomDomain 'CloudLens.Contoso.com' -NoPrivateLink -PrivateLinkSubscriptionIds 'BBBBBBBB-bbbb-bbbb-bbbb-bbbbbbbbbbbb, bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' | ConvertFrom-Json -AsHashtable
    if ($privateValues['APP_CUSTOM_DOMAIN'] -cne 'cloudlens.contoso.com' -or $privateValues['APP_PRIVATE_LINK_ENABLED'] -cne 'false' -or
        $privateValues['APP_PRIVATE_LINK_ALLOWED_SUBSCRIPTIONS'] -cne 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') {
        throw 'The custom domain, the Private Link switch and the allowed subscriptions must be stored normalized.'
    }
    if ($domainSummary.webUrl -ne 'https://cloudlens.contoso.com' -or $domainSummary.privateLinkServiceId) { throw 'The summary must show the custom domain and no Private Link Service.' }
    foreach ($bad in @(@{ CustomDomain = 'not a domain' }, @{ PrivateLinkSubscriptionIds = 'not-a-subscription' })) {
        $refused = $null
        $badParameters = $privateParameters + $bad
        try { & $script @badParameters -PlanOnly | Out-Null } catch { $refused = $_.Exception.Message }
        $name = @($bad.Keys)[0]
        if ($refused -notmatch "-$name") { throw "-$name '$($bad[$name])' was not refused: $refused" }
    }

    # Private and public-only settings never combine: refused before anything is deployed.
    $state.azdCalls.Clear()
    foreach ($case in @(
            @{ Arguments = @{ IngressVisibility = 'private'; AllowedIpRanges = '203.0.113.7' }; Pattern = 'public ingress' },
            @{ Arguments = @{ IngressVisibility = 'private'; TlsClusterIssuer = 'letsencrypt' }; Pattern = 'public internet' },
            @{ Arguments = @{ AllowedIpRanges = '203.0.113.7' }; Pattern = 'this environment is private' },
            @{ Arguments = @{ TlsClusterIssuer = 'letsencrypt-staging' }; Pattern = 'public internet' })) {
        $refused = $null
        $combined = $privateParameters + $case.Arguments
        try { & $script @combined -SkipPreview | Out-Null } catch { $refused = $_.Exception.Message }
        if ($refused -notmatch $case.Pattern -or $state.azdCalls.Count) { throw "$(($case.Arguments.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') must be refused before azd runs; got: $refused" }
    }

    # An environment that already has a public address is never switched silently.
    $keptVisibility = $values['APP_INGRESS_VISIBILITY']
    $values.Remove('APP_INGRESS_VISIBILITY')
    $unspecified = $parameters.Clone()
    $unspecified.Remove('IngressVisibility')
    $refused = $null
    try { & $script @unspecified -SkipPreview | Out-Null } catch { $refused = $_.Exception.Message }
    if ($refused -notmatch 'already has a public address' -or $refused -notmatch '-IngressVisibility public' -or $refused -notmatch '-IngressVisibility private' -or $state.azdCalls.Count) {
        throw "An existing public environment must be refused without a choice, before azd runs; got: $refused"
    }
    $values['APP_INGRESS_VISIBILITY'] = $keptVisibility

    # Switching it on purpose: the old ingress's settings are reset, a warning explains, and the result is private.
    $values['APP_WEB_ALLOWED_IP_RANGES'] = '203.0.113.7/32'
    $values['APP_TLS_CLUSTER_ISSUER'] = 'letsencrypt'
    $switchOutput = @(& $script @unspecified -SkipPreview -IngressVisibility private -OperatorMode 3>&1)
    $switchWarnings = @($switchOutput | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { "$_" })
    $switchSummary = (@($switchOutput | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }) -join "`n") | ConvertFrom-Json -AsHashtable
    if ($values['APP_INGRESS_VISIBILITY'] -cne 'private' -or $values['APP_WEB_ALLOWED_IP_RANGES'] -ne '' -or $values['APP_TLS_CLUSTER_ISSUER'] -ne 'private-ca') {
        throw 'Switching to private must reset the allow-list and the certificate source of the public ingress.'
    }
    if (-not @($switchWarnings | Where-Object { $_ -match 'Switching' -and $_ -match 'public to a private' }).Count) { throw "Switching must warn; got: $($switchWarnings -join ' | ')" }
    if ($switchSummary.ingressVisibility -ne 'private' -or $switchSummary.webUrl -ne 'https://web.example.test'.Replace('web.example.test', 'cloudlens-test.internal') -or
        $switchSummary.portForward -ne 'kubectl port-forward --namespace cloudlens service/web 8080:8080' -or $switchSummary.healthy) {
        throw "Private operator mode must report the private URL and keep port-forward: $($switchSummary | ConvertTo-Json -Compress)"
    }

    # ... and back to public, which resets the private CA, so Let's Encrypt is chosen again.
    $backOutput = @(& $script @parameters -SkipPreview -SkipIdentityBootstrap 3>&1)
    $backSummary = (@($backOutput | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }) -join "`n") | ConvertFrom-Json -AsHashtable
    if ($values['APP_INGRESS_VISIBILITY'] -cne 'public' -or $values['APP_TLS_CLUSTER_ISSUER'] -ne 'letsencrypt' -or $backSummary.ingressVisibility -ne 'public' -or
        $backSummary.webUrl -ne 'https://web.example.test' -or $backSummary.privateIp) {
        throw 'Switching back to public must pick Let''s Encrypt again and report the public URL.'
    }
    $closedSummary = & $script @parameters -SkipPreview -OperatorMode -AllowedIpRanges '' | ConvertFrom-Json -AsHashtable
    if ($values['APP_WEB_ALLOWED_IP_RANGES'] -ne '' -or $closedSummary.webUrl -or $closedSummary.allowedIpRanges) {
        throw "-AllowedIpRanges '' must remove the allow-list and close the public URL again."
    }
    $state.azdCalls.Clear()
    $refused = $null
    try { & $script @parameters -SkipPreview -OperatorMode -AllowedIpRanges '0.0.0.0/0' | Out-Null } catch { $refused = $_.Exception.Message }
    if ($refused -notmatch 'AllowedIpRanges' -or $state.azdCalls.Count) { throw "An internet-wide range must be refused before anything is deployed; got: $refused" }

    # Missing kubectl/kubelogin: the helper asks before installing them with az aks install-cli into the
    # tools directory, -InstallKubernetesTools installs without asking, and an unattended run that cannot
    # ask explains what to do instead of guessing. Tools the run had to put on PATH itself come with the
    # commands a later plain azd needs, because the helper restores PATH when it finishes.
    $savedPath = $env:PATH
    $emptyPath = Join-Path $repoRoot 'empty-path'
    New-Item -ItemType Directory -Path $emptyPath -Force | Out-Null
    $toolSuffix = if ($IsWindows) { '.exe' } else { '' }
    $kubectlDirectory = Join-Path $toolsHome '.azure-kubectl'
    $kubeloginDirectory = Join-Path $toolsHome '.azure-kubelogin'
    $pathSeparator = [System.IO.Path]::PathSeparator
    $sessionCommand = "`$env:PATH = '$kubectlDirectory$pathSeparator$kubeloginDirectory$pathSeparator' + `$env:PATH"
    try {
        $env:PATH = $emptyPath
        Remove-Item -Path Function:\kubectl, Function:\kubelogin
        $state.answers.Add('')
        $installedOutput = (& $script @parameters -SkipPreview -SkipIdentityBootstrap -SkipRoleAssignments 6>&1 | ForEach-Object { "$_" }) -join "`n"
        if ($state.questions.Count -ne 1 -or $state.questions[0] -notmatch 'az aks install-cli') {
            throw "Missing Kubernetes tools must be offered for installation in the terminal. Asked: $($state.questions -join ' | ')"
        }
        $expectedInstall = "$(Join-Path $kubectlDirectory "kubectl$toolSuffix")|$(Join-Path $kubeloginDirectory "kubelogin$toolSuffix")"
        if (($state.installCliCalls -join ';') -ne $expectedInstall) { throw "az aks install-cli was not run once into the tools directory: $($state.installCliCalls -join ';')" }
        if ($env:PATH -ne $emptyPath) { throw 'The helper must restore PATH when it finishes.' }
        if (-not $installedOutput.Contains($sessionCommand)) { throw "Freshly installed tools must come with the command that puts them on PATH; got: $installedOutput" }

        $state.questions.Clear()
        $state.installCliCalls.Clear()
        Remove-Item -Path Function:\kubectl, Function:\kubelogin
        & $script @parameters -SkipPreview -SkipIdentityBootstrap -SkipRoleAssignments -InstallKubernetesTools | Out-Null
        if ($state.questions.Count -ne 0 -or $state.installCliCalls.Count -ne 1) { throw '-InstallKubernetesTools must install without asking.' }

        Remove-Item -Path Function:\kubectl, Function:\kubelogin
        $refused = $null
        try { & $script @parameters -SkipPreview -SkipIdentityBootstrap -SkipRoleAssignments | Out-Null } catch { $refused = $_.Exception.Message }
        if ($refused -notmatch 'az aks install-cli' -or $refused -notmatch '-InstallKubernetesTools') {
            throw "A session that cannot answer must explain how to install the tools; got: $refused"
        }

        # The usual state on a later run: tools from an earlier az aks install-cli that are not on PATH. They
        # are reused without asking, and the printed command really puts them on PATH. The helper only
        # explains the permanent fix; it must never change the user's PATH itself.
        $kubectlFile = Join-Path $kubectlDirectory "kubectl$toolSuffix"
        $kubeloginFile = Join-Path $kubeloginDirectory "kubelogin$toolSuffix"
        foreach ($file in @($kubectlFile, $kubeloginFile)) {
            New-Item -ItemType File -Path $file -Force | Out-Null
            if (-not $IsWindows) { & chmod +x $file }
        }
        $state.questions.Clear()
        $state.installCliCalls.Clear()
        $userPathBefore = if ($IsWindows) { [Environment]::GetEnvironmentVariable('Path', 'User') } else { '' }
        $reusedOutput = (& $script @parameters -SkipPreview -SkipIdentityBootstrap -SkipRoleAssignments 6>&1 | ForEach-Object { "$_" }) -join "`n"
        if ($state.questions.Count -or $state.installCliCalls.Count) { throw 'Tools from an earlier install must be reused without asking or reinstalling.' }
        if ($env:PATH -ne $emptyPath) { throw 'The helper must restore PATH when it finishes.' }
        if ($IsWindows -and [Environment]::GetEnvironmentVariable('Path', 'User') -ne $userPathBefore) { throw 'The helper must not change the user PATH.' }
        $hintLines = @($reusedOutput -split "`n" | ForEach-Object { $_.Trim() })
        $printedSession = @($hintLines | Where-Object { $_.StartsWith('$env:PATH = ') })
        # Once right after the tool check and once after the summary, so a long run does not scroll it away.
        if ($printedSession.Count -ne 2 -or $printedSession[0] -ne $sessionCommand) {
            throw "The run must show the PATH command for later azd runs at the start and the end; got: $reusedOutput"
        }
        Invoke-Expression $printedSession[0]
        if ((Get-Command kubectl).Source -ne $kubectlFile -or (Get-Command kubelogin).Source -ne $kubeloginFile) {
            throw 'The printed PATH command does not make kubectl and kubelogin resolvable.'
        }
        $env:PATH = $emptyPath
        $printedPermanent = @($hintLines | Where-Object { $_ -match '^(\[Environment\]::SetEnvironmentVariable|export PATH=)' }) | Select-Object -First 1
        $parseErrors = $null
        if ($IsWindows) { [System.Management.Automation.Language.Parser]::ParseInput("$printedPermanent", [ref] $null, [ref] $parseErrors) | Out-Null }
        if (-not $printedPermanent -or @($parseErrors).Count -or -not $printedPermanent.Contains($kubectlDirectory) -or -not $printedPermanent.Contains($kubeloginDirectory)) {
            throw "The run must show a valid permanent PATH command for both folders; got: $printedPermanent"
        }
    } finally {
        $env:PATH = $savedPath
        Install-KubernetesToolStubs
    }

    [ordered]@{ result = 'passed'; azdCalls = 'up,deploy'; roleAssignments = 6; rerunRedeploysOnce = $true
                noHiddenPrompts = $true; azdQuestionsAskedInTerminal = $true; serviceTreeIdAskedAndRemembered = $true
                kubernetesToolsOfferedAndInstalled = $true; kubernetesToolsPathExplained = $true
                operatorModeSkipsSignInAndPublicUrl = $true; allowListOpensPublicUrl = $true
                cloudShellSkipsBlockedHealthCheck = $true; privateIngressIsTheDefault = $true
                publicAddressNeverSwitchedSilently = $true } | ConvertTo-Json -Compress
} finally {
    foreach ($name in $cloudShellMarkers.Keys) { [Environment]::SetEnvironmentVariable($name, $cloudShellMarkers[$name], 'Process') }
    Remove-Variable -Name deployTestState -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\kubectl, Function:\kubelogin -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $repoRoot -Recurse -Force -ErrorAction SilentlyContinue
}
