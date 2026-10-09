Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Offline harness for scripts/deploy-on-host.ps1 and scripts/prepare-deploy-host.ps1: azd, az, docker, kubectl and kubelogin are stubbed.
$deployOnHost = Join-Path $PSScriptRoot '../deploy-on-host.ps1'
$prepareHost = Join-Path $PSScriptRoot '../prepare-deploy-host.ps1'
$azureYaml = Join-Path $PSScriptRoot '../../azure.yaml'
$envFile = Join-Path ([System.IO.Path]::GetTempPath()) "cloudlens-host-env-$([guid]::NewGuid().ToString('n')).env"

$global:hostTestState = $null
function Reset-State {
    $global:hostTestState = @{
        environments = @{}
        calls = [System.Collections.Generic.List[string]]::new()
        failDeploy = $false
        dockerWorks = $true
        remoteBuildOffAtDeploy = $false
        hookSawProvisionOnly = $false
    }
}

function Start-Sleep { param([int] $Seconds) }
function kubectl { $global:LASTEXITCODE = 0 }
function kubelogin { $global:LASTEXITCODE = 0 }
function az {
    $global:LASTEXITCODE = 0
    $a = @($args)
    if ($a[0] -eq 'account' -and $a[1] -eq 'show') { return }
    throw "Unexpected az call: $($a -join ' ')"
}
function docker {
    $global:LASTEXITCODE = 0
    $state = $global:hostTestState
    $state.calls.Add("docker $(@($args) -join ' ')")
    if (-not $state.dockerWorks) { $global:LASTEXITCODE = 1; return 'permission denied while trying to connect to the docker API' }
}

function Get-StubArgument {
    param([string[]] $Arguments, [string] $Name)
    $index = [array]::IndexOf($Arguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $Arguments.Count) { return '' }
    return $Arguments[$index + 1]
}

