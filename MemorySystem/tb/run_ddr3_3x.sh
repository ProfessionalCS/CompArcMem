#!/bin/bash
cd /root/deploy
echo "========================================="
echo "=== DDR3 TEST RUN 1 of 3 ==="
echo "========================================="
./ddr3_test 2>&1
RET1=$?
echo "ddr3_test run 1 exit code: $RET1"
echo ""

echo "========================================="
echo "=== DDR3 TEST RUN 2 of 3 ==="
echo "========================================="
./ddr3_test 2>&1
RET2=$?
echo "ddr3_test run 2 exit code: $RET2"
echo ""

echo "========================================="
echo "=== DDR3 TEST RUN 3 of 3 ==="
echo "========================================="
./ddr3_test 2>&1
RET3=$?
echo "ddr3_test run 3 exit code: $RET3"
echo ""

echo "========================================="
echo "=== SUMMARY ==="
echo "Run 1: exit=$RET1"
echo "Run 2: exit=$RET2"
echo "Run 3: exit=$RET3"
if [ $RET1 -eq 0 ] && [ $RET2 -eq 0 ] && [ $RET3 -eq 0 ]; then
    echo "ALL 3 DDR3 TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
echo "========================================="
