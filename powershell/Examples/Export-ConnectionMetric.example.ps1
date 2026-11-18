# Example: CSV of a CoPilot metric for every spoke->transit attachment and
# transit<->transit peering, both directions. Edit the settings, then run.
# Credentials: set COPILOT_USER / COPILOT_PASSWORD, or you'll be prompted.
# Time ranges, login and logout are handled by the AviatrixCopilot module.

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

Import-Module "$PSScriptRoot/../AviatrixCopilot/AviatrixCopilot.psd1" -Force

Connect-AviatrixCopilot -ComputerName $copilot -SkipCertificateCheck | Out-Null

$export = @{
    TransitGateway       = $transits
    Metric               = $metric
    Aggregation          = $aggregation
    Path                 = $csv
}
if ($range -eq 'Custom') { $export.Start = $customStart; $export.End = $customEnd }
else                     { $export.TimeRange = $range }

Export-AviatrixCopilotConnectionMetric @export

Disconnect-AviatrixCopilot
