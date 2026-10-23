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

function Connect-AviatrixCopilot {
    <#
    .SYNOPSIS
        Logs in to Aviatrix CoPilot with a local user account.
    .EXAMPLE
        Connect-AviatrixCopilot -ComputerName copilot.contoso.com -Credential (Get-Credential)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [PSCredential]$Credential,

        [int]$Port = 443,

        [switch]$SkipCertificateCheck
    )

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

    $invokeParams = @{
        Uri         = "$($Script:AviatrixCopilotSession.BaseUri)/api/logout"
        Method      = 'Get'
        WebSession  = $Script:AviatrixCopilotSession.WebSession
        ErrorAction = 'Stop'
    }
    foreach ($kv in (Get-AviatrixCopilotSkipCertParams -SkipCertificateCheck:$SkipCertificateCheck).GetEnumerator()) {
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

Export-ModuleMember -Function Connect-AviatrixCopilot, Disconnect-AviatrixCopilot, Get-AviatrixCopilotSession, Get-AviatrixCopilotGatewayInterface, Get-AviatrixCopilotGatewayInterfaceStats, Get-AviatrixCopilotGatewayPairTunnelStats