function azd {
    $global:LASTEXITCODE = 0
    $state = $global:hostTestState
    $a = @(@($args) | Where-Object { $_ -ne '--no-prompt' })
    $environment = Get-StubArgument $a '--environment'
    if ($a[0] -eq 'auth') { return }
    if ($a[0] -eq 'env') {
        switch ($a[1]) {
            'list' { return (ConvertTo-Json -InputObject @($state.environments.Keys | ForEach-Object { @{ Name = $_ } }) -Depth 3) }
            'new' { $state.environments[$a[2]] = [ordered]@{}; $state.calls.Add("env new $($a[2])"); return }
            'select' { $state.calls.Add("env select $($a[2])"); return }
            'set' { $state.environments[$environment][$a[4]] = $a[5]; return }
            'get-value' {
                $name = $a[-1]
                if (-not $state.environments[$environment].Contains($name)) { $global:LASTEXITCODE = 1; return "ERROR: key '$name' not found" }
                return $state.environments[$environment][$name]
            }
            'get-values' {
                $values = $state.environments[$environment]
                return @($values.Keys | ForEach-Object { "$_=`"$($values[$_])`"" })
            }
        }
    }
    if ($a[0] -eq 'hooks' -and $a[1] -eq 'run' -and $a[2] -eq 'postprovision') {
        $state.hookSawProvisionOnly = [bool]$env:CLOUDLENS_PROVISION_ONLY
        $state.calls.Add('hook postprovision')
        return
    }
    if ($a[0] -eq 'deploy') {
        $state.calls.Add('deploy')
        $state.remoteBuildOffAtDeploy = (Get-Content -LiteralPath $azureYaml -Raw) -notmatch 'remoteBuild:\s*true'
        if ($state.failDeploy) { $global:LASTEXITCODE = 1; return 'ERROR: deploying service api: failed' }
        $state.environments[$environment]['SERVICE_API_IMAGE_NAME'] = 'acr.azurecr.io/api:1'
        $state.environments[$environment]['SERVICE_WEB_IMAGE_NAME'] = 'acr.azurecr.io/web:1'
        return
    }
    throw "Unexpected azd call: $($a -join ' ')"
}

$yamlBefore = [System.IO.File]::ReadAllText($azureYaml)
if (([regex]::Matches($yamlBefore, '(?m)^\s*remoteBuild:\s*true\s*$')).Count -ne 2) { throw 'azure.yaml is expected to build both services remotely.' }
try {
    [System.IO.File]::WriteAllLines($envFile, @(
        'AZURE_ENV_NAME="priv-env"',
        'AZURE_AKS_CLUSTER_NAME="aks-0123456789abc"',
        'APP_AKS_PRIVATE_CLUSTER="true"',
        'APP_PRIVATE_REGISTRY="true"',
        'APP_WEB_ORIGIN="https://cloudlens-test.internal"',
        'APP_MODEL_DEPLOYMENTS="[{\"name\":\"model-router\"}]"',
        'APP_TLS_CLUSTER_ISSUER="private-ca"',
        '# a comment line is ignored'))

    # The settings exported from the laptop become the azd environment; the hook runs for real (not provision-only), the images are
    # built with local Docker while the registry is private, and azure.yaml is exactly as it was afterwards.
    Reset-State
    & $deployOnHost -EnvironmentName 'priv-env' -EnvFile $envFile -MaxAttempts 2 -SettleSeconds 0 | Out-Null
    $state = $global:hostTestState
    $imported = $state.environments['priv-env']
    if ($imported['AZURE_AKS_CLUSTER_NAME'] -ne 'aks-0123456789abc' -or $imported['APP_AKS_PRIVATE_CLUSTER'] -ne 'true' -or $imported['APP_MODEL_DEPLOYMENTS'] -ne '[{"name":"model-router"}]') {
        throw "The exported settings must be imported exactly, quotes included: $($imported | ConvertTo-Json -Compress)"
    }
    if (($state.calls -join ' | ') -ne 'env new priv-env | env select priv-env | docker info | hook postprovision | deploy') { throw "Unexpected steps: $($state.calls -join ' | ')" }
    if ($state.hookSawProvisionOnly) { throw 'The deploy stage must run the cluster bootstrap for real.' }
    if (-not $state.remoteBuildOffAtDeploy) { throw 'A private registry cannot be built into remotely: remoteBuild must be off while deploying.' }
    if ([System.IO.File]::ReadAllText($azureYaml) -ne $yamlBefore) { throw 'azure.yaml must be put back exactly as it was.' }

    # A rerun reuses the environment it already has, even without the file.
    $state.calls.Clear()
    & $deployOnHost -EnvironmentName 'priv-env' -MaxAttempts 2 -SettleSeconds 0 | Out-Null
    if ($state.calls -contains 'env new priv-env') { throw 'An existing environment must not be recreated.' }

    # A failing deploy is retried, then reported, and still puts azure.yaml back.
    $state.calls.Clear()
    $state.failDeploy = $true
    $failed = $null
    try { & $deployOnHost -EnvironmentName 'priv-env' -MaxAttempts 2 -SettleSeconds 0 | Out-Null } catch { $failed = $_.Exception.Message }
    if ($failed -notmatch 'failed after 2 attempt' -or @($state.calls | Where-Object { $_ -eq 'deploy' }).Count -ne 2) { throw "A failing deploy must be retried and reported; got: $failed" }
    if ([System.IO.File]::ReadAllText($azureYaml) -ne $yamlBefore) { throw 'azure.yaml must be restored even when the deploy fails.' }

    # Docker that this user cannot use is explained before anything is changed.
    Reset-State
    $global:hostTestState.dockerWorks = $false
    $noDocker = $null
    try { & $deployOnHost -EnvironmentName 'priv-env' -EnvFile $envFile -MaxAttempts 1 -SettleSeconds 0 | Out-Null } catch { $noDocker = $_.Exception.Message }
    if ($noDocker -notmatch 'cannot use it' -or $global:hostTestState.calls -contains 'deploy' -or [System.IO.File]::ReadAllText($azureYaml) -ne $yamlBefore) {
        throw "Unusable Docker must be reported before deploying; got: $noDocker"
    }

    # An environment this machine has never seen needs the exported settings.
    Reset-State
    $missing = $null
    try { & $deployOnHost -EnvironmentName 'unknown-env' -MaxAttempts 1 -SettleSeconds 0 | Out-Null } catch { $missing = $_.Exception.Message }
    if ($missing -notmatch '-EnvFile' -or $global:hostTestState.calls.Count) { throw "A missing environment must ask for -EnvFile; got: $missing" }

    # prepare-deploy-host: refuses an environment without a deploy host, and plans without touching Azure.
    Reset-State
    $global:hostTestState.environments['plain-env'] = [ordered]@{ AZURE_AKS_CLUSTER_NAME = 'aks-0123456789abc' }
    $noHost = $null
    try { & $prepareHost -EnvironmentName 'plain-env' | Out-Null } catch { $noHost = $_.Exception.Message }
    if ($noHost -notmatch 'no deploy host') { throw "An environment without a deploy host must be refused; got: $noHost" }
    $global:hostTestState.environments['host-env'] = [ordered]@{
        APP_DEPLOY_HOST_ID = '/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-deploy-1'
        APP_DEPLOY_HOST_NAME = 'vm-deploy-1'; AZURE_RESOURCE_GROUP = 'rg'
    }
    $plan = & $prepareHost -EnvironmentName 'host-env' -PlanOnly | ConvertFrom-Json
    if ($plan.deployHost -ne 'vm-deploy-1' -or $plan.copies -ne '/home/cloudlensadmin/cloudlens/host-env.env') { throw "The plan must name the host and where the settings go: $($plan | ConvertTo-Json -Compress)" }
    foreach ($bad in @(@{ RepoUrl = 'http://insecure.example/repo.git' }, @{ RepoBranch = "main'; rm -rf /" })) {
        $hostSettings = @{ EnvironmentName = 'host-env' } + $bad
        $refusedInput = $null
        try { & $prepareHost @hostSettings | Out-Null } catch { $refusedInput = $_.Exception.Message }
        if ($refusedInput -notmatch 'https') { throw "A repository URL or branch that is not plain must be refused; got: $refusedInput" }
    }

    [ordered]@{ result = 'passed'; importsExportedSettings = $true; buildsLocallyForAPrivateRegistry = $true; restoresAzureYaml = $true
                retriesAndReports = $true; explainsUnusableDocker = $true; refusesWhatCannotWork = $true } | ConvertTo-Json -Compress
} finally {
    [System.IO.File]::WriteAllText($azureYaml, $yamlBefore)
    Remove-Item -LiteralPath $envFile -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name hostTestState -Scope Global -ErrorAction SilentlyContinue
}
