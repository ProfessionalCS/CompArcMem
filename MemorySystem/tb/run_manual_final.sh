#!/bin/bash
cd /root/deploy
echo "=== MANUAL_TEST CLEAN TEST ==="
./manual_test clean test 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tee /tmp/manual_out.txt
echo ""
echo "EXIT=$?"
echo ""
echo "=== PASS/FAIL COUNTS ==="
PASS_COUNT=$(grep -c "PASS" /tmp/manual_out.txt 2>/dev/null || echo 0)
FAIL_COUNT=$(grep -c "FAIL" /tmp/manual_out.txt 2>/dev/null || echo 0)
TIMEOUT_COUNT=$(grep -c "TIMEOUT" /tmp/manual_out.txt 2>/dev/null || echo 0)
echo "PASS=$PASS_COUNT"
echo "FAIL=$FAIL_COUNT"
echo "TIMEOUT=$TIMEOUT_COUNT"
