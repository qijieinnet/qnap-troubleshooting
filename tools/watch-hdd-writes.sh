#!/bin/sh
# Record WHICH PROCESS writes WHICH FILE on HDD-backed filesystems,
# plus the real write counters of the HDDs once per minute.
#
# Run inside the helper container started with `-v /:/host:ro` (see tools/README.md):
#   sh watch-hdd-writes.sh 2400 > writes.log     # 2400 s = 40 min
#
# Close the QTS web UI while measuring: the admin pages poll CGIs that write
# to the system partition every few seconds and will pollute the result.
#
# Adjust HDD_FS to your layout. /mnt/HDA_ROOT and /mnt/ext are QNAP system
# partitions which are mirrored onto EVERY internal disk (incl. HDDs).
# Add your HDD data volumes, e.g. /share/CACHEDEV1_DATA.
DURATION=${1:-2400}
HDD_FS=${HDD_FS:-"/host/mnt/HDA_ROOT|/host/mnt/ext|/host/share/CACHEDEV1_DATA|/host/share/CACHEDEV2_DATA"}
DISKS=${DISKS:-"sda sdb"}

echo https://dl-cdn.alpinelinux.org/alpine/edge/testing >> /etc/apk/repositories
apk add -q fatrace >/dev/null 2>&1 || { echo "cannot install fatrace"; exit 1; }

# per-minute HDD write counters (field 8 of /proc/diskstats = writes completed)
(
  end=$(( $(date +%s) + DURATION ))
  while [ "$(date +%s)" -lt "$end" ]; do
    line="DISK $(date +%H:%M:%S)"
    for d in $DISKS; do
      line="$line $d:w=$(awk -v d=$d '$3==d{print $8}' /proc/diskstats)"
    done
    echo "$line"
    sleep 60
  done
) &

# -f W = only write events; fatrace prints "time comm(pid): EVENT path"
timeout "$DURATION" fatrace -t -f W 2>&1 | grep -E "($HDD_FS)"
wait
