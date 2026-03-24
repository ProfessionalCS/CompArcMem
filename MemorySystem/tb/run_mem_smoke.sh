#!/bin/bash
cd /root/deploy
echo "========================================="
echo "=== MEM_TEST SMOKE ==="
echo "========================================="
./mem_test smoke 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
echo ""
echo "mem_test_smoke_exit=$?"
echo "========================================="
