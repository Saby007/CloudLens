<#
.SYNOPSIS
    Test only: puts a Windows jump box behind Azure Bastion in a separate virtual network, connected to the app's
    private endpoint, so a private CloudLens deployment can be opened from a browser without any public address.

.DESCRIPTION
    A private deployment (deploy-end-to-end.ps1, the default) has no public address: it is reached from inside a virtual
    network, or through a private endpoint to its Private Link Service. To check that from a laptop that is not on the
    customer's network, this builds the same path with a jump box:

      - a virtual network of its own (it needs no relation to the application's);
      - a private endpoint in it, connected to the app's Private Link Service - the path a customer's network uses;
      - a private DNS zone, named after the app's host, that points the host at that endpoint;
      - a Windows Server VM with no public address, that trusts the cluster's private CA when the app uses one, and
        shuts itself down every day;
      - Azure Bastion, so you open the VM from the Azure portal in your browser, then Microsoft Edge on the VM opens
        the app.

    It is not part of the generic deployment and nothing there depends on it. State lives under
    .azure/<environment>/test-jumpbox, so -Destroy removes exactly what this created. Bastion bills hourly until it is
    destroyed (the VM stops costing compute at its daily shutdown), so destroy it when you are done.

.PARAMETER EnvironmentName
    The azd environment of the private CloudLens deployment to test.

.PARAMETER Location
    Region of the jump box. Defaults to the deployment's region.

.PARAMETER VmSize
    Size of the Windows VM. Defaults to Standard_B2ms.

.PARAMETER ManualConnection
    Request the private endpoint connection for approval, for a Private Link Service whose subscription is not on its
    auto-approval list; the connection then waits until someone approves it on the service.

.PARAMETER SkipCertificateTrust
    Do not install the cluster's private CA on the VM (for an app whose certificate comes from a CA the VM already trusts).

.PARAMETER ShowPassword
    Print the VM's generated administrator password. It is always kept in the Terraform state.

.PARAMETER Destroy
    Remove everything this created: the VM, Bastion, private endpoint, virtual network and resource group.

.PARAMETER PlanOnly
    Print what would be built without contacting Azure or the cluster.

.EXAMPLE
    pwsh ./scripts/deploy-test-jumpbox.ps1 -EnvironmentName my-environment

.EXAMPLE
    pwsh ./scripts/deploy-test-jumpbox.ps1 -EnvironmentName my-environment -Destroy
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,40}$')]
    [string] $EnvironmentName,
    [string] $Location = '',
    [string] $VmSize = 'Standard_B2ms',
    [switch] $ManualConnection,
    [switch] $SkipCertificateTrust,
    [switch] $ShowPassword,
    [switch] $Destroy,
    [switch] $PlanOnly,
    # Where Terraform keeps its state and plugins; the default sits next to the environment's own, and is ignored by git.
    [string] $StateDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.0') { throw 'PowerShell 7 or later is required.' }

$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleDirectory = Join-Path $repoRoot 'infra/test-jumpbox'
if (-not $StateDirectory) { $StateDirectory = Join-Path $repoRoot ".azure/$EnvironmentName/test-jumpbox" }
# Terraform runs with -chdir, which would otherwise resolve a relative state path against the module directory.
$StateDirectory = [System.IO.Path]::GetFullPath($StateDirectory)
$statePath = Join-Path $StateDirectory 'terraform.tfstate'

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
    # azd prints the literal string "ERROR: ..." for keys the environment has never held.
    if ($text -like 'ERROR:*') { return '' }
    return $text
}

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]] $Arguments)
    & terraform "-chdir=$moduleDirectory" @Arguments
    if ($LASTEXITCODE -ne 0) { throw "terraform $($Arguments[0]) failed (exit $LASTEXITCODE). Review the output above." }
}

foreach ($tool in @('azd', 'az', 'terraform')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' is required and was not found on PATH." }
}

# Terraform keeps its plugins and state here, so a destroy later finds exactly what an apply built.
New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
$env:TF_DATA_DIR = Join-Path $StateDirectory '.terraform'
$env:TF_IN_AUTOMATION = '1'
$env:TF_INPUT = '0'

