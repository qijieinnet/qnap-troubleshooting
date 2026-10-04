#!/bin/sh
# Show APM level and head-parking statistics for every spinning disk.
#
# Run inside the helper container (see tools/README.md):
#   apk add -q hdparm smartmontools
#   sh check-disks.sh
#
# Run it twice, e.g. 10-30 minutes apart, and compare Load_Cycle_Count.
# Seagate IronWolf / many NAS drives are rated for ~600,000 load cycles.
for b in /sys/block/sd*; do
  n=${b##*/}
  [ "$(cat $b/queue/rotational 2>/dev/null)" = "1" ] || continue
  A=$(smartctl -d sat -A /dev/$n 2>/dev/null)
  M=$(smartctl -d sat -i /dev/$n 2>/dev/null | awk -F: '/Device Model/{gsub(/^ +/,"",$2);print $2}')
  APM=$(hdparm -B /dev/$n 2>/dev/null | awk '/APM_level/{print $3}')
  LCC=$(echo "$A" | awk '/Load_Cycle_Count/{print $10}')
  POH=$(echo "$A" | awk '/Power_On_Hours/{print $10}')
  SSC=$(echo "$A" | awk '/Start_Stop_Count/{print $10}')
  echo "$(date '+%F %T') $n model=$M APM=$APM Load_Cycle_Count=$LCC Start_Stop_Count=$SSC Power_On_Hours=$POH"
done
