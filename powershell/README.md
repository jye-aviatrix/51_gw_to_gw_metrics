# AviatrixCopilot PowerShell module

Reads gateway performance metrics from Aviatrix CoPilot and exports them to CSV. Built for the
gateway-to-gateway lab deployed by the Terraform in the [repo root](../README.md), but it works
against any CoPilot.

## Requirements

- PowerShell 5.1+ (7+ recommended)
- Network access to CoPilot over HTTPS and a local CoPilot user
- The names of your **transit gateways**: either a primary transit gateway name (for example
  `transit1-gw`) or a transit gateway group name (for example `transit4`). You can mix both.
  Discovery starts from those transits and follows each tunnel's destination to find spokes and
  peerings. See [Gateway groups](#gateway-groups-and-ha-gateways).

## Quick start

```powershell
Import-Module ./powershell/AviatrixCopilot/AviatrixCopilot.psd1

# One call: connects, exports, logs out
Export-AviatrixCopilotConnectionMetric -ComputerName <copilot> -SkipCertificateCheck `
    -TransitGateway transit1-gw,transit2-gw,transit3-gw `
    -Metric rate_total -AggMethod avg `
    -TimeRange Last24Hours -Path ./connection-metrics.csv
```

To run several exports on one login, connect once instead and omit `-ComputerName`:

```powershell
Connect-AviatrixCopilot -ComputerName <copilot> -SkipCertificateCheck
Export-AviatrixCopilotConnectionMetric -TransitGateway ... -Metric rate_total -TimeRange Last7Days -Path ./a.csv
Export-AviatrixCopilotConnectionMetric -TransitGateway ... -Metric rate_total -TimeRange Last24Hours -Path ./b.csv
Disconnect-AviatrixCopilot
```

`Connect-AviatrixCopilot` takes credentials from `-Credential`, else from the `COPILOT_USER` and
`COPILOT_PASSWORD` environment variables, else it prompts.

`-SkipCertificateCheck` is needed when CoPilot uses a self-signed certificate. Pass it to
`Connect-AviatrixCopilot` and the session remembers it, so `Export-AviatrixCopilotConnectionMetric` and
`Disconnect-AviatrixCopilot` don't need it again. The lower-level `Get-AviatrixCopilot*` commands
still take their own `-SkipCertificateCheck`.

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
| `Connect-AviatrixCopilot -ComputerName [-Credential] [-Port 443] [-SkipCertificateCheck]` | Log in and keep the session for later commands |
| `Disconnect-AviatrixCopilot` | Log out and clear the session |
| `Get-AviatrixCopilotSession` | Show the current session, if any |

### Topology

```powershell
Get-AviatrixCopilotSpokeTransitAttachment -TransitGateway transit1-gw,transit2-gw,transit3-gw -SkipCertificateCheck
Get-AviatrixCopilotTransitPeering         -TransitGateway transit1-gw,transit2-gw,transit3-gw -SkipCertificateCheck
```

Both list gateway pairs, including HA gateways and gateway group members, and the group each side belongs to. Example output:

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
| `-ComputerName`, `-Credential` | none | Connect for this call and log out afterwards. Without `-ComputerName` the export uses your existing session |
| `-TransitGateway` | required | Primary transit gateway names (their HA gateways are found automatically) or transit gateway group names (all instances are used). Any member name also works |
| `-Metric` | required | CoPilot metric name, for example `rate_total` |
| `-Path` | required | Output CSV file |
| `-AggMethod` | `avg` | One of `avg`, `min`, `max`, `sum`: how each tunnel's points over the time range are reduced to one value. One method per export |
| `-TimeRange` | none | Named range ending now, such as `Last24Hours`, or `Custom` |
| `-Start`, `-End` | now minus 5 minutes, now | Range used with `-TimeRange Custom` or when `-TimeRange` is omitted |
| `-ConnectionType` | `All` | `All`, `SpokeTransitAttachment` or `TransitPeering` |
| `-Detailed` | off | One row per tunnel and timestamp instead of one row per tunnel |
| `-PassThru` | off | Also return the rows as objects |
| `-ThrottleLimit` | `1` | Concurrent requests (PowerShell 7+, max 16). See below |
| `-FetchPerAggregation` | off | Ask CoPilot for the chosen `-AggMethod` per point instead of computing it from the avg series |
| `-SkipCertificateCheck` | off | Skip TLS certificate validation |

More examples:

```powershell
# 24 hours of per-timestamp averages, peerings only
Export-AviatrixCopilotConnectionMetric -TransitGateway transit1-gw,transit2-gw,transit3-gw `
    -Metric rate_total -AggMethod avg -Detailed -ConnectionType TransitPeering `
    -Start (Get-Date).AddHours(-24) -Path ./peerings-24h.csv -SkipCertificateCheck
```

### Time ranges

`-TimeRange` accepts `Last15Min`, `Last30Min`, `Last60Min`, `Last24Hours`, `Last7Days` or `LastMonth`
(a rolling month back from now), or `Custom`. `Custom` uses `-Start` and `-End` (any `[datetime]`, both
required). For the named ranges `-Start`/`-End` are ignored, so one call can always pass all three. You
can also leave `-TimeRange` out and pass just `-Start`/`-End`; `-End` defaults to now and `-Start` to 5
minutes before `-End`. `Get-AviatrixCopilotTimeRange -Range <name>` returns the Start and End a named
range resolves to.

```powershell
$gw = 'transit1-gw','transit2-gw','transit3-gw'
$common = @{ TransitGateway = $gw; Metric = 'rate_total'; AggMethod = 'max' }

# Last 15 / 30 / 60 minutes
Export-AviatrixCopilotConnectionMetric @common -TimeRange Last15Min -Path ./last-15m.csv
Export-AviatrixCopilotConnectionMetric @common -TimeRange Last30Min -Path ./last-30m.csv
Export-AviatrixCopilotConnectionMetric @common -TimeRange Last60Min -Path ./last-60m.csv

# Last 24 hours, last 7 days, last month
Export-AviatrixCopilotConnectionMetric @common -TimeRange Last24Hours -Path ./last-24h.csv
Export-AviatrixCopilotConnectionMetric @common -TimeRange Last7Days -Path ./last-7d.csv
Export-AviatrixCopilotConnectionMetric @common -TimeRange LastMonth -Path ./last-month.csv

# Custom range (local time)
Export-AviatrixCopilotConnectionMetric @common -TimeRange Custom -Start (Get-Date).AddMinutes(-40) -End (Get-Date).AddMinutes(-10) -Path ./custom.csv

# Custom range in UTC
Export-AviatrixCopilotConnectionMetric @common -TimeRange Custom -Start ([datetime]'2026-11-17T08:00:00Z') -End ([datetime]'2026-11-17T12:30:00Z') -Path ./custom-utc.csv
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
"ConnectionType","Gateway","PeerGateway","Tunnel","Metric","AggMethod","Start","End","Points","Value","GatewayGroup","PeerGroup"
"SpokeTransitAttachment","spoke1-gw","transit1-gw","tun-0A000184-0","rate_total","avg","2026-11-04T22:46:30Z","2026-11-04T22:51:30Z","5","5265989.8","spoke1-gw","transit1-gw"
"SpokeTransitAttachment","spoke1-gw","transit1-gw","tun-0A000185-0","rate_total","avg","2026-11-04T22:46:30Z","2026-11-04T22:51:30Z","5","10484360.6","spoke1-gw","transit1-gw"
```

- **One row per tunnel.** Nothing is combined across tunnels: whether tunnels can be added up, averaged
  or compared depends on the metric (rates add up, latency does not), so grouping is left to you.
  Use `Gateway`, `PeerGateway`, `GatewayGroup` and `PeerGroup` to group the rows.
- **Both directions:** each connection appears twice, once from each gateway's own side
  (`Gateway` to `PeerGateway`, then the reverse). A tunnel therefore appears in both directions.
- **`GatewayGroup` and `PeerGroup`:** the gateway groups of the two sides. For a legacy primary and HA
  pair both gateways are in a group named after the primary (`transit1-gw`); a gateway group created
  with `aviatrix_transit_group` or `aviatrix_spoke_group` has its own name (`transit4`).
- **`Value`:** the tunnel's value over the time range, reduced with `AggMethod`: the mean (`avg`), the
  minimum (`min`), the maximum (`max`) or the sum (`sum`) of CoPilot's points. `Points` is how many
  points that used. With `-Detailed` the columns `Timestamp` and `Value` replace `Points` and `Value`,
  one row per point.
- **Units:** `rate_total` is reported in bits per second (inferred: one 5 Mbit/s iperf3 flow shows as
  about 5.2 M). Check other metrics before assuming units.
- **Row count:** one row per tunnel and direction. Tunnels between members of the same group (primary
  to HA, or one gateway group instance to another) are not exported.
- **Combining tunnels yourself:** to total a rate such as `rate_total`, sum `Value` over the tunnels of
  a group pair and direction, and use one export with `-AggMethod avg`, or with `-Detailed` if you
  need totals per minute. Tunnels report on slightly different minute marks, so check `Points` first.

## Gateway groups and HA gateways

CoPilot puts every gateway in a *gateway group*, and the module reads the groups once per export from
`GET /api/gateways`:

- A **legacy primary gateway** and its HA gateway share a group named after the primary:
  `transit1-gw` and `transit1-gw-hagw` are in group `transit1-gw`. Pass `-TransitGateway transit1-gw`
  and the HA gateway is found automatically. No `-hagw` naming convention is assumed.
- A **gateway group** created with `aviatrix_transit_group` / `aviatrix_spoke_group` holds its
  instances under the group's own name: `transit4-gw1`, `-gw2` and `-gw3` are in group `transit4`. Pass
  `-TransitGateway transit4` and every instance is used.

Either way the export reports the tunnels of all members of each group. Spokes are found from the
tunnels and are grouped the same way. A tunnel to a transit gateway you did not name is reported as a
`TransitPeering`, so naming only `transit1-gw` still shows its peerings to the other transits.

`/api/gateways` is undocumented, and the export needs it: if the call fails or returns no group
information, the export stops with an error instead of guessing gateway names.

## Request volume and timing

The export is designed not to hammer CoPilot:

- Each gateway's interface list is fetched once and reused.
- Each tunnel's series is fetched **once**, and the chosen `-AggMethod` is computed from it. At CoPilot's
  1-minute interval the avg, min and max series were identical for `rate_total`, so this gives the
  same CSV as asking CoPilot for that method. If that is not true for your metric, add
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
as a build artifact (kept 30 days). The job summary only states how many tunnel rows were exported.

Set up in the repo's *Settings > Secrets and variables > Actions*:

| Type | Name | Value |
|---|---|---|
| Secret | `COPILOT_USER`, `COPILOT_PASSWORD` | CoPilot login |
| Variable | `COPILOT_HOST` | CoPilot IP or FQDN |

Run inputs: transit gateways (comma-separated primary gateway or group names, default `transit1-gw,transit2-gw,transit3-gw,transit4`), time range (`Last15Min` through `LastMonth`, or `Custom` with UTC start and end such as
`2026-11-18T13:00:00Z`), metric, aggregation method (`avg`, `min`, `max` or `sum`) and connection type. The runner must reach
CoPilot over HTTPS: GitHub-hosted runners need CoPilot to be reachable from the internet, otherwise
change `runs-on` to a self-hosted runner. A commented-out `schedule` trigger is included for recurring
exports (those runs use the defaults: the four lab transits, `Last15Min`, `rate_total`, `avg`). The workflow imports
the module and makes one `Export-AviatrixCopilotConnectionMetric -ComputerName ...` call, so the same
call works locally.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Not connected to Aviatrix CoPilot` | Run `Connect-AviatrixCopilot` first; sessions are per PowerShell session |
| `No connections found for the given transit gateways` | Names are wrong or have no tunnels in the time range. Check them with `Get-AviatrixCopilotGatewayInterface` |
| `'x' is not a gateway or gateway group known to CoPilot` | The name is not a gateway or group in CoPilot. The error lists the transit groups it does know |
| `'x' is in spoke gateway group ...` | `-TransitGateway` takes transit gateways or transit gateway groups, not spokes |
| `Failed to get Aviatrix CoPilot gateways` or `CoPilot returned no gateway group information` | The export reads gateways and their groups from `/api/gateways`. A network or login error, or a CoPilot version without that endpoint or without `group_name`, stops it. Run `Get-AviatrixCopilotGatewayGroupMap` to see what CoPilot returns |
| `Must be a valid UTC ISO datetime` | A raw API call used the wrong time format; CoPilot needs `yyyy-MM-ddTHH:mm:ss.fffZ` (the module does this for you) |
| Passing `-TransitGateway a,b,c` to a script with `pwsh -File` finds nothing | `-File` delivers one string `"a,b,c"`. Set the list inside the script or use `-Command` |
| Certificate errors | Add `-SkipCertificateCheck` (self-signed CoPilot) |
