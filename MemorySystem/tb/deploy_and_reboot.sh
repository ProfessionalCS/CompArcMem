#!/bin/bash
set -e
cd /root/deploy

# Fix line endings on scripts
for f in fix_bridges_boot.sh; do
    if [ -f "$f" ]; then
        tr -d '\r' < "$f" > /tmp/_fix && mv /tmp/_fix "$f"
        chmod +x "$f"
    fi
done

# Compile all binaries
echo "=== Compiling ==="
gcc -O2 -o fix_bridges fix_bridges.c
gcc -O2 -o enable_bridges enable_bridges.c
gcc -O2 -o test_h2f test_h2f.c
gcc -O2 -o ddr3_test ddr3_test.c
gcc -O2 -o manual_test manual_test.c
gcc -O2 -o mem_test mem_test.c
gcc -O2 -o devmem2 devmem2.c
gcc -O2 -o devmem_verify devmem_verify.c
cp devmem2 /usr/local/bin/devmem2
echo "BUILD_OK"

# Install service
tr -d '\r' < fpga-bridges.service > /etc/systemd/system/fpga-bridges.service
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/fpga-bridges.service /etc/systemd/system/multi-user.target.wants/fpga-bridges.service
chmod +x fix_bridges_boot.sh
echo "SERVICE_INSTALLED"

# Mount FAT and install RBF + patch DTB
mkdir -p /mnt/bootfat
umount /mnt/bootfat 2>/dev/null || true
mount /dev/mmcblk0p1 /mnt/bootfat

DTB=/mnt/bootfat/socfpga_cyclone5_de0_nano_soc.dtb
if [ -f "$DTB" ] && [ ! -f "${DTB}.orig" ]; then
    cp "$DTB" "${DTB}.orig"
fi

if [ -f "$DTB" ]; then
    dtc -I dtb -O dts -o /tmp/_deploy.dts "$DTB" 2>/dev/null
    sed 's/status = "disabled"/status = "okay"/g' /tmp/_deploy.dts > /tmp/_deploy2.dts
    dtc -I dts -O dtb -o /tmp/_deploy.dtb /tmp/_deploy2.dts 2>/dev/null
    cp /tmp/_deploy.dtb "$DTB"
    echo "DTB_PATCHED"
    rm -f /tmp/_deploy.dts /tmp/_deploy2.dts /tmp/_deploy.dtb
fi

# Install RBF
cp /root/deploy/soc_system.rbf /mnt/bootfat/soc_system.rbf
sync
umount /mnt/bootfat
echo "RBF_INSTALLED"

echo "=== SETUP_COMPLETE — rebooting in 3s ==="
sleep 3
reboot
