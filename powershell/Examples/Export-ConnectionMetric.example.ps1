# Example: CSV of a CoPilot metric for every spoke->transit attachment and
# transit<->transit peering, both directions. Edit the settings, then run.
# Credentials: set COPILOT_USER / COPILOT_PASSWORD, or you'll be prompted.

# --- Settings ----------------------------------------------------------------
$copilot  = 'copilot.example.com'
$transits = 'transit1-gw', 'transit2-gw', 'transit3-gw'
$minutes  = 5                       # look back this far from now
$csv      = './connection-metrics.csv'
# -----------------------------------------------------------------------------

Import-Module "$PSScriptRoot/../AviatrixCopilot/AviatrixCopilot.psd1" -Force

$cred = if ($env:COPILOT_USER -and $env:COPILOT_PASSWORD) {
    [PSCredential]::new($env:COPILOT_USER, (ConvertTo-SecureString $env:COPILOT_PASSWORD -AsPlainText -Force))
} else { Get-Credential }

Connect-AviatrixCopilot -ComputerName $copilot -Credential $cred -SkipCertificateCheck | Out-Null

Export-AviatrixCopilotConnectionMetric -TransitGateway $transits -Metric rate_total `
    -Aggregation Average, Min, Max -Start (Get-Date).AddMinutes(-$minutes) -Path $csv -SkipCertificateCheck

Disconnect-AviatrixCopilot -SkipCertificateCheck
