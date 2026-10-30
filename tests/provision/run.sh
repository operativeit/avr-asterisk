#!/usr/bin/env bash
# Integration test for the database migrations and provision: builds the image,
# lets its entrypoint create every database on an empty MySQL, provisions every
# account type and DDIs with plain INSERTs, and checks that Asterisk (realtime,
# no reload) and the test helpers see them. Then repeats the migration on a
# database that already had the old schema.
#
#   tests/provision/run.sh          # leaves nothing running when it ends
#   KEEP=1 tests/provision/run.sh   # keep the containers for inspection
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
DC=(docker compose -f "$PWD/compose.yml")
AGENT=01a13595-4f65-7d9c-83cd-88dc57dfbce3
AGENT2=01a1359c-4f76-7dd4-8215-1c79c2c938c3
passed=0
failed=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failed=$((failed + 1)); }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi; }
section() { printf '\n== %s\n' "$1"; }

# As the application user, so the provision grants are tested too.
sql()  { "${DC[@]}" exec -T avr-asterisk-db sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -uasterisk -N "$@"' sh "$@" 2>&1; }
root() { "${DC[@]}" exec -T avr-asterisk-db sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N "$@"' sh "$@" 2>&1; }
# 16 chars from the allowed alphabet, with a lowercase, uppercase, digit and symbol.
strong_password() { grep -qE '^[A-Za-z0-9!%*+.^_~-]{16}$' <<<"$1" && grep -q '[a-z]' <<<"$1" && grep -q '[A-Z]' <<<"$1" && grep -q '[0-9]' <<<"$1" && grep -q '[!%*+.^_~-]' <<<"$1"; }
ast()  { "${DC[@]}" exec -T "${2:-avr-asterisk}" asterisk -rx "$1" 2>&1; }
# Errors make mysql exit 1, so match on the captured output, not the pipeline.
rejects() { local out; out="$(sql provision -e "$1")"; grep -q "$2" <<<"$out"; }
# Dialplan execution (verbose) goes to a log file; docker logs only has notices.
dialplan_log() { "${DC[@]}" exec -T avr-asterisk cat /var/log/asterisk/provision-test.log 2>/dev/null; }
wait_for() { local desc="$1"; shift; for _ in $(seq 1 20); do if "$@" >/dev/null 2>&1; then ok "$desc"; return; fi; sleep 1; done; fail "$desc"; }

cleanup() {
    if [ -z "${KEEP:-}" ]; then
        "${DC[@]}" down -v --remove-orphans >/dev/null 2>&1
        rm -rf work
    fi
}
trap cleanup EXIT

section "Environment"
rm -rf work && mkdir work
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=provision-test \
    -keyout work/key.pem -out work/cert.pem 2>/dev/null
echo "  building the image and starting the environment..."
"${DC[@]}" up -d --build --quiet-pull >work/up.log 2>&1 || { cat work/up.log; echo "docker compose up failed"; exit 1; }

wait_ready() {
    for _ in $(seq 1 60); do
        ast "odbc show asterisk" | grep -q "active connections: 1" && return 0
        sleep 2
    done
    return 1
}

section "Migrations applied by the entrypoint (empty database)"
check "Asterisk started and connected to the database" wait_ready
check "all migrations recorded" grep -qx "0001-asterisk.sql,0002-cdr.sql,0003-recordings.sql,0004-provision.sql,0005-provision-strong-passwords.sql,0006-cdr-partitions.sql,0007-recordings-partitions.sql" <(root asterisk -e "SELECT GROUP_CONCAT(version ORDER BY version) FROM schema_migrations")
check "databases cdr, recordings and provision exist" grep -qx 3 <(root -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name IN ('cdr','recordings','provision')")
check "no cdr or recordings table left in asterisk" grep -qx 0 <(root -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='asterisk' AND table_name IN ('cdr','recordings')")
check "cdr ODBC connection up" grep -q "active connections: 1" <(ast "odbc show cdr")
check "app user can write recordings" grep -qx 1 <(sql recordings -e "INSERT INTO recordings (uuid, recording_path, recording_blob, recording_size) VALUES ('11111111-1111-1111-1111-111111111111', '/tmp/x.wav', '', 0); SELECT ROW_COUNT();")
"${DC[@]}" restart avr-asterisk >/dev/null 2>&1
check "restart: entrypoint finds the schema up to date" bash -c "sleep 8; docker compose -f $PWD/compose.yml logs --no-log-prefix avr-asterisk 2>&1 | grep -q 'avr-db-migrate: schema is up to date'"
check "Asterisk back after restart" wait_ready
ast "logger add channel provision-test.log verbose,notice,warning,error" >/dev/null

section "Validation"
check "bad name rejected" rejects "INSERT INTO accounts (name, type) VALUES ('bad name', 'local')" "name must be"
check "external without host rejected" rejects "INSERT INTO accounts (name, type, username, password) VALUES ('x1', 'external', 'u', 'p')" "need host"
check "registering trunk without credentials rejected" rejects "INSERT INTO accounts (name, type, host, register) VALUES ('x2', 'trunk', 'h', 1)" "need username and password"
check "wss outside local rejected" rejects "INSERT INTO accounts (name, type, host, transport) VALUES ('x3', 'trunk', 'h', 'wss')" "only for local"
check "invalid agent_uuid rejected" rejects "INSERT INTO accounts (name, type, agent_uuid) VALUES ('x4', 'local', 'nope')" "not a UUID"
root asterisk -e "INSERT INTO ps_endpoints (id, context) VALUES ('1000', 'from-phones')" >/dev/null
check "endpoint created outside provision (1000) not taken over" rejects "INSERT INTO accounts (name, type) VALUES ('1000', 'local')" "already exists in asterisk"
check "ddi with account and agent rejected" rejects "INSERT INTO ddis (ddi, account, agent_uuid) VALUES ('123456', '1000', '$AGENT')" "exactly one"
check "nothing left behind by rejected inserts" grep -qx 0 <(sql provision -e "SELECT COUNT(*) FROM accounts")

section "Local accounts (no reload)"
sql provision -e "INSERT INTO accounts (name, type, password) VALUES ('2001', 'local', 'phonepass2001');
                  INSERT INTO accounts (name, type, password, transports) VALUES ('2002', 'local', 'phonepass2002', 'tcp');
                  INSERT INTO accounts (name, type, transports, callerid) VALUES ('2003', 'local', 'udp,wss', 'Ana <2003>');" >/dev/null
check "generated password for 2003 is strong" strong_password "$(sql provision -e "SELECT password FROM accounts WHERE name='2003'")"
# The generator itself, many times: every password must meet the rule.
weak="$(root provision -e "WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 500)
    SELECT COUNT(*) FROM (SELECT random_password(16) AS p FROM n) g
    WHERE NOT (p REGEXP BINARY '^[A-Za-z0-9!%*+.^_~-]{16}\$' AND p REGEXP BINARY '[a-z]' AND p REGEXP BINARY '[A-Z]'
               AND p REGEXP BINARY '[0-9]' AND p REGEXP BINARY '[!%*+.^_~-]')")"
check "500 generated passwords all meet the rule" test "$weak" = 0
check "md5_cred stored instead of the password" grep -qx "md5" <(sql asterisk -e "SELECT auth_type FROM ps_auths WHERE id='2001' AND password IS NULL")
check "2003-webrtc endpoint with webrtc=yes" grep -qE "^ *webrtc +: yes" <(ast "pjsip show endpoint 2003-webrtc")
check "2002 (tcp only) has no webrtc endpoint" grep -qx 0 <(sql asterisk -e "SELECT COUNT(*) FROM ps_endpoints WHERE id='2002-webrtc'")
ast "pjsip send register *all" phone >/dev/null
sleep 6
wait_for "phone registered 2001 over UDP" bash -c "docker compose -f $PWD/compose.yml exec -T avr-asterisk asterisk -rx 'pjsip show contacts' | grep -q '2001/sip:2001@172.31.251.12:5060 '"
wait_for "phone registered 2002 over TCP" bash -c "docker compose -f $PWD/compose.yml exec -T avr-asterisk asterisk -rx 'pjsip show contacts' | grep -qi '2002/sip:2002@172.31.251.12:[0-9]*;transport=tc'"

section "External extension (registration queued for the API)"
sql provision -e "INSERT INTO accounts (name, type, host, username, password, agent_uuid)
                  VALUES ('pbx128', 'external', '172.31.251.13', 'ext128', 'pbxpass128', '$AGENT2');" >/dev/null
check "ps_registrations row with line=yes" grep -qx "yes" <(sql asterisk -e "SELECT line FROM ps_registrations WHERE id='pbx128-reg'")
check "register queued" grep -qx "pbx128-reg	register" <(sql provision -e "SELECT registration_id, action FROM registration_queue WHERE processed_at IS NULL")
check "agent row internal/ext128" grep -q "avr,$AGENT2" <(sql asterisk -e "SELECT appdata FROM extensions WHERE context='internal' AND exten='ext128'")
# What elokia-asterisk-api will do with a "register" entry. A registration
# Asterisk has not loaded yet cannot be sent; showing it loads and starts it.
check "send register before the registration is loaded fails" grep -q "Unable to retrieve registration" <(ast "pjsip send register pbx128-reg")
ast "pjsip show registration pbx128-reg" >/dev/null
wait_for "registered on the remote PBX" bash -c "docker compose -f $PWD/compose.yml exec -T avr-asterisk asterisk -rx 'pjsip show registrations' | grep 'pbx128-reg' | grep -qw Registered"
ast "channel originate PJSIP/ext128 application Wait 3" pbx >/dev/null
wait_for "call from the remote PBX reaches the agent (line=yes, internal)" bash -c "docker compose -f $PWD/compose.yml exec -T avr-asterisk cat /var/log/asterisk/provision-test.log | grep -q 'ext128@internal:1\] GoSub(.*avr,$AGENT2'"

section "External extensions over TCP and TLS on non-standard ports"
sql provision -e "INSERT INTO accounts (name, type, host, port, transport, username, password, agent_uuid)
                  VALUES ('pbx129', 'external', '172.31.251.13', 5062, 'tcp', 'ext129', 'pbxpass129', '$AGENT'),
                         ('pbx130', 'external', '172.31.251.13', 5063, 'tls', 'ext130', 'pbxpass130', '$AGENT');" >/dev/null
check "tcp registration targets port 5062 over tcp" grep -qx "sip:172.31.251.13:5062	transport-tcp" <(sql asterisk -e "SELECT server_uri, transport FROM ps_registrations WHERE id='pbx129-reg'")
check "tls registration targets port 5063 over tls" grep -qx "sip:172.31.251.13:5063	transport-tls" <(sql asterisk -e "SELECT server_uri, transport FROM ps_registrations WHERE id='pbx130-reg'")
ast "pjsip show registration pbx129-reg" >/dev/null
ast "pjsip show registration pbx130-reg" >/dev/null
for ext in 129 130; do
    wait_for "pbx$ext registered on the remote PBX" bash -c "docker compose -f $PWD/compose.yml exec -T avr-asterisk asterisk -rx 'pjsip show registrations' | grep 'pbx$ext-reg' | grep -qw Registered"
done
check "remote PBX holds our ext129 and ext130 contacts" grep -qx 2 <(ast "pjsip show contacts" pbx | grep -cE "ext1(29|30)/sip:ext1(29|30)@172.31.251.11")
ast "channel originate PJSIP/ext129 application Wait 3" pbx >/dev/null
ast "channel originate PJSIP/ext130 application Wait 3" pbx >/dev/null
wait_for "call from the remote PBX over tcp reaches the agent" bash -c "docker compose -f $PWD/compose.yml exec -T avr-asterisk cat /var/log/asterisk/provision-test.log | grep -q 'ext129@internal:1\] GoSub(.*avr,$AGENT'"
wait_for "call from the remote PBX over tls reaches the agent" bash -c "docker compose -f $PWD/compose.yml exec -T avr-asterisk cat /var/log/asterisk/provision-test.log | grep -q 'ext130@internal:1\] GoSub(.*avr,$AGENT'"

section "IP trunk and DDIs"
sql provision -e "INSERT INTO accounts (name, type, host, match_ips) VALUES ('carrier1', 'trunk', 'carrier.example', '172.31.251.14');
                  INSERT INTO ddis (ddi, account) VALUES ('34968000001', '2001');
                  INSERT INTO ddis (ddi, agent_uuid, record) VALUES ('34968000002', '$AGENT', 0);" >/dev/null
check "no registration queued for an IP trunk" grep -qx 0 <(sql provision -e "SELECT COUNT(*) FROM registration_queue WHERE account='carrier1'")
check "ddi to account: Dial with recording" grep -q "PJSIP/2001,30,U(start-recording-on-answer" <(sql asterisk -e "SELECT appdata FROM extensions WHERE context='incoming' AND exten='34968000001'")
check "ddi to agent creates internal/<uuid>" grep -qx 1 <(sql asterisk -e "SELECT COUNT(*) FROM extensions WHERE context='internal' AND exten='$AGENT'")
ast "channel originate PJSIP/34968000001@ours application Wait 3" carrier >/dev/null
ast "channel originate PJSIP/34968000002@ours application Wait 3" carrier >/dev/null
sleep 6
out="$(dialplan_log)"
check "carrier identified by IP (from-trunk)" grep -q "34968000001@from-trunk:1" <<<"$out"
check "ddi 34968000001 dials PJSIP/2001" grep -q "34968000001@incoming:1\] Dial(.*PJSIP/2001" <<<"$out"
check "ddi 34968000002 goes to the agent" grep -q "34968000002@incoming:1\] Dial(.*local/$AGENT@internal" <<<"$out"
cdr_seen() { [ "$(sql cdr -e "SELECT COUNT(*) FROM cdr WHERE dst IN ('34968000001', '34968000002')")" -ge 1 ]; }
wait_for "CDRs written to the cdr database" cdr_seen

section "Registering trunk"
sql provision -e "INSERT INTO accounts (name, type, host, register, username, password, transport)
                  VALUES ('voip1', 'trunk', 'sip.provider.example', 1, 'acct1', 'secret1', 'tls');" >/dev/null
check "tls trunk defaults to port 5061" grep -qx "sip:sip.provider.example:5061" <(sql asterisk -e "SELECT server_uri FROM ps_registrations WHERE id='voip1-reg'")
check "register queued for voip1" grep -qx 1 <(sql provision -e "SELECT COUNT(*) FROM registration_queue WHERE account='voip1' AND action='register'")

section "WhatsApp"
sql provision -e "INSERT INTO accounts (name, type, username, password, from_domain) VALUES ('wa1', 'whatsapp', '+34968000678', 'metapass', 'crm.example');
                  INSERT INTO ddis (ddi, agent_uuid) VALUES ('+34968000678', '$AGENT2');" >/dev/null
check "identify by X-FB-External-Domain header" grep -q "X-FB-External-Domain: wa.meta.vc" <(sql asterisk -e "SELECT match_header FROM ps_endpoint_id_ips WHERE id='wa1-identify'")
check "whatsapp endpoint over tls with dtls" grep -q "media_encryption *: *dtls" <(ast "pjsip show endpoint wa1")
ast "channel originate Local/wa@call-wa application Wait 3" meta >/dev/null
sleep 6
out="$(dialplan_log)"
check "call with the header identified as wa1 (from-whatsapp)" grep -q "+34968000678@from-whatsapp:1" <<<"$out"
check "whatsapp number follows its ddi to the agent" grep -q "+34968000678@incoming:1\] Dial(.*local/$AGENT2@internal" <<<"$out"

section "Updates and deletes"
old_md5="$(sql asterisk -e "SELECT md5_cred FROM ps_auths WHERE id='2001'")"
sql provision -e "UPDATE accounts SET password='newpass2001' WHERE name='2001'" >/dev/null
new_md5="$(sql asterisk -e "SELECT md5_cred FROM ps_auths WHERE id='2001'")"
check "password change updates md5_cred" test -n "$new_md5" -a "$new_md5" != "$old_md5"
check "renaming an account rejected" rejects "UPDATE accounts SET name='2009' WHERE name='2003'" "cannot change"
sql provision -e "UPDATE accounts SET enabled=0 WHERE name='2003'" >/dev/null
check "disabling removes the realtime rows" grep -qx 0 <(sql asterisk -e "SELECT COUNT(*) FROM ps_endpoints WHERE id IN ('2003','2003-webrtc')")
sql provision -e "UPDATE accounts SET enabled=1 WHERE name='2003'" >/dev/null
check "re-enabling recreates them" grep -qx 2 <(sql asterisk -e "SELECT COUNT(*) FROM ps_endpoints WHERE id IN ('2003','2003-webrtc')")
check "deleting an account with ddis rejected" rejects "DELETE FROM accounts WHERE name='2001'" "foreign key constraint"
sql provision -e "UPDATE ddis SET account='2002' WHERE ddi='34968000001'" >/dev/null
check "ddi re-pointed to 2002" grep -q "PJSIP/2002," <(sql asterisk -e "SELECT appdata FROM extensions WHERE context='incoming' AND exten='34968000001'")
sql provision -e "DELETE FROM ddis WHERE ddi='34968000001'; DELETE FROM accounts WHERE name='2001'" >/dev/null
check "ddi delete removes its dialplan row" grep -qx 0 <(sql asterisk -e "SELECT COUNT(*) FROM extensions WHERE context='incoming' AND exten='34968000001'")
check "account delete removes endpoint, aor, auth, contacts" grep -qx 0 <(sql asterisk -e "SELECT (SELECT COUNT(*) FROM ps_endpoints WHERE id='2001') + (SELECT COUNT(*) FROM ps_aors WHERE id='2001') + (SELECT COUNT(*) FROM ps_auths WHERE id='2001') + (SELECT COUNT(*) FROM ps_contacts WHERE endpoint='2001')")
sql provision -e "DELETE FROM accounts WHERE name='pbx128'" >/dev/null
check "deleting the external account queues unregister" grep -qx 1 <(sql provision -e "SELECT COUNT(*) FROM registration_queue WHERE account='pbx128' AND action='unregister'")
check "and removes its agent row" grep -qx 0 <(sql asterisk -e "SELECT COUNT(*) FROM extensions WHERE context='internal' AND exten='ext128'")

section "Asterisk health"
check "no realtime mapping warnings" grep -qx 0 <("${DC[@]}" logs --no-log-prefix avr-asterisk 2>&1 | grep -c "failed to open mapping")

section "Existing database (created before migrations, like staging)"
"${DC[@]}" down -v >/dev/null 2>&1
mkdir -p work/old-init && cp ../../db/migrations/0001-asterisk.sql work/old-init/0001-init.sql
root_old_schema="$PWD/work/old-init"
OLD_SCHEMA_DIR="$root_old_schema" "${DC[@]}" up -d avr-asterisk-db avr-asterisk >work/up-old.log 2>&1 || { cat work/up-old.log; exit 1; }
check "Asterisk started on the old database" wait_ready
check "0001 recorded as already applied" grep -q "existing database: recording 0001-asterisk.sql as applied" <("${DC[@]}" logs --no-log-prefix avr-asterisk 2>&1)
check "0002-0007 applied on top" grep -qx "0001-asterisk.sql,0002-cdr.sql,0003-recordings.sql,0004-provision.sql,0005-provision-strong-passwords.sql,0006-cdr-partitions.sql,0007-recordings-partitions.sql" <(root asterisk -e "SELECT GROUP_CONCAT(version ORDER BY version) FROM schema_migrations")
sql provision -e "INSERT INTO accounts (name, type, password) VALUES ('3001', 'local', 'p3001')" >/dev/null
check "provision works on the old database" grep -qx 1 <(sql asterisk -e "SELECT COUNT(*) FROM ps_endpoints WHERE id='3001'")

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
