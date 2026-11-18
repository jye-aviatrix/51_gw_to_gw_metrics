# Aviatrix gateway-to-gateway metrics lab: Terraform deployment

A small Azure lab for studying Aviatrix gateway-to-gateway traffic metrics. Terraform builds a
transit/spoke mesh and a set of VMs that generate continuous, known-rate traffic between spokes.

To read the resulting per-tunnel metrics from Aviatrix CoPilot and export them to CSV, see
[powershell/README.md](powershell/README.md).

## What gets deployed

```
          transit1-gw ──── transit2-gw        full-mesh transit peering
               \    \      /    /              (mc-transit-peering, plus transit4
                \    transit3-gw /               peered to each of the three)
                 \      |      /
                  transit4 group (HPE): transit4-gw1, -gw2, -gw3

 spoke1-gw ── transit1-gw     spoke2-gw ── transit2-gw     spoke3-gw ── transit3-gw
   2 test VMs                   2 test VMs                   2 test VMs

 spoke4 group (HPE): spoke4-gw1, -gw2, -gw3  ── transit4 group
   3 test VMs (one per zone)
```

| Piece | Details |
|---|---|
| Transit gateways | `transit1-gw`, `transit2-gw`, `transit3-gw` (10.0.1-3.0/24), insane mode, `Standard_D2s_v5`, HA (`-hagw`) |
| Spoke gateways | `spoke1-gw`, `spoke2-gw`, `spoke3-gw` (172.16.1-3.0/24), each attached to the same-numbered transit |
| transit4 group | `transit4` group with `transit4-gw1`, `-gw2`, `-gw3` (10.0.4.0/23, zones az-1 to az-3), insane mode (HPE), built with `aviatrix_transit_group` and `aviatrix_transit_instance`. The three instances are equal group members, with no `-hagw` gateway |
| spoke4 group | `spoke4` group with `spoke4-gw1`, `-gw2`, `-gw3` (172.16.4.0/23), insane mode (HPE), built with `aviatrix_spoke_group` and `aviatrix_spoke_instance`, attached to the `transit4` group |
| Transit peering | Full mesh across all four transits: transit1-3 through `mc-transit-peering`, and the `transit4` group peered to each of them |
| Test VMs | 9 Ubuntu 22.04 VMs: 2 in each of spoke1-3 and 3 in spoke4 (one per availability zone, zones 1 to 3, matching its gateways), in the non-gateway public subnets, each with a public IP |
| Traffic | Every VM runs 9 `iperf3` servers (ports 5201-5209) and 8 continuous clients, one to each other VM (72 flows). Default 5 Mbit/s per flow across 5 streams |

The test VMs target each other's **private** IPs, so cross-spoke traffic transits the Aviatrix
gateways. Inbound SSH is limited to the public IP of the machine that ran `terraform apply`.

## Files

| Path | Purpose |
|---|---|
| `main.tf` | Transit, spoke and peering modules (transit1-3, spoke1-3) |
| `hpe_groups.tf` | transit4 and spoke4 built with the gateway group resources, their VNets, the attachment and the peerings to transit1-3 |
| `test_instances.tf` | NSGs, public IPs, NICs and VMs for the traffic generators |
| `templates/test-instance-cloud-init.yaml.tpl` | Installs `iperf3`, starts the servers and clients as systemd services |
| `variables.tf`, `versions.tf`, `providers.tf` | Inputs and provider pins (Aviatrix provider 10.0.20 for the 10.0.21 controller; see the note below) |
| `powershell/` | CoPilot metrics module and examples (see its own README) |

## Prerequisites

- Terraform >= 1.0
- An Aviatrix Controller with an Azure access account onboarded (its Azure client secret must be valid)
- Azure credentials in the `ARM_*` environment variables (used by the `azurerm` provider)
- An SSH key pair; the public key path defaults to `~/.ssh/az-key-pair.pub`

## Configure

Create `terraform.tfvars` (it is git-ignored):

```hcl
region              = "East US"
account             = "<aviatrix azure access account>"
controller_ip       = "<controller ip or fqdn>"
controller_username = "admin"
controller_password = "<password>"
```

| Variable | Default | Purpose |
|---|---|---|
| `region`, `account`, `controller_ip`, `controller_username`, `controller_password` | required | Azure region, Aviatrix Azure access account, controller login |
| `ssh_public_key_path` | `~/.ssh/az-key-pair.pub` | Public key injected into the test VMs |
| `test_vm_admin_username` | `azureuser` | Admin user on the test VMs |
| `test_vm_size` | `Standard_B1s` | Azure VM size for the test VMs |
| `traffic_bandwidth_mbps` | `5` | Total bandwidth each VM sends to every other VM |
| `traffic_parallel_streams` | `5` | Parallel iperf3 streams per flow |

