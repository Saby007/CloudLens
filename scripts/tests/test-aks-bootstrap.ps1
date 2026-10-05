Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Offline test of scripts/aks-bootstrap.ps1: az, kubectl, kubelogin and the download are stubbed.
$script = Join-Path $PSScriptRoot '../aks-bootstrap.ps1'
$certManagerContent = "apiVersion: v1`nkind: Namespace`nmetadata:`n  name: cert-manager`n"
$certManagerSha = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($certManagerContent))).Replace('-', '').ToLowerInvariant()

$global:bootstrapTestState = $null
function Reset-State {
    $global:bootstrapTestState = @{
        calls = [System.Collections.Generic.List[string]]::new()
        canIAnswers = [System.Collections.Generic.List[string]]::new()
        installedVersion = ''
        failManifestApplies = 1
        appliedManifest = ''
        kubeconfig = ''
        content = $certManagerContent
        rbacDenied = $false
    }
}

function Start-Sleep { param([int] $Seconds) }

function Invoke-WebRequest {
    param($Uri, $OutFile, [switch] $UseBasicParsing, [int] $TimeoutSec)
    $global:bootstrapTestState.calls.Add("download $Uri")
    [System.IO.File]::WriteAllText($OutFile, $global:bootstrapTestState.content)
}

function az {
    $a = @($args)
    $global:LASTEXITCODE = 0
    $state = $global:bootstrapTestState
    if ($a[0] -eq 'aks' -and $a[1] -eq 'get-credentials') {
        $file = $a[[array]::IndexOf($a, '--file') + 1]
        if ($a -notcontains '--subscription' -or $a -notcontains '--overwrite-existing') { throw 'get-credentials must pin the subscription and refresh the file.' }
        if ($file -notlike "$([System.IO.Path]::GetTempPath())*") { throw 'Credentials must go to a temporary kubeconfig, never the operator''s own.' }
        Set-Content -LiteralPath $file -Value 'apiVersion: v1'
        $state.kubeconfig = $file
        $state.calls.Add("get-credentials $($a[[array]::IndexOf($a, '--name') + 1])")
        return
    }
    throw "Unexpected az call: $($a -join ' ')"
}

function kubelogin {
    $a = @($args)
    $global:LASTEXITCODE = 0
    $state = $global:bootstrapTestState
    if ($a[0] -ne 'convert-kubeconfig' -or $a[2] -ne 'azurecli' -or $a[4] -ne $state.kubeconfig) { throw "Unexpected kubelogin call: $($a -join ' ')" }
    $state.calls.Add('kubelogin azurecli')
}

function kubectl {
    $a = @($args)
    $global:LASTEXITCODE = 0
    $state = $global:bootstrapTestState
    if ($env:KUBECONFIG -ne $state.kubeconfig) { throw 'kubectl must use the temporary kubeconfig.' }
    if ($a[0] -eq 'auth') {
        # Like kubectl, warn on standard error when a cluster-scoped resource is checked inside a namespace.
        $namespaced = $a -notcontains '--all-namespaces' -and $a -notcontains '-A'
        if ($namespaced) {
            Write-Error -ErrorAction Continue "Warning: resource 'customresourcedefinitions' is not namespace scoped in group 'apiextensions.k8s.io'"
        }
        if ($state.rbacDenied) {
            $global:LASTEXITCODE = 1
            return 'no'
        }
        $answer = if ($state.canIAnswers.Count) { $state.canIAnswers[0] } else { 'yes' }
        if ($state.canIAnswers.Count) { $state.canIAnswers.RemoveAt(0) }
        $state.calls.Add("can-i $answer$(if ($namespaced) { ' (namespaced)' })")
        if ($answer -ne 'yes') { $global:LASTEXITCODE = 1 }
        return $answer
    }
    if ($a[0] -eq 'get' -and $a[1] -eq 'deployment') {
        # A server warning on standard error must never be read as the installed version.
        Write-Error -ErrorAction Continue 'Warning: unrecognized format "int64"'
        return $state.installedVersion
    }
    if ($a[0] -eq 'apply') {
        if ($a -notcontains '--server-side' -or $a -notcontains '--force-conflicts') { throw 'Applies must be server-side.' }
        $file = $a[-1]
        if ($file -eq '-') {
            if ($state.failManifestApplies -gt 0) {
                $state.failManifestApplies--
                $state.calls.Add('apply bootstrap (webhook not ready)')
                $global:LASTEXITCODE = 1
                return 'Error from server (InternalError): failed calling webhook "webhook.cert-manager.io": connection refused'
            }
            $state.appliedManifest = (@($input) -join "`n")
            $state.calls.Add('apply bootstrap')
            return 'applied'
        }
        $state.calls.Add('apply cert-manager')
        return 'applied'
    }
    if ($a[0] -eq 'rollout') { $state.calls.Add("rollout $($a[2])"); return 'successfully rolled out' }
    if ($a[0] -eq 'wait') { $state.calls.Add("wait $($a[1])"); return 'condition met' }
    throw "Unexpected kubectl call: $($a -join ' ')"
}

