<#
.SYNOPSIS
    Keeps an environment's IP allow-list current: points it at your public IP address in seconds, without a redeploy.

.DESCRIPTION
    In operator mode (deploy-end-to-end.ps1 -OperatorMode) the app has no sign-in, so its public URL answers only
    the addresses in APP_WEB_ALLOWED_IP_RANGES. When your address changes, run this script. It updates the HTTPS
    rule of the node subnet's network security group in place, then stores the new list in the azd environment so
    later provisions keep it. The list must already be in place: deploy once with -AllowedIpRanges to create it.

    Without -IpAddress, your current public IPv4 address is looked up at https://api.ipify.org. That address is only
    the one the app sees if your traffic to the app takes the same network path as the lookup. A VPN that carries
    only some destinations - Microsoft's carries Azure's address ranges - sends your traffic to the app through the
    VPN instead, so the app sees the VPN's exit address. The script checks this first and stops without changes.
    In Azure Cloud Shell, which runs in Azure, it does not look the address up at all: pass your computer's
    address with -IpAddress.

.PARAMETER EnvironmentName
    The azd environment whose allow-list to update.

.PARAMETER IpAddress
    IPv4 address or CIDR range to allow (comma-separated for several) instead of looking up your current address.

.PARAMETER Add
    Keep the addresses already allowed, for example an office range, and add this one.

.PARAMETER PlanOnly
    Print the list that would be applied without changing anything.

.EXAMPLE
    pwsh ./scripts/allow-my-ip.ps1 -EnvironmentName my-dev

.EXAMPLE
    pwsh ./scripts/allow-my-ip.ps1 -EnvironmentName my-dev -IpAddress 198.51.100.0/24 -Add
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,63}$')]
    [string] $EnvironmentName,
    [string] $IpAddress = '',
    [switch] $Add,
    [switch] $PlanOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion -lt [version]'7.4') { throw 'PowerShell 7.4 or later is required.' }

$ruleName = 'AllowHttpsToIngress'

function Get-AzdValue {
    param([Parameter(Mandatory)][string] $Name)
    $value = & azd env get-value --environment $EnvironmentName $Name --no-prompt 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    $text = ((@($value | Where-Object { $null -ne $_ }) -join "`n")).Trim()
    # azd prints the literal string "ERROR: ..." for keys the environment has never held.
    if ($text -like 'ERROR:*') { return '' }
    return $text
}

# The same rules Terraform's web_allowed_ip_ranges validation applies: IPv4, /8 to /32, written with the network address.
function ConvertTo-IpAllowList {
    param([AllowEmptyString()][string] $Value)
    $ranges = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @("$Value" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $text = if ($item.Contains('/')) { $item } else { "$item/32" }
        $network = [System.Net.IPNetwork]::new([System.Net.IPAddress]::Any, 0)
        if ($text -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' -or -not [System.Net.IPNetwork]::TryParse($text, [ref] $network) -or
            $network.PrefixLength -lt 8 -or "$($network.BaseAddress)/$($network.PrefixLength)" -cne $text) {
            throw "Allowed addresses must be IPv4 addresses or CIDR ranges from /8 to /32 written with their network address, for example 203.0.113.7 or 198.51.100.0/24; '$item' is not one."
        }
        if (-not $ranges.Contains($text)) { $ranges.Add($text) }
    }
    return ($ranges -join ',')
}

