# TODO

## Switch transit4 / spoke4 peering and attachment to group names

`hpe_groups.tf` peers and attaches by the first instance's name (`transit4-gw1`, `spoke4-gw1`) because
provider 10.0.20 and the 10.0.21 controller cannot resolve group names. After a controller upgrade
that supports `get_gateway_group_details_by_name`:

1. Move to provider 10.1.x and the 10.1.0 `mc-transit` / `mc-spoke` modules (see `versions.tf`).
2. Use `aviatrix_transit_group.transit4.group_name` and `aviatrix_spoke_group.spoke4.group_name` in the
   peerings and the attachment.
3. Run `terraform plan`; it should show no gateway changes.
4. Confirm in CoPilot that every group member has tunnels.

## PowerShell module

Done: `-TransitGateway` takes a primary transit gateway name or a transit gateway group name. Both
resolve to a CoPilot gateway group (`GET /api/gateways`, field `group_name`), so primary + HA gateways
and gateway group instances are discovered without assuming a `-hagw` suffix. Tunnels inside one group
are skipped, and the CSV has `GatewayGroup` / `PeerGroup` columns plus `GROUP` total rows.

Still open:

- `/api/gateways` is undocumented. It was found by probing and may change between CoPilot versions,
  and the export now depends on it (there is no `-hagw` naming fallback). Tested only on an
  18-gateway response with two-member (primary + HA) and three-member groups; unknown whether very
  large environments paginate.
- The response contains sensitive data (cloud account names, public and private IPs, resource IDs,
  and empty-here fields for LDAP, Duo and Okta secrets). The module keeps only the gateway name, group
  and type; never log, save or commit the raw response.
- `is_hagw` and `ha_enabled` in that response are not reliable (a gateway group reports an arbitrary
  member as the "primary", and `ha_enabled` was `no` everywhere). The module relies on `group_name`
  and `$gw_type` only.
- `ALL` and `GROUP` totals only count timestamps at which every tunnel reported. If one tunnel has
  a long gap or starts late (for example a freshly created tunnel), the total covers only the minutes
  where all tunnels have data; check `Points` on the row and run with `-Verbose` to see what was dropped.
- `GET /api/topology` also returns JSON (about 240 KB) and has not been looked at; it may be a better
  source for the whole connection map.
- Add automated tests (Pester) for the group resolution and edge discovery with canned responses.
