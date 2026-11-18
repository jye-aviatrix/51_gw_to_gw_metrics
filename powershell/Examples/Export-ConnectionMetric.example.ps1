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

# Connects, exports, then logs out
Export-AviatrixCopilotConnectionMetric -ComputerName $copilot -SkipCertificateCheck `
    -TransitGateway $transits -Metric $metric -Aggregation $aggregation `
    -TimeRange $range -Start $customStart -End $customEnd -Path $csv

# --- Other ways to pick the time range ---------------------------------------
# Copy one of these in place of the call above. Each connects, exports, logs out.
#
# Last 15 minutes:
#   Export-AviatrixCopilotConnectionMetric -ComputerName $copilot -SkipCertificateCheck `
#       -TransitGateway $transits -Metric $metric -Aggregation $aggregation `
#       -TimeRange Last15Min -Path ./last-15min.csv
#
# Custom range, relative to now (here 2 hours ago to 1 hour ago, local time):
#   Export-AviatrixCopilotConnectionMetric -ComputerName $copilot -SkipCertificateCheck `
#       -TransitGateway $transits -Metric $metric -Aggregation $aggregation `
#       -TimeRange Custom -Start (Get-Date).AddHours(-2) -End (Get-Date).AddHours(-1) -Path ./custom-relative.csv
#
# Custom range, fixed local dates and times:
#   Export-AviatrixCopilotConnectionMetric -ComputerName $copilot -SkipCertificateCheck `
#       -TransitGateway $transits -Metric $metric -Aggregation $aggregation `
#       -TimeRange Custom -Start (Get-Date '2026-11-18 08:00') -End (Get-Date '2026-11-18 12:30') -Path ./custom-local.csv
#
# Custom range in UTC (the trailing Z marks the time as UTC):
#   Export-AviatrixCopilotConnectionMetric -ComputerName $copilot -SkipCertificateCheck `
#       -TransitGateway $transits -Metric $metric -Aggregation $aggregation `
#       -TimeRange Custom -Start ([datetime]'2026-11-18T13:00:00Z') -End ([datetime]'2026-11-18T17:30:00Z') -Path ./custom-utc.csv
#
# Custom ranges must fall inside the period CoPilot has data for (see $customStart above).
