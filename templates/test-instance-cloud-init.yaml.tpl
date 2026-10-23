#cloud-config
package_update: true
packages:
  - iperf3

write_files:
  - path: /etc/systemd/system/iperf3-server@.service
    content: |
      [Unit]
      Description=iperf3 server on port %i
      After=network.target

      [Service]
      ExecStart=/usr/bin/iperf3 -s -p %i
      Restart=always
      RestartSec=2

      [Install]
      WantedBy=multi-user.target

  - path: /usr/local/bin/iperf3-client.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      exec /usr/bin/iperf3 -c "$1" -p ${my_port} -P ${streams} -b ${bandwidth_per_stream_mbps}M -t 0 --forceflush

  - path: /etc/systemd/system/iperf3-client@.service
    content: |
      [Unit]
      Description=iperf3 continuous client to peer %i
      After=network-online.target
      Wants=network-online.target

      [Service]
      ExecStart=/usr/local/bin/iperf3-client.sh %i
      Restart=always
      RestartSec=5

      [Install]
      WantedBy=multi-user.target

runcmd:
  - systemctl daemon-reload
%{ for p in server_ports ~}
  - systemctl enable --now iperf3-server@${p}.service
%{ endfor ~}
%{ for peer_ip in peer_ips ~}
  - systemctl enable --now "iperf3-client@${peer_ip}.service"
%{ endfor ~}
