<#
.SYNOPSIS
    Builds, deploys and verifies CloudLens on its private VM without SSH, Bastion, VPN or copied login tokens.
    Managed Run Command survives a Cloud Shell disconnect; a rerun waits for an existing execution.
.PARAMETER VerifyOnly
    Repeat the private networking, rollout and HTTPS checks without rebuilding the images.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')]
    [string] $EnvironmentName,
    [string] $RepoUrl = 'https://github.com/Saby007/CloudLens.git',
    [string] $RepoRevision = '',
    [ValidateRange(600, 14400)]
    [int] $TimeoutSeconds = 7200,
    [ValidateRange(1, 120)]
    [int] $PollSeconds = 15,
    [switch] $VerifyOnly,
    [switch] $KeepDeployHostRunning,
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CliText {
    param($Value)
    return (@($Value | Where-Object { $null -ne $_ }) -join "`n").Trim()
}

function Get-AzdValue {
    param([string] $Name)
    $value = & azd env get-value --environment $EnvironmentName $Name --no-prompt 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Required deployment output $Name is unavailable." }
    return Get-CliText $value
}

function Invoke-Az {
    param([string[]] $Arguments)
    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0]) failed: $(Get-CliText $output)" }
    return Get-CliText $output
}

$vmId = Get-AzdValue 'APP_DEPLOY_HOST_ID'
$subscription = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
$location = Get-AzdValue 'AZURE_LOCATION'
if ($vmId -notmatch "^/subscriptions/$([regex]::Escape($subscription))/resourceGroups/[^/]+/providers/Microsoft.Compute/virtualMachines/[^/]+$") {
    throw 'No deploy host exists in this environment. Provision it, or run deploy-on-host.ps1 from a connected network.'
}
if (-not $RepoRevision) {
    $RepoRevision = Get-CliText (& git -C (Join-Path $PSScriptRoot '..') rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve the exact source revision to deploy.' }
}
if ($RepoRevision -notmatch '^[a-f0-9]{40,64}$' -or $RepoUrl -notmatch '^https://[A-Za-z0-9._:/-]+\.git$') {
    throw 'Deployment requires an HTTPS Git repository URL without credentials and an exact commit hash.'
}
$commandName = if ($VerifyOnly) { 'cloudlens-verify' } else { 'cloudlens-deploy' }
$commandUrl = "https://management.azure.com$vmId/runCommands/${commandName}?api-version=2024-07-01"
$logFile = "/var/log/cloudlens-$commandName-$EnvironmentName.log"
if ($PlanOnly) {
    [pscustomobject]@{
        deployHost = $vmId
        revision = $RepoRevision
        authentication = 'system-assigned managed identity'
        transport = 'Azure managed Run Command'
        verifyOnly = [bool]$VerifyOnly
        logFile = $logFile
    } | ConvertTo-Json
    exit 0
}

function Get-RunCommand {
    $output = & az rest --method get --url "$commandUrl&`$expand=instanceView" --output json --only-show-errors 2>&1
    $text = Get-CliText $output
    if ($LASTEXITCODE -ne 0) {
        if ($text -match '\(ResourceNotFound\)|\(NotFound\)|"code"\s*:\s*"(ResourceNotFound|NotFound)"') { return $null }
        throw "Unable to inspect managed Run Command: $text"
    }
    return $text | ConvertFrom-Json -AsHashtable
}

$state = Invoke-Az @('vm', 'get-instance-view', '--ids', $vmId, '--query', "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]", '-o', 'tsv')
if ($state -ne 'PowerState/running') {
    Write-Host 'Starting the private deploy host...' -ForegroundColor Cyan
    $null = Invoke-Az @('vm', 'start', '--ids', $vmId, '-o', 'none')
}
$existing = Get-RunCommand
$existingView = if ($existing -and $existing.properties['instanceView'] -is [Collections.IDictionary]) { $existing.properties['instanceView'] } else { @{} }
if ($existing -and $existing.properties['provisioningState'] -notin @('Failed', 'Canceled') -and
    $existingView['executionState'] -notin @('Succeeded', 'Failed', 'Canceled', 'TimedOut')) {
    $requestMatch = [regex]::Match($existing.properties.source.script, '(?m)^# request ([a-f0-9]{32})\r?$')
    if (-not $requestMatch.Success) { throw 'An unrecognized managed command is running; inspect it before starting another deployment.' }
    $requestId = $requestMatch.Groups[1].Value
    Write-Host 'Resuming the existing private execution; not starting a second build.' -ForegroundColor Cyan
} else {
    $requestId = [guid]::NewGuid().ToString('n')
    $settings = & azd env get-values --environment $EnvironmentName --no-prompt 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to export deployment settings.' }
    $settings = @($settings | Where-Object {
        $_ -match '^[A-Za-z_][A-Za-z0-9_]*=' -and
        $_ -notmatch '^([A-Z0-9_]*(SECRET|PASSWORD|TOKEN|KEY)|ARM_[A-Z0-9_]+)='
    })
    if (-not $settings.Count) { throw 'No deployment settings were exported.' }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($settings -join "`n") + "`n"))
    $deployCommand = if ($VerifyOnly) {
        'pwsh -NoLogo -NoProfile -File ./scripts/verify-private-deployment.ps1 -EnvironmentName "$environment" -ResultFile "$work/result.json"'
    } else {
        'pwsh -NoLogo -NoProfile -File ./scripts/deploy-on-host.ps1 -EnvironmentName "$environment" -EnvFile "$work/settings.env" -SkipLogin -Verify -ResultFile "$work/result.json"'
    }
    $remoteScript = @'
