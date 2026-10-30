#!/usr/bin/env bash
# Test for the recordings partitions (0007-recordings-partitions.sql): day
# partitions, monthly archiving, purge, and the conversion of an existing
# unpartitioned table. Time is simulated by calling the procedures the events
# run with CURDATE() (create_partitions_at, archive_at, purge_at) with other
# dates. Uses the environment of tests/cdr under another project name.
#
#   tests/recordings/run.sh          # leaves nothing running when it ends
#   KEEP=1 tests/recordings/run.sh   # keep the containers for inspection
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
DC=(docker compose -p avr-asterisk-recordings-test -f "$PWD/../cdr/compose.yml")
Y="$(date +%Y)"
passed=0
failed=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failed=$((failed + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
section() { printf '\n== %s\n' "$1"; }

root() { "${DC[@]}" exec -T avr-asterisk-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N "$@"' sh "$@" 2>&1; }
app()  { "${DC[@]}" exec -T avr-asterisk-db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -uasterisk -N "$@"' sh "$@" 2>&1; }
is()   { [ "$1" = "$2" ]; }
days_in() { root -e "SELECT DATEDIFF(MAKEDATE($1 + 1, 1), MAKEDATE($1, 1))"; }
parts()  { root -e "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='recordings' AND table_name='$1' AND partition_name LIKE 'p$2%'"; }
rows()   { root recordings -e "SELECT COUNT(*) FROM $1 WHERE DATE_FORMAT(created_at, '%Y%m') LIKE '$2%'"; }
create_at()  { root recordings -e "CALL create_partitions_at('$1')"; }
archive_at() { root recordings -e "CALL archive_at('$1')"; }
purge_at()   { root recordings -e "CALL purge_at('$1')"; }
event()      { root -e "SELECT CONCAT(status, ' ', interval_value, ' ', interval_field, ' ', DATE_FORMAT(starts, '%m-%d %H:%i')) FROM information_schema.events WHERE event_schema='recordings' AND event_name='$1'"; }
checksum()   { root recordings -e "SELECT CONCAT(COUNT(*), ':', SUM(CRC32(CONCAT_WS('|', id, uuid, created_at, recording_size)))) FROM $1 WHERE created_at >= '$2' AND created_at < '$3'"; }
add_rec() {  # uuid created_at
    app recordings -e "INSERT INTO recordings (uuid, caller, destination, recording_path, recording_blob, recording_size, created_at)
                       VALUES ('$1', '100', '200', '/tmp/x.wav', 'audio', 5, '$2')"
}

start() {
    "${DC[@]}" up -d --build --quiet-pull >work/up.log 2>&1 || { cat work/up.log; exit 1; }
    for _ in $(seq 1 150); do
        [ "$(root -e "SELECT COUNT(*) FROM asterisk.schema_migrations WHERE version='0007-recordings-partitions.sql'" 2>/dev/null)" = 1 ] && return 0
        "${DC[@]}" logs --no-log-prefix avr-asterisk 2>&1 | grep -q "avr-db-migrate: ERROR" && break
        sleep 2
    done
    "${DC[@]}" logs --no-log-prefix avr-asterisk 2>&1 | grep "avr-db-migrate"
    return 1
}

cleanup() {
    if [ -z "${KEEP:-}" ]; then
        "${DC[@]}" down -v --remove-orphans >/dev/null 2>&1
        rm -rf work
    fi
}
trap cleanup EXIT
rm -rf work && mkdir work

section "New installation"
echo "  building the image and starting MySQL..."
check "migrations applied (0007 included)" start
check "event recordings_create_partitions: yearly, 15 December 03:00" is "$(event recordings_create_partitions)" "ENABLED 1 YEAR 12-15 03:00"
check "event recordings_archive: daily 03:00" grep -qE "^ENABLED 1 DAY [0-9]{2}-[0-9]{2} 03:00$" <<<"$(event recordings_archive)"
check "event recordings_purge: daily 03:30" grep -qE "^ENABLED 1 DAY [0-9]{2}-[0-9]{2} 03:30$" <<<"$(event recordings_purge)"
check "settings: 1 hot month, 12 months retention" is "$(root recordings -e 'SELECT CONCAT(hot_months, ",", retention_months) FROM recordings_settings')" "1,12"
B=$((Y + 1))   # months are simulated in next year, which starts empty
# On install, days before the first day of the previous month are archived.
expected_main="$(root recordings -e "SELECT DATEDIFF(MAKEDATE($Y + 1, 1), GREATEST(month_start(CURDATE(), 1), MAKEDATE($Y, 1)))")"
check "recordings has day partitions from the previous month to the end of $Y" is "$(parts recordings "$Y")" "$expected_main"
check "pmin and pmax present" is "$(root -e "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='recordings' AND table_name='recordings' AND partition_name IN ('pmin','pmax')")" 2
check "primary key (created_at, id)" is "$(root -e "SELECT GROUP_CONCAT(column_name ORDER BY seq_in_index) FROM information_schema.statistics WHERE table_schema='recordings' AND table_name='recordings' AND index_name='PRIMARY'")" "created_at,id"
check "unique key (uuid, created_at)" is "$(root -e "SELECT CONCAT(MIN(non_unique), ':', GROUP_CONCAT(column_name ORDER BY seq_in_index)) FROM information_schema.statistics WHERE table_schema='recordings' AND table_name='recordings' AND index_name='uuid_created_at'")" "0:uuid,created_at"
check "uuid, caller, destination and status indexes end with created_at" is "$(root -e "SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema='recordings' AND table_name='recordings' AND index_name LIKE '%_created_at' AND column_name='created_at'")" 6

section "recordings_create_partitions (15 December)"
create_at "$Y-12-15" >/dev/null
check "$B created" is "$(parts recordings "$B")" "$(days_in "$B")"

section "Queries and writes"
app recordings -e "INSERT INTO recordings (uuid, caller, destination, recording_path, recording_blob, recording_size, created_at)
                   SELECT UUID(), CONCAT('10', n MOD 5), '200', '/tmp/x.wav', 'audio', 5, TIMESTAMP(MAKEDATE($B, 1) + INTERVAL n DAY, '10:00:00')
                     FROM (WITH RECURSIVE s (n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM s WHERE n < $(( $(days_in "$B") - 1 ))) SELECT n FROM s) days" >/dev/null
check "app user inserted one recording per day of $B" is "$(rows recordings "$B")" "$(days_in "$B")"
check "one day reads one day partition (plus the always-empty pmin)" is "$(root recordings -e "EXPLAIN SELECT * FROM recordings WHERE created_at >= '$B-10-15' AND created_at < '$B-10-16'" | cut -f4 | tr ',' '\n' | grep -v '^pmin$' | tr '\n' ' ')" "p${B}1015 "
check "pending transcriptions of a month use the status index" grep -q "transcription_status_created_at" <(root recordings -e "EXPLAIN SELECT id FROM recordings WHERE transcription_status='pending' AND created_at >= '$B-10-01' AND created_at < '$B-11-01'")
upsert() { app recordings -e "INSERT INTO recordings (uuid, caller, recording_path, recording_blob, recording_size, created_at)
                              VALUES ('same-call', '$1', '/tmp/x.wav', 'audio', 5, '$B-10-15 10:00:00')
                              ON DUPLICATE KEY UPDATE caller = VALUES(caller)"; }
upsert first >/dev/null; upsert retry >/dev/null
check "same call saved twice (same uuid and created_at) updates, no duplicate" is "$(root recordings -e "SELECT CONCAT(COUNT(*), ':', MAX(caller)) FROM recordings WHERE uuid='same-call'")" "1:retry"
app recordings -e "DELETE FROM recordings WHERE uuid='same-call'" >/dev/null

section "recordings_archive: monthly (current and previous month stay)"
before="$(checksum recordings "$B-01-01" "$B-05-01")"
archive_at "$B-06-15" >/dev/null
check "15 June: no January-April recordings left" is "$(root recordings -e "SELECT COUNT(*) FROM recordings WHERE created_at < '$B-05-01'")" 0
check "15 June: no partitions before May left in recordings" is "$(root -e "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='recordings' AND table_name='recordings' AND partition_name REGEXP '^p[0-9]{8}$' AND partition_name < 'p${B}0501'")" 0
check "15 June: May and June stay in recordings" is "$(rows recordings "${B}05"):$(rows recordings "${B}06")" "31:30"
check "archived recordings identical (count and checksum)" is "$(checksum recordings_archives "$B-01-01" "$B-05-01")" "$before"
check "recordings_swap left empty" is "$(root recordings -e 'SELECT COUNT(*) FROM recordings_swap')" 0
archive_at "$B-06-30" >/dev/null
check "rest of June changes nothing" is "$(rows recordings "${B}05")" 31
add_rec late-march "$B-03-20 10:00:00" >/dev/null
check "a late recording of an archived month still inserts" is "$(rows recordings "${B}03")" 1
archive_at "$B-07-01" >/dev/null
check "1 July: May archived" is "$(rows recordings "${B}05"):$(rows recordings_archives "${B}05")" "0:31"
check "the late recording reached its day in the archive (p${B}0320)" is "$(root recordings -e "SELECT COUNT(*) FROM recordings_archives PARTITION (p${B}0320)"):$(rows recordings "${B}03")" "2:0"

section "Year change (days already archived are not recreated)"
create_at "$B-12-15" >/dev/null
check "15 December: $((B + 1)) created although January-May $B are gone" is "$(parts recordings $((B + 1)))" "$(days_in $((B + 1)))"
check "archived days not recreated in recordings" is "$(root -e "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='recordings' AND table_name='recordings' AND partition_name REGEXP '^p[0-9]{8}$' AND partition_name < 'p${B}0601'")" 0
archive_at "$((B + 1))-01-02" >/dev/null
check "2 January: everything before December archived" is "$(root -e "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='recordings' AND table_name='recordings' AND partition_name REGEXP '^p[0-9]{8}$' AND partition_name < 'p${B}1201'")" 0
check "2 January: December stays (previous month)" is "$(rows recordings "${B}12")" 31

section "recordings_purge drops whole partitions beyond retention_months"
purge_at "$((B + 1))-01-02" >/dev/null
check "within 12 months (from January $B): $B kept" is "$(rows recordings_archives "${B}01")" 31
purge_at "$((B + 1))-04-01" >/dev/null
check "1 April $((B + 1)): January-March $B partitions dropped, rows with them" is "$(root -e "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='recordings' AND table_name='recordings_archives' AND partition_name REGEXP '^p[0-9]{8}$' AND partition_name < 'p${B}0401'"):$(root recordings -e "SELECT COUNT(*) FROM recordings_archives WHERE created_at < '$B-04-01'")" "0:0"
check "April $B onwards kept" is "$(rows recordings_archives "${B}04")" 30

section "Settings: hot_months=0 archives the previous month too"
root recordings -e "UPDATE recordings_settings SET hot_months = 0" >/dev/null
archive_at "$((B + 1))-04-02" >/dev/null
check "December archived" is "$(rows recordings "${B}12"):$(rows recordings_archives "${B}12")" "0:31"

section "Existing database with an unpartitioned recordings table (like staging)"
"${DC[@]}" down -v >/dev/null 2>&1
mkdir -p work/init
now_month="$(date +%Y-%m)-01"
# From the 1st of the month, so day 31 never overflows (BSD date, then GNU date).
months_ago() { date -j -v-"$1"m -f %Y-%m-%d "$now_month" +%Y-%m-01 2>/dev/null || date -d "$now_month -$1 month" +%Y-%m-01; }
prev_month="$(months_ago 1)"
old_month="$(months_ago 3)"
very_old="$(months_ago 14)"
{
    echo "CREATE TABLE asterisk.schema_migrations (version VARCHAR(255) NOT NULL PRIMARY KEY, applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP);"
    for v in 0001-asterisk 0002-cdr 0003-recordings 0004-provision 0005-provision-strong-passwords 0006-cdr-partitions; do
        echo "INSERT INTO asterisk.schema_migrations (version) VALUES ('$v.sql');"
    done
    sed -e 's/{{recordings_db}}/recordings/g' -e "s/{{app_user}}/asterisk/g" ../../db/migrations/0003-recordings.sql
    for r in "cur:$now_month" "prev:$prev_month" "old:$old_month" "veryold:$very_old"; do
        echo "INSERT INTO recordings.recordings (uuid, recording_path, recording_blob, recording_size, created_at) VALUES ('${r%%:*}', '/tmp/x.wav', 'audio', 5, '${r#*:} 10:00:00');"
    done
} > work/init/01-old.sql
INIT_DIR="$PWD/work/init" start >/dev/null 2>&1
check "0007 applied on the existing database" is "$(root -e "SELECT COUNT(*) FROM asterisk.schema_migrations WHERE version='0007-recordings-partitions.sql'")" 1
check "no unpartitioned table left" is "$(root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='recordings' AND table_name='recordings_unpartitioned'")" 0
check "current and previous month stay in recordings" is "$(root recordings -e "SELECT GROUP_CONCAT(uuid ORDER BY created_at) FROM recordings")" "prev,cur"
check "3 months old: archived" is "$(root recordings -e "SELECT GROUP_CONCAT(uuid) FROM recordings_archives")" "old"
check "14 months old: purged by the retention period" is "$(root recordings -e "SELECT COUNT(*) FROM recordings_archives WHERE uuid='veryold'")" 0

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
