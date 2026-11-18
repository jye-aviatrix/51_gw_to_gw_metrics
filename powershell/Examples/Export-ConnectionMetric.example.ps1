# Example: CSV of a CoPilot metric for every spoke->transit attachment and
# transit<->transit peering, both directions. Edit the settings, then run.
# Credentials: set COPILOT_USER / COPILOT_PASSWORD, or you'll be prompted.

# --- Settings ----------------------------------------------------------------
$copilot  = 'copilot.example.com'
$transits = 'transit1-gw', 'transit2-gw', 'transit3-gw'
$csv      = './connection-metrics.csv'

# CoPilot metric name, for example rate_total
$metric   = 'rate_total'

# One or more of: Average, Min, Max
$aggregation = 'Average', 'Min', 'Max'

# Time range. Pick one of:
#   Last15Min, Last30Min, Last60Min, Last24Hours, Last7Days, LastMonth, Custom
$range    = 'Last15Min'

# Only used when $range = 'Custom' (local time; use any [datetime] value).
# The window must fall inside the period CoPilot has data for; if not, the export fails
# with "No connections found" or warns that only part of the range has data.
$customStart = (Get-Date).AddMinutes(-40)
$customEnd   = (Get-Date).AddMinutes(-10)
# -----------------------------------------------------------------------------

$now = Get-Date
switch ($range) {
    'Last15Min'   { $start = $now.AddMinutes(-15); $end = $now }
    'Last30Min'   { $start = $now.AddMinutes(-30); $end = $now }
    'Last60Min'   { $start = $now.AddMinutes(-60); $end = $now }
    'Last24Hours' { $start = $now.AddHours(-24);   $end = $now }
    'Last7Days'   { $start = $now.AddDays(-7);     $end = $now }
    'LastMonth'   { $start = $now.AddMonths(-1);   $end = $now }   # rolling 1 month back from now
    'Custom'      { $start = $customStart;         $end = $customEnd }
    default       { throw "Unknown `$range '$range'" }
}
Write-Host "Time range: $start -> $end"

Import-Module "$PSScriptRoot/../AviatrixCopilot/AviatrixCopilot.psd1" -Force

$cred = if ($env:COPILOT_USER -and $env:COPILOT_PASSWORD) {
    [PSCredential]::new($env:COPILOT_USER, (ConvertTo-SecureString $env:COPILOT_PASSWORD -AsPlainText -Force))
} else { Get-Credential }

Connect-AviatrixCopilot -ComputerName $copilot -Credential $cred -SkipCertificateCheck | Out-Null

Export-AviatrixCopilotConnectionMetric -TransitGateway $transits -Metric $metric `
    -Aggregation $aggregation -Start $start -End $end -Path $csv -SkipCertificateCheck

Disconnect-AviatrixCopilot -SkipCertificateCheck
