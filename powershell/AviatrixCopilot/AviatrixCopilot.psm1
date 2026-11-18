# CoPilot's web UI authenticates against POST /api/login with a plain JSON
# {username, password} body and a cookie-based session (confirmed against a
# live CoPilot instance: the "session"/"session.sig" cookies set on login are
# cleared by GET /api/logout). This is CoPilot's own API, distinct from the
# Controller's CID-based /v2/api/login.

$Script:AviatrixCopilotSession = $null

function Get-AviatrixCopilotErrorMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    }
    elseif ($ErrorRecord.Exception.Response) {
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
        }
        catch {
            $body = $null
        }
    }

    if ($body) {
        try {
            $parsed = $body | ConvertFrom-Json -ErrorAction Stop
            if ($parsed.message) {
                return $parsed.message
            }
        }
        catch {
            # Body wasn't JSON; fall through and return it as-is.
        }
        return $body
    }

    return $ErrorRecord.Exception.Message
}

function Get-AviatrixCopilotSkipCertParams {
    [CmdletBinding()]
    param(
        [switch]$SkipCertificateCheck
    )

    $params = @{}
    if (-not $SkipCertificateCheck) {
        return $params
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $params['SkipCertificateCheck'] = $true
    }
    else {
        # Windows PowerShell 5.1 has no -SkipCertificateCheck; bypass cert
        # validation process-wide for this session instead.
        if (-not ('AviatrixCopilotCertPolicy' -as [type])) {
            Add-Type @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class AviatrixCopilotCertPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
'@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object AviatrixCopilotCertPolicy
    }

    return $params
}

function ConvertTo-AviatrixCopilotQueryString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Parameters
    )

    ($Parameters.GetEnumerator() | Where-Object { $null -ne $_.Value -and $_.Value -ne '' } | ForEach-Object {
        "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))"
    }) -join '&'
}

function ConvertTo-AviatrixCopilotUtcIso8601 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$Date
    )

    # /get_performance_gateway_interface_stats rejects epoch_millis with
    # "Must be a valid UTC ISO datetime"; a strict ISO 8601 UTC string is
    # the only format it accepts (confirmed against a live CoPilot instance).
    $Date.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function Get-AviatrixCopilotTimeRange {
    <#
    .SYNOPSIS
        Converts a named time range such as Last24Hours into Start and End dates.
    .DESCRIPTION
        Ranges end now. LastMonth is a rolling month back from now, not the previous calendar month.
        For a custom range, pass -Start and -End to the commands directly.
    .EXAMPLE
        Get-AviatrixCopilotTimeRange -Range Last7Days
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Last15Min', 'Last30Min', 'Last60Min', 'Last24Hours', 'Last7Days', 'LastMonth')]
        [string]$Range
    )

    $end = Get-Date
    $start = switch ($Range) {
        'Last15Min'   { $end.AddMinutes(-15) }
        'Last30Min'   { $end.AddMinutes(-30) }
        'Last60Min'   { $end.AddMinutes(-60) }
        'Last24Hours' { $end.AddHours(-24) }
        'Last7Days'   { $end.AddDays(-7) }
        'LastMonth'   { $end.AddMonths(-1) }
    }
    [PSCustomObject]@{ Start = $start; End = $end }
}

