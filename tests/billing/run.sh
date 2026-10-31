#!/usr/bin/env bash
# Test for CDR tagging and rating (0009-cdr-billing, 0010-provision-tenant,
# 0011-billing, cdr_adaptive_odbc and bin/avr-rate): real calls between a
# carrier, our Asterisk and a phone, then avr-rate on the CDRs they leave.
#
#   tests/billing/run.sh          # leaves nothing running when it ends
#   KEEP=1 tests/billing/run.sh   # keep the containers for inspection
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
DC=(docker compose -f "$PWD/compose.yml")
passed=0
failed=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failed=$((failed + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
section() { printf '\n== %s\n' "$1"; }
is() { [ "$1" = "$2" ]; }

sql()  { "${DC[@]}" exec -T avr-asterisk-db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -uasterisk -N "$@"' sh "$@" 2>&1; }
ast()  { "${DC[@]}" exec -T "${2:-avr-asterisk}" asterisk -rx "$1" 2>&1; }
rate() { "${DC[@]}" exec -T avr-asterisk avr-rate "$@" 2>&1; }
wait_for() { local desc="$1"; shift; for _ in $(seq 1 30); do if "$@" >/dev/null 2>&1; then ok "$desc"; return; fi; sleep 1; done; fail "$desc"; }

T1=11111111-1111-1111-1111-111111111111
T2=22222222-2222-2222-2222-222222222222
T3=33333333-3333-3333-3333-333333333333
A1=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
A2=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

# One CDR field of the tagged leg(s) matching a WHERE clause.
cdr() { sql cdr -e "SELECT $1 FROM cdr WHERE direction IS NOT NULL AND $2 ORDER BY calldate, id"; }

cleanup() {
    if [ -z "${KEEP:-}" ]; then
        "${DC[@]}" down -v --remove-orphans >/dev/null 2>&1
        rm -rf work
    fi
}
trap cleanup EXIT
rm -rf work && mkdir work

section "Environment"
echo "  building the image and starting the environment..."
"${DC[@]}" up -d --build --quiet-pull >work/up.log 2>&1 || { cat work/up.log; echo "docker compose up failed"; exit 1; }
ready() { ast "odbc show cdr" | grep -q "active connections: 1"; }
wait_for "Asterisk connected to the databases" ready
check "cdr_adaptive_odbc loaded, cdr_odbc gone" bash -c "docker compose -f $PWD/compose.yml exec -T avr-asterisk asterisk -rx 'module show like cdr_' | grep -q cdr_adaptive_odbc && ! docker compose -f $PWD/compose.yml exec -T avr-asterisk ls /usr/lib/asterisk/modules/cdr_odbc.so"
check "migrations 0009-0011 applied" is "$(sql asterisk -e "SELECT COUNT(*) FROM schema_migrations WHERE version IN ('0009-cdr-billing.sql', '0010-provision-tenant.sql', '0011-billing.sql')")" 3
check "cdr, cdr_archives and cdr_swap have the same columns" is \
    "$(sql cdr -e "SELECT COUNT(DISTINCT cols) FROM (SELECT table_name, GROUP_CONCAT(column_name, column_type, IFNULL(column_default, '') ORDER BY ordinal_position) cols FROM information_schema.columns WHERE table_schema = 'cdr' AND table_name IN ('cdr', 'cdr_archives', 'cdr_swap') GROUP BY table_name) t")" 1

section "Provision: tenants on DDIs and accounts"
sql provision -e "INSERT INTO accounts (name, type, host, match_ips) VALUES ('carrier1', 'trunk', '172.31.252.14', '172.31.252.14');
                  INSERT INTO accounts (name, type, password, tenant_uuid) VALUES ('2001', 'local', 'Ph0ne-2001-pass', '$T1');
                  INSERT INTO accounts (name, type, agent_uuid, tenant_uuid) VALUES ('2002', 'local', '$A1', '$T1');
                  INSERT INTO ddis (ddi, account, tenant_uuid, record) VALUES ('34968000001', '2001', '$T1', 0);
                  INSERT INTO ddis (ddi, agent_uuid, tenant_uuid) VALUES ('34968000002', '$A2', '$T2');
                  INSERT INTO ddis (ddi, account, tenant_uuid, record) VALUES ('34968000004', '2001', '$T3', 0);" >/dev/null
check "tenant_uuid is validated" grep -q "tenant_uuid is not a UUID" <<<"$(sql provision -e "INSERT INTO ddis (ddi, account, tenant_uuid) VALUES ('34968000009', '2001', 'nope')")"
check "endpoint 2001 sets __TENANT_ID" is "$(sql asterisk -e "SELECT set_var FROM ps_endpoints WHERE id='2001'")" "__TENANT_ID=$T1"
check "endpoint 2002 sets __TENANT_ID and __AGENT_ID" is "$(sql asterisk -e "SELECT set_var FROM ps_endpoints WHERE id='2002'")" "__TENANT_ID=$T1;__AGENT_ID=$A1"
check "ddi to agent: tenant, agent, then Dial" is "$(sql asterisk -e "SELECT GROUP_CONCAT(priority, ':', app ORDER BY priority) FROM extensions WHERE context='incoming' AND exten='34968000002'")" "1:Set,2:Set,3:Dial"
check "ddi to account: tenant, then Dial" is "$(sql asterisk -e "SELECT GROUP_CONCAT(priority, ':', app, ':', appdata ORDER BY priority SEPARATOR '|') FROM extensions WHERE context='incoming' AND exten='34968000001'")" "1:Set:CDR(tenant_id)=$T1|2:Dial:PJSIP/2001,30"
sql provision -e "UPDATE ddis SET ring_timeout = 20 WHERE ddi = '34968000001'" >/dev/null
check "an UPDATE keeps the tags" is "$(sql asterisk -e "SELECT GROUP_CONCAT(appdata ORDER BY priority SEPARATOR '|') FROM extensions WHERE context='incoming' AND exten='34968000001'")" "CDR(tenant_id)=$T1|PJSIP/2001,20"
check "the endpoint shows the variables" grep -qE "__AGENT_ID +: $A1" <<<"$(ast "pjsip show endpoint 2002")"

ast "pjsip send register *all" phone >/dev/null
registered() { ast "pjsip show contacts" | grep -q "2001/sip:2001@172.31.252.12"; }
wait_for "phone registered 2001" registered

section "Calls"
ast "channel originate PJSIP/34968000001@ours application Wait 6" carrier >/dev/null   # ddi to account
ast "channel originate PJSIP/34968000002@ours application Wait 6" carrier >/dev/null   # ddi to agent
ast "channel originate PJSIP/34968000003@ours application Wait 12" carrier >/dev/null  # agent, then transfer out
ast "channel originate PJSIP/34968000004@ours application Wait 6" carrier >/dev/null   # tenant without prices
ast "channel originate PJSIP/968123456@ours application Wait 6" phone >/dev/null       # outgoing, national number
ast "channel originate PJSIP/2002@ours application Wait 4" phone >/dev/null            # internal, to an agent
legs() { [ "$(sql cdr -e "SELECT COUNT(*) FROM cdr WHERE direction IS NOT NULL")" -ge 7 ]; }
wait_for "7 tagged CDR legs written" legs
sleep 2
sql cdr -e "SELECT direction, dst, tenant_id, agent_id, trunk, disposition, billsec, rating_status FROM cdr WHERE direction IS NOT NULL ORDER BY calldate, id" >work/legs.txt

check "ddi to account: in, tenant, carrier trunk" is "$(cdr "CONCAT_WS(' ', tenant_id, IFNULL(agent_id, '-'), trunk, disposition)" "dst = '34968000001'")" "$T1 - carrier1 ANSWERED"
check "ddi to agent: in, tenant and agent" is "$(cdr "CONCAT_WS(' ', direction, tenant_id, agent_id)" "dst = '34968000002'")" "in $T2 $A2"
check "transfer: in leg to the agent, then out leg, same tenant" is \
    "$(cdr "CONCAT_WS(' ', direction, tenant_id, agent_id, dst)" "uniqueid = (SELECT uniqueid FROM cdr WHERE dst = '34968000003' LIMIT 1)" | tr '\n' '|')" \
    "in $T1 $A1 34968000003|out $T1 $A1 34600111222|"
check "transfer legs share the linkedid" is "$(sql cdr -e "SELECT COUNT(DISTINCT linkedid) FROM cdr WHERE direction IS NOT NULL AND tenant_id = '$T1' AND agent_id = '$A1' AND dst IN ('34968000003', '34600111222')")" 1
check "outgoing: tenant from the endpoint, dst in E.164" is "$(cdr "CONCAT_WS(' ', direction, tenant_id, trunk, disposition)" "dst = '34968123456'")" "out $T1 carrier1 ANSWERED"
check "internal call: direction internal, tenant of the caller" is "$(cdr "CONCAT_WS(' ', direction, tenant_id, IFNULL(agent_id, '-'))" "dst = '2002'")" "internal $T1 -"
check "new legs wait as unrated" is "$(sql cdr -e "SELECT COUNT(*) FROM cdr WHERE rating_status <> 'unrated'")" 0

section "Prices"
sql billing -e "
INSERT INTO billing_profiles (id, name) VALUES (1, 'Tenant out'), (2, 'Tenant in'), (3, 'Carrier out'), (4, 'Carrier in');
INSERT INTO billing_zones (id, billing_profile_id, zone, detail) VALUES
  (1, 1, 'Europe', 'Spain'), (2, 1, 'Europe', 'Spain mobile'), (3, 2, 'Inbound', 'Spain'),
  (4, 3, 'Europe', 'Spain'), (5, 3, 'Europe', 'Spain mobile'), (6, 4, 'Inbound', 'Any');
INSERT INTO billing_fees (billing_profile_id, billing_zone_id, destination, init_rate, init_interval, follow_rate, follow_interval) VALUES
  (1, 1, '^34.*\$', 0.06, 60, 0.06, 1), (1, 2, '^346.*\$', 0.12, 1, 0.12, 1),
  (2, 3, '^34.+\$', 0.03, 1, 0.03, 1),
  (3, 4, '^34.*\$', 0.02, 1, 0.02, 1), (3, 5, '^346.*\$', 0.05, 1, 0.05, 1),
  (4, 6, '^.+\$', 0, 1, 0, 1);
INSERT INTO billing_tenants (tenant_id, name, in_billing_profile_id, out_billing_profile_id) VALUES
  ('$T1', 'Tenant 1', 2, 1), ('$T2', 'Tenant 2', 2, 1);
INSERT INTO billing_carriers (trunk, name, in_billing_profile_id, out_billing_profile_id) VALUES ('carrier1', 'Carrier 1', 4, 3);" >/dev/null

section "Rating"
check "avr-rate rates every pending leg" grep -q "CDRs rated" <<<"$(rate)"
check "nothing left unrated" is "$(sql cdr -e "SELECT COUNT(*) FROM cdr WHERE rating_status = 'unrated'")" 0
# Expected price of a leg: rate per minute, by the second.
per_second() { sql cdr -e "SELECT ROUND($1 * billsec / 60, 4) FROM cdr WHERE direction IS NOT NULL AND $2"; }
check "in: tenant price 0.03/min, carrier 0, ok" is "$(cdr "CONCAT_WS(' ', cost, carrier_cost, rating_status)" "dst = '34968000001'")" "$(per_second 0.03 "dst = '34968000001'") 0.0000 ok"
check "out: first 60 s at 0.06/min, carrier 0.02/min" is "$(cdr "CONCAT_WS(' ', cost, carrier_cost, billing_zone_id, carrier_billing_zone_id)" "dst = '34968123456'")" "0.0600 $(per_second 0.02 "dst = '34968123456'") 1 4"
check "longest expression wins (^346 before ^34)" is "$(cdr "CONCAT_WS(' ', cost, billing_zone_id, carrier_billing_zone_id)" "dst = '34600111222'")" "$(per_second 0.12 "dst = '34600111222'") 2 5"
check "tenant without prices: failed_no_tenant" is "$(cdr rating_status "dst = '34968000004'")" failed_no_tenant
check "internal call ignored" is "$(cdr rating_status "dst = '2002'")" ignored
check "untagged legs (Local channels) ignored" is "$(sql cdr -e "SELECT COUNT(*) FROM cdr WHERE direction IS NULL AND rating_status <> 'ignored'")" 0

section "Balances"
day="$(sql cdr -e "SELECT DATE(MIN(calldate)) FROM cdr")"
balance() { sql billing -e "SELECT CONCAT_WS(' ', calls, billsec, cost, carrier_cost) FROM tenant_balances WHERE tenant_id = '$1' AND period = '$2' AND direction = '$3'"; }
sum() { sql cdr -e "SELECT CONCAT_WS(' ', COUNT(*), SUM(billsec), SUM(cost), SUM(carrier_cost)) FROM cdr WHERE tenant_id = '$1' AND direction = '$2' AND rating_status = 'ok'"; }
check "daily out balance of tenant 1 (out call + transfer)" is "$(balance $T1 daily out)" "$(sum $T1 out)"
check "daily in balance of tenant 1" is "$(balance $T1 daily in)" "$(sum $T1 in)"
check "monthly equals daily on a single day" is "$(balance $T2 monthly in)" "$(balance $T2 daily in)"
check "out balance has 2 calls" is "$(balance $T1 daily out | cut -d' ' -f1)" 2
check "daily balance dated on the call day" is "$(sql billing -e "SELECT COUNT(*) FROM tenant_balances WHERE period = 'daily' AND start = '$day'")" "$(sql billing -e "SELECT COUNT(*) FROM tenant_balances WHERE period = 'daily'")"

section "Retry and rerate"
sql billing -e "INSERT INTO billing_tenants (tenant_id, in_billing_profile_id, out_billing_profile_id) VALUES ('$T3', 2, 1)" >/dev/null
rate --retry-failed >/dev/null
check "--retry-failed rates the tenant added since" is "$(cdr rating_status "dst = '34968000004'")" ok
sql billing -e "UPDATE billing_fees SET init_rate = 0.6, follow_rate = 0.6 WHERE billing_profile_id = 2" >/dev/null
rate "--rerate-from=$day" >/dev/null
check "--rerate-from applies new prices" is "$(cdr cost "dst = '34968000001'")" "$(per_second 0.6 "dst = '34968000001'")"
check "and rebuilds the balances" is "$(balance $T1 daily in)" "$(sum $T1 in)"

sql billing -e "UPDATE billing_carriers SET in_billing_profile_id = NULL WHERE trunk = 'carrier1'" >/dev/null
rate "--rerate-from=$day" >/dev/null
check "carrier without incoming profile: incoming legs cost it 0, ok" is "$(cdr "CONCAT_WS(' ', carrier_cost, IFNULL(carrier_billing_profile_id, '-'), rating_status)" "dst = '34968000001'")" "0.0000 - ok"
sql billing -e "UPDATE billing_carriers SET out_billing_profile_id = NULL WHERE trunk = 'carrier1'" >/dev/null
rate "--rerate-from=$day" >/dev/null
check "but outgoing legs without a profile fail" is "$(cdr rating_status "dst = '34968123456'")" failed_no_carrier
sql billing -e "UPDATE billing_carriers SET in_billing_profile_id = 4, out_billing_profile_id = 3 WHERE trunk = 'carrier1'" >/dev/null
rate "--rerate-from=$day" >/dev/null

section "cdr_report view"
check "one line per tagged leg" is "$(sql billing -e "SELECT COUNT(*) FROM cdr_report")" "$(sql cdr -e "SELECT COUNT(*) FROM cdr WHERE direction IS NOT NULL")"
check "human duration and destination name" grep -qE "^34600111222 00h 00m 0[0-9]s Spain mobile$" <<<"$(sql billing -e "SELECT CONCAT_WS(' ', destination, duration_human, destination_name) FROM cdr_report WHERE destination = '34600111222'")"
check "margin = cost - carrier_cost" is "$(sql billing -e "SELECT COUNT(*) FROM cdr_report WHERE margin <> cost - carrier_cost")" 0

section "Asterisk health"
check "no CDR insert errors" bash -c "! docker compose -f $PWD/compose.yml logs avr-asterisk 2>&1 | grep -iE 'cdr_adaptive_odbc.*(error|fail)'"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
    echo "--- tagged legs"; cat work/legs.txt
    echo "--- avr-asterisk log (CDR / errors)"
    "${DC[@]}" logs --no-log-prefix avr-asterisk 2>&1 | grep -iE "cdr|error|warning" | tail -30
fi
[ "$failed" -eq 0 ]
