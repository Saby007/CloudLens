Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$subject = Join-Path $PSScriptRoot '../invoke-private-deploy.ps1'
$revision = 'a' * 40
$subscription = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$global:privateTest = @{}

function Reset-Test {
    param([string] $Mode = 'success')
    $global:privateTest = @{
        mode = $Mode
        created = $false
        puts = 0
        starts = 0
        stops = 0
        polls = 0
        script = ''
        requestId = 'b' * 32
        revision = 'a' * 40
    }
}

function Argument-Value {
    param([object[]] $Values, [string] $Name)
    $index = [array]::IndexOf($Values, $Name)
    if ($index -lt 0) { return '' }
    return "$($Values[$index + 1])"
}

function Start-Sleep { param([int] $Seconds) }

function azd {
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'env' -and $args[1] -eq 'get-value') {
        switch ($args[4]) {
            'APP_DEPLOY_HOST_ID' { return '/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-test' }
            'AZURE_SUBSCRIPTION_ID' { return 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' }
            'AZURE_LOCATION' { return 'centralindia' }
            default { throw "Unexpected output name: $($args -join ' ')" }
        }
    }
    if ($args[0] -eq 'env' -and $args[1] -eq 'get-values') {
        return @(
            'AZURE_ENV_NAME="test"'
            'APP_PROFILE="data"'
            'APP_DEPLOY_HOST_ADMIN_PASSWORD="synthetic-password-never-copy"'
            'AZURE_CLIENT_SECRET="synthetic-secret-never-copy"'
            'ARM_ACCESS_TOKEN="synthetic-token-never-copy"'
            'COST_EXPORT_CONTAINER="cost-exports"'
        )
    }
    throw "Unexpected azd command: $($args -join ' ')"
}

function az {
    $a = @($args)
    $state = $global:privateTest
    $global:LASTEXITCODE = 0
    if ($a[0] -eq 'vm' -and $a[1] -eq 'get-instance-view') { return 'PowerState/deallocated' }
    if ($a[0] -eq 'vm' -and $a[1] -eq 'start') { $state.starts++; return }
    if ($a[0] -eq 'vm' -and $a[1] -eq 'deallocate') { $state.stops++; return }
    if ($a[0] -ne 'rest') { throw "Unexpected az command: $($a -join ' ')" }
    if ((Argument-Value $a '--method') -eq 'put') {
        $state.puts++
        $state.created = $true
        $bodyPath = (Argument-Value $a '--body').TrimStart('@')
        $body = Get-Content -LiteralPath $bodyPath -Raw | ConvertFrom-Json
        if (-not $body.properties.asyncExecution -or $body.properties.timeoutInSeconds -ne 7200) { throw 'Run Command must be durable and bounded.' }
        $state.script = $body.properties.source.script
        $state.requestId = [regex]::Match($state.script, '(?m)^# request ([a-f0-9]{32})$').Groups[1].Value
        if (-not $state.requestId -or $state.script.Contains("`r")) { throw 'The Linux script must have LF endings and a request correlation ID.' }
        if ($state.script -match 'synthetic-(password|secret|token)-never-copy') { throw 'A credential was copied to the host.' }
        $encoded = [regex]::Match($state.script, "printf '%s' '([A-Za-z0-9+/=]+)'").Groups[1].Value
        $settings = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        if ($settings -match 'synthetic-(password|secret|token)-never-copy') { throw 'An encoded credential was copied to the host.' }
        if ($settings -notmatch 'COST_EXPORT_CONTAINER="cost-exports"') { throw 'Non-secret deployment settings were lost.' }
        if ($state.script -notmatch 'az login --identity' -or $state.script -notmatch 'azd auth login --managed-identity') { throw 'The host must authenticate as itself.' }
        return
    }
    if ($state.mode -eq 'forbidden') {
        $global:LASTEXITCODE = 1
        return '(AuthorizationFailed) synthetic denial'
    }
    if (-not $state.created -and $state.mode -notin @('resume', 'starting')) {
        $global:LASTEXITCODE = 1
        return '(ResourceNotFound) no existing command'
    }
    $state.polls++
    if ($state.mode -eq 'starting' -and $state.polls -eq 1) {
        return @{ properties = @{ provisioningState = 'Updating'; source = @{ script = "# request $($state.requestId)`n" }; instanceView = $null } } | ConvertTo-Json -Depth 6
    }
    $execution = if ($state.polls -eq 1) { 'Running' } else { 'Succeeded' }
    $result = @{
        environment = if ($state.mode -eq 'wrong-scope') { 'another-environment' } else { 'test' }
        healthy = $true
        apiImage = 'acr.test/api:revision'
        webImage = 'acr.test/web:revision'
        caCertificateBase64 = ''
        requestId = $state.requestId
        sourceRevision = $state.revision
    }
    $output = 'CLOUDLENS_RESULT:' + ($result | ConvertTo-Json -Compress)
    if ($state.mode -eq 'stale-result' -and $state.polls -eq 2) {
        $result.requestId = 'c' * 32
        $output = 'CLOUDLENS_RESULT:' + ($result | ConvertTo-Json -Compress)
    }
    if ($state.mode -eq 'no-result') { $output = 'Build completed, but verification did not run.' }
    if ($state.mode -eq 'failed') { $execution = 'Failed' }
    return @{
        properties = @{
            provisioningState = 'Succeeded'
            source = @{ script = "# request $($state.requestId)`n" }
            instanceView = @{ executionState = $execution; exitCode = 0; output = $output; error = 'synthetic failure detail' }
        }
    } | ConvertTo-Json -Depth 6
}

