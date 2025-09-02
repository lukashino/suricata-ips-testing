#! /bin/sh

set -e
set -x

sudo iptables -P FORWARD DROP
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -I FORWARD -j NFQUEUE
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward

exec /bin/bash