set -eu
umask 077
environment='__ENVIRONMENT__'
work="/var/lib/cloudlens/deployments/$environment"
log='__LOG__'
mkdir -p "$work"
trap 'status=$?; if [ "$status" -ne 0 ]; then tail -n 40 "$log"; fi; exit "$status"' EXIT
{
  deadline=$(($(date +%s) + 1800))
  while [ ! -f /var/lib/cloudlens/tools-ready ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      tail -n 40 /var/log/cloudlens-tools.log
      echo "Deploy host tools did not become ready in 30 minutes." >&2
      exit 1
    fi
    sleep 15
  done
  printf '%s' '__SETTINGS__' | base64 -d > "$work/settings.env"
  export AZURE_CONFIG_DIR="$work/azure-cli"
  export AZURE_EXTENSION_USE_DYNAMIC_INSTALL=yes_without_prompt
  export CLOUDLENS_DEPLOY_REQUEST_ID='__REQUEST_ID__'
  export CLOUDLENS_SOURCE_REVISION='__REVISION__'
  az login --identity --output none --only-show-errors
  az account set --subscription '__SUBSCRIPTION__'
  azd auth login --managed-identity --no-prompt
  if [ ! -d "$work/CloudLens/.git" ]; then
    git clone --quiet --no-checkout '__REPOSITORY__' "$work/CloudLens"
  fi
  git -C "$work/CloudLens" fetch --quiet origin '__REVISION__'
  git -C "$work/CloudLens" checkout --quiet --detach '__REVISION__'
  cd "$work/CloudLens"
  __DEPLOY__
} >> "$log" 2>&1
printf 'CLOUDLENS_RESULT:'
cat "$work/result.json"
printf '\n'
'@
    $remoteScript = $remoteScript.Replace('__ENVIRONMENT__', $EnvironmentName).Replace('__LOG__', $logFile).
        Replace('__SETTINGS__', $encoded).Replace('__SUBSCRIPTION__', $subscription).
        Replace('__REPOSITORY__', $RepoUrl).Replace('__REVISION__', $RepoRevision).Replace('__DEPLOY__', $deployCommand).
        Replace('__REQUEST_ID__', $requestId)
    $remoteScript = ($remoteScript -replace "`r`n", "`n") + "`n# request $requestId`n"
    $request = @{
        location = $location
        properties = @{ source = @{ script = $remoteScript }; asyncExecution = $true; timeoutInSeconds = $TimeoutSeconds }
    }
    $requestFile = Join-Path ([IO.Path]::GetTempPath()) "cloudlens-run-$([guid]::NewGuid().ToString('n')).json"
    try {
        [IO.File]::WriteAllText($requestFile, ($request | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        Write-Host 'Starting the private build/deploy and HTTPS verification through Azure Resource Manager...' -ForegroundColor Cyan
        $null = Invoke-Az @('rest', '--method', 'put', '--url', $commandUrl, '--body', "@$requestFile", '-o', 'none')
    } finally {
        Remove-Item -LiteralPath $requestFile -Force
    }
}

$clock = [Diagnostics.Stopwatch]::StartNew()
do {
    $command = Get-RunCommand
    $view = if ($command -and $command.properties['instanceView'] -is [Collections.IDictionary]) { $command.properties['instanceView'] } else { @{} }
    $execution = $view['executionState']
    if ($execution -eq 'Succeeded') {
        if ($view['exitCode'] -ne 0) { throw "Private execution failed with exit code $($view['exitCode']): $($view['error']) $($view['output'])" }
        $match = [regex]::Match("$($view['output'])", '(?m)^CLOUDLENS_RESULT:(\{[^\r\n]*\})\r?$')
        if (-not $match.Success) { throw "The host did not report a verified result. Inspect $logFile on the deploy host; no success was assumed." }
        $result = $match.Groups[1].Value | ConvertFrom-Json
        if ($result.requestId -eq $requestId) {
            if ($result.healthy -ne $true -or $result.environment -ne $EnvironmentName) { throw 'The host returned an unhealthy or out-of-scope result.' }
            if ($result.sourceRevision -ne $RepoRevision) { throw 'The resumed job completed at an older source revision. Rerun this command to deploy the current checkout.' }
            if (-not $KeepDeployHostRunning) {
                Write-Host 'Verification succeeded; deallocating the build VM (the application keeps running on AKS).' -ForegroundColor Cyan
                $null = Invoke-Az @('vm', 'deallocate', '--ids', $vmId, '-o', 'none')
            }
            return $result
        }
    }
    if ($execution -in @('Failed', 'Canceled', 'TimedOut') -or ($command -and $command.properties['provisioningState'] -eq 'Failed')) {
        throw "Private execution failed ($execution). $($view['error']) $($view['output']) Log: $logFile"
    }
    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        throw "Timed out waiting for the host. The managed command may still be running; rerun to resume monitoring. Log: $logFile"
    }
    Write-Host "  Private execution: $(if ($execution) { $execution } else { 'starting' }); $([int]$clock.Elapsed.TotalSeconds)s elapsed." -ForegroundColor DarkGray
    Start-Sleep -Seconds $PollSeconds
} while ($true)