Reset-Test
$result = & $subject -EnvironmentName test -RepoRevision $revision -PollSeconds 1
if (-not $result.healthy -or $global:privateTest.puts -ne 1 -or $global:privateTest.starts -ne 1 -or $global:privateTest.stops -ne 1) { throw 'Private deployment did not complete and deallocate its build VM.' }
if ($global:privateTest.script -notmatch 'deploy-on-host.ps1.*-Verify -ResultFile') { throw 'Build must finish with private HTTPS verification.' }
Write-Host 'PASS: private managed-identity deployment, exact revision, credential exclusion and verified result'

Reset-Test resume
$result = & $subject -EnvironmentName test -RepoRevision $revision -PollSeconds 1
if (-not $result.healthy -or $global:privateTest.puts -ne 0) { throw 'A resumed execution must not start another build.' }
Write-Host 'PASS: Cloud Shell reconnect resumes the existing job'

Reset-Test starting
$result = & $subject -EnvironmentName test -RepoRevision $revision -PollSeconds 1
if (-not $result.healthy -or $global:privateTest.puts -ne 0) { throw 'A command still starting must be resumed, not overwritten.' }
Write-Host 'PASS: reconnect during VM-agent startup does not duplicate execution'

Reset-Test stale-result
$result = & $subject -EnvironmentName test -RepoRevision $revision -PollSeconds 1
if (-not $result.healthy -or $global:privateTest.polls -ne 3) { throw 'A stale successful result must not satisfy a new deployment request.' }
Write-Host 'PASS: a previous deployment result cannot masquerade as a new success'

Reset-Test
$result = & $subject -EnvironmentName test -RepoRevision $revision -PollSeconds 1 -VerifyOnly
if ($global:privateTest.script -notmatch 'verify-private-deployment.ps1' -or $global:privateTest.script -match 'deploy-on-host.ps1') { throw 'VerifyOnly must not rebuild.' }
Write-Host 'PASS: repeat verification without a rebuild'

foreach ($mode in @('forbidden', 'failed', 'no-result', 'wrong-scope')) {
    Reset-Test $mode
    $threw = $false
    try { & $subject -EnvironmentName test -RepoRevision $revision -PollSeconds 1 | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw "$mode must be a failure, never a successful pending deployment." }
    Write-Host "PASS: $mode is surfaced explicitly"
}
Reset-Test
$threw = $false
try { & $subject -EnvironmentName test -RepoRevision $revision -RepoUrl 'https://user:password@example.test/repo.git' | Out-Null } catch { $threw = $true }
if (-not $threw -or $global:privateTest.puts) { throw 'Repository credentials must not be sent to a VM.' }
Write-Host 'PASS: repository URLs cannot embed credentials'
@{ result = 'passed'; durableExecution = $true; resumesWithoutDuplicateBuild = $true; verifiesBeforeSuccess = $true; excludesCredentials = $true } | ConvertTo-Json -Compress
