<#
.SYNOPSIS
    Puts a private CloudLens environment's settings and the repository on its deploy host, and prints how to finish the
    deployment there.

.DESCRIPTION
    A private cluster and a private registry are reachable only from inside the virtual network. Terraform created a
    deploy host in it (a Linux VM with no public address, reached through Azure Bastion). This script runs from anywhere:

      - starts the VM if it is stopped (it shuts itself down every day);
      - copies this environment's azd settings to it (never the host's own password) and clones the repository at the
        branch you name, using az vm run-command, which goes through Azure Resource Manager and needs no network path;
      - checks that the host has finished installing its tools;
      - prints the sign-in details and the commands to run on the host.

    deploy-end-to-end.ps1 calls it when it cannot reach the cluster itself. It is safe to rerun, and rerunning it
    refreshes the host's copy of the settings.

.PARAMETER EnvironmentName
    The azd environment of the deployment (it must have been provisioned: the deploy host exists).

.PARAMETER RepoUrl
    Repository to clone on the host.

.PARAMETER RepoBranch
    Branch to check out on the host.

.PARAMETER PlanOnly
    Print what would be done without contacting Azure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')]
    [string] $EnvironmentName,
    [string] $RepoUrl = 'https://github.com/Saby007/CloudLens.git',
    [string] $RepoBranch = 'cloudlensdev',
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.0') { throw 'PowerShell 7 or later is required.' }

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
    if ($text -like 'ERROR:*') { return '' }
    return $text
}

# The host gets what the deployment needs, and no credentials of its own: the admin password stays with whoever deployed.
function Get-ExportableSettings {
    $lines = @(& azd env get-values --environment $EnvironmentName --no-prompt 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $lines.Count) { throw "Unable to read the settings of azd environment '$EnvironmentName'." }
    return @($lines | Where-Object { $_ -match '^[A-Za-z_][A-Za-z0-9_]*=' -and $_ -notmatch '^(APP_DEPLOY_HOST_ADMIN_PASSWORD|[A-Z0-9_]*(SECRET|PASSWORD|TOKEN|KEY))=' })
}

$vmId = Get-AzdValue 'APP_DEPLOY_HOST_ID'
$vmName = Get-AzdValue 'APP_DEPLOY_HOST_NAME'
$adminUser = Get-AzdValue 'APP_DEPLOY_HOST_ADMIN_USERNAME'
$resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
$subscription = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
if (-not $vmId -or -not $vmName) {
    throw "Environment '$EnvironmentName' has no deploy host (APP_DEPLOY_HOST_ID is empty): it was provisioned with -NoDeployHost, or not yet. Provision it first, or deploy from a machine connected to the cluster's virtual network with scripts/deploy-on-host.ps1."
}
if (-not $adminUser) { $adminUser = 'cloudlensadmin' }
$hostHome = "/home/$adminUser"

if ($PlanOnly) {
    [pscustomobject]@{
        environment = $EnvironmentName
        deployHost = $vmName
        resourceGroup = $resourceGroup
        copies = "$hostHome/cloudlens/$EnvironmentName.env"
        clones = "$RepoUrl@$RepoBranch -> $hostHome/cloudlens/CloudLens"
    } | ConvertTo-Json
    exit 0
}

if ($RepoUrl -notmatch '^https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$' -or $RepoBranch -notmatch '^[A-Za-z0-9._/-]+$') {
    throw 'The repository URL must be https and the branch name plain characters.'
}

$state = Get-CliText (& az vm get-instance-view --ids $vmId --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" --output tsv --only-show-errors 2>$null)
if ($state -ne 'PowerState/running') {
    Write-Host "The deploy host is '$state'; starting it (it shuts down every day to save cost)." -ForegroundColor Yellow
    & az vm start --ids $vmId --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw "Unable to start the deploy host $vmName." }
}


$settingsText = (Get-ExportableSettings) -join "`n"
$settingsBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($settingsText + "`n"))
# Runs as root on the host. The branch and URL are validated by git itself; they are passed as data, not interpreted.
$script = @"
set -eu
install -d -o $adminUser -g $adminUser -m 700 $hostHome/cloudlens
echo '$settingsBase64' | base64 -d > $hostHome/cloudlens/$EnvironmentName.env
chown $adminUser`:$adminUser $hostHome/cloudlens/$EnvironmentName.env
chmod 600 $hostHome/cloudlens/$EnvironmentName.env
if [ -d $hostHome/cloudlens/CloudLens/.git ]; then
  sudo -u $adminUser git -C $hostHome/cloudlens/CloudLens fetch --quiet origin '$RepoBranch'
  sudo -u $adminUser git -C $hostHome/cloudlens/CloudLens checkout --quiet -B '$RepoBranch' FETCH_HEAD
else
  sudo -u $adminUser git clone --quiet --branch '$RepoBranch' '$RepoUrl' $hostHome/cloudlens/CloudLens
fi
if [ -f /var/lib/cloudlens/tools-ready ]; then echo TOOLS_READY; else echo TOOLS_PENDING; fi
"@

Write-Host "Copying the settings and the repository to $vmName (through Azure Resource Manager, no network path needed)..." -ForegroundColor Cyan
$result = Get-CliText (& az vm run-command invoke --ids $vmId --command-id RunShellScript --scripts $script --query 'value[0].message' --output tsv --only-show-errors 2>&1)
if ($LASTEXITCODE -ne 0) { throw "The run command on $vmName failed: $result" }
if ($result -match 'TOOLS_PENDING') {
    Write-Warning 'The deploy host is still installing its tools (about 10 minutes after it is created). Check on it with: az vm run-command invoke --ids <vm id> --command-id RunShellScript --scripts "tail -5 /var/log/cloudlens-tools.log". Wait until /var/lib/cloudlens/tools-ready exists before deploying.'
} elseif ($result -notmatch 'TOOLS_READY') {
    throw "The deploy host did not report its state; the run command returned: $result"
}

$password = Get-AzdValue 'APP_DEPLOY_HOST_ADMIN_PASSWORD'
Write-Host ''
Write-Host "The deploy host is ready: $vmName in $resourceGroup." -ForegroundColor Green
Write-Host '  1. Azure portal -> the VM -> Connect -> Bastion, user ' -NoNewline
Write-Host $adminUser -ForegroundColor Yellow -NoNewline
Write-Host ', password from:  azd env get-value APP_DEPLOY_HOST_ADMIN_PASSWORD' -NoNewline
if (-not $password) { Write-Host ' (not in this environment; reset it in the portal: VM -> Reset password)' -NoNewline }
Write-Host ''
Write-Host '  2. On the host, sign in and deploy:'
Write-Host '       az login --use-device-code'
Write-Host '       azd auth login --use-device-code'
Write-Host '       cd ~/cloudlens/CloudLens'
Write-Host "       pwsh ./scripts/deploy-on-host.ps1 -EnvironmentName $EnvironmentName -EnvFile ~/cloudlens/$EnvironmentName.env"
Write-Host "  The host's address for outbound traffic is $(Get-AzdValue 'APP_NAT_GATEWAY_IP') (shared with the cluster)."
Write-Host "  The host shuts down every day; start it again with: az vm start --ids $vmId"
