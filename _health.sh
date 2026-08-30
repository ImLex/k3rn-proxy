#!/usr/bin/env bash
P=$(systemctl show k3rn-proxy.service -p MainPID --value)
echo "MainPID=$P"
echo "active=$(systemctl is-active k3rn-proxy.service)"
ps -o pid=,etimes=,comm= -p "$P" || echo "PID_NOT_RUNNING"
if sudo grep -qa PENDING /proc/"$P"/environ; then
  echo "KEY=STALE_PENDING"
else
  echo "KEY=real_loaded"
fi
echo "--- writer line for this pid ---"
sudo journalctl -u k3rn-proxy.service --no-pager | grep -a "mitmdump\[$P\]" | grep -a "writer started" | tail -1
echo "--- addon revision for this pid ---"
sudo journalctl -u k3rn-proxy.service --no-pager | grep -a "mitmdump\[$P\]" | grep -ao "rev [0-9-]*" | tail -1
echo "--- OFF line for this pid (should be empty) ---"
sudo journalctl -u k3rn-proxy.service --no-pager | grep -a "mitmdump\[$P\]" | grep -a "capture is OFF" | tail -1
echo "END"