function Connect-AviatrixCopilot {
    <#
    .SYNOPSIS
        Logs in to Aviatrix CoPilot with a local user account.
    .DESCRIPTION
        If -Credential is omitted, the COPILOT_USER and COPILOT_PASSWORD environment variables
        are used when both are set; otherwise you are prompted. With -SkipCertificateCheck the
        session remembers it, so Disconnect-AviatrixCopilot and
        Export-AviatrixCopilotConnectionMetric do not need the switch again.
    .EXAMPLE
        Connect-AviatrixCopilot -ComputerName copilot.contoso.com -Credential (Get-Credential)
    .EXAMPLE
        $env:COPILOT_USER = 'admin'; $env:COPILOT_PASSWORD = '<password>'
        Connect-AviatrixCopilot -ComputerName copilot.contoso.com -SkipCertificateCheck
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [PSCredential]$Credential,

        [int]$Port = 443,

        [switch]$SkipCertificateCheck
    )

    if (-not $Credential) {
        $Credential = if ($env:COPILOT_USER -and $env:COPILOT_PASSWORD) {
            [PSCredential]::new($env:COPILOT_USER, (ConvertTo-SecureString $env:COPILOT_PASSWORD -AsPlainText -Force))
        }
        else { Get-Credential -Message "Aviatrix CoPilot login for $ComputerName" }
    }

    $baseUri = "https://${ComputerName}:${Port}"
    $loginUri = "$baseUri/api/login"

    $body = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
    } | ConvertTo-Json

    $invokeParams = @{
        Uri             = $loginUri
        Method          = 'Post'
        Body            = $body
        ContentType     = 'application/json'
        SessionVariable = 'webSession'
        ErrorAction     = 'Stop'
    }
    foreach ($kv in (Get-AviatrixCopilotSkipCertParams -SkipCertificateCheck:$SkipCertificateCheck).GetEnumerator()) {
        $invokeParams[$kv.Key] = $kv.Value
    }

    try {
        Invoke-RestMethod @invokeParams | Out-Null
    }
    catch {
        throw "Aviatrix CoPilot login failed: $(Get-AviatrixCopilotErrorMessage $_)"
    }

    $Script:AviatrixCopilotSession = [PSCustomObject]@{
        BaseUri    = $baseUri
        UserName   = $Credential.UserName
        WebSession = $webSession
        LoggedInAt = Get-Date
        SkipCertificateCheck = [bool]$SkipCertificateCheck
    }

    Write-Verbose "Logged in to Aviatrix CoPilot at $baseUri as $($Credential.UserName)."
    return $Script:AviatrixCopilotSession
}

function Disconnect-AviatrixCopilot {
    <#
    .SYNOPSIS
        Logs out of the current Aviatrix CoPilot session, if any.
    #>
    [CmdletBinding()]
    param(
        [switch]$SkipCertificateCheck
    )

    if (-not $Script:AviatrixCopilotSession) {
        Write-Verbose 'No active Aviatrix CoPilot session.'
        return
    }

    $skipCert = $SkipCertificateCheck -or $Script:AviatrixCopilotSession.SkipCertificateCheck
    $invokeParams = @{
        Uri         = "$($Script:AviatrixCopilotSession.BaseUri)/api/logout"
        Method      = 'Get'
        WebSession  = $Script:AviatrixCopilotSession.WebSession
        ErrorAction = 'Stop'
    }
    foreach ($kv in (Get-AviatrixCopilotSkipCertParams -SkipCertificateCheck:$skipCert).GetEnumerator()) {
        $invokeParams[$kv.Key] = $kv.Value
    }

    try {
        Invoke-RestMethod @invokeParams | Out-Null
    }
    catch {
        Write-Warning "Logout request failed, clearing local session anyway: $(Get-AviatrixCopilotErrorMessage $_)"
    }
    finally {
        $Script:AviatrixCopilotSession = $null
    }
}

function Get-AviatrixCopilotSession {
    <#
    .SYNOPSIS
        Returns the current Aviatrix CoPilot session, if logged in.
    #>
    [CmdletBinding()]
    param()

    $Script:AviatrixCopilotSession
}

function Get-AviatrixCopilotGatewayInterface {
    <#
    .SYNOPSIS
        Lists the gateway interfaces that have performance data for a time range.
    .EXAMPLE
        Get-AviatrixCopilotGatewayInterface -GatewayName transit-gw-1 -Start (Get-Date).AddDays(-1) -End (Get-Date) -SkipCertificateCheck
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$GatewayName,

        [Parameter(Mandatory)]
        [datetime]$Start,

        [Parameter(Mandatory)]
        [datetime]$End,

        [switch]$SkipCertificateCheck
    )

    $session = Get-AviatrixCopilotSession
    if (-not $session) {
        throw 'Not connected to Aviatrix CoPilot. Run Connect-AviatrixCopilot first.'
    }

    $query = @{
        gatewayName = $GatewayName
        start       = ConvertTo-AviatrixCopilotUtcIso8601 $Start
        end         = ConvertTo-AviatrixCopilotUtcIso8601 $End
    }

    $invokeParams = @{
        Uri         = "$($session.BaseUri)/api/get_performance_gateway_interfaces?$(ConvertTo-AviatrixCopilotQueryString $query)"
        Method      = 'Get'
        WebSession  = $session.WebSession
        ErrorAction = 'Stop'
    }
    foreach ($kv in (Get-AviatrixCopilotSkipCertParams -SkipCertificateCheck:$SkipCertificateCheck).GetEnumerator()) {
        $invokeParams[$kv.Key] = $kv.Value
    }

    try {
        $response = Invoke-RestMethod @invokeParams
    }
    catch {
        throw "Failed to get Aviatrix CoPilot gateway interfaces: $(Get-AviatrixCopilotErrorMessage $_)"
    }

    # Invoke-RestMethod writes a top-level JSON array as a single
    # non-enumerated pipeline object; re-emitting the captured variable here
    # forces normal one-item-at-a-time enumeration for callers piping into
    # Where-Object (otherwise -like/-eq compare against the whole array and
    # can produce false-positive matches).
    return $response
}

