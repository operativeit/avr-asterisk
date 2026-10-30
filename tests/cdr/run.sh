#!/usr/bin/env bash
# Test for the CDR partitions (0006-cdr-partitions.sql): day partitions,
# next-year creation, yearly archiving, purge, pmax and the conversion of an
# existing unpartitioned table. Time is simulated by calling the procedures
# the events run with CURDATE() (create_partitions_at, archive_at, purge_at)
# with other dates.
#
#   tests/cdr/run.sh          # leaves nothing running when it ends
#   KEEP=1 tests/cdr/run.sh   # keep the containers for inspection
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
DC=(docker compose -f "$PWD/compose.yml")
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
parts() { root -e "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='cdr' AND table_name='$1' AND partition_name LIKE 'p$2%'"; }
rows()  { root cdr -e "SELECT COUNT(*) FROM $1 WHERE YEAR(calldate) = $2"; }
create_at()  { root cdr -e "CALL create_partitions_at('$1')"; }
archive_at() { root cdr -e "CALL archive_at('$1')"; }
purge_at()   { root cdr -e "CALL purge_at('$1')"; }
event()      { root -e "SELECT CONCAT(status, ' ', interval_value, ' ', interval_field, ' ', DATE_FORMAT(starts, '%m-%d %H:%i')) FROM information_schema.events WHERE event_schema='cdr' AND event_name='$1'"; }

