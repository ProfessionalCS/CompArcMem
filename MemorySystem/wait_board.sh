#!/bin/bash
sshpass -p root ssh -o StrictHostKeyChecking=no root@192.168.0.2 "sync; reboot" 2>/dev/null || true
echo "Reboot sent. Waiting 35s..."
sleep 35
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    ping -c 1 -W 2 192.168.0.2 > /dev/null 2>&1 && echo "Board is back after ~$((35 + i*5))s" && exit 0
    echo "  Still waiting... ($i)"
    sleep 5
done
echo "TIMEOUT: board did not come back"
exit 1
