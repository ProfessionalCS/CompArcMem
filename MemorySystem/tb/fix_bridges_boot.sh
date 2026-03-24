#!/bin/bash
LOG=/root/deploy/bridge_boot.log
echo "$(date): fix_bridges_boot.sh starting" > "$LOG"
/root/deploy/fix_bridges >> "$LOG" 2>&1
RET=$?
echo "$(date): fix_bridges exited $RET" >> "$LOG"
exit $RET
