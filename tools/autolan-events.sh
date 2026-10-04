#!/bin/sh
# Count QuFirewall "auto-LAN discovery rule" updates in the QTS system event log.
#
# Each update rewrites QuFirewall.conf, regenerates sshd_config, writes the
# event log and the Notification Center DB -- all on the system partition,
# which is mirrored to every HDD. Dozens of updates per day = the HDDs are
# written every few minutes.
#
# Run inside the helper container started with `-v /:/host:ro`:
#   apk add -q sqlite && sh autolan-events.sh
cp /host/mnt/HDA_ROOT/.logs/event.log /tmp/event.db   # work on a copy

echo "== auto-LAN updates per day (last 10 days)"
sqlite3 /tmp/event.db "SELECT event_date, count(*) FROM NASLOG_EVENT
  WHERE event_desc LIKE '%auto-LAN discovery%' GROUP BY event_date ORDER BY event_date DESC LIMIT 10;"

echo "== latest 10 updates (look at the IPv6 'Source' list: a single /128 address"
echo "   that keeps appearing and disappearing is a route-cache entry, see posts/2026-10-03-hdd-noise-and-standby)"
sqlite3 /tmp/event.db "SELECT event_date||' '||event_time, substr(event_desc, 1, 220) FROM NASLOG_EVENT
  WHERE event_desc LIKE '%auto-LAN discovery%' ORDER BY event_id DESC LIMIT 10;"
