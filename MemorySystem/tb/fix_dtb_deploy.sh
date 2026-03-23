#!/bin/bash
# fix_dtb_deploy.sh — Fix DTB + install RBF on DE10-Nano boot partition
# Run ON the board as root.
set -e

echo "=== DTB + RBF Recovery ==="

# Mount boot partition
mkdir -p /mnt/bootfat
umount /mnt/bootfat 2>/dev/null || true
mount /dev/mmcblk0p1 /mnt/bootfat
echo "[1] Boot partition mounted"

# Backup original DTB
DTB=/mnt/bootfat/socfpga_cyclone5_de0_nano_soc.dtb
cp "$DTB" "${DTB}.bak"
echo "[2] DTB backed up"

# Decompile
dtc -I dtb -O dts -o /root/current.dts "$DTB" 2>/dev/null
echo "[3] DTB decompiled"

# Enable all disabled nodes
sed -i 's/status = "disabled"/status = "okay"/g' /root/current.dts
echo "[4] All disabled -> okay"

# Add bridge-enable = <1> to all bridge nodes
awk '
/fpga-bridge@ff400000|fpga-bridge@ff500000|fpga-bridge@ff600000|fpga2sdram/ {
    in_bridge=1
}
{
    print
    if (in_bridge && /status = "okay"/) {
        print "\t\t\tbridge-enable = <1>;"
        in_bridge=0
    }
}
' /root/current.dts > /root/modified.dts
echo "[5] bridge-enable added to all 4 bridges"

# Recompile
dtc -I dts -O dtb -o /root/new.dtb /root/modified.dts 2>/dev/null
echo "[6] New DTB compiled"

# Install
cp /root/new.dtb "$DTB"
echo "[7] New DTB installed"

# Install RBF if available
if [ -f /root/deploy/soc_system.rbf ]; then
    cp /root/deploy/soc_system.rbf /mnt/bootfat/soc_system.rbf
    echo "[8] RBF installed to boot partition"
else
    echo "[8] No RBF in /root/deploy — skipping"
fi

# Sync and unmount
sync
umount /mnt/bootfat
echo "[9] Boot partition synced and unmounted"

# Cleanup
rm -f /root/current.dts /root/modified.dts /root/new.dtb

echo "=== DTB fix complete. Reboot to apply. ==="
