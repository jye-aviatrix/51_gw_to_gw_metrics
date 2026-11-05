<#
.SYNOPSIS
    CI entry point: logs in to CoPilot, runs Export-AviatrixCopilotConnectionMetric, writes a CSV
    and (when running in GitHub Actions) a job summary.

.DESCRIPTION
    Credentials come from COPILOT_USER / COPILOT_PASSWORD environment variables (use secrets).
    List parameters accept comma-separated strings because `pwsh -File` passes them as one string.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ComputerName,
    [Parameter(Mandatory)] [string]$TransitGateway,
    [string]$Metric = 'rate_total',
    [string]$Aggregation = 'Average,Min,Max',
    [int]$Minutes = 5,
    [ValidateSet('All', 'SpokeTransitAttachment', 'TransitPeering')]
    [string]$ConnectionType = 'All',
    [string]$OutputPath = './connection-metrics.csv',
    [bool]$SkipCertificateCheck = $true
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $env:COPILOT_USER -or -not $env:COPILOT_PASSWORD) {
    throw 'COPILOT_USER and COPILOT_PASSWORD must be set.'
}

$modulePath = Join-Path $PSScriptRoot '../../powershell/AviatrixCopilot/AviatrixCopilot.psd1'
Import-Module $modulePath -Force

$transits = @($TransitGateway -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$aggs = @($Aggregation -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $transits) { throw 'TransitGateway is empty.' }

$cred = [PSCredential]::new($env:COPILOT_USER, (ConvertTo-SecureString $env:COPILOT_PASSWORD -AsPlainText -Force))
$end = Get-Date

Connect-AviatrixCopilot -ComputerName $ComputerName -Credential $cred -SkipCertificateCheck:$SkipCertificateCheck | Out-Null
try {
    $rows = Export-AviatrixCopilotConnectionMetric -TransitGateway $transits -Metric $Metric -Aggregation $aggs `
        -Start $end.AddMinutes(-$Minutes) -End $end -ConnectionType $ConnectionType `
        -Path $OutputPath -PassThru -SkipCertificateCheck:$SkipCertificateCheck
}
finally {
    Disconnect-AviatrixCopilot -SkipCertificateCheck:$SkipCertificateCheck
}

Write-Host "Wrote $(@($rows).Count) rows to $OutputPath"

if ($env:GITHUB_STEP_SUMMARY) {
    $md = New-Object System.Collections.Generic.List[string]
    $md.Add("### Connection metrics: $Metric (last $Minutes min, $(@($rows).Count) CSV rows)")
    $md.Add('')
    $md.Add('| Type | Gateway | Peer | Aggregation | Value |')
    $md.Add('|---|---|---|---|---:|')
    foreach ($r in ($rows | Where-Object { $_.Tunnel -eq 'ALL' -and $_.Gateway -notlike '*-hagw' -and $_.PeerGateway -notlike '*-hagw' })) {
        $md.Add(('| {0} | {1} | {2} | {3} | {4:N0} |' -f $r.ConnectionType, $r.Gateway, $r.PeerGateway, $r.Aggregation, [double]$r.Value))
    }
    $md.Add('')
    $md.Add('Totals are the sum of all tunnels for the primary gateways; the full per-tunnel data, including HA gateways, is in the CSV artifact.')
    $md -join "`n" | Add-Content -Path $env:GITHUB_STEP_SUMMARY
}