function Get-AviatrixCopilotGatewayInterfaceStats {
    <#
    .SYNOPSIS
        Gets a performance metric time series for one gateway interface.
    .EXAMPLE
        Get-AviatrixCopilotGatewayInterfaceStats -GatewayName transit-gw-1 -InterfaceName tun-0A000184-0 `
            -Metric rate_total -AggMethod avg -Start (Get-Date).AddHours(-24) -End (Get-Date) -SkipCertificateCheck
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$GatewayName,

        [Parameter(Mandatory)]
        [string]$InterfaceName,

        [Parameter(Mandatory)]
        [string]$Metric,

        [ValidateSet('avg', 'max', 'min', 'sum')]
        [string]$AggMethod,

        [Parameter(Mandatory)]
        [datetime]$Start,

        [Parameter(Mandatory)]
        [datetime]$End,

        [switch]$SkipCertificateCheck
    )

    $session = Get-AviatrixCopilotSession
    if (-not $session) {
        throw 'Not connected to Aviatrix CoPilot. Run Connect-AviatrixCopilot first.'
    }

    $query = @{
        gatewayName   = $GatewayName
        interfaceName = $InterfaceName
        metric        = $Metric
        aggMethod     = $AggMethod
        start         = ConvertTo-AviatrixCopilotUtcIso8601 $Start
        end           = ConvertTo-AviatrixCopilotUtcIso8601 $End
    }

    $invokeParams = @{
        Uri         = "$($session.BaseUri)/api/get_performance_gateway_interface_stats?$(ConvertTo-AviatrixCopilotQueryString $query)"
        Method      = 'Get'
        WebSession  = $session.WebSession
        ErrorAction = 'Stop'
    }
    foreach ($kv in (Get-AviatrixCopilotSkipCertParams -SkipCertificateCheck:$SkipCertificateCheck).GetEnumerator()) {
        $invokeParams[$kv.Key] = $kv.Value
    }

    try {
        $response = Invoke-RestMethod @invokeParams
    }
    catch {
        throw "Failed to get Aviatrix CoPilot gateway interface stats: $(Get-AviatrixCopilotErrorMessage $_)"
    }

    # See the matching comment in Get-AviatrixCopilotGatewayInterface: this
    # response is also a top-level JSON array and needs the same explicit
    # re-emit to enumerate normally for callers.
    return $response
}

function Get-AviatrixCopilotGatewayPairTunnelStats {
    <#
    .SYNOPSIS
        Gets a performance metric time series for every tunnel between two gateways.
    .EXAMPLE
        Get-AviatrixCopilotGatewayPairTunnelStats -GatewayName transit-gw-1 -PeerGatewayName transit-gw-2 `
            -Metric rate_total -AggMethod avg -Start (Get-Date).AddHours(-24) -End (Get-Date) -SkipCertificateCheck
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$GatewayName,

        [Parameter(Mandatory)]
        [string]$PeerGatewayName,

        [Parameter(Mandatory)]
        [string]$Metric,

        [ValidateSet('avg', 'max', 'min', 'sum')]
        [string]$AggMethod,

        [Parameter(Mandatory)]
        [datetime]$Start,

        [Parameter(Mandatory)]
        [datetime]$End,

        [switch]$SkipCertificateCheck
    )

    if (-not (Get-AviatrixCopilotSession)) {
        throw 'Not connected to Aviatrix CoPilot. Run Connect-AviatrixCopilot first.'
    }

    $tunnels = Get-AviatrixCopilotGatewayInterface -GatewayName $GatewayName -Start $Start -End $End -SkipCertificateCheck:$SkipCertificateCheck |
        Where-Object { $_.interfaceName -like 'tun-*' -and $_.destinationGateway -eq $PeerGatewayName }

    if (-not $tunnels) {
        throw "No tunnels found between '$GatewayName' and '$PeerGatewayName' in the given time range."
    }

    foreach ($tunnel in $tunnels) {
        $stats = Get-AviatrixCopilotGatewayInterfaceStats -GatewayName $GatewayName -InterfaceName $tunnel.interfaceName `
            -Metric $Metric -AggMethod $AggMethod -Start $Start -End $End -SkipCertificateCheck:$SkipCertificateCheck

        [PSCustomObject]@{
            GatewayName        = $GatewayName
            DestinationGateway = $PeerGatewayName
            InterfaceName      = $tunnel.interfaceName
            Metric             = $Metric
            Series             = $stats.($Metric).($GatewayName).($tunnel.interfaceName)
        }
    }
}

# --- Topology discovery -----------------------------------------------------
# CoPilot has no gateway-list endpoint we can rely on, but every tunnel
# interface reports its destinationGateway. Starting from the transit
# gateways you name, that is enough to derive every spoke->transit attachment
# and transit<->transit peering. HA gateways (<name>-hagw) are queried too and
# are treated as part of the same logical gateway as their primary.

function Get-AviatrixCopilotHaBaseName {
    param([string]$Name)
    if ($Name -like '*-hagw') { return $Name.Substring(0, $Name.Length - 5) }
    return $Name
}

function Get-AviatrixCopilotTopologyEdge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$TransitGateway,

        [Parameter(Mandatory)]
        [datetime]$Start,

        [Parameter(Mandatory)]
        [datetime]$End,

        # Optional gateway name -> interface list cache, filled in place so callers
        # can reuse the listings instead of re-requesting them.
        [hashtable]$InterfaceCache = @{},

        [switch]$SkipCertificateCheck
    )

    $transitSet = @{}
    foreach ($t in $TransitGateway) { $transitSet[$t] = $true }

    $edges = @{}
    foreach ($transit in $TransitGateway) {
        foreach ($gw in @($transit, "$transit-hagw")) {
            if ($InterfaceCache.ContainsKey($gw)) {
                $ifaces = $InterfaceCache[$gw]
            }
            else {
                try {
                    $ifaces = @(Get-AviatrixCopilotGatewayInterface -GatewayName $gw -Start $Start -End $End -SkipCertificateCheck:$SkipCertificateCheck)
                }
                catch {
                    if ($gw -eq $transit) { throw }
                    continue    # transit has no HA gateway
                }
                $InterfaceCache[$gw] = $ifaces
            }

            foreach ($i in $ifaces) {
                if ($i.interfaceName -notlike 'tun-*' -or -not $i.destinationGateway) { continue }
                $peer = [string]$i.destinationGateway
                $gwBase = Get-AviatrixCopilotHaBaseName $gw
                $peerBase = Get-AviatrixCopilotHaBaseName $peer
                if ($gwBase -eq $peerBase) { continue }   # primary<->HA link

                if ($transitSet.ContainsKey($peerBase)) {
                    $type = 'TransitPeering'
                    $pair = @($gw, $peer) | Sort-Object
                    $a = $pair[0]; $b = $pair[1]
                }
                else {
                    $type = 'SpokeTransitAttachment'
                    $a = $peer; $b = $gw     # a = spoke side, b = transit side
                }
                $key = "$type|$a|$b"
                if (-not $edges.ContainsKey($key)) {
                    $edges[$key] = [PSCustomObject]@{
                        Type      = $type
                        GatewayA  = $a      # spoke (attachments) or alphabetically first (peerings)
                        GatewayB  = $b      # transit
                        SpokeOrA  = Get-AviatrixCopilotHaBaseName $a
                        TransitOrB = Get-AviatrixCopilotHaBaseName $b
                    }
                }
            }
        }
    }

    $edges.Values | Sort-Object Type, GatewayA, GatewayB
}

function Get-AviatrixCopilotSpokeTransitAttachment {
    <#
    .SYNOPSIS
        Lists spoke->transit attachments (gateway pairs, including HA gateways), derived from tunnel interfaces.
    .EXAMPLE
        Get-AviatrixCopilotSpokeTransitAttachment -TransitGateway transit1-gw,transit2-gw,transit3-gw -SkipCertificateCheck
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$TransitGateway,

        [datetime]$End = (Get-Date),

        [datetime]$Start = $End.AddHours(-1),

        [switch]$SkipCertificateCheck
    )

    Get-AviatrixCopilotTopologyEdge -TransitGateway $TransitGateway -Start $Start -End $End -SkipCertificateCheck:$SkipCertificateCheck |
        Where-Object Type -eq 'SpokeTransitAttachment' |
        ForEach-Object {
            [PSCustomObject]@{
                SpokeGateway   = $_.GatewayA
                TransitGateway = $_.GatewayB
            }
        }
}

function Get-AviatrixCopilotTransitPeering {
    <#
    .SYNOPSIS
        Lists transit<->transit peerings (gateway pairs, including HA gateways), derived from tunnel interfaces.
    .EXAMPLE
        Get-AviatrixCopilotTransitPeering -TransitGateway transit1-gw,transit2-gw,transit3-gw -SkipCertificateCheck
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$TransitGateway,

        [datetime]$End = (Get-Date),

        [datetime]$Start = $End.AddHours(-1),

        [switch]$SkipCertificateCheck
    )

    Get-AviatrixCopilotTopologyEdge -TransitGateway $TransitGateway -Start $Start -End $End -SkipCertificateCheck:$SkipCertificateCheck |
        Where-Object Type -eq 'TransitPeering' |
        ForEach-Object {
            [PSCustomObject]@{
                TransitGatewayA = $_.GatewayA
                TransitGatewayB = $_.GatewayB
            }
        }
}

function Invoke-AviatrixCopilotGet {
    # Single GET with retry/backoff on throttling (429) and server errors (5xx).
    # Self-contained on purpose: its text is re-created inside parallel runspaces.
    param(
        [string]$Uri,
        $WebSession,
        [hashtable]$CertParams = @{},
        [int]$MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Method Get -WebSession $WebSession -ErrorAction Stop @CertParams
        }
        catch {
            $status = 0
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            $retryable = ($status -eq 0) -or ($status -eq 429) -or ($status -ge 500)
            if ($attempt -ge $MaxAttempts -or -not $retryable) { throw }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }
}

function Export-AviatrixCopilotConnectionMetric {
    <#
    .SYNOPSIS
        Writes a CSV of one metric for every spoke->transit attachment and transit<->transit peering, in both directions.
    .DESCRIPTION
        Discovers all connections from the given transit gateways, then reads the metric from
        each gateway's own side (A->B and B->A) for the time range. For each requested
        aggregation (Average, Min, Max) one row is written per tunnel plus one 'ALL' row per
        direction that sums the tunnels at each timestamp before aggregating.
        Use -Detailed to write one row per timestamp instead of the summary.

        Request volume is kept low: each gateway's interface list is fetched once, each tunnel's
        series is fetched once (Average/Min/Max are computed from the returned points), and
        requests are sent one at a time by default (-ThrottleLimit raises concurrency on
        PowerShell 7+), with retry/backoff on 429/5xx. CoPilot's stats endpoint accepts one
        interface per request, so one request per tunnel is the minimum.

        CoPilot returns identical per-point values for avg/min/max at its 1-minute interval,
        so deriving Min/Max from one series is equivalent. If that ever stops being true for
        your metric, use -FetchPerAggregation to request each aggregation from CoPilot separately.
    .EXAMPLE
        Export-AviatrixCopilotConnectionMetric -TransitGateway transit1-gw,transit2-gw,transit3-gw `
            -Metric rate_total -Aggregation Average,Min,Max -Path .\rates.csv -SkipCertificateCheck
    .EXAMPLE
        Export-AviatrixCopilotConnectionMetric -TransitGateway transit1-gw,transit2-gw,transit3-gw `
            -Metric rate_total -TimeRange Last24Hours -Path .\rates.csv
    .EXAMPLE
        # Connects, exports and logs out in one call
        Export-AviatrixCopilotConnectionMetric -ComputerName copilot.contoso.com -SkipCertificateCheck `
            -TransitGateway transit1-gw,transit2-gw,transit3-gw -Metric rate_total `
            -TimeRange Last24Hours -Path .\rates.csv
    #>
    [CmdletBinding()]
    param(
        # Connect to this CoPilot for the duration of the call, then log out. Credentials come
        # from -Credential, else COPILOT_USER / COPILOT_PASSWORD, else a prompt. Omit to use
        # the session from an earlier Connect-AviatrixCopilot.
        [string]$ComputerName,

        [PSCredential]$Credential,

        [Parameter(Mandatory)]
        [string[]]$TransitGateway,

        [Parameter(Mandatory)]
        [string]$Metric,

        [ValidateSet('Average', 'Min', 'Max')]
        [string[]]$Aggregation = 'Average',

        # Named range ending now. For a custom range use -Start/-End instead (not both).
        [ValidateSet('Last15Min', 'Last30Min', 'Last60Min', 'Last24Hours', 'Last7Days', 'LastMonth')]
        [string]$TimeRange,

        [datetime]$End = (Get-Date),

        [datetime]$Start = $End.AddMinutes(-5),

        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateSet('All', 'SpokeTransitAttachment', 'TransitPeering')]
        [string]$ConnectionType = 'All',

        # Maximum concurrent requests to CoPilot (PowerShell 7+). Default 1 = sequential: in
        # testing CoPilot served concurrent requests no faster than sequential ones, so raising
        # this only adds load. Opt in if your CoPilot behaves differently.
        [ValidateRange(1, 16)]
        [int]$ThrottleLimit = 1,

        # Request each aggregation from CoPilot instead of deriving them from one series.
        [switch]$FetchPerAggregation,

        [switch]$Detailed,

        [switch]$PassThru,

        [switch]$SkipCertificateCheck
    )

    if ($ComputerName) {
        $forward = @{}
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            if ($kv.Key -notin 'ComputerName', 'Credential') { $forward[$kv.Key] = $kv.Value }
        }
        $connect = @{ ComputerName = $ComputerName; SkipCertificateCheck = $SkipCertificateCheck }
        if ($Credential) { $connect.Credential = $Credential }
        Connect-AviatrixCopilot @connect | Out-Null
        try { return Export-AviatrixCopilotConnectionMetric @forward }
        finally { Disconnect-AviatrixCopilot }
    }

    $session = Get-AviatrixCopilotSession
    if (-not $session) {
        throw 'Not connected to Aviatrix CoPilot. Pass -ComputerName, or run Connect-AviatrixCopilot first.'
    }

    if ($TimeRange) {
        if ($PSBoundParameters.ContainsKey('Start') -or $PSBoundParameters.ContainsKey('End')) {
            throw 'Use either -TimeRange or -Start/-End, not both.'
        }
        $r = Get-AviatrixCopilotTimeRange -Range $TimeRange
        $Start = $r.Start; $End = $r.End
    }
    if ($session.SkipCertificateCheck) { $SkipCertificateCheck = [switch]$true }
    Write-Information "Time range: $Start -> $End" -InformationAction Continue

    $apiAgg = @{ Average = 'avg'; Min = 'min'; Max = 'max' }
    $startUtc = $Start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $endUtc = $End.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # 1. Discovery; interface listings are cached per gateway and reused below.
    $ifaceCache = @{}
    $edges = @(Get-AviatrixCopilotTopologyEdge -TransitGateway $TransitGateway -Start $Start -End $End `
            -InterfaceCache $ifaceCache -SkipCertificateCheck:$SkipCertificateCheck)
    if ($ConnectionType -ne 'All') { $edges = @($edges | Where-Object Type -eq $ConnectionType) }
    if (-not $edges) {
        throw ("No connections found for the given transit gateways between $startUtc and $endUtc (UTC). " +
            'Check the gateway names. If they are right, CoPilot has no interface data for this time range: ' +
            'the gateways may have been created or restarted after the range start, or the range is older than CoPilot retains. ' +
            'Try a more recent range.')
    }

    # 2. Work list: one request per (direction, tunnel, API aggregation).
    $sourceAggs = if ($FetchPerAggregation) { @($Aggregation | ForEach-Object { $apiAgg[$_] } | Select-Object -Unique) } else { @('avg') }
    $work = New-Object System.Collections.Generic.List[object]
    foreach ($edge in $edges) {
        foreach ($dir in @(@($edge.GatewayA, $edge.GatewayB), @($edge.GatewayB, $edge.GatewayA))) {
            $from = $dir[0]; $to = $dir[1]
            if (-not $ifaceCache.ContainsKey($from)) {
                $ifaceCache[$from] = @(Get-AviatrixCopilotGatewayInterface -GatewayName $from -Start $Start -End $End -SkipCertificateCheck:$SkipCertificateCheck)
            }
            $tunnels = @($ifaceCache[$from] | Where-Object { $_.interfaceName -like 'tun-*' -and $_.destinationGateway -eq $to })
            if (-not $tunnels) {
                Write-Warning "$from -> ${to}: no tunnels found in the given time range."
                continue
            }
            foreach ($tun in $tunnels) {
                foreach ($a in $sourceAggs) {
                    $query = @{
                        gatewayName   = $from
                        interfaceName = $tun.interfaceName
                        metric        = $Metric
                        aggMethod     = $a
                        start         = ConvertTo-AviatrixCopilotUtcIso8601 $Start
                        end           = ConvertTo-AviatrixCopilotUtcIso8601 $End
                    }
                    $work.Add([PSCustomObject]@{
                            Edge = $edge; From = $from; To = $to; Tunnel = $tun.interfaceName; ApiAgg = $a
                            Uri  = "$($session.BaseUri)/api/get_performance_gateway_interface_stats?$(ConvertTo-AviatrixCopilotQueryString $query)"
                        })
                }
            }
        }
    }

    # 3. Fetch with bounded concurrency.
    $ws = $session.WebSession
    $certParams = Get-AviatrixCopilotSkipCertParams -SkipCertificateCheck:$SkipCertificateCheck
    $fnText = ${function:Invoke-AviatrixCopilotGet}.ToString()

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $ThrottleLimit -gt 1) {
        $fetched = $work | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $get = [scriptblock]::Create($using:fnText)
            $response = $null; $err = $null
            try { $response = @(& $get -Uri $_.Uri -WebSession $using:ws -CertParams $using:certParams) }
            catch { $err = $_.Exception.Message }
            [PSCustomObject]@{ Work = $_; Response = $response; Error = $err }
        }
    }
    else {
        $get = [scriptblock]::Create($fnText)
        $fetched = foreach ($w in $work) {
            $response = $null; $err = $null
            try { $response = @(& $get -Uri $w.Uri -WebSession $ws -CertParams $certParams) }
            catch { $err = $_.Exception.Message }
            [PSCustomObject]@{ Work = $w; Response = $response; Error = $err }
        }
    }

    # 4. Index results by (edge, direction, tunnel, API aggregation).
    $series = @{}
    foreach ($f in $fetched) {
        $w = $f.Work
        if ($f.Error) { Write-Warning "$($w.From) -> $($w.To) $($w.Tunnel): $($f.Error)"; continue }
        $raw = @($f.Response)[0].($Metric).($w.From).($w.Tunnel)
        $series["$($w.Edge.Type)|$($w.From)|$($w.To)|$($w.Tunnel)|$($w.ApiAgg)"] = @($raw | Where-Object { $null -ne $_ -and $null -ne $_.y } |
                ForEach-Object { [PSCustomObject]@{ x = $_.x; y = [double]$_.y } })
    }

    # 4b. Check that the data covers the requested range and warn if it does not.
    $toUtc = {
        param($x)
        if ($x -is [datetime]) {
            if ($x.Kind -eq 'Local') { $x.ToUniversalTime() } else { [datetime]::SpecifyKind($x, 'Utc') }
        }
        else { [datetimeoffset]::Parse([string]$x, [cultureinfo]::InvariantCulture, 'AssumeUniversal').UtcDateTime }
    }
    $allTimes = @($series.Values | ForEach-Object { $_ } | ForEach-Object { & $toUtc $_.x })
    $emptyCount = @($series.Values | Where-Object { @($_).Count -eq 0 }).Count
    if ($series.Count -gt 0 -and -not $allTimes) {
        Write-Warning "CoPilot returned no data points for $Metric between $startUtc and $endUtc (UTC); the CSV will have empty values. Check the metric name and the time range."
    }
    elseif ($allTimes) {
        $reqStart = $Start.ToUniversalTime(); $reqEnd = $End.ToUniversalTime()
        $span = $reqEnd - $reqStart
        # Allow for CoPilot's 1-minute sampling and edge rounding.
        $tol = [timespan]::FromMinutes([math]::Max(5, $span.TotalMinutes * 0.05))
        $first = ($allTimes | Measure-Object -Minimum).Minimum
        $last = ($allTimes | Measure-Object -Maximum).Maximum
        $fmt = 'yyyy-MM-dd HH:mm'
        if ($first - $reqStart -gt $tol) {
            Write-Warning ("Requested range starts $($reqStart.ToString($fmt)) UTC, but CoPilot's first data point is $($first.ToString($fmt)) UTC. " +
                "Only $([math]::Round(($reqEnd - $first).TotalMinutes)) of the requested $([math]::Round($span.TotalMinutes)) minutes have data, " +
                'so the values cover a shorter period than asked. The gateways may be newer than the range start, or data older than this is not retained.')
        }
        if ($reqEnd - $last -gt $tol) {
            Write-Warning ("CoPilot's last data point is $($last.ToString($fmt)) UTC, before the requested end $($reqEnd.ToString($fmt)) UTC. " +
                'Metrics may have stopped being reported (gateway down or CoPilot collection delayed).')
        }
        if ($emptyCount -gt 0) {
            Write-Warning "$emptyCount of $($series.Count) tunnel series returned no data points in this range."
        }
    }

    # 5. Build rows: per tunnel plus an ALL row (tunnels summed per timestamp), per requested aggregation.
    $out = New-Object System.Collections.Generic.List[object]
    $addRows = {
        param($edge, $from, $to, $tunnelName, $agg, $points)
        $common = [ordered]@{
            ConnectionType = $edge.Type
            Gateway        = $from
            PeerGateway    = $to
            Tunnel         = $tunnelName
            Metric         = $Metric
            Aggregation    = $agg
            Start          = $startUtc
            End            = $endUtc
        }
        if ($Detailed) {
            foreach ($p in $points) {
                $o = [ordered]@{} + $common
                $o['Timestamp'] = $p.x
                $o['Value'] = $p.y
                $out.Add([PSCustomObject]$o)
            }
            return
        }
        $vals = @($points | ForEach-Object { $_.y })
        $o = [ordered]@{} + $common
        $o['Points'] = $vals.Count
        $o['Value'] = $null
        if ($vals.Count) {
            $m = $vals | Measure-Object -Average -Minimum -Maximum
            switch ($agg) {
                'Average' { $o['Value'] = $m.Average }
                'Min'     { $o['Value'] = $m.Minimum }
                'Max'     { $o['Value'] = $m.Maximum }
            }
        }
        $out.Add([PSCustomObject]$o)
    }

    foreach ($edge in $edges) {
        foreach ($dir in @(@($edge.GatewayA, $edge.GatewayB), @($edge.GatewayB, $edge.GatewayA))) {
            $from = $dir[0]; $to = $dir[1]
            $tunnelNames = @($ifaceCache[$from] | Where-Object { $_.interfaceName -like 'tun-*' -and $_.destinationGateway -eq $to } |
                    ForEach-Object { $_.interfaceName })
            foreach ($agg in $Aggregation) {
                $src = if ($FetchPerAggregation) { $apiAgg[$agg] } else { 'avg' }
                $perTime = @{}
                $any = $false
                foreach ($tn in $tunnelNames) {
                    $key = "$($edge.Type)|$from|$to|$tn|$src"
                    if (-not $series.ContainsKey($key)) { continue }
                    $any = $true
                    $pts = $series[$key]
                    foreach ($p in $pts) {
                        if (-not $perTime.ContainsKey($p.x)) { $perTime[$p.x] = 0.0 }
                        $perTime[$p.x] += $p.y
                    }
                    & $addRows $edge $from $to $tn $agg $pts
                }
                if ($any) {
                    $total = @($perTime.Keys | Sort-Object | ForEach-Object { [PSCustomObject]@{ x = $_; y = $perTime[$_] } })
                    & $addRows $edge $from $to 'ALL' $agg $total
                }
            }
        }
    }

    $out | Export-Csv -Path $Path -NoTypeInformation
    Write-Verbose "Wrote $($out.Count) rows for $(@($edges).Count) connections ($($work.Count) metric requests) to $Path."
    if ($PassThru) { $out }
}

Export-ModuleMember -Function Get-AviatrixCopilotTimeRange, Connect-AviatrixCopilot, Disconnect-AviatrixCopilot, Get-AviatrixCopilotSession, Get-AviatrixCopilotGatewayInterface, Get-AviatrixCopilotGatewayInterfaceStats, Get-AviatrixCopilotGatewayPairTunnelStats, Get-AviatrixCopilotSpokeTransitAttachment, Get-AviatrixCopilotTransitPeering, Export-AviatrixCopilotConnectionMetric