$environment = @{
    AZURE_SUBSCRIPTION_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    AZURE_RESOURCE_GROUP = 'rg-app-test'
    AZURE_AKS_CLUSTER_NAME = 'aks-0123456789abc'
    APP_INGRESS_CLASS = 'cloudlens-nginx'
    APP_INGRESS_PUBLIC_IP_NAME = 'pip-ingress-0123456789abc'
    APP_INGRESS_PUBLIC_IP = '20.0.0.10'
    APP_ACME_EMAIL = ''
}
$saved = @{}
foreach ($name in $environment.Keys + @('KUBECONFIG')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    foreach ($entry in $environment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
    Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue

    # Plan: the rendered manifest binds the controller to the Terraform-owned IP and drops the optional email.
    Reset-State
    $plan = & $script -PlanOnly | ConvertFrom-Json
    if ($plan.certManager.version -ne 'v1.21.2' -or $plan.certManager.url -notlike 'https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml' -or
        $plan.certManager.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'The plan must pin the cert-manager release and its checksum.' }
    foreach ($expected in @('ingressClassName: "cloudlens-nginx"', 'service.beta.kubernetes.io/azure-pip-name: "pip-ingress-0123456789abc"',
            'service.beta.kubernetes.io/azure-load-balancer-resource-group: "rg-app-test"', 'name: letsencrypt', 'name: letsencrypt-staging',
            'https://acme-v02.api.letsencrypt.org/directory', 'https://acme-staging-v02.api.letsencrypt.org/directory')) {
        if (-not $plan.manifest.Contains($expected)) { throw "The rendered manifest is missing: $expected" }
    }
    if ($plan.manifest -match 'email:' -or $plan.manifest -match '\$\{') { throw 'An empty optional email must drop its line and no placeholder may remain.' }
    if ($global:bootstrapTestState.calls.Count) { throw '-PlanOnly must not touch Azure or the cluster.' }

    $env:APP_ACME_EMAIL = 'ops@contoso.example'
    $plan = & $script -PlanOnly | ConvertFrom-Json
    if (([regex]::Matches($plan.manifest, 'email: "ops@contoso.example"')).Count -ne 2) { throw 'A configured email must reach both issuers.' }
    $env:APP_ACME_EMAIL = 'not-an-email'
    $rejected = $null
    try { & $script -PlanOnly | Out-Null } catch { $rejected = $_.Exception.Message }
    if ($rejected -notmatch 'not an email address') { throw 'An invalid email must be rejected.' }
    $env:APP_ACME_EMAIL = ''

    # Before the first provision there is no cluster yet: nothing to do.
    $env:AZURE_AKS_CLUSTER_NAME = ''
    $skipped = & $script 6>&1 | Out-String
    if ($skipped -notmatch 'Skipping the AKS bootstrap' -or $global:bootstrapTestState.calls.Count) { throw 'Without a cluster the hook must skip quietly.' }
    $env:AZURE_AKS_CLUSTER_NAME = 'aks-0123456789abc'

    # Full run: waits for RBAC, installs the checksum-verified release, retries while the webhook starts.
    Reset-State
    $global:bootstrapTestState.canIAnswers.AddRange([string[]]@('no', 'no', 'yes'))
    & $script -CertManagerSha256 $certManagerSha -RbacTimeoutSeconds 30 6>$null | Out-Null
    $state = $global:bootstrapTestState
    $expectedCalls = @(
        'get-credentials aks-0123456789abc', 'kubelogin azurecli', 'can-i no', 'can-i no', 'can-i yes',
        'download https://github.com/cert-manager/cert-manager/releases/download/v1.21.2/cert-manager.yaml', 'apply cert-manager',
        'rollout deployment/cert-manager', 'rollout deployment/cert-manager-cainjector', 'rollout deployment/cert-manager-webhook',
        'apply bootstrap (webhook not ready)', 'apply bootstrap', 'wait nginxingresscontroller/cloudlens')
    if (($state.calls -join ' | ') -ne ($expectedCalls -join ' | ')) { throw "Unexpected bootstrap sequence: $($state.calls -join ' | ')" }
    if (-not $state.appliedManifest.Contains('kind: NginxIngressController') -or -not $state.appliedManifest.Contains('kind: ClusterIssuer')) {
        throw 'The bootstrap manifest was not piped to kubectl.'
    }
    if (Test-Path Env:KUBECONFIG) { throw 'KUBECONFIG must be restored after the run.' }
    if (Test-Path -LiteralPath $state.kubeconfig) { throw 'The temporary kubeconfig must be deleted.' }
    if (@(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'cert-manager-v1.21.2-*.yaml').Count) { throw 'The downloaded manifest must be deleted.' }

    # A tampered download is never applied.
    Reset-State
    $global:bootstrapTestState.content = $certManagerContent + "# tampered`n"
    $refused = $null
    try { & $script -CertManagerSha256 $certManagerSha -RbacTimeoutSeconds 30 6>$null | Out-Null } catch { $refused = $_.Exception.Message }
    if ($refused -notmatch 'not the pinned' -or $global:bootstrapTestState.calls -contains 'apply cert-manager') { throw 'A checksum mismatch must stop before anything is applied.' }

    # A rerun with cert-manager already current skips the download.
    Reset-State
    $global:bootstrapTestState.installedVersion = 'v1.21.2'
    & $script -CertManagerSha256 $certManagerSha -RbacTimeoutSeconds 30 6>$null | Out-Null
    if (@($global:bootstrapTestState.calls | Where-Object { $_ -like 'download*' -or $_ -eq 'apply cert-manager' }).Count) { throw 'An installed release must not be downloaded or reapplied.' }
    if ($global:bootstrapTestState.calls -notcontains 'apply bootstrap') { throw 'The ingress controller and issuers must still be reconciled on reruns.' }

    # Access that never arrives: the hook stops with kubectl's last answer instead of waiting without a word.
    Reset-State
    $global:bootstrapTestState.rbacDenied = $true
    $denied = $null
    try { & $script -CertManagerSha256 $certManagerSha -RbacTimeoutSeconds 1 6>$null | Out-Null } catch { $denied = $_.Exception.Message }
    if ($denied -notmatch 'still cannot administer' -or $denied -notmatch 'last response from kubectl: no\)') { throw "Denied access must be reported with kubectl's answer; got: $denied" }
    if ($global:bootstrapTestState.calls -contains 'apply cert-manager' -or @($global:bootstrapTestState.calls | Where-Object { $_ -like 'download*' }).Count) {
        throw 'Nothing may be installed before access is confirmed.'
    }

    [ordered]@{ result = 'passed'; rbacWaited = $true; checksumEnforced = $true; webhookRetried = $true; kubeconfigIsolated = $true
                kubectlWarningsIgnored = $true; deniedAccessReported = $true } | ConvertTo-Json -Compress
} finally {
    foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
    Remove-Variable -Name bootstrapTestState -Scope Global -ErrorAction SilentlyContinue
}