# The local addresses this machine sends from to reach a destination. Connecting a UDP socket only consults the
# routing table - no packet is sent - so a different answer for two destinations means two networks carry them.
function Resolve-SourceAddress {
    param([Parameter(Mandatory)][string] $Destination)
    $sources = foreach ($address in [System.Net.Dns]::GetHostAddresses($Destination)) {
        if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
        $socket = [System.Net.Sockets.Socket]::new([System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        try {
            $socket.Connect($address, 443)
            $socket.LocalEndPoint.Address.ToString()
        } finally {
            $socket.Dispose()
        }
    }
    return @($sources | Select-Object -Unique)
}

# azd finds the environment through the project's azure.yaml.
Push-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
try {
    if ((Get-AzdValue 'APP_WEB_INGRESS_RESTRICTED') -ne 'true') {
        throw "The public URL of '$EnvironmentName' is not on an IP allow-list yet, so there is no rule to update. Run scripts/deploy-end-to-end.ps1 with -AllowedIpRanges '<your IP>' once (with -OperatorMode for an environment without sign-in); this script keeps the list current after that."
    }
    $resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
    $nsgName = Get-AzdValue 'APP_INGRESS_NSG_NAME'
    $subscription = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
    if (-not $resourceGroup -or -not $nsgName -or -not $subscription) {
        throw "The azd environment '$EnvironmentName' does not name its resource group, subscription and network security group. Rerun scripts/deploy-end-to-end.ps1 once to refresh it."
    }

    if (-not $IpAddress) {
        # Cloud Shell sets ACC_CLOUD in every shell. It runs in Azure, so a lookup there would return Cloud Shell's own
        # address, which other people's sessions share.
        if ($env:ACC_CLOUD -or "$env:AZUREPS_HOST_ENVIRONMENT" -like 'cloud-shell*') {
            throw "This is Azure Cloud Shell, which runs in Azure: looking your address up here would return Cloud Shell's own address, shared with other people's sessions, not your computer's. Nothing was changed. Open https://api.ipify.org in your computer's browser (with any VPN off) and pass that address with -IpAddress."
        }
        # The lookup site sees whichever network carries traffic to it, which is not always the one carrying traffic to the app.
        $appHost = Get-AzdValue 'APP_INGRESS_PUBLIC_IP'
        if (-not $appHost) { $appHost = (Get-AzdValue 'APP_WEB_ORIGIN') -replace '^https://', '' }
        $appSources = @()
        $lookupSources = @()
        try {
            if ($appHost) { $appSources = @(Resolve-SourceAddress $appHost) }
            $lookupSources = @(Resolve-SourceAddress 'api.ipify.org')
        } catch {
            $appSources = @()
        }
        if (-not $appSources.Count -or -not $lookupSources.Count) {
            Write-Warning "Could not check which network carries this machine's traffic to the app. On a VPN that carries Azure traffic, the app sees the VPN's exit address rather than the one looked up here."
        } elseif (@($lookupSources | Where-Object { $_ -notin $appSources }).Count) {
            throw "This machine reaches the app ($appHost) from $($appSources -join ', ') but the IP lookup site from $($lookupSources -join ', '): a VPN or second network carries your traffic to the app, so the app would not see the address the lookup reports. Nothing was changed. Disconnect the VPN and rerun this script, or use kubectl port-forward while it is connected. To allow that network anyway, pass its exit address with -IpAddress - everyone else on it could then reach the app as you."
        }
        try {
            $IpAddress = "$(Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15)".Trim()
        } catch {
            throw "Your public IP address could not be looked up ($($_.Exception.Message)). Pass it with -IpAddress."
        }
        Write-Host "Your public IP address is $IpAddress."
    }
    $current = Get-AzdValue 'APP_WEB_ALLOWED_IP_RANGES'
    $ranges = ConvertTo-IpAllowList $(if ($Add) { "$current,$IpAddress" } else { $IpAddress })
    if (-not $ranges) { throw 'Pass at least one address with -IpAddress.' }
    $result = [ordered]@{ environment = $EnvironmentName; previous = $current; allowedIpRanges = $ranges; applied = $false }

    if (-not $PlanOnly) {
        # Applied even when the list looks unchanged: it is idempotent and also repairs a rule changed by hand.
        & az network nsg rule update --resource-group $resourceGroup --nsg-name $nsgName --name $ruleName --subscription $subscription `
            --source-address-prefixes @($ranges -split ',') --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) { throw "Updating $ruleName on $nsgName failed, so the allow-list is unchanged." }
        & azd env set --environment $EnvironmentName APP_WEB_ALLOWED_IP_RANGES $ranges --no-prompt | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "The network rule now allows $ranges, but saving the list in azd environment '$EnvironmentName' failed, so the next provision would restore the old one. Run: azd env set APP_WEB_ALLOWED_IP_RANGES '$ranges' --environment $EnvironmentName"
        }
        $result.applied = $true
        Write-Host "HTTPS to $(Get-AzdValue 'APP_WEB_ORIGIN') is now limited to: $($ranges -replace ',', ', ')" -ForegroundColor Green
    }
    [pscustomobject] $result | ConvertTo-Json -Compress
} finally {
    Pop-Location
}
