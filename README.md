# Aviatrix gateway-to-gateway metrics lab: Terraform deployment

A small Azure lab for studying Aviatrix gateway-to-gateway traffic metrics. Terraform builds a
transit/spoke mesh and a set of VMs that generate continuous, known-rate traffic between spokes.

To read the resulting per-tunnel metrics from Aviatrix CoPilot and export them to CSV, see
[powershell/README.md](powershell/README.md).

## What gets deployed

```
          transit1-gw ──── transit2-gw        full-mesh transit peering
               \              /               (mc-transit-peering)
                \            /
                 transit3-gw

 spoke1-gw ── transit1-gw     spoke2-gw ── transit2-gw     spoke3-gw ── transit3-gw
   2 test VMs                   2 test VMs                   2 test VMs
```

| Piece | Details |
|---|---|
| Transit gateways | `transit1-gw`, `transit2-gw`, `transit3-gw` (10.0.1-3.0/24), insane mode, `Standard_D2s_v5`, HA (`-hagw`) |
| Spoke gateways | `spoke1-gw`, `spoke2-gw`, `spoke3-gw` (172.16.1-3.0/24), each attached to the same-numbered transit |
| Transit peering | Full mesh across all three transits |
| Test VMs | 6 Ubuntu 22.04 VMs, 2 per spoke, in the non-gateway public subnets, each with a public IP |
| Traffic | Every VM runs 6 `iperf3` servers (ports 5201-5206) and 5 continuous clients, one to each other VM (30 flows). Default 5 Mbit/s per flow across 5 streams |

The test VMs target each other's **private** IPs, so cross-spoke traffic transits the Aviatrix
gateways. Inbound SSH is limited to the public IP of the machine that ran `terraform apply`.

## Files

| Path | Purpose |
|---|---|
| `main.tf` | Transit, spoke and peering modules |
| `test_instances.tf` | NSGs, public IPs, NICs and VMs for the traffic generators |
| `templates/test-instance-cloud-init.yaml.tpl` | Installs `iperf3`, starts the servers and clients as systemd services |
| `variables.tf`, `versions.tf`, `providers.tf` | Inputs and provider pins (Aviatrix provider 8.1.30 for an 8.1.40 controller) |
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
systemctl is-active iperf3-server@5201.service            # 6 servers, ports 5201-5206
systemctl list-units 'iperf3-client@*'                    # 5 clients, one per peer
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
