# Export HPE connection metrics

Aviatrix CoPilot can display individual tunnel network metric, however, when HPE is been used between Gateways, it's difficult to answer questions such as:
1. When there are full mesh transit peerings, what's the amount of traffic going across specific transit peering in the last 7 days?
2. When HPE spoke gateway is attached to east/west transit and egress transit at the same time, how much traffic is sent via E/W transit in the last 7 days?

As such, it's difficult to perform capacity planning as we cannot answer these questions easily.
It's possible to multi-select tunnels via remote gateway label in CoPilot Metric page manually, but it will be a diffcult task if you are working in larger environments.


# Structure of the repo

## Terraform
The root folder of this repo contains terraform code to build:
1. Three HPE transit gateways, they are connected to each other full-mesh
2. Each HPE transit gateway group has it's own HPE Spoke gateways attachment
3. Each spoke has test VMs generate traffic towards all other test VMs.

## PowerShell module
/powershell folder contains PowerShell module that will query against CoPilot instance
1. It's expecting environment variable for COPILOT_USER and COPILOT_PASSWORD, or you will be prompted to enter credential interactively.
2. /powershell/Exaples/Export-ConnectionMetric.example.ps1 give you various exmaples of how to provide inputs, and specify output CSV

## GitHub action
/.github/workflows/export-connection-metrics.yml give you an example of how to call the PowerShell script from GitHub actions
