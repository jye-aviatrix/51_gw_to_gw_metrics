# TODO

## Discover HA gateways from CoPilot instead of guessing the `-hagw` suffix

### Current behaviour

`Get-AviatrixCopilotTopologyEdge` (in `powershell/AviatrixCopilot/AviatrixCopilot.psm1`) tries
`<transit>-hagw` for every transit gateway and treats a failed lookup as "this transit has no HA
gateway", without any warning. Consequences:

- An HA gateway that is not named `<primary>-hagw` is not found.
- A transient failure (network error, timeout) on the `-hagw` lookup silently drops the HA rows from
  the export.
- Spoke HA gateways are only found indirectly, from the tunnel destinations seen on the transits.

### Finding: CoPilot has an endpoint that reports HA relationships

`GET /api/gateways` (same session cookie as the other calls) returns every gateway in one response:

```
{ "return": true, "results": [ { ...one object per gateway... } ] }
```

Observed on the lab CoPilot: 12 entries (3 transits, 3 spokes, and an HA gateway for each). Fields
that matter:

| Field | Meaning |
|---|---|
| `gw_name` | Gateway name |
| `is_hagw` | `"yes"` for an HA gateway, `"no"` for a primary |
| `ha_gw_name_list` | Array of the primary's HA gateway names, for example `["transit1-gw-hagw"]`. Empty on HA gateways |
| `$gw_type` | `transit` or `spoke` |
| `$connection_to_ha_list` | Same relationship as `ha_gw_name_list` |
| `$connection_to_transit_list`, `site_peering_list` | Transit peers of a transit gateway |
| `$connection_to_spoke_list`, `spoke_gw_list` | Spokes attached to a transit gateway |
| `$hagw_details_list` | Full records of the HA gateways |

Do **not** rely on `ha_enabled`: it was `"no"` on every gateway, including ones that have an HA
gateway.

`GET /api/topology` also returns JSON (about 240 KB) and has not been looked at yet; it may be a
better source for the whole connection map.

### Proposed change

1. Call `/api/gateways` once per export and build a map of primary gateway to HA gateway names from
   `ha_gw_name_list` (primaries are the entries with `is_hagw = no`).
2. Use that map in `Get-AviatrixCopilotTopologyEdge` in place of `"$transit-hagw"`. Handle more than
   one HA gateway per primary, since the field is an array.
3. If the call fails or the endpoint is missing, fall back to the `-hagw` suffix and write a warning
   that says so.
4. Make a failed lookup of a known HA gateway an error or a warning instead of silently skipping it.
5. Optionally use `$connection_to_spoke_list` and `$connection_to_transit_list` to cross-check the
   connections discovered from tunnel destinations.

### Gateway groups (transit4 / spoke4)

The lab now includes `transit4-gw1..3` and `spoke4-gw1..3`, built with the gateway group resources.
These have no `-hagw` gateway, so the `-hagw` guess finds nothing for them. Until HA discovery uses
`/api/gateways`, pass all three `transit4-gw*` names as transit gateways to the export so the
transit-to-transit peerings are classified correctly. Check how `/api/gateways` reports group
instances (`ha_gw_name_list`, `is_hagw`) once they are deployed.

The group members also have tunnels to each other (for example `transit4-gw1` to `transit4-gw2`, and
`spoke4-gw1` to `spoke4-gw2`). The export treats any tunnel between gateways with different names as a
connection, so with all three `transit4-gw*` names in the transit list it would report those internal
tunnels as extra transit peerings. Use the group information from `/api/gateways` to skip tunnels
between members of the same group (the same way primary-to-HA tunnels are skipped today).

### Caveats

- The endpoint is undocumented. It was found by probing, so it may change between CoPilot versions.
  Keep the suffix fallback.
- Only tested on one lab with one HA gateway per primary. Unknown: behaviour with several HA
  gateways, and whether very large environments paginate the response.
- The response contains sensitive data (cloud account names, public and private IPs, resource IDs,
  and empty-here fields for LDAP, Duo and Okta secrets). Keep only the fields needed, and never log,
  save or commit the raw response.
- Add a test that checks the HA map against a real CoPilot before relying on it.

## Other

- Discovery relies on `destinationGateway` in tunnel interfaces; once `/api/gateways` is used, check
  whether the explicit peer and spoke lists make that unnecessary.

## Switch transit4 / spoke4 peering and attachment to group names

`hpe_groups.tf` peers and attaches by the first instance's name (`transit4-gw1`, `spoke4-gw1`) because
provider 10.0.20 and the 10.0.21 controller cannot resolve group names. After a controller upgrade
that supports `get_gateway_group_details_by_name`:

1. Move to provider 10.1.x and the 10.1.0 `mc-transit` / `mc-spoke` modules (see `versions.tf`).
2. Use `aviatrix_transit_group.transit4.group_name` and `aviatrix_spoke_group.spoke4.group_name` in the
   peerings and the attachment.
3. Run `terraform plan`; it should show no gateway changes.
4. Confirm in CoPilot that every group member has tunnels, and update the export to handle group
   members once HA discovery uses `/api/gateways`.
