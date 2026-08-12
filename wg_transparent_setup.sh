#!/usr/bin/env bash
#
# Switch the proxy box from explicit-proxy (Wi-Fi only) to TRANSPARENT
# interception so capture works on cellular too, and only HackEx traffic is
# routed through the tunnel (DNS-steering). REVIEW before running — it changes
# the live capture path. Run as root on the proxy box.
#
#   sudo bash wg_transparent_setup.sh
#
# What it does:
#   1. Enable IPv4 forwarding (persisted).
#   2. dnsmasq on 10.8.0.1: pin HackEx hostnames to a fixed Cloudflare edge that
#      is inside the tunnel's AllowedIPs; forward everything else upstream (so
#      non-HackEx traffic resolves to real IPs NOT in AllowedIPs and stays off
#      the tunnel).
#   3. iptables: redirect tcp:443/:80 arriving on wg0 to mitmdump's :8080.
#   4. Point the k3rn-proxy service at mitmdump --mode transparent, intercepting
#      ONLY *.hackex.net (--allow-hosts); any other host that happens to share a
#      Cloudflare edge IP is TLS-passthrough, so it isn't broken by our CA.
#
# The client .conf (returned by provision-peer) must set:
#   DNS = 10.8.0.1
#   AllowedIPs = 104.26.4.103/32,104.26.5.103/32,172.67.71.254/32,10.8.0.0/24
set -euo pipefail

WG_IFACE=wg0
PROXY_PORT=8080
HACKEX_PIN=104.26.4.103   # a current api2.hackex.net Cloudflare edge (in AllowedIPs)

echo "==> 1/4 enable ip_forward"
sysctl -w net.ipv4.ip_forward=1
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

echo "==> 2/4 dnsmasq DNS-steering on 10.8.0.1"
apt-get install -y dnsmasq >/dev/null
# systemd-resolved may hold :53 — bind dnsmasq to the tunnel address only.
cat >/etc/dnsmasq.d/k3rn.conf <<EOF
listen-address=10.8.0.1
bind-interfaces
no-resolv
server=1.1.1.1
server=8.8.8.8
# Pin HackEx to a stable Cloudflare edge that is inside the tunnel AllowedIPs so
# only game traffic is captured. Update HACKEX_PIN if this edge ever goes away.
address=/hackex.net/${HACKEX_PIN}
# Strip AAAA (IPv6) from all replies. Without this the phone prefers IPv6 for
# HackEx (a real Cloudflare v6 addr NOT in AllowedIPs) and the game traffic
# bypasses the tunnel entirely — capture silently fails. Forcing IPv4-only keeps
# HackEx on the pinned A record that routes through wg0.
filter-AAAA
# Strip SVCB(64)/HTTPS(65) records too. iOS connects via the HTTPS RR when present,
# and that record carries its own IP hints (incl. IPv6) that bypass the A-record
# pin. Filtering it forces fallback to the pinned A record. Both filters together
# guarantee HackEx only ever resolves to HACKEX_PIN, which is inside AllowedIPs.
filter-rr=64,65
EOF
systemctl restart dnsmasq
systemctl enable dnsmasq >/dev/null

echo "==> 3/4 iptables redirect 443/80 (wg0) -> mitmdump ${PROXY_PORT}"
add_redirect() {
  local dport=$1
  iptables -t nat -C PREROUTING -i "$WG_IFACE" -p tcp --dport "$dport" \
    -j REDIRECT --to-ports "$PROXY_PORT" 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$WG_IFACE" -p tcp --dport "$dport" \
    -j REDIRECT --to-ports "$PROXY_PORT"
}
add_redirect 443
add_redirect 80
apt-get install -y iptables-persistent >/dev/null || true
netfilter-persistent save || iptables-save > /etc/iptables/rules.v4 || true

echo "==> 4/4 switch k3rn-proxy to transparent mode (HackEx only)"
mkdir -p /etc/systemd/system/k3rn-proxy.service.d
cat >/etc/systemd/system/k3rn-proxy.service.d/transparent.conf <<EOF
[Service]
ExecStart=
ExecStart=/home/ubuntu/.local/bin/mitmdump --mode transparent \\
  --showhost --set block_global=false \\
  --allow-hosts '(^|\\.)hackex\\.net' \\
  --listen-host 0.0.0.0 --listen-port ${PROXY_PORT} \\
  -s /home/ubuntu/k3rn_capture_addon.py
EOF
systemctl daemon-reload
systemctl restart k3rn-proxy
sleep 2
systemctl is-active k3rn-proxy

echo
echo "Done. Verify from a phone (cellular): tunnel ON + CA trusted -> open HackEx ->"
echo "a capture should appear. To roll back: rm the two drop-in/conf files, remove the"
echo "iptables rules, and 'systemctl restart k3rn-proxy dnsmasq'."
