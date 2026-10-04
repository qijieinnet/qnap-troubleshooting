#!/bin/sh
# Watch REAL disk I/O (reads AND writes) on the HDDs every 5 seconds.
# Whenever an HDD is touched, print which md arrays were involved and the
# processes with the largest storage I/O in that interval.
#
# fatrace sees file accesses, but many reads are served from page cache and
# never reach the disk. /proc/diskstats only counts requests that really hit
# the disk, so this is the better tool for "is the HDD actually working?".
# (The QNAP kernel has no block tracepoints, so per-request attribution is
# not possible; the process list is a "who was busy at that moment" hint.)
#
# Run inside the helper container (needs --pid=host):
#   sh watch-hdd-io.sh 2400 > io.log
DURATION=${1:-2400}
DEVS=${DEVS:-"sda sdb md9 md13 md1 md3 md256 md322"}   # HDDs + arrays on them

snap_d(){ awk -v L="$DEVS" 'BEGIN{n=split(L,a," ");for(i=1;i<=n;i++)w[a[i]]=1} ($3 in w){print $3,$4,$8}' /proc/diskstats; }
snap_p(){ for f in /proc/[0-9]*/io; do p=${f#/proc/}; p=${p%/io}; awk -v p=$p '/^read_bytes/{r=$2}/^write_bytes/{w=$2}END{print p,r,w}' $f 2>/dev/null; done; }

snap_d > /tmp/d0; snap_p > /tmp/p0
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  sleep 5
  snap_d > /tmp/d1; snap_p > /tmp/p1
  out=$(awk 'NR==FNR{r[$1]=$2;w[$1]=$3;next}{dr=$2-r[$1];dw=$3-w[$1]; if(dr||dw) printf "%s r+%d w+%d  ",$1,dr,dw}' /tmp/d0 /tmp/d1)
  case "$out" in *sd*)
    echo "IO $(date +%H:%M:%S) $out"
    awk 'NR==FNR{r[$1]=$2;w[$1]=$3;next}($1 in r){dr=$2-r[$1];dw=$3-w[$1]; if(dr>0||dw>0) print dr,dw,$1}' /tmp/p0 /tmp/p1 \
      | sort -rn | head -6 | while read dr dw p; do echo "   pid=$p comm=$(cat /proc/$p/comm 2>/dev/null) read=$dr write=$dw"; done;;
  esac
  mv /tmp/d1 /tmp/d0; mv /tmp/p1 /tmp/p0
done
