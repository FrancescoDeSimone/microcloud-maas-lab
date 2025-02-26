#!/bin/bash

set -e
set -u

cd "$(dirname "$0")"

lxc profile create microcloud 2>/dev/null || true
lxc profile device add microcloud kvm unix-char path=/dev/kvm 2>/dev/null || true
lxc profile device add microcloud vhost-net unix-char path=/dev/vhost-net mode=0600 2>/dev/null || true
lxc profile set microcloud security.nesting true
lxc profile set microcloud boot.autostart false

lxc init ubuntu:jammy microcloud \
    -p default -p microcloud \
    -c user.user-data="$(cat user-script.sh)"

lxc network attach lxdbr0 microcloud eth0 eth0
lxc config device set microcloud eth0 ipv4.address 10.0.9.12
lxc config device add microcloud proxy-ssh proxy \
    listen=tcp:0.0.0.0:10912 connect=tcp:127.0.0.1:22

lxc start microcloud

sleep 15

lxc file push -p --uid 1000 --gid 1000 --mode 0600 ~/.ssh/authorized_keys microcloud/home/ubuntu/.ssh/
while true; do
    sleep 15
    status=$(lxc exec -t microstack -- cloud-init status | grep -oP '^status:\s+\K\w+')
    if [[ "$status" != "running" ]]; then
        notify-send "Microcloud deployment" "Current status: $status"
	exit
    fi
done &

if which ts >/dev/null; then
    lxc exec -t microcloud -- tail -f -n+1 /var/log/cloud-init-output.log | ts
else
    lxc exec -t microcloud -- tail -f -n+1 /var/log/cloud-init-output.log
fi
