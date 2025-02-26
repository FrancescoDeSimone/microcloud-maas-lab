#!/bin/bash

set -e
set -u
set -x

trap cleanup SIGHUP SIGINT SIGTERM EXIT

function cleanup() {
  mv /root/.maascli.db ~ubuntu/ || true
  mv /root/.local ~ubuntu/ || true
  mv /root/.kube ~ubuntu/ || true
  mv /root/.ssh/id_* ~ubuntu/.ssh/ || true
  mv /root/* ~ubuntu/ || true
  chown -f ubuntu:ubuntu -R ~ubuntu
}

# try not to kill some commands by session management
# it seems like a race condition with MAAS jobs in root user and snapped
# juju command's systemd scope
# LP: #1921876, LP: #2058030
loginctl enable-linger root

export DEBIAN_FRONTEND=noninteractive
mkdir -p /root/.local/share/juju/ssh/ # LP: #2029515
cd ~/

MAAS_PPA='ppa:maas/3.5'

# proxy
if host squid-deb-proxy.lxd >/dev/null; then
  http_proxy="http://$(dig +short squid-deb-proxy.lxd):8000/"
  echo "Acquire::http::Proxy \"${http_proxy}\";" >/etc/apt/apt.conf
fi

# ppa
apt-add-repository -y "$MAAS_PPA"

apt-get update

# utils
eatmydata apt-get install -y tree jq

# KVM setup
eatmydata apt-get install -y libvirt-daemon-system
eatmydata apt-get install -y virtinst --no-install-recommends

cat >>/etc/libvirt/qemu.conf <<EOF

# Avoid the error in LXD containers:
# Unable to set XATTR trusted.libvirt.security.dac on
# /var/lib/libvirt/qemu/domain-*: Operation not permitted
remember_owner = 0
EOF

systemctl restart libvirtd.service

virsh net-destroy default
virsh net-autostart --disable default

virsh pool-define-as default dir --target /var/lib/libvirt/images
virsh pool-autostart default
virsh pool-start default

cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>maas</name>
  <bridge name='maas' stp='off'/>
  <forward mode='nat'/>
  <ip address='192.168.151.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart maas
virsh net-start maas

cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>public</name>
  <bridge name='public' stp='off'/>
  <forward mode='nat'/>
  <ip address='192.168.171.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart public
virsh net-start public

# maas package install
echo maas-region-controller maas/default-maas-url string 192.168.151.1 |
  debconf-set-selections
eatmydata apt-get install -y maas

# maas login as ubuntu/ubuntu
maas createadmin --username ubuntu --password ubuntu \
  --email ubuntu@localhost.localdomain

# LP: #2031842
sleep 30
maas login admin http://localhost:5240/MAAS "$(maas apikey --username ubuntu)"

ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
maas admin sshkeys create key="$(cat ~/.ssh/id_ed25519.pub)"

maas admin maas set-config name=enable_analytics value=false
maas admin maas set-config name=release_notifications value=false
maas admin maas set-config name=maas_name value='Demo'
maas admin maas set-config name=kernel_opts value='console=tty0 console=ttyS0,115200n8'
maas admin maas set-config name=completed_intro value=true

# configure network / DHCP
maas admin subnet update 192.168.151.0/24 \
  gateway_ip=192.168.151.1 \
  dns_servers=192.168.151.1

maas admin subnet update 192.168.171.0/24 \
  gateway_ip=192.168.171.1 \
  dns_servers=192.168.171.1

fabric=$(maas admin subnets read | jq -r \
  '.[] | select(.cidr=="192.168.151.0/24").vlan.fabric')
maas admin ipranges create type=reserved \
  start_ip=192.168.151.1 end_ip=192.168.151.100
maas admin ipranges create type=dynamic \
  start_ip=192.168.151.201 end_ip=192.168.151.254
maas admin vlan update "$fabric" 0 dhcp_on=true primary_rack="$HOSTNAME"

fabric=$(maas admin subnets read | jq -r \
  '.[] | select(.cidr=="192.168.171.0/24").vlan.fabric')
maas admin ipranges create type=reserved \
  start_ip=192.168.171.1 end_ip=192.168.171.100
maas admin ipranges create type=dynamic \
  start_ip=192.168.171.201 end_ip=192.168.171.254
#maas admin vlan update "$fabric" 0 dhcp_on=true primary_rack="$HOSTNAME"

maas admin spaces create name=space-first
fabric_id=$(maas admin subnets read | jq -r '.[] | select(.cidr=="192.168.151.0/24").vlan.fabric_id')
maas admin vlan update "$fabric_id" 0 space=space-first

maas admin spaces create name=space-second
fabric_id=$(maas admin subnets read | jq -r '.[] | select(.cidr=="192.168.171.0/24").vlan.fabric_id')
maas admin vlan update "$fabric_id" 0 space=space-second

maas admin boot-source-selections create 1 os=ubuntu release=noble arches=amd64 subarches='*' labels='*'

# wait image
time while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
  sleep 15
done

#sleep 120

# MAAS Pod
sudo -u maas -H ssh-keygen -t ed25519 -f ~maas/.ssh/id_ed25519 -N ''
install -m 0600 ~maas/.ssh/id_ed25519.pub /root/.ssh/authorized_keys

# "pod compose" is not going to be used
# but register the KVM host just for the UI demo purpose
maas admin pods create \
  type=virsh \
  cpu_over_commit_ratio=10 \
  memory_over_commit_ratio=1.5 \
  name=localhost \
  power_address='qemu+ssh://root@127.0.0.1/system'

# compose machines
num_machines=3
for i in $(seq 1 "$num_machines"); do
  # Create the VM
  virt-install \
    --import --noreboot \
    --name "compute-$i" \
    --osinfo ubuntujammy \
    --boot network,hd \
    --vcpus cores=16 \
    --cpu host-passthrough,cache.mode=passthrough \
    --memory 16384 \
    --disk size=600,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
    --disk size=600,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
    --disk size=600,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
    --network network=maas \
    --network network=public

  # Get the MAC address of the VM
  mac_address=$(virsh dumpxml "compute-$i" | xmllint --xpath 'string(//mac/@address)' -)

  # Create the machine in MAAS
  maas admin machines create \
    hostname="compute-$i" \
    architecture=amd64 \
    mac_addresses="$mac_address" \
    power_type=virsh \
    power_parameters_power_address='qemu+ssh://root@127.0.0.1/system' \
    power_parameters_power_id="compute-$i"

done

PRIVATE_KEY_CONTENT=$(cat ~/.ssh/id_ed25519 | sed ':a;N;$!ba;s/\n/\n      /g' )
# cloud-init for installing packages
cat >cloud-init.yaml <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - snapd
write_files:
  - path: /home/ubuntu/.ssh/id_ed25519
    permissions: '0600'
    content: |
      $PRIVATE_KEY_CONTENT
  - path: /home/ubuntu/.ssh/id_ed25519.pub
    permissions: '0644'
    content: |
      $(cat ~/.ssh/id_ed25519.pub)
  - path: /home/ubuntu/.ssh/config
    permissions: '0644'
    content: |
      Host *
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
runcmd:
  - [ chmod, 700, /home/ubuntu/.ssh]
  - [ chmod, 600, /home/ubuntu/.ssh/id_ed25519]
  - [ chmod, 644, /home/ubuntu/.ssh/id_ed25519.pub]
  - [ chown, -R, ubuntu:ubuntu, /home/ubuntu]
  - [ snap, remove, --purge, lxd ]
  - [ snap, install, lxd, --channel=5.21/stable, --cohort=+ ]
  - [ snap, install, microceph, --channel=squid/stable, --cohort=+ ]
  - [ snap, install, microovn, --channel=24.03/stable, --cohort=+ ]
  - [ snap, install, microcloud, --channel=2/stable, --cohort=+ ]
  - |
      cat <<EOF | sudo microcloud preseed
      initiator: compute-1
      lookup_subnet: 192.168.151.0/24
      session_passphrase: 83P27XWKbDczUyE7xaX3pgVfaEacfQ2qiQ0r6gPb
      systems:
      - name: compute-1
        ovn_uplink_interface: enp2s0
        storage:
          local:
            path: /dev/sdb
          ceph:
            - path: /dev/sdc
      - name: compute-2
        ovn_uplink_interface: enp2s0
        storage:
          local:
            path: /dev/sdb
          ceph:
            - path: /dev/sdc
      - name: compute-3
        ovn_uplink_interface: enp2s0
        storage:
          local:
            path: /dev/sdb
          ceph:
            - path: /dev/sdc
      ovn:
        ipv4_gateway: 192.168.171.1/24
        ipv4_range: 192.168.171.100-192.168.171.254
      EOF
  - |
      if [ "\$(hostname)" = "compute-1" ]; then
          lxc config set cluster.healing_threshold 1
          lxc config set core.https_address ":8443"
          lxc config set core.metrics_address ":8444"
          export COS_ADDR=\$(host COS | awk '/has address/ { print \$4 }')
          lxc config set loki.api.url="http://\${COS_ADDR}/cos-loki-0"
	  lxc config set loki.instance=\$(ssh COS -- juju ssh --container prometheus prometheus/0 cat /etc/prometheus/prometheus.yml | grep -oP 'job_name: \K.*prometheus-scrape-target-k8s_external_jobs')

      fi
  - [ snap, install, grafana-agent ]
  - |
      export COS_ADDR=\$(host COS | awk '/has address/ { print \$4 }')
      cat <<EOF > /var/snap/grafana-agent/current/etc/grafana-agent.yaml
      integrations:
        agent:
          enabled: true
        node_exporter:
          enabled: true

      metrics:
        global:
          remote_write:
            - url: http://\${COS_ADDR}/cos-prometheus-0/api/v1/write

      logs:
        configs:
        - name: default
          positions:
            filename: /tmp/positions.yaml
          scrape_configs:
            - job_name: varlogs
              static_configs:
                - targets: [localhost]
                  labels:
                    job: varlogs
                    __path__: /var/log/*log
        clients:
          - url: http://\${COS_ADDR}/cos-loki-0/loki/api/v1/push
      EOF
  - [ snap, restart, grafana-agent ]
  - [ mv, /root/snap, /home/ubuntu/snap ]
  - [ chown, ubuntu:ubuntu, -R, /home/ubuntu/snap]
EOF

virt-install \
  --import --noreboot \
  --name "COS" \
  --osinfo ubuntujammy \
  --boot network,hd \
  --vcpus cores=16 \
  --cpu host-passthrough,cache.mode=passthrough \
  --memory 8192 \
  --disk size=500,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
  --network network=maas \
  --network network=public

# Get the MAC address of the VM
mac_address=$(virsh dumpxml "COS" | xmllint --xpath 'string(//mac/@address)' -)

# Create the machine in MAAS
maas admin machines create \
  hostname="COS" \
  architecture=amd64 \
  mac_addresses="$mac_address" \
  power_type=virsh \
  power_parameters_power_address='qemu+ssh://root@127.0.0.1/system' \
  power_parameters_power_id="COS"

# cloud-init for installing packages
cat >cloud-init-cos.yaml <<EOF
#cloud-config
package_update: true
package_upgrade: true
packages:
  - snapd
write_files:
  - path: /home/ubuntu/.ssh/id_ed25519
    permissions: '0600'
    content: |
      $PRIVATE_KEY_CONTENT
  - path: /home/ubuntu/.ssh/id_ed25519.pub
    permissions: '0644'
    content: |
      $(cat ~/.ssh/id_ed25519.pub)
  - path: /home/ubuntu/.ssh/config
    permissions: '0644'
    content: |
      Host *
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
  - path: /usr/local/bin/setup-addon.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -x
      microk8s enable dns
      microk8s enable hostpath-storage
      IPADDR=\$(ip -4 -j route get 2.2.2.2 | jq -r '.[] | .prefsrc')
      microk8s enable metallb:\$IPADDR-\$IPADDR
      microk8s kubectl rollout status deployments/hostpath-provisioner -n kube-system, -w
      microk8s kubectl rollout status deployments/coredns -n kube-system -w
      microk8s kubectl rollout status daemonset.apps/speaker -n metallb-system -w
  - path: /usr/local/bin/setup-juju.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -x
      sudo usermod -a -G snap_microk8s ubuntu
      # Make sure group is applied
      newgrp snap_microk8s <<EOF
        juju bootstrap microk8s
        juju add-model cos
        juju deploy cos-lite --trust
        juju deploy prometheus-scrape-target-k8s
        juju relate prometheus prometheus-scrape-target-k8s
      EOF
  - path: /usr/local/bin/setup-metrics.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -x
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -sha384 -keyout /home/ubuntu/metrics.key -nodes -out /home/ubuntu/metrics.crt -days 3650 -subj "/CN=metrics.local"
      scp /home/ubuntu/metrics.crt compute-1:/home/ubuntu/metrics.crt
      ssh -o StrictHostKeyChecking=no compute-1.maas << 'EOF'
        sudo lxc config trust add /home/ubuntu/metrics.crt --type=metrics
      EOF
      ssh -o StrictHostKeyChecking=no compute-1.maas "sudo lxc query /1.0" | jq -r .environment.certificate > /tmp/cluster.crt
      COMPUTE_1_IP=\$(host compute-1 | awk '/has address/ { print \$4 }')
      COMPUTE_2_IP=\$(host compute-2 | awk '/has address/ { print \$4 }')
      COMPUTE_3_IP=\$(host compute-3 | awk '/has address/ { print \$4 }')

      # Set up Prometheus configuration with dynamically resolved IPs
      juju config prometheus-scrape-target-k8s \
		metrics_path=/1.0/metrics \
		scheme=https \
		tls_config_ca_file="\$(cat /tmp/cluster.crt)" \
		tls_config_cert_file="\$(cat /home/ubuntu/metrics.crt)" \
		tls_config_key_file="\$(cat /home/ubuntu/metrics.key)" \
		tls_config_server_name="127.0.0.1" \
		targets=\$COMPUTE_1_IP:8443,\$COMPUTE_2_IP:8443,\$COMPUTE_3_IP:8443
runcmd:
  - [ chmod, 700, /home/ubuntu/.ssh]
  - [ chmod, 600, /home/ubuntu/.ssh/id_ed25519]
  - [ chmod, 644, /home/ubuntu/.ssh/id_ed25519.pub]
  - [ chown, -R, ubuntu:ubuntu, /home/ubuntu]
  - [ snap, install, microk8s, --channel=1.32-strict/stable ]
  - [ snap, install, juju ]
  - [ apt, install, jq, --yes ]
  - [ /usr/local/bin/setup-addon.sh ]
  - [ sudo, -u, ubuntu, /usr/local/bin/setup-juju.sh ]
  - [ sudo, -u, ubuntu, /usr/local/bin/setup-metrics.sh]
EOF

for i in $(seq 1 "$num_machines"); do
  while true; do
    status=$(maas admin machines read | jq -r ".[] | select(.hostname == \"compute-$i\") | .status_name")
    if [[ "$status" == "Ready" ]]; then
      echo "Machine $i is ready!"
      break
    fi
    echo "Waiting for machine $i to be commissioned (current status: $status)..."
    sleep 15
  done
  system_id=$(maas admin nodes read | jq -r ".[] | select(.hostname == \"compute-$i\") | .system_id")
  maas admin machine deploy "$system_id" user_data="$(base64 -w0 cloud-init.yaml)"
done

while true; do
  status=$(maas admin machines read | jq -r ".[] | select(.hostname == \"COS\") | .status_name")
  if [[ "$status" == "Ready" ]]; then
    echo "Machine COS is ready!"
    break
  fi
  echo "Waiting for machine COS to be commissioned (current status: $status)..."
  sleep 15
done
system_id=$(maas admin nodes read | jq -r ".[] | select(.hostname == \"COS\") | .system_id")
maas admin machine deploy "$system_id" user_data="$(base64 -w0 cloud-init-cos.yaml)"
