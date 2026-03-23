#!/bin/bash
sshpass -p root ssh -o StrictHostKeyChecking=no root@192.168.0.2 << 'EOF'
echo "=== /proc/iomem ==="
cat /proc/iomem
echo ""
echo "=== meminfo ==="
cat /proc/meminfo | head -5
echo ""
echo "=== cmdline ==="
cat /proc/cmdline
echo ""
echo "=== devmem2 test ==="
cd /root/deploy && ./devmem2 0x38001000 w
echo ""
echo "=== devmem2 low addr ==="
cd /root/deploy && ./devmem2 0x20000000 w
EOF
