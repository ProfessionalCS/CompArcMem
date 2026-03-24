#!/bin/bash
echo "=== FPGA State ==="
cat /sys/class/fpga_manager/fpga0/state
echo "=== Bridge States ==="
for b in /sys/class/fpga_bridge/*/; do
    name=$(cat ${b}name 2>/dev/null || basename $b)
    state=$(cat ${b}state 2>/dev/null || echo "unknown")
    echo "$name: $state"
done
echo "=== Service Status ==="
cat /root/deploy/bridge_boot.log 2>/dev/null || echo "no boot log"
echo "=== Binaries ==="
ls /root/deploy/ddr3_test /root/deploy/manual_test /root/deploy/fix_bridges 2>&1
echo "VERIFY_DONE"