## Deploy

```sh
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Gateway creation is slow (many minutes). Outputs: `terraform output test_instance_public_ips` and
`test_instance_private_ips`.

### If an apply fails or times out

- **"gateway ... is not ready"** (`AVXERR-TRANSIT-0029`): the gateway was still coming up. Re-run
  `terraform plan` and apply again.
- **"... already exists"** (`AVXERR-TRANSIT-0055`) after a timeout: the controller created the object
  but Terraform recorded it as failed. `terraform plan` shows it as *tainted* and wants to recreate
  it, which fails again. Run `terraform untaint '<resource address>'`, then plan; it should report
  no changes.
- **`AADSTS7000222` / "client secret keys ... are expired"**: the Azure client secret behind the
  controller's Azure access account has expired. Create a new secret for the app registration in
  Entra ID, update the access account on the controller, then re-plan.

### Verify the traffic

SSH to a VM (`ssh -i <private key> azureuser@<public ip>`) and check:

```sh
systemctl is-active iperf3-server@5201.service            # 9 servers, ports 5201-5209
systemctl list-units 'iperf3-client@*'                    # 8 clients, one per peer
journalctl -u iperf3-client@172.16.2.20.service -n 5     # live per-flow rate
```

Each flow should show about 5.24 Mbit/s with the default settings.

## Cleanup

```sh
terraform destroy
```

## Notes

- `terraform.tfvars` and state files are git-ignored. State is local and can contain sensitive
  resource attributes (for example gateway and VM details); do not commit or share it.
- The controller's TLS certificate is not verified (`verify_ssl_certificate = false`), as is common
  for lab controllers.
- `terraform.tfvars.example` uses older variable names (`aviatrix_controller_ip`, ...) that no longer
  match `variables.tf`; use the names in the table above.

### Gateway groups need provider 9.x or later, and the controller version matters

`transit4` and `spoke4` use the group resources, which exist only in provider 9.x and later. Provider
10.1.x cannot be used with a 10.0.21 controller: it looks gateway groups up with an API the controller
does not have, and `terraform plan` then fails even for the existing gateways (`Valid action
required: get_gateway_group_details_by_name`). This lab therefore pins provider 10.0.20 with the 9.0.0
`mc-transit` and `mc-spoke` modules (the 10.1.0 modules require provider 10.1.0 or later). Upgrade the
controller before moving to provider 10.1.x.

The 9.x modules default `tunnel_forward_secrecy` to `enable`; `main.tf` sets `disable` so the existing
gateways do not change.

### Peering and attaching groups by gateway name (workaround)

The current provider docs say `transit_gateway_name1/2` (peering) and `spoke_gw_name` / `transit_gw_name`
(attachment) accept a gateway **or gateway group** name. That is true for provider 10.1.x against a
controller that has the group lookup API, but not for this lab:

- Provider 10.0.20 only describes gateway names for those arguments. Passing the group name `transit4`
  fails with `failed to get gateway transit4: ErrNotFound` (peering) and `could not find spoke gateway:
  ErrNotFound` (attachment).
- Provider 10.1.x does accept group names, but it looks them up with `get_gateway_group_details_by_name`,
  which the 10.0.21 controller rejects (HTTP 400, `Valid action required`).

`hpe_groups.tf` therefore peers and attaches using the name of each group's first instance
(`transit4-gw1` and `spoke4-gw1`), the same way the `mc-transit` and `mc-spoke` modules use their
primary gateway's name. The controller applies it to the whole group, which is how the existing
primary and HA gateways behave. After applying, check in CoPilot that `transit4-gw2` and `transit4-gw3`
also have tunnels to transit1-3 and that all three spoke4 gateways have tunnels to the transit4 gateways.

**When the controller is upgraded** to a release with the group API, move to provider 10.1.x and the
10.1.0 modules, then replace `aviatrix_transit_instance.transit4["gw1"].gw_name` and
`aviatrix_spoke_instance.spoke4["gw1"].gw_name` in the peering and attachment with
`aviatrix_transit_group.transit4.group_name` and `aviatrix_spoke_group.spoke4.group_name`.

### Adding transit4/spoke4 to an existing deployment

`terraform plan` shows the 6 existing test VMs being **replaced**: their startup script lists every
peer, and it now includes the three spoke4 VMs. Gateways and VNets of transit1-3 and spoke1-3 are not
touched.
