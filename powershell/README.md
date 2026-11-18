# AviatrixCopilot PowerShell module

Reads gateway performance metrics from Aviatrix CoPilot and exports them to CSV. Built for the
gateway-to-gateway lab deployed by the Terraform in the [repo root](../README.md), but it works
against any CoPilot.

## Requirements

- PowerShell 5.1+ (7+ recommended)
- Network access to CoPilot over HTTPS and a local CoPilot user
- The names of your **transit gateways**. CoPilot has no gateway-list endpoint the module can rely
  on, so discovery starts from the transits you name and follows each tunnel's destination gateway
  to find spokes, HA gateways and peerings.

## Quick start

```powershell
Import-Module ./powershell/AviatrixCopilot/AviatrixCopilot.psd1

Connect-AviatrixCopilot -ComputerName <copilot> -Credential (Get-Credential) -SkipCertificateCheck

Export-AviatrixCopilotConnectionMetric `
    -TransitGateway transit1-gw,transit2-gw,transit3-gw `
    -Metric rate_total -Aggregation Average,Min,Max `
    -Start (Get-Date).AddMinutes(-5) -Path ./connection-metrics.csv -SkipCertificateCheck

Disconnect-AviatrixCopilot -SkipCertificateCheck
```

`-SkipCertificateCheck` is needed when CoPilot uses a self-signed certificate. Pass it to every
command that talks to CoPilot, including `Disconnect-AviatrixCopilot`.

### Ready-made example

[`Examples/Export-ConnectionMetric.example.ps1`](Examples/Export-ConnectionMetric.example.ps1) does the
above in about 20 lines. Edit the settings block at the top (CoPilot address, transit names, time range,
output file) and run it. `$range` accepts `Last15Min`, `Last30Min`, `Last60Min`, `Last24Hours`,
`Last7Days`, `LastMonth` or `Custom` (uses `$customStart` / `$customEnd`):

```powershell
$env:COPILOT_USER = 'admin'; $env:COPILOT_PASSWORD = '<password>'   # or omit to be prompted
./powershell/Examples/Export-ConnectionMetric.example.ps1
```

## Commands

### Session

| Command | Purpose |
|---|---|
| `Connect-AviatrixCopilot -ComputerName -Credential [-Port 443] [-SkipCertificateCheck]` | Log in and keep the session for later commands |
| `Disconnect-AviatrixCopilot` | Log out and clear the session |
| `Get-AviatrixCopilotSession` | Show the current session, if any |

### Topology

```powershell
Get-AviatrixCopilotSpokeTransitAttachment -TransitGateway transit1-gw,transit2-gw,transit3-gw -SkipCertificateCheck
Get-AviatrixCopilotTransitPeering         -TransitGateway transit1-gw,transit2-gw,transit3-gw -SkipCertificateCheck
```

Both list gateway pairs, including HA gateways (`<name>-hagw`). Example output:

```
SpokeGateway     TransitGateway
------------     --------------
spoke1-gw        transit1-gw
spoke1-gw        transit1-gw-hagw
spoke1-gw-hagw   transit1-gw
spoke1-gw-hagw   transit1-gw-hagw
...

