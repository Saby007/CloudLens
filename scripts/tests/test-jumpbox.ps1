Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Offline harness for scripts/deploy-test-jumpbox.ps1: azd, az, terraform, kubectl and kubelogin are stubbed.
$subscriptionId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$privateLinkId = "/subscriptions/$subscriptionId/resourceGroups/rg-app-test-aks-nodes/providers/Microsoft.Network/privateLinkServices/pls-cloudlens-test"
$certificate = "-----BEGIN CERTIFICATE-----`nMIIBsampleCertificate`n-----END CERTIFICATE-----`n"

$global:jumpboxTestState = @{
    environments = @{
        'private-ca-env' = [ordered]@{
            APP_INGRESS_VISIBILITY = 'private'; APP_PRIVATE_LINK_ID = $privateLinkId; APP_INGRESS_HOST = 'cloudlens-test.internal'
            APP_TLS_CLUSTER_ISSUER = 'private-ca'; AZURE_SUBSCRIPTION_ID = $subscriptionId; AZURE_LOCATION = 'centralindia'
            AZURE_AKS_CLUSTER_NAME = 'aks-0123456789abc'; AZURE_RESOURCE_GROUP = 'rg-app-test'
        }
        'byo-env' = [ordered]@{
            APP_INGRESS_VISIBILITY = 'private'; APP_PRIVATE_LINK_ID = $privateLinkId; APP_INGRESS_HOST = 'cloudlens.contoso.com'
            APP_TLS_CLUSTER_ISSUER = 'byo'; AZURE_SUBSCRIPTION_ID = $subscriptionId; AZURE_LOCATION = 'eastus2'
        }
        'public-env' = [ordered]@{
            APP_INGRESS_VISIBILITY = 'public'; APP_INGRESS_HOST = 'cloudlens-test.centralindia.cloudapp.azure.com'
            APP_TLS_CLUSTER_ISSUER = 'letsencrypt'; AZURE_SUBSCRIPTION_ID = $subscriptionId
        }
        'no-pls-env' = [ordered]@{
            APP_INGRESS_VISIBILITY = 'private'; APP_PRIVATE_LINK_ID = ''; APP_INGRESS_HOST = 'cloudlens-test.internal'
            APP_TLS_CLUSTER_ISSUER = 'private-ca'; AZURE_SUBSCRIPTION_ID = $subscriptionId
        }
    }
    calls = [System.Collections.Generic.List[string]]::new()
    terraform = [System.Collections.Generic.List[hashtable]]::new()
    plsExists = $true
    secretValue = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($certificate))
    kubeconfigs = [System.Collections.Generic.List[string]]::new()
}

function Get-StubArgument {
    param([object[]] $Arguments, [string] $Name)
    $index = [array]::IndexOf($Arguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $Arguments.Count) { return '' }
    return $Arguments[$index + 1]
}

function azd {
    $a = @($args)
    $global:LASTEXITCODE = 0
    $state = $global:jumpboxTestState
    if ($a[0] -ne 'env' -or $a[1] -ne 'get-value') { throw "The script may only read azd values: $($a -join ' ')" }
    $values = $state.environments[(Get-StubArgument $a '--environment')]
    $name = $a | Where-Object { $_ -match '^[A-Z0-9_]+$' } | Select-Object -Last 1
    if (-not $values.Contains($name)) {
        $global:LASTEXITCODE = 1
        return "ERROR: key '$name' not found"
    }
    return $values[$name]
}

function az {
    $a = @($args)
    $global:LASTEXITCODE = 0
    $state = $global:jumpboxTestState
    if ($a[0] -eq 'network' -and $a[1] -eq 'private-link-service' -and $a[2] -eq 'show') {
        $state.calls.Add('az pls show')
        if (-not $state.plsExists) {
            $global:LASTEXITCODE = 3
            return 'ERROR: (ResourceNotFound) The Resource was not found.'
        }
        return 'pls-cloudlens-test'
    }
    if ($a[0] -eq 'aks' -and $a[1] -eq 'get-credentials') {
        $state.calls.Add('az aks get-credentials')
        $file = Get-StubArgument $a '--file'
        Set-Content -LiteralPath $file -Value 'apiVersion: v1'
        $state.kubeconfigs.Add($file)
        return
    }
    throw "Unexpected az call: $($a -join ' ')"
}

function kubelogin {
    $global:LASTEXITCODE = 0
    $global:jumpboxTestState.calls.Add('kubelogin')
}

function kubectl {
    $a = @($args)
    $global:LASTEXITCODE = 0
    $global:jumpboxTestState.calls.Add('kubectl get secret')
    if ($a[0] -ne 'get' -or $a[1] -ne 'secret' -or $a[2] -ne 'cloudlens-private-ca' -or (Get-StubArgument $a '--namespace') -ne 'cert-manager') {
        throw "Unexpected kubectl call: $($a -join ' ')"
    }
    return $global:jumpboxTestState.secretValue
}

