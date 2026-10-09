Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The script behaves differently in Azure Cloud Shell; clear its markers so results never depend on where tests run.
$cloudShellMarkers = @{}
foreach ($name in 'ACC_CLOUD', 'AZUREPS_HOST_ENVIRONMENT') {
    $cloudShellMarkers[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}

# Offline harness for scripts/allow-my-ip.ps1: azd, az and the public-address lookup are stubbed.
$global:allowTestState = @{
    environments = @{
        'app-test' = [ordered]@{
            AZURE_RESOURCE_GROUP = 'rg-app-test'
            AZURE_SUBSCRIPTION_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            APP_INGRESS_NSG_NAME = 'nsg-aks-nodes-0123456789abc'
            APP_INGRESS_PUBLIC_IP = '192.0.2.10'
            APP_WEB_ORIGIN = 'https://web.example.test'
            APP_WEB_INGRESS_RESTRICTED = 'true'
            APP_WEB_ALLOWED_IP_RANGES = '203.0.113.7/32'
        }
        'open-test' = [ordered]@{
            AZURE_RESOURCE_GROUP = 'rg-open-test'
            AZURE_SUBSCRIPTION_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            APP_INGRESS_NSG_NAME = 'nsg-aks-nodes-fedcba9876543'
            APP_WEB_INGRESS_RESTRICTED = 'false'
        }
        'private-test' = [ordered]@{
            AZURE_RESOURCE_GROUP = 'rg-private-test'
            AZURE_SUBSCRIPTION_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            APP_INGRESS_NSG_NAME = 'nsg-aks-nodes-0000000000000'
            APP_INGRESS_VISIBILITY = 'private'
            APP_INGRESS_PRIVATE_IP = '10.42.1.36'
            APP_WEB_INGRESS_RESTRICTED = 'true'
        }
    }
    ruleUpdates = [System.Collections.Generic.List[string]]::new()
    otherAzd = [System.Collections.Generic.List[string]]::new()
    routeProbes = [System.Collections.Generic.List[string]]::new()
    lookups = 0
    publicIp = '198.51.100.23'
    # The local address the stubbed routing table uses for the app; Wi-Fi unless a test puts a VPN in between.
    appSource = '192.168.0.10'
    routeFailure = $false
    failRuleUpdate = $false
}

function Get-StubArgument {
    param([object[]] $Arguments, [string] $Name)
    $index = [array]::IndexOf($Arguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $Arguments.Count) { return '' }
    return $Arguments[$index + 1]
}

function Invoke-RestMethod {
    param($Uri, [int] $TimeoutSec)
    if ("$Uri" -ne 'https://api.ipify.org') { throw "Unexpected address lookup: $Uri" }
    $global:allowTestState.lookups++
    return $global:allowTestState.publicIp
}

function azd {
    $raw = @($args)
    $global:LASTEXITCODE = 0
    $state = $global:allowTestState
    if ($raw -notcontains '--no-prompt') { throw "azd must run with --no-prompt: $($raw -join ' ')" }
    $a = @($raw | Where-Object { $_ -ne '--no-prompt' })
    if ($a[0] -ne 'env' -or $a[1] -notin @('get-value', 'set')) {
        $state.otherAzd.Add($a -join ' ')
        throw "The helper may only read and set azd environment values, never redeploy: $($a -join ' ')"
    }
    $values = $state.environments[(Get-StubArgument $a '--environment')]
    if ($a[1] -eq 'get-value') {
        $name = $a[-1]
        if (-not $values.Contains($name)) {
            $global:LASTEXITCODE = 1
            return "ERROR: key '$name' not found"
        }
        return $values[$name]
    }
    $values[$a[4]] = $a[5]
}

function az {
    # A native command receives an array argument as separate values; flatten it the same way.
    $a = @($args | ForEach-Object { $_ })
    $global:LASTEXITCODE = 0
    $state = $global:allowTestState
    if ($a[0] -eq 'network' -and $a[1] -eq 'nsg' -and $a[2] -eq 'rule' -and $a[3] -eq 'update') {
        if ($state.failRuleUpdate) {
            $global:LASTEXITCODE = 1
            return
        }
        $prefixes = @()
        for ($i = [array]::IndexOf($a, '--source-address-prefixes') + 1; $i -lt $a.Count -and -not "$($a[$i])".StartsWith('--'); $i++) { $prefixes += "$($a[$i])" }
        $state.ruleUpdates.Add(('{0}|{1}|{2}|{3}|{4}' -f (Get-StubArgument $a '--resource-group'), (Get-StubArgument $a '--nsg-name'),
            (Get-StubArgument $a '--name'), (Get-StubArgument $a '--subscription'), ($prefixes -join ' ')))
        return
    }
    throw "Unexpected az call: $($a -join ' ')"
}

# The script's route probe is one of its own functions; an alias outranks a function, so this stub replaces it.
function Get-StubSourceAddress {
    param([string] $Destination)
    $state = $global:allowTestState
    $state.routeProbes.Add($Destination)
    if ($state.routeFailure) { throw 'No route to host.' }
    if ($Destination -eq 'api.ipify.org') { return @('192.168.0.10') }
    return @($state.appSource)
}
Set-Alias -Name Resolve-SourceAddress -Value Get-StubSourceAddress

$script = Join-Path $PSScriptRoot '../allow-my-ip.ps1'
$state = $global:allowTestState
$values = $state.environments['app-test']
try {
    # Looks up the current address, replaces the old one, and stores the list only after the rule took it.
    $result = & $script -EnvironmentName 'app-test' | ConvertFrom-Json
    if ($state.lookups -ne 1) { throw 'Without -IpAddress the current public address must be looked up once.' }
    if (($state.ruleUpdates -join ';') -ne 'rg-app-test|nsg-aks-nodes-0123456789abc|AllowHttpsToIngress|aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa|198.51.100.23/32') {
        throw "The HTTPS rule was not updated as expected: $($state.ruleUpdates -join ';')"
    }
    if ($values['APP_WEB_ALLOWED_IP_RANGES'] -ne '198.51.100.23/32' -or $result.previous -ne '203.0.113.7/32' -or -not $result.applied) {
        throw 'The new address must replace the old one in the azd environment.'
    }
    if (($state.routeProbes -join ',') -ne '192.0.2.10,api.ipify.org') {
        throw "Before trusting the lookup, the network paths to the app and to the lookup site must be compared: $($state.routeProbes -join ',')"
    }

    # -Add keeps what is already allowed; an explicit address skips the lookup and the path check.
    & $script -EnvironmentName 'app-test' -IpAddress '203.0.113.0/24' -Add | Out-Null
    if ($state.lookups -ne 1 -or $state.routeProbes.Count -ne 2) { throw 'An explicit -IpAddress must not look the address up or probe routes.' }
    if ($values['APP_WEB_ALLOWED_IP_RANGES'] -ne '198.51.100.23/32,203.0.113.0/24' -or $state.ruleUpdates[-1] -notlike '*|198.51.100.23/32 203.0.113.0/24') {
        throw '-Add must keep the addresses already allowed.'
    }

    # -PlanOnly changes nothing.
    $state.ruleUpdates.Clear()
    $plan = & $script -EnvironmentName 'app-test' -IpAddress '192.0.2.1' -PlanOnly | ConvertFrom-Json
    if ($state.ruleUpdates.Count -or $values['APP_WEB_ALLOWED_IP_RANGES'] -ne '198.51.100.23/32,203.0.113.0/24' -or
        $plan.allowedIpRanges -ne '192.0.2.1/32' -or $plan.applied) {
        throw '-PlanOnly must only report the list it would apply.'
    }

    # Internet-wide, misaligned and non-IPv4 values are refused before anything changes.
    foreach ($bad in @('0.0.0.0/0', '10.0.0.0/7', '198.51.100.7/24', '2001:db8::1', 'not-an-address')) {
        $refused = $null
        try { & $script -EnvironmentName 'app-test' -IpAddress $bad | Out-Null } catch { $refused = $_.Exception.Message }
        if ($refused -notmatch 'IPv4 addresses or CIDR ranges') { throw "'$bad' was not refused: $refused" }
    }
    if ($state.ruleUpdates.Count) { throw 'A refused address must not reach the network rule.' }

    # A failed rule update leaves the stored list as it was.
    $state.failRuleUpdate = $true
    $failed = $null
    try { & $script -EnvironmentName 'app-test' -IpAddress '192.0.2.1' | Out-Null } catch { $failed = $_.Exception.Message }
    if ($failed -notmatch 'allow-list is unchanged' -or $values['APP_WEB_ALLOWED_IP_RANGES'] -ne '198.51.100.23/32,203.0.113.0/24') {
        throw "A failed rule update must leave the stored list alone; got: $failed"
    }
    $state.failRuleUpdate = $false

    # A VPN that carries traffic to the app but not to the lookup site: the app would not see the looked-up address,
    # so the helper stops before the lookup and changes nothing.
    $state.appSource = '100.64.0.10'
    $state.ruleUpdates.Clear()
    $refused = $null
    try { & $script -EnvironmentName 'app-test' | Out-Null } catch { $refused = $_.Exception.Message }
    if ($refused -notmatch 'VPN' -or $refused -notmatch '-IpAddress' -or $refused -notmatch [regex]::Escape('100.64.0.10') -or
        $refused -notmatch 'Nothing was changed' -or $state.lookups -ne 1 -or $state.ruleUpdates.Count -or
        $values['APP_WEB_ALLOWED_IP_RANGES'] -ne '198.51.100.23/32,203.0.113.0/24') {
        throw "A VPN carrying traffic to the app must stop the helper before the lookup; got: $refused"
    }
    $state.appSource = '192.168.0.10'

    # When the paths cannot be compared, the lookup still runs, with a warning.
    $state.routeFailure = $true
    $output = @(& $script -EnvironmentName 'app-test' -PlanOnly 3>&1)
    $warnings = @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    if (-not $warnings.Count -or "$($warnings[0])" -notmatch 'VPN' -or $state.lookups -ne 2 -or $state.ruleUpdates.Count) {
        throw 'An unknown network path must warn and still look the address up.'
    }
    $state.routeFailure = $false

    # Cloud Shell runs in Azure, so a lookup there would return its own, shared address: looking up is refused before
    # anything else happens, and an explicit address still works.
    foreach ($marker in @(@('ACC_CLOUD', 'AzureCloud'), @('AZUREPS_HOST_ENVIRONMENT', 'cloud-shell/1.0'))) {
        [Environment]::SetEnvironmentVariable($marker[0], $marker[1], 'Process')
        try {
            $probesBefore = $state.routeProbes.Count
            $refused = $null
            try { & $script -EnvironmentName 'app-test' | Out-Null } catch { $refused = $_.Exception.Message }
            if ($refused -notmatch 'Cloud Shell' -or $refused -notmatch '-IpAddress' -or $refused -notmatch 'Nothing was changed' -or
                $state.lookups -ne 2 -or $state.routeProbes.Count -ne $probesBefore -or $state.ruleUpdates.Count) {
                throw "With $($marker[0]) set, the lookup must be refused before anything else; got: $refused"
            }
            $explicit = & $script -EnvironmentName 'app-test' -IpAddress '192.0.2.1' -PlanOnly | ConvertFrom-Json
            if ($explicit.allowedIpRanges -ne '192.0.2.1/32') { throw 'An explicit -IpAddress must still work in Cloud Shell.' }
        } finally {
            [Environment]::SetEnvironmentVariable($marker[0], $null, 'Process')
        }
    }

    # Without an allow-list there is no rule to update: the helper points at the deploy script instead.
    $refused = $null
    try { & $script -EnvironmentName 'open-test' | Out-Null } catch { $refused = $_.Exception.Message }
    if ($refused -notmatch 'deploy-end-to-end\.ps1' -or $refused -notmatch '-AllowedIpRanges' -or $state.lookups -ne 2 -or $state.ruleUpdates.Count) {
        throw "An environment without an allow-list must be refused without changes; got: $refused"
    }
    if ($state.otherAzd.Count) { throw "The helper must never redeploy: $($state.otherAzd -join '; ')" }

    # A private ingress has no public address, hence no allow-list: refused with a pointer, before anything is looked up or changed.
    $lookupsBefore = $state.lookups
    $probesBefore = $state.routeProbes.Count
    $refused = $null
    try { & $script -EnvironmentName 'private-test' -IpAddress '192.0.2.1' | Out-Null } catch { $refused = $_.Exception.Message }
    if ($refused -notmatch 'private ingress' -or $refused -notmatch 'no public address' -or $refused -notmatch '-IngressVisibility public' -or
        $state.lookups -ne $lookupsBefore -or $state.routeProbes.Count -ne $probesBefore -or $state.ruleUpdates.Count) {
        throw "A private environment must be refused without any lookup or change; got: $refused"
    }

    [ordered]@{ result = 'passed'; detectsAddress = $true; keepsOthersWithAdd = $true; refusesBroadRanges = $true
                savesOnlyAfterRuleUpdate = $true; noRedeploy = $true; detectsVpnSplitTunnel = $true
                refusesCloudShellLookup = $true } | ConvertTo-Json -Compress
} finally {
    Remove-Variable -Name allowTestState -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -Path Alias:\Resolve-SourceAddress -ErrorAction SilentlyContinue
    foreach ($name in $cloudShellMarkers.Keys) { [Environment]::SetEnvironmentVariable($name, $cloudShellMarkers[$name], 'Process') }
}