TransitGatewayA  TransitGatewayB
---------------  ---------------
transit1-gw      transit2-gw
transit1-gw      transit2-gw-hagw
transit1-gw      transit3-gw
...
```

The first table is from `Get-AviatrixCopilotSpokeTransitAttachment`, the second from
`Get-AviatrixCopilotTransitPeering`.

### Metrics export

```powershell
Export-AviatrixCopilotConnectionMetric -TransitGateway <names> -Metric <metric> -Path <file.csv> [options]
```

Writes one CSV covering every spoke-to-transit attachment and transit-to-transit peering, in both
directions.

| Parameter | Default | Meaning |
|---|---|---|
| `-TransitGateway` | required | Transit gateways to start discovery from |
| `-Metric` | required | CoPilot metric name, for example `rate_total` |
| `-Path` | required | Output CSV file |
| `-Aggregation` | `Average` | Any of `Average`, `Min`, `Max` |
| `-Start`, `-End` | now minus 5 minutes, now | Time range |
| `-ConnectionType` | `All` | `All`, `SpokeTransitAttachment` or `TransitPeering` |
| `-Detailed` | off | One row per timestamp instead of one summary row |
| `-PassThru` | off | Also return the rows as objects |
| `-ThrottleLimit` | `1` | Concurrent requests (PowerShell 7+, max 16). See below |
| `-FetchPerAggregation` | off | Request each aggregation from CoPilot separately |
| `-SkipCertificateCheck` | off | Skip TLS certificate validation |

More examples:

```powershell
# 24 hours of per-timestamp averages, peerings only
Export-AviatrixCopilotConnectionMetric -TransitGateway transit1-gw,transit2-gw,transit3-gw `
    -Metric rate_total -Aggregation Average -Detailed -ConnectionType TransitPeering `
    -Start (Get-Date).AddHours(-24) -Path ./peerings-24h.csv -SkipCertificateCheck
```

### Time ranges

`-Start` and `-End` take any `[datetime]`; `-End` defaults to now and `-Start` to 5 minutes before `-End`.

```powershell
$gw = 'transit1-gw','transit2-gw','transit3-gw'
$common = @{ TransitGateway = $gw; Metric = 'rate_total'; Aggregation = 'Average','Min','Max'; SkipCertificateCheck = $true }

# Last 15 / 30 / 60 minutes
Export-AviatrixCopilotConnectionMetric @common -Start (Get-Date).AddMinutes(-15) -Path ./last-15m.csv
Export-AviatrixCopilotConnectionMetric @common -Start (Get-Date).AddMinutes(-30) -Path ./last-30m.csv
Export-AviatrixCopilotConnectionMetric @common -Start (Get-Date).AddMinutes(-60) -Path ./last-60m.csv

# Last 24 hours, last 7 days, last month
Export-AviatrixCopilotConnectionMetric @common -Start (Get-Date).AddHours(-24) -Path ./last-24h.csv
Export-AviatrixCopilotConnectionMetric @common -Start (Get-Date).AddDays(-7)   -Path ./last-7d.csv
Export-AviatrixCopilotConnectionMetric @common -Start (Get-Date).AddMonths(-1) -Path ./last-month.csv

# Custom range (local time)
Export-AviatrixCopilotConnectionMetric @common -Start (Get-Date).AddMinutes(-40) -End (Get-Date).AddMinutes(-10) -Path ./custom.csv