function terraform {
    $a = @($args)
    $global:LASTEXITCODE = 0
    $state = $global:jumpboxTestState
    $command = @($a | Where-Object { $_ -notlike '-chdir=*' })
    $record = @{
        Command = $command[0]
        Arguments = $command
        Environment = (Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_VAR_*' -or $_.Name -eq 'TF_DATA_DIR' } | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } })
    }
    $state.terraform.Add($record)
    if ($command[0] -eq 'output') {
        return (@{
            app_url = @{ value = 'https://cloudlens-test.internal' }
            resource_group_name = @{ value = 'rg-private-ca-env-jumpbox' }
            bastion_name = @{ value = 'bas-private-ca-env' }
            vm_name = @{ value = 'vm-jumpbox-private-ca-env' }
            admin_username = @{ value = 'cloudlensadmin' }
            admin_password = @{ value = 'Aa1-Bb2_Cc3=Dd4+Ee5!Ff6'; sensitive = $true }
            private_endpoint_ip = @{ value = '10.50.0.100' }
            private_endpoint_id = @{ value = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Network/privateEndpoints/pe' }
            trusts_private_ca = @{ value = $true }
        } | ConvertTo-Json -Depth 5)
    }
}

function Get-TerraformEnvironment {
    param([string] $Command)
    $call = @($global:jumpboxTestState.terraform | Where-Object { $_.Command -eq $Command }) | Select-Object -Last 1
    $values = @{}
    foreach ($item in $call.Environment) { $values[$item.Name] = $item.Value }
    return $values
}

$script = Join-Path $PSScriptRoot '../deploy-test-jumpbox.ps1'
$stateDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "cloudlens-jumpbox-test-$([guid]::NewGuid().ToString('n'))"
$state = $global:jumpboxTestState
try {
    # A public deployment, or one without a Private Link Service, has nothing for a private endpoint to connect to.
    foreach ($case in @(@('public-env', 'not a deployed private ingress'), @('no-pls-env', 'no Private Link Service'))) {
        $refused = $null
        try { & $script -EnvironmentName $case[0] -StateDirectory $stateDirectory | Out-Null } catch { $refused = $_.Exception.Message }
        if ($refused -notmatch $case[1] -or $state.terraform.Count -or $state.calls.Count) { throw "$($case[0]) must be refused before anything runs; got: $refused" }
    }

    # -PlanOnly touches nothing and says what would be built.
    $plan = & $script -EnvironmentName 'private-ca-env' -StateDirectory $stateDirectory -PlanOnly | ConvertFrom-Json
    if ($plan.privateLinkServiceId -ne $privateLinkId -or $plan.appHost -ne 'cloudlens-test.internal' -or -not $plan.installsPrivateCa -or $plan.location -ne 'centralindia' -or
        $plan.resourceGroup -ne 'rg-private-ca-env-jumpbox') {
        throw "The plan misreports the jump box: $($plan | ConvertTo-Json -Compress)"
    }
    if ($state.terraform.Count -or $state.calls.Count) { throw '-PlanOnly must not contact Azure, the cluster or Terraform.' }

    # The Private Link Service must exist, or the private endpoint has nothing to connect to.
    $state.plsExists = $false
    $refused = $null
    try { & $script -EnvironmentName 'private-ca-env' -StateDirectory $stateDirectory | Out-Null } catch { $refused = $_.Exception.Message }
    if ($refused -notmatch 'was not found' -or $refused -notmatch 'nginxingresscontroller' -or $state.terraform.Count) { throw "A missing Private Link Service must stop the run before Terraform; got: $refused" }
    $state.plsExists = $true
    $state.calls.Clear()

    # A private CA secret that holds a key is never sent to the VM.
    $state.secretValue = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$certificate-----BEGIN PRIVATE KEY-----`nabc`n-----END PRIVATE KEY-----`n"))
    $refused = $null
    try { & $script -EnvironmentName 'private-ca-env' -StateDirectory $stateDirectory | Out-Null } catch { $refused = $_.Exception.Message }
    if ($refused -notmatch 'plain certificate' -or $state.terraform.Count) { throw "A CA secret with a private key must be refused before Terraform; got: $refused" }
    $state.secretValue = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($certificate))
    $state.calls.Clear()

    # The full run: the CA is exported with a temporary kubeconfig, then Terraform builds the jump box in its own state.
    $result = & $script -EnvironmentName 'private-ca-env' -StateDirectory $stateDirectory | ConvertFrom-Json
    $apply = Get-TerraformEnvironment 'apply'
    $commands = @($state.terraform | ForEach-Object { $_.Command })
    if (($commands -join ',') -ne 'init,apply,output') { throw "Unexpected Terraform sequence: $($commands -join ',')" }
    if (($state.calls -join ' | ') -ne 'az pls show | az aks get-credentials | kubelogin | kubectl get secret') { throw "Unexpected calls: $($state.calls -join ' | ')" }
    if ($apply['TF_VAR_app_host'] -ne 'cloudlens-test.internal' -or $apply['TF_VAR_private_link_service_id'] -ne $privateLinkId -or $apply['TF_VAR_environment_name'] -ne 'private-ca-env' -or
        $apply['TF_VAR_location'] -ne 'centralindia' -or $apply['TF_VAR_manual_connection'] -ne 'false' -or $apply['TF_VAR_vm_size'] -ne 'Standard_B2ms') {
        throw 'Terraform did not receive the deployment''s values.'
    }
    if ($apply['TF_VAR_ca_certificate_pem'] -ne $certificate) { throw 'The private CA certificate must reach Terraform exactly.' }
    if ($apply['TF_DATA_DIR'] -ne (Join-Path $stateDirectory '.terraform')) { throw 'Terraform must keep its plugins with the jump box state.' }
    $applyArguments = @($state.terraform | Where-Object { $_.Command -eq 'apply' })[0].Arguments
    if ($applyArguments -notcontains '-auto-approve' -or $applyArguments -notcontains "-state=$(Join-Path $stateDirectory 'terraform.tfstate')") { throw 'The jump box must use its own state file.' }
    if ($result.appUrl -ne 'https://cloudlens-test.internal' -or $result.vm -ne 'vm-jumpbox-private-ca-env' -or $result.privateEndpointIp -ne '10.50.0.100' -or -not $result.trustsPrivateCa -or
        $result.destroyWith -notmatch '-Destroy') {
        throw "The summary misreports the jump box: $($result | ConvertTo-Json -Compress)"
    }
    if ($result.PSObject.Properties['vmPassword']) { throw 'The password must be printed only when asked for.' }
    if (@($state.kubeconfigs | Where-Object { Test-Path -LiteralPath $_ }).Count) { throw 'The temporary kubeconfig must be deleted.' }
    foreach ($leaked in @('TF_VAR_ca_certificate_pem', 'TF_VAR_app_host', 'TF_DATA_DIR')) {
        if (Test-Path "Env:$leaked") { throw "$leaked must not outlive the script." }
    }

    # -ShowPassword prints it; -SkipCertificateTrust and an issuer that is not the private CA send no certificate at all.
    $state.terraform.Clear(); $state.calls.Clear()
    $shown = & $script -EnvironmentName 'private-ca-env' -StateDirectory $stateDirectory -ShowPassword -SkipCertificateTrust -ManualConnection -VmSize Standard_D2s_v5 -Location westeurope | ConvertFrom-Json
    $apply = Get-TerraformEnvironment 'apply'
    if ($shown.vmPassword -ne 'Aa1-Bb2_Cc3=Dd4+Ee5!Ff6') { throw '-ShowPassword must print the generated password.' }
    if ($apply['TF_VAR_ca_certificate_pem'] -or $state.calls -contains 'kubectl get secret' -or $apply['TF_VAR_manual_connection'] -ne 'true' -or
        $apply['TF_VAR_vm_size'] -ne 'Standard_D2s_v5' -or $apply['TF_VAR_location'] -ne 'westeurope') {
        throw '-SkipCertificateTrust, -ManualConnection, -VmSize and -Location must be honored.'
    }
    $state.terraform.Clear(); $state.calls.Clear()
    & $script -EnvironmentName 'byo-env' -StateDirectory $stateDirectory | Out-Null
    $apply = Get-TerraformEnvironment 'apply'
    if ($apply['TF_VAR_ca_certificate_pem'] -or $state.calls -contains 'kubectl get secret' -or $apply['TF_VAR_location'] -ne 'eastus2') {
        throw 'An app with its own certificate needs no CA exported, and keeps its own region.'
    }

    # -Destroy removes what the state records, and refuses when there is none.
    $emptyDirectory = Join-Path $stateDirectory 'empty'
    $refused = $null
    try { & $script -EnvironmentName 'private-ca-env' -StateDirectory $emptyDirectory -Destroy | Out-Null } catch { $refused = $_.Exception.Message }
    if ($refused -notmatch 'nothing to destroy') { throw "Destroy without state must be refused; got: $refused" }
    Set-Content -LiteralPath (Join-Path $stateDirectory 'terraform.tfstate') -Value '{}'
    $state.terraform.Clear()
    & $script -EnvironmentName 'private-ca-env' -StateDirectory $stateDirectory -Destroy | Out-Null
    $destroy = @($state.terraform | Where-Object { $_.Command -eq 'destroy' })
    if ($destroy.Count -ne 1 -or $destroy[0].Arguments -notcontains '-auto-approve' -or $destroy[0].Arguments -notcontains "-state=$(Join-Path $stateDirectory 'terraform.tfstate')") {
        throw 'Destroy must run once, against the jump box state.'
    }

    [ordered]@{ result = 'passed'; refusesWhatCannotWork = $true; exportsTheCaWithoutKeys = $true; usesItsOwnState = $true
                cleansUp = $true; destroysOnlyWhatItBuilt = $true } | ConvertTo-Json -Compress
} finally {
    Remove-Variable -Name jumpboxTestState -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stateDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