start() {
    "${DC[@]}" up -d --build --quiet-pull >work/up.log 2>&1 || { cat work/up.log; exit 1; }
    for _ in $(seq 1 90); do
        "${DC[@]}" logs --no-log-prefix avr-asterisk 2>&1 | grep -qE "avr-db-migrate: (applying 0006|schema is up to date)" &&
            [ "$(root -e "SELECT COUNT(*) FROM asterisk.schema_migrations WHERE version='0006-cdr-partitions.sql'")" = 1 ] && return 0
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
check "migrations applied (0006 included)" start
check "event scheduler is ON" is "$(root -e 'SELECT @@event_scheduler')" ON
check "event cdr_create_partitions: yearly, 15 December 03:00" is "$(event cdr_create_partitions)" "ENABLED 1 YEAR 12-15 03:00"
check "event cdr_archive: daily 03:00" grep -qE "^ENABLED 1 DAY [0-9]{2}-[0-9]{2} 03:00$" <<<"$(event cdr_archive)"
check "event cdr_purge: daily 03:30" grep -qE "^ENABLED 1 DAY [0-9]{2}-[0-9]{2} 03:30$" <<<"$(event cdr_purge)"
expected=$(days_in "$Y")
[ "$(date +%m%d)" -ge 1215 ] && expected_next=$(days_in $((Y + 1))) || expected_next=0
check "cdr has one partition per day of $Y" is "$(parts cdr "$Y")" "$expected"
check "cdr next year only from 15 December" is "$(parts cdr $((Y + 1)))" "$expected_next"
check "cdr and cdr_archives have pmax" is "$(root -e "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='cdr' AND partition_name='pmax' AND table_name IN ('cdr','cdr_archives')")" 2
check "cdr_archives starts with pmin and pmax only" is "$(root -e "SELECT GROUP_CONCAT(partition_name ORDER BY partition_ordinal_position) FROM information_schema.partitions WHERE table_schema='cdr' AND table_name='cdr_archives'")" "pmin,pmax"
check "primary key (calldate, id)" is "$(root -e "SELECT GROUP_CONCAT(column_name ORDER BY seq_in_index) FROM information_schema.statistics WHERE table_schema='cdr' AND table_name='cdr' AND index_name='PRIMARY'")" "calldate,id"
check "indexes src/dst/accountcode with calldate, uniqueid, id" is "$(root -e "SELECT GROUP_CONCAT(DISTINCT index_name ORDER BY index_name) FROM information_schema.statistics WHERE table_schema='cdr' AND table_name='cdr' AND index_name <> 'PRIMARY'")" "accountcode_calldate,dst_calldate,id,src_calldate,uniqueid"
check "cdr_settings default retention: 4 years" is "$(root cdr -e 'SELECT retention_years FROM cdr_settings')" 4

section "Queries read only the partitions they need"
app cdr -e "INSERT INTO cdr (calldate, src, dst, uniqueid, accountcode, disposition, duration, billsec)
            SELECT TIMESTAMP(MAKEDATE($Y, 1) + INTERVAL n DAY, '10:00:00'), CONCAT('10', n MOD 5), CONCAT('3496800', n MOD 50),
                   CONCAT('$Y.', n), CONCAT('acct', n MOD 3), 'ANSWERED', 60, 50
              FROM (WITH RECURSIVE s (n) AS (SELECT 0 UNION ALL SELECT n + 1 FROM s WHERE n < $((expected - 1))) SELECT n FROM s) days" >/dev/null
check "app user inserted one CDR per day of $Y" is "$(rows cdr "$Y")" "$expected"
plan_day="$(root cdr -e "EXPLAIN SELECT * FROM cdr WHERE calldate >= '$Y-10-15' AND calldate < '$Y-10-16'" | cut -f4)"
check "one day reads one partition (p${Y}1015)" is "$plan_day" "p${Y}1015"
plan_month="$(root cdr -e "EXPLAIN SELECT COUNT(*) FROM cdr WHERE calldate >= '$Y-10-01' AND calldate < '$Y-11-01'" | cut -f4 | tr ',' '\n')"
check "one month reads October's 31 days (plus the always-empty pmin)" is "$(grep -cE '^p[0-9]{8}$' <<<"$plan_month"):$(grep -cE "^p${Y}10[0-9]{2}$" <<<"$plan_month"):$(grep -vE '^p[0-9]{8}$' <<<"$plan_month")" "31:31:pmin"
check "pmin is empty" is "$(root cdr -e 'SELECT COUNT(*) FROM cdr PARTITION (pmin)')" 0
check "number + day uses src_calldate" grep -q "src_calldate" <(root cdr -e "EXPLAIN SELECT * FROM cdr WHERE src='101' AND calldate >= '$Y-10-15' AND calldate < '$Y-10-16'")
check "account + month uses accountcode_calldate" grep -q "accountcode_calldate" <(root cdr -e "EXPLAIN SELECT SUM(billsec) FROM cdr WHERE accountcode='acct1' AND calldate >= '$Y-10-01' AND calldate < '$Y-11-01'")

section "cdr_create_partitions (15 December)"
create_at "$Y-12-15" >/dev/null
check "next year $((Y + 1)) created" is "$(parts cdr $((Y + 1)))" "$(days_in $((Y + 1)))"
check "$Y untouched" is "$(parts cdr "$Y")" "$expected"
create_at "$Y-12-15" >/dev/null
check "running it again changes nothing" is "$(parts cdr $((Y + 1)))" "$(days_in $((Y + 1)))"

section "cdr_archive (daily 03:00; never the current year)"
app cdr -e "INSERT INTO cdr (calldate, src, dst, uniqueid) VALUES ('$Y-12-31 23:59:00', '100', '200', 'late.1'), ('$((Y + 1))-01-02 09:00:00', '100', '200', 'next.1'), ('$((Y + 1))-01-05 09:00:00', '100', '200', 'next.2')" >/dev/null
sum_before="$(root cdr -e "SELECT CONCAT(COUNT(*), ':', SUM(CRC32(CONCAT_WS('|', id, calldate, src, dst, uniqueid)))) FROM cdr WHERE YEAR(calldate) = $Y")"
archive_at "$Y-12-31" >/dev/null
check "31 December: nothing archived (yesterday is the current year)" is "$(parts cdr "$Y"):$(parts cdr_archives "$Y")" "$expected:0"
archive_at "$((Y + 1))-01-01" >/dev/null
check "1 January: $Y gone from cdr" is "$(parts cdr "$Y")" 0
check "1 January: $Y day partitions in cdr_archives" is "$(parts cdr_archives "$Y")" "$expected"
check "every $Y CDR archived, identical (count and checksum)" is "$(root cdr -e "SELECT CONCAT(COUNT(*), ':', SUM(CRC32(CONCAT_WS('|', id, calldate, src, dst, uniqueid)))) FROM cdr_archives WHERE YEAR(calldate) = $Y")" "$sum_before"
check "each CDR in its day partition (31 December holds 2)" is "$(root cdr -e "SELECT COUNT(*) FROM cdr_archives PARTITION (p${Y}1231)")" 2
check "$((Y + 1)) CDRs still in cdr" is "$(rows cdr $((Y + 1)))" 2
check "cdr_swap left empty" is "$(root cdr -e 'SELECT COUNT(*) FROM cdr_swap')" 0
archive_at "$((Y + 1))-01-02" >/dev/null
check "next days change nothing" is "$(rows cdr_archives "$Y"):$(rows cdr $((Y + 1)))" "$((expected + 1)):2"
app cdr -e "INSERT INTO cdr (calldate, src, dst, uniqueid) VALUES ('$Y-12-30 10:00:00', '100', '200', 'very.late')" >/dev/null
check "a CDR of the archived year arriving after 03:00 still inserts" is "$(rows cdr "$Y")" 1
create_at "$((Y + 1))-12-15" >/dev/null
archive_at "$((Y + 2))-01-01" >/dev/null
check "next year it reaches its day in cdr_archives (p${Y}1230)" is "$(root cdr -e "SELECT COUNT(*) FROM cdr_archives PARTITION (p${Y}1230)"):$(rows cdr "$Y")" "2:0"
check "and $((Y + 1)) archived too" is "$(rows cdr_archives $((Y + 1))):$(parts cdr $((Y + 1)))" "2:0"

section "cdr_purge drops whole partitions beyond retention_years"
check "cdr_archives holds $Y and $((Y + 1)) before the purge" is "$(root -e "SELECT GROUP_CONCAT(DISTINCT SUBSTRING(partition_name, 2, 4) ORDER BY 1) FROM information_schema.partitions WHERE table_schema='cdr' AND table_name='cdr_archives' AND partition_name REGEXP '^p[0-9]{8}$'")" "$Y,$((Y + 1))"
purge_at "$((Y + 4))-06-01" >/dev/null
check "within retention (4 years before $((Y + 4))): nothing dropped" is "$(parts cdr_archives "$Y")" "$expected"
purge_at "$((Y + 5))-01-01" >/dev/null
check "$Y partitions dropped, rows with them" is "$(parts cdr_archives "$Y"):$(rows cdr_archives "$Y")" "0:0"
check "$((Y + 1)) kept with its CDRs" is "$(parts cdr_archives $((Y + 1))):$(rows cdr_archives $((Y + 1)))" "$(days_in $((Y + 1))):2"
check "cdr untouched by the purge" is "$(parts cdr $((Y + 2)))" "$(days_in $((Y + 2)))"
root cdr -e "UPDATE cdr_settings SET retention_years = 1" >/dev/null
purge_at "$((Y + 5))-01-02" >/dev/null
check "retention_years=1: $((Y + 1)) dropped too" is "$(root -e "SELECT COUNT(*) FROM information_schema.partitions WHERE table_schema='cdr' AND table_name='cdr_archives' AND partition_name REGEXP '^p[0-9]{8}$'")" 0
check "cdr_archives keeps pmin and pmax" is "$(root -e "SELECT GROUP_CONCAT(partition_name ORDER BY partition_ordinal_position) FROM information_schema.partitions WHERE table_schema='cdr' AND table_name='cdr_archives'")" "pmin,pmax"

section "pmax keeps CDRs without a partition"
app cdr -e "INSERT INTO cdr (calldate, src, dst, uniqueid) VALUES ('$((Y + 3))-06-01 12:00:00', '100', '200', 'future.1')" >/dev/null
check "CDR beyond the partitions lands in pmax" is "$(root cdr -e 'SELECT COUNT(*) FROM cdr PARTITION (pmax)')" 1
create_at "$((Y + 2))-12-15" >/dev/null
check "creating its year moves it to p$((Y + 3))0601" is "$(root cdr -e "SELECT COUNT(*) FROM cdr PARTITION (p$((Y + 3))0601)"):$(root cdr -e 'SELECT COUNT(*) FROM cdr PARTITION (pmax)')" "1:0"

section "Existing database with an unpartitioned cdr table (like staging)"
"${DC[@]}" down -v >/dev/null 2>&1
mkdir -p work/init
{
    echo "CREATE TABLE asterisk.schema_migrations (version VARCHAR(255) NOT NULL PRIMARY KEY, applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP);"
    for v in 0001-asterisk 0002-cdr 0003-recordings 0004-provision 0005-provision-strong-passwords; do
        echo "INSERT INTO asterisk.schema_migrations (version) VALUES ('$v.sql');"
    done
    sed -e 's/{{cdr_db}}/cdr/g' -e "s/{{app_user}}/asterisk/g" ../../db/migrations/0002-cdr.sql
    echo "INSERT INTO cdr.cdr (calldate, src, dst, uniqueid) VALUES ('$((Y - 1))-03-10 10:00:00', '100', '200', 'old.1'), ('$((Y - 1))-12-31 23:00:00', '100', '200', 'old.2'), ('$Y-02-01 10:00:00', '100', '200', 'cur.1');"
} > work/init/01-old.sql
INIT_DIR="$PWD/work/init" start >/dev/null 2>&1
check "0006 applied on the existing database" is "$(root -e "SELECT COUNT(*) FROM asterisk.schema_migrations WHERE version='0006-cdr-partitions.sql'")" 1
check "no unpartitioned table left" is "$(root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='cdr' AND table_name='cdr_unpartitioned'")" 0
check "current-year CDR kept in cdr" is "$(rows cdr "$Y")" 1
check "last year's CDRs archived right away" is "$(rows cdr_archives $((Y - 1)))" 2
check "ids preserved" is "$(root cdr -e "SELECT GROUP_CONCAT(uniqueid ORDER BY id) FROM (SELECT id, uniqueid FROM cdr UNION ALL SELECT id, uniqueid FROM cdr_archives) a")" "old.1,old.2,cur.1"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
