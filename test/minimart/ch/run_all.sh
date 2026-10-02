#!/usr/bin/env bash
# Runs every test of the minimart ClickHouse mirror against the ClickHouse binary in $MM_CH_BIN
# (default `clickhouse`; use the official 24.8 build to test the production version):
#
#   bash test/minimart/ch/run_all.sh
#   MM_CH_BIN=/path/to/clickhouse-24.8.14.39 bash test/minimart/ch/run_all.sh
#
# Needs a local Postgres (socket /tmp, current user superuser) and ClickHouse; no Docker (the scripts run
# unmodified through the shims in test/minimart/ch/shim). Each test uses its own Postgres database
# (mmc_<name>), its own scratch ClickHouse server and its own ports, so they could run in parallel.
cd "$(dirname "$0")/../../.." || exit 1
export PGHOST=${PGHOST:-/tmp}
rc=0
for t in run_grants_test run_rule_test run_sync_test run_drift_test; do
  f=test/minimart/ch/$t.sh
  [ -f "$f" ] || { echo "== $t: missing"; rc=1; continue; }
  echo "== $t"
  out=$(bash "$f" 2>&1); r=$?
  echo "$out" | grep -E "FAIL|RESULT|== result" | head -30
  [ $r -eq 0 ] || { echo "   -> $t exited $r"; rc=1; }
done
[ $rc -eq 0 ] && echo "ALL OK" || echo "SOME TESTS FAILED"
exit $rc
