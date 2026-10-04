#!/bin/sh
# QNAP autorun.sh: set APM=254 on all rotational disks at every boot.
#
# Why: with the default APM level (often 128) the drive unloads its heads after
# a few seconds of idle and reloads them on the next I/O. On a NAS that is
# touched every few minutes this means dozens of head load/unload cycles per
# hour (audible "click", plus wear: Load_Cycle_Count grows very fast).
# APM 254 = maximum performance, heads stay loaded, drive does not spin down
# by itself (QTS "HDD standby" still works independently).
#
# QTS may reset APM during startup, so we apply it twice: 2 and 10 minutes
# after boot. A log is written to /tmp/apm254.log (RAM, lost on reboot).
#
# Install: see README.md -> "Fix 1".
(
  for delay in 120 480; do
    sleep $delay
    for b in /sys/block/sd*; do
      n=${b##*/}
      # only spinning disks; SSDs report rotational=0
      [ "$(cat $b/queue/rotational 2>/dev/null)" = "1" ] || continue
      echo "$(date '+%F %T') $n: $(/sbin/hdparm -B 254 /dev/$n 2>&1 | grep -i "power management")"
    done
  done
) > /tmp/apm254.log 2>&1 &