Push-Location -LiteralPath $repoRoot
try {
    if ($Destroy) {
        if (-not (Test-Path -LiteralPath $statePath)) { throw "There is no jump box state at $statePath, so there is nothing to destroy." }
        if ($PlanOnly) { Write-Host "Would destroy the jump box recorded in $statePath."; return }
        Write-Host '==> Destroying the test jump box' -ForegroundColor Cyan
        Invoke-Terraform @('init', '-input=false')
        # Variables only have to be valid; destroy works from the state.
        $env:TF_VAR_environment_name = $EnvironmentName
        $env:TF_VAR_app_host = 'destroy.invalid'
        $env:TF_VAR_private_link_service_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/destroy/providers/Microsoft.Network/privateLinkServices/destroy'
        Invoke-Terraform @('destroy', '-auto-approve', "-state=$statePath")
        Write-Host 'The test jump box is gone.' -ForegroundColor Green
        return
    }

    $visibility = Get-AzdValue 'APP_INGRESS_VISIBILITY'
    if ($visibility -ne 'private') {
        throw "Environment '$EnvironmentName' is not a deployed private ingress (APP_INGRESS_VISIBILITY is '$visibility'). A public deployment is opened at its public address; deploy privately first with scripts/deploy-end-to-end.ps1."
    }
    $privateLinkId = Get-AzdValue 'APP_PRIVATE_LINK_ID'
    if (-not $privateLinkId) {
        throw "Environment '$EnvironmentName' has no Private Link Service: it was deployed with -NoPrivateLink, or has not been provisioned yet. Redeploy without -NoPrivateLink, or reach the app from a network that is peered to its virtual network."
    }
    $appHost = Get-AzdValue 'APP_INGRESS_HOST'
    if (-not $appHost) { throw "Environment '$EnvironmentName' has no APP_INGRESS_HOST yet; run the deployment first." }
    $issuer = Get-AzdValue 'APP_TLS_CLUSTER_ISSUER'
    $subscription = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
    if (-not $Location) { $Location = Get-AzdValue 'AZURE_LOCATION' }
    if (-not $Location) { $Location = 'centralindia' }
    $trustCa = ($issuer -eq 'private-ca') -and -not $SkipCertificateTrust

    $plan = [ordered]@{
        environment = $EnvironmentName
        subscription = $subscription
        location = $Location
        appHost = $appHost
        privateLinkServiceId = $privateLinkId
        tlsIssuer = $issuer
        installsPrivateCa = $trustCa
        manualConnection = [bool] $ManualConnection
        vmSize = $VmSize
        resourceGroup = "rg-$EnvironmentName-jumpbox"
        stateDirectory = $StateDirectory
    }
    if ($PlanOnly) {
        $plan | ConvertTo-Json -Depth 4
        return
    }

    # The Private Link Service is created by AKS once the ingress controller is bound to the internal load balancer.
    # Without it a private endpoint has nothing to connect to.
    Write-Host '==> Checking that the Private Link Service exists' -ForegroundColor Cyan
    $existing = Get-CliText (& az network private-link-service show --ids $privateLinkId --query 'name' --output tsv --only-show-errors 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The Private Link Service $privateLinkId was not found. AKS creates it when the ingress controller starts: check 'kubectl get nginxingresscontroller cloudlens' and 'kubectl get service --namespace app-routing-system', or rerun 'azd provision'. Details: $existing"
    }
    Write-Host "  $existing exists."

    $caPem = ''
    if ($trustCa) {
        Write-Host '==> Exporting the private CA, so the jump box trusts the app''s certificate' -ForegroundColor Cyan
        foreach ($tool in @('kubectl', 'kubelogin')) {
            if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' is required to export the private CA (az aks install-cli), or pass -SkipCertificateTrust and install the CA yourself." }
        }
        $cluster = Get-AzdValue 'AZURE_AKS_CLUSTER_NAME'
        $resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
        $kubeconfig = Join-Path ([System.IO.Path]::GetTempPath()) "cloudlens-jumpbox-$([guid]::NewGuid().ToString('n')).kubeconfig"
        try {
            & az aks get-credentials --resource-group $resourceGroup --name $cluster --subscription $subscription --file $kubeconfig --overwrite-existing --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'az aks get-credentials failed.' }
            & kubelogin convert-kubeconfig --login azurecli --kubeconfig $kubeconfig
            if ($LASTEXITCODE -ne 0) { throw 'kubelogin convert-kubeconfig failed.' }
            $encoded = Get-CliText (& kubectl get secret cloudlens-private-ca --namespace cert-manager --kubeconfig $kubeconfig --output 'jsonpath={.data.tls\.crt}' 2>&1)
            if ($LASTEXITCODE -ne 0 -or -not $encoded) { throw "The cluster's private CA secret could not be read: $encoded" }
            $caPem = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        } finally {
            Remove-Item -LiteralPath $kubeconfig -Force -ErrorAction SilentlyContinue
        }
        # Only the certificate may travel to the VM, never a key.
        if ($caPem -notmatch '-----BEGIN CERTIFICATE-----' -or $caPem -match 'PRIVATE KEY') { throw 'The private CA secret did not hold a plain certificate, so nothing was installed.' }
    }

    $env:TF_VAR_environment_name = $EnvironmentName
    $env:TF_VAR_location = $Location
    $env:TF_VAR_app_host = $appHost
    $env:TF_VAR_private_link_service_id = $privateLinkId
    $env:TF_VAR_ca_certificate_pem = $caPem
    $env:TF_VAR_manual_connection = if ($ManualConnection) { 'true' } else { 'false' }
    $env:TF_VAR_vm_size = $VmSize

    Write-Host '==> Building the jump box, Bastion and private endpoint (about 10 minutes)' -ForegroundColor Cyan
    Invoke-Terraform @('init', '-input=false')
    Invoke-Terraform @('apply', '-auto-approve', "-state=$statePath")

    $outputs = (& terraform "-chdir=$moduleDirectory" output -json "-state=$statePath" | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw 'terraform output failed.' }
    $result = [ordered]@{
        environment = $EnvironmentName
        appUrl = $outputs.app_url.value
        resourceGroup = $outputs.resource_group_name.value
        bastion = $outputs.bastion_name.value
        vm = $outputs.vm_name.value
        vmUsername = $outputs.admin_username.value
        privateEndpointIp = $outputs.private_endpoint_ip.value
        trustsPrivateCa = [bool] $outputs.trusts_private_ca.value
        destroyWith = "pwsh ./scripts/deploy-test-jumpbox.ps1 -EnvironmentName $EnvironmentName -Destroy"
    }
    if ($ShowPassword) { $result.vmPassword = $outputs.admin_password.value }
    $result | ConvertTo-Json -Depth 4

    Write-Host ''
    Write-Host 'Open the app from the jump box:' -ForegroundColor Green
    Write-Host "  1. Azure portal -> Virtual machines -> $($outputs.vm_name.value) (resource group $($outputs.resource_group_name.value)) -> Connect -> Bastion."
    Write-Host "  2. Sign in as $($outputs.admin_username.value)$(if ($ShowPassword) { ' with the password above' } else { ", with the password from: terraform -chdir=infra/test-jumpbox output -raw admin_password -state='$statePath'" })."
    Write-Host "  3. In Microsoft Edge on the VM, open $($outputs.app_url.value)."
    if (-not $outputs.trusts_private_ca.value -and $issuer -eq 'private-ca') {
        Write-Host '     The CA was not installed on the VM (-SkipCertificateTrust), so Edge will warn about the certificate.' -ForegroundColor Yellow
    }
    Write-Host '  If the page does not open, the private endpoint connection may still be waiting for approval: az network private-endpoint show --ids' $outputs.private_endpoint_id.value '--query "privateLinkServiceConnections[0].privateLinkServiceConnectionState"'
    Write-Host ''
    Write-Host "Bastion bills by the hour until it is destroyed; the VM deallocates itself every day. When you are done: $($result.destroyWith)" -ForegroundColor Yellow
} finally {
    Pop-Location
    foreach ($name in @('TF_VAR_environment_name', 'TF_VAR_location', 'TF_VAR_app_host', 'TF_VAR_private_link_service_id', 'TF_VAR_ca_certificate_pem', 'TF_VAR_manual_connection', 'TF_VAR_vm_size', 'TF_DATA_DIR')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}