# Custom range in UTC
Export-AviatrixCopilotConnectionMetric @common -Start ([datetime]'2026-11-17T08:00:00Z') -End ([datetime]'2026-11-17T12:30:00Z') -Path ./custom-utc.csv
```

If CoPilot has less data than the range asks for (for example gateways created an hour ago and
`-Start` 7 days back), the export still writes the CSV but warns with the actual first and last data
timestamps. If it has none at all, the error says so. Treat values from a warned run as covering the
shorter period, not the full range.

Long ranges return more points per tunnel, so they take longer and `-Detailed` CSVs get large.
Check the `Points` column in the output to see how much data each row covers.

### Lower-level commands

| Command | Purpose |
|---|---|
| `Get-AviatrixCopilotGatewayInterface -GatewayName -Start -End` | Interfaces with data for a gateway; tunnels (`tun-*`) include `destinationGateway` |
| `Get-AviatrixCopilotGatewayInterfaceStats -GatewayName -InterfaceName -Metric -AggMethod -Start -End` | Time series for one interface |
| `Get-AviatrixCopilotGatewayPairTunnelStats -GatewayName -PeerGatewayName -Metric -AggMethod -Start -End` | Time series for every tunnel between two gateways |

`-AggMethod` takes the CoPilot values `avg`, `max`, `min` or `sum`.

## CSV format

```
"ConnectionType","Gateway","PeerGateway","Tunnel","Metric","Aggregation","Start","End","Points","Value"
"SpokeTransitAttachment","spoke1-gw","transit1-gw","tun-0A000184-0","rate_total","Average","2026-11-04T22:46:30Z","2026-11-04T22:51:30Z","5","5265989.8"
```

- **Both directions:** each connection appears twice, once from each gateway's own side
  (`Gateway` to `PeerGateway`, then the reverse).
- **Per tunnel and `ALL`:** every direction has one row per tunnel plus an `ALL` row that sums the
  tunnels at each timestamp before aggregating.
- **`Value`:** for `Average`, `Min` and `Max` it is the mean, minimum or maximum over the time range
  of CoPilot's 1-minute points. `Points` is how many points that used. With `-Detailed` the columns
  `Timestamp` and `Value` replace `Points` and `Value`, one row per point.
- **Units:** `rate_total` is reported in bits per second (inferred: one 5 Mbit/s iperf3 flow shows as
  about 5.2 M). Check other metrics before assuming units.
- **Row count:** 3 transits and 3 spokes with HA gives 24 connections, so 576 rows for three
  aggregations.

## Request volume and timing

The export is designed not to hammer CoPilot:

- Each gateway's interface list is fetched once and reused.
- Each tunnel's series is fetched **once**; Average, Min and Max are computed from it. At CoPilot's
  1-minute interval the avg, min and max series were identical for `rate_total`, so this gives the
  same CSV as three separate requests. If that is not true for your metric, add
  `-FetchPerAggregation`.
- CoPilot's stats endpoint takes one interface per request, so one request per tunnel is the minimum.
- Requests run one at a time by default, with retry and backoff (2 s, then 4 s) on throttling (429),
  server errors (5xx) and network errors. Other 4xx errors fail immediately.
- `-ThrottleLimit` raises concurrency on PowerShell 7+. In testing, CoPilot served concurrent
  requests no faster than sequential ones, so it only adds load.

A 5-minute export of the lab (24 connections, 144 tunnel series) takes about 16 seconds.

## GitHub Actions

[`.github/workflows/export-connection-metrics.yml`](../.github/workflows/export-connection-metrics.yml)
runs the export on demand (**Actions > Export connection metrics > Run workflow**) and uploads the CSV
as a build artifact (kept 30 days). It also writes a job summary table of the primary-gateway totals.

Set up in the repo's *Settings > Secrets and variables > Actions*:

| Type | Name | Value |
|---|---|---|
| Secret | `COPILOT_USER`, `COPILOT_PASSWORD` | CoPilot login |
| Variable | `COPILOT_HOST` | CoPilot IP or FQDN |
| Variable | `TRANSIT_GATEWAYS` | Comma-separated, for example `transit1-gw,transit2-gw,transit3-gw` |

Run inputs: look-back minutes, metric, aggregations and connection type. The runner must reach
CoPilot over HTTPS: GitHub-hosted runners need CoPilot to be reachable from the internet, otherwise
change `runs-on` to a self-hosted runner. A commented-out `schedule` trigger is included for recurring
exports. The job calls [`.github/scripts/Export-ConnectionMetrics.ps1`](../.github/scripts/Export-ConnectionMetrics.ps1),
which you can also run locally with the same environment variables.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Not connected to Aviatrix CoPilot` | Run `Connect-AviatrixCopilot` first; sessions are per PowerShell session |
| `No connections found for the given transit gateways` | Names are wrong or have no tunnels in the time range. Check them with `Get-AviatrixCopilotGatewayInterface` |
| `No tunnels found between 'A' and 'B'` | Same cause for one pair; HA gateway names must match exactly (`<name>-hagw`) |
| `Must be a valid UTC ISO datetime` | A raw API call used the wrong time format; CoPilot needs `yyyy-MM-ddTHH:mm:ss.fffZ` (the module does this for you) |
| Passing `-TransitGateway a,b,c` to a script with `pwsh -File` finds nothing | `-File` delivers one string `"a,b,c"`. Set the list inside the script or use `-Command` |
| Certificate errors | Add `-SkipCertificateCheck` (self-signed CoPilot) |
