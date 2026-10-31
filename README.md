# AVR Asterisk Docker Image

This is a lightweight Asterisk 23.1.0 Docker image optimized for VoIP applications. The image is based on Ubuntu 22.04 and includes only essential modules and features.

## Features

- Asterisk 23.1.0
- PJSIP support
- Manager API enabled
- HTTP API enabled
- Prometheus metrics enabled
- Minimal footprint with only essential modules
- Timezone set to Europe/Rome by default
- G722 codec
- ChanSpy
- Confbridge
- ODBC support
- ping, curl, jq, wget  utils
- PHP 8.5 support
- Include extensions.d/* into extensions.conf for modularity
- Share agi-bin, bin and sounds directories

## Quick Start

### Using Docker

Due too database dependency, it's easier to use "Docker compose" instead

### Using Docker Compose

```yaml
version: '3.8'

services:
  asterisk:
    image: agentvoiceresponse/avr-asterisk:latest
    container_name: asterisk
    environment:
      - MYSQL_HOST=${DATABASE_ASTERISK_HOST:-avr-asterisk-db}
      - MYSQL_PORT=${DATABASE_ASTERISK_PORT:-3306}
      - MYSQL_DATABASE=${DATABASE_ASTERISK_NAME:-asterisk}
      - MYSQL_USER=${DATABASE_ASTERISK_USERNAME:-asterisk}
      - MYSQL_PASSWORD=${DATABASE_ASTERISK_PASSWORD}
      - MYSQL_ROOT_PASSWORD=${DATABASE_ROOT_PASSWORD}
    ports:
      - 5038:5038
      - target: 5060
        published: 5060
        protocol: tcp
      - target: 5060
        published: 5060
        protocol: udp
      - 10000-10050:10000-10050/udp
      - 8088:8088
    volumes:
      - ./conf/manager.conf:/etc/asterisk/my_manager.conf
      - ./conf/pjsip.conf:/etc/asterisk/my_pjsip.conf
      - ./conf/extensions.conf:/etc/asterisk/my_extensions.conf
      - ./conf/queues.conf:/etc/asterisk/my_queues.conf
      - ./conf/ari.conf:/etc/asterisk/my_ari.conf
      - ./conf/extensions.d:/etc/asterisk/extensions.d
      - ./sounds:/var/lib/asterisk/sounds/avr
      - ./agi-bin:/var/lib/asterisk/agi-bin/avr
      - ./bin:/usr/local/bin/avr
    restart: unless-stopped

  avr-asterisk-db:
    image: mysql:8.0.15
    platform: linux/x86_64
    container_name: avr-asterisk-db
    command: mysqld --default-authentication-plugin=mysql_native_password
    restart: always
    environment:
      - MYSQL_DATABASE=${DATABASE_ASTERISK_NAME:-asterisk}
      - MYSQL_USER=${DATABASE_ASTERISK_USERNAME:-asterisk}
      - MYSQL_PASSWORD=${DATABASE_ASTERISK_PASSWORD}
      - MYSQL_ROOT_PASSWORD=${DATABASE_ROOT_PASSWORD}
    ports:
      - 3309:3306
    volumes:
      - ./db:/var/lib/mysql
      - ./init:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD", "mysqladmin" ,"ping", "-h", "localhost"]
      timeout: 20s
      retries: 10
    networks:
      - avr

```

## Configuration

The container uses the following default configuration files:
- `extensions.conf`
- `pjsip.conf`
- `manager.conf`
- `queues.conf`
- `ari.conf`
- `extconfig.conf` (realtime table mappings)
- `sorcery.conf` (PJSIP object storage)

You can override these configurations by mounting your own configuration files to `/etc/asterisk/` in the container. Each of these files includes a `my_<name>.conf` (for example `my_pjsip.conf`); mount yours there. For `extconfig.conf` and `sorcery.conf`, the image ships defaults as `my_extconfig.conf` and `my_sorcery.conf`, and a mounted file replaces them.

### Default Ports

- 5038: Asterisk Manager Interface (AMI)
- 8088: HTTP API
- 10000-20000: RTP ports for media streaming

## Environment Variables

- `TZ`: Timezone (default: Europe/Rome)
- `ASTERISK_COUNTRY`: Default country for indication tones (dial, busy, ring...) in `indications.conf`, as a two-letter code such as `es`, `fr` or `it` (default: `us`). Unknown codes are ignored with a warning.
- `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`: database server, realtime database and application user.
- `MYSQL_ROOT_PASSWORD`: lets the container create and migrate the databases at startup (see [Databases](#databases)). Without it, migrations are skipped.
- `CDR_DATABASE` (default `cdr`), `RECORDINGS_DATABASE` (default `recordings`), `PROVISION_DATABASE` (default `provision`): names of the other databases.
- `DB_MIGRATE=no`: skip the migrations (for example when they are managed elsewhere).
- `DB_MIGRATE_TIMEOUT` (default `120`): seconds to wait for MySQL before failing.

## Databases

At startup, before Asterisk, `entrypoint.sh` runs `avr-db-migrate`, which applies the migrations shipped in the image (`db/migrations/`) once each and records them in `<MYSQL_DATABASE>.schema_migrations`. It connects as root (`MYSQL_ROOT_PASSWORD`) and grants the application user (`MYSQL_USER`) access to the databases it creates. If a migration fails, the container stops with the error in its log.

| Database | Content |
|---|---|
| `MYSQL_DATABASE` (`asterisk`) | Realtime configuration: PJSIP (`ps_*`), dialplan (`extensions`), queues, voicemail |
| `CDR_DATABASE` (`cdr`) | Call detail records, written by `cdr_odbc` through a second ODBC connection named `cdr` |
| `RECORDINGS_DATABASE` (`recordings`) | Call recording metadata |
| `PROVISION_DATABASE` (`provision`) | Accounts, trunks and DDIs created with one `INSERT` (below) |

A database created before migrations existed already has the realtime schema: `0001-asterisk.sql` is recorded as applied without running, and the newer migrations are applied on top. Old `cdr` / `recordings` tables in the realtime database are left untouched.

Demo data (endpoints `1000`/`1001`, a trunk, a queue) is in `db/seed/demo.sql`; it is not applied automatically.

### CDR and recordings: partitions, archive and retention

`cdr` and `recordings` (and their `cdr_archives` / `recordings_archives`) have **one partition per day** (`pYYYYMMDD`), so a query on a day reads one partition and a query on a month about 30. The primary key starts with the date (`(calldate, id)`, `(created_at, id)`), which keeps each day's rows together; the other indexes end with the date (`src`, `dst`, `accountcode` for CDRs; `caller`, `destination`, the processing statuses for recordings) to answer "this number / status in this period". Filter by date whenever you can: indexes are per partition, so a lookup without a date (for example by `uniqueid` alone) checks every partition.

Every table also has two fixed partitions: `pmax` catches rows dated beyond the existing partitions (an insert never fails, and they move to their day when it is created), and `pmin` stays empty (MySQL always adds the first partition to range queries, so it costs nothing).

| | CDRs | Recordings |
|---|---|---|
| Main table keeps | the current calendar year | the current month and the previous `hot_months` (default 1) |
| Archived | whole past years, on 1 January | older months, every day |
| Dropped from the archive | years older than `retention_years` (default 4) | months older than `retention_months` (default 12) |
| Settings | `cdr.cdr_settings` | `recordings.recordings_settings` |

Six MySQL events do this (the event scheduler must be on: `--event-scheduler=ON`, the MySQL 8 default):

| Event | When | What |
|---|---|---|
| `cdr_create_partitions` / `recordings_create_partitions` | 15 December, 03:00 | Next year's day partitions |
| `cdr_archive` / `recordings_archive` | daily, 03:00 | Moves the due days to the archive with `EXCHANGE PARTITION` (no row copy) |
| `cdr_purge` / `recordings_purge` | daily, 03:30 | `DROP PARTITION` of archive days beyond retention: rows and partitions go together |

```sql
-- Retention (takes effect at the next run, 03:30)
UPDATE cdr.cdr_settings SET retention_years = 5;
UPDATE recordings.recordings_settings SET hot_months = 2, retention_months = 6;

-- Partitions of a table, with their row estimates
SELECT partition_name, table_rows FROM information_schema.partitions
 WHERE table_schema = 'cdr' AND table_name = 'cdr' ORDER BY partition_ordinal_position;

-- The events and when they last ran
SELECT event_schema, event_name, status, last_executed FROM information_schema.events;
```

- **Late rows** (a CDR of 31 December written after midnight, a recording of an archived month) still insert: they land in the main table's first day partition and reach their own day in the archive at the next archiving.
- **`recordings.uuid`** is unique together with `created_at` (MySQL requires the partitioning column in every unique key). Writers must give a recording a fixed `created_at` per call, so that a retry hits the key and `ON DUPLICATE KEY UPDATE` applies; elokia-infra's `save_recording.php` uses the call start.
- Recording partitions are on `UNIX_TIMESTAMP(created_at)`: day boundaries follow the MySQL server time zone when they are created, so do not change it afterwards.
- On a database created before 0006/0007, existing rows are moved once to their final place (main table or archive); rows already older than the retention period are not kept.

`tests/cdr/run.sh` and `tests/recordings/run.sh` simulate the calendar (partition creation, archiving, late rows, purge, settings, and the conversion of existing tables).

### Provisioning accounts, trunks and DDIs

Triggers on the `provision` database write the realtime rows, so an account works right after its `INSERT`, without a reload:

```sql
-- Phone registering here over UDP/TCP/TLS, plus a 2003-webrtc endpoint for WebRTC; password generated
-- (see it with: SELECT password FROM accounts WHERE name = '2003')
INSERT INTO accounts (name, type, transports, callerid) VALUES ('2003', 'local', 'udp,tcp,tls,wss', 'Ana <2003>');

-- Extension of another PBX (any transport and port); calls to it go to an AVR agent
INSERT INTO accounts (name, type, host, port, transport, username, password, agent_uuid)
VALUES ('pbx-128', 'external', 'pbx.example.com', 5062, 'tcp', '128', '…', '01a13595-4f65-7d9c-83cd-88dc57dfbce3');

-- SIP trunk authenticated by IP (or register=1 with username/password)
INSERT INTO accounts (name, type, host, match_ips) VALUES ('carrier1', 'trunk', 'sip.carrier.example', '203.0.113.10');

-- WhatsApp Business calling (identified by the X-FB-External-Domain header)
INSERT INTO accounts (name, type, username, password, from_domain) VALUES ('wa-main', 'whatsapp', '+34968000678', '…', 'crm.example.com');

-- DDIs to an account or to an AVR agent
INSERT INTO ddis (ddi, account) VALUES ('34968012704', '2003');
INSERT INTO ddis (ddi, agent_uuid) VALUES ('+34968000678', '01a13595-4f65-7d9c-83cd-88dc57dfbce3');
```

| `type` | What it is | Realtime rows (`<name>` = account name) |
|---|---|---|
| `local` | A phone registering on this Asterisk | `ps_auths` (`md5_cred`), `ps_aors`, `ps_endpoints` without a fixed transport; with `wss` in `transports`, also `<name>-webrtc` |
| `external` | This Asterisk registers as an extension of another PBX | `<name>-auth`, `ps_aors`, `ps_endpoints`, `<name>-reg` (`line=yes`, so extensions of the same PBX stay apart) |
| `trunk` | SIP provider | Like `external` with `register=1`; with `register=0`, `<name>-identify` on `match_ips` (default `host`) |
| `whatsapp` | WhatsApp Business calling (Meta) | TLS + DTLS-SRTP endpoint, `<name>-auth`, `<name>-identify` on `X-FB-External-Domain: wa.meta.vc` |

- A `local` account accepts up to `max_contacts` devices at once (default 5; with `remove_existing`, a new one replaces the oldest).
- A `local` account without `password` gets a generated one: 16 characters from a cryptographically secure source (`RANDOM_BYTES`), with at least one lowercase letter, uppercase letter, digit and symbol. Symbols are limited to `! % * + - . ^ _ ~`, which need no quoting in phone configs, `.env` files, URLs or shells. Asterisk only stores its hash (`md5_cred`); `provision.accounts` keeps it readable.
- `transport` (`udp`, `tcp`, `tls`) and `port` (any) describe the remote side of `external`, `trunk` and `whatsapp` accounts; defaults are `udp` (`tls` for WhatsApp) and 5060 (5061 with `tls`).
- Default contexts: `local` → `from-phones`, `external` → `internal`, `trunk` → `from-trunk`, `whatsapp` → `from-whatsapp`.
- `agent_uuid` adds `internal/<username>` → `GoSub(avr,<agent_uuid>,1(avr-core:5001))`. DDIs become `incoming/<ddi>` → `Dial(PJSIP/<account>,…)` or `Dial(local/<agent_uuid>@internal,…)`.
- The dialplan must provide those contexts: `internal` and `incoming` with `switch => Realtime/@`, and `from-trunk` / `from-whatsapp` going to `incoming` for known DDIs.
- `UPDATE` regenerates the rows and keeps the devices already registered; `enabled=0` or `DELETE` removes them (and their registrations); `name` and `type` cannot change; accounts with DDIs cannot be deleted. Invalid rows fail with a `provision: …` error and nothing is written; names already used in Asterisk are refused.
- **Outbound registrations** (`external`, `trunk` with `register=1`): Asterisk starts a new realtime registration only once it loads it (`pjsip show registration <name>-reg`; `pjsip send register` fails with "Unable to retrieve registration" until then) and renews it by itself afterwards; a deleted one keeps running until `pjsip send unregister <name>-reg`. The triggers queue these actions in `provision.registration_queue` (`processed_at IS NULL`) for an external worker.
- PJSIP cannot restrict per endpoint the transport a request arrives on: `transports` decides which endpoints exist, not which transport is accepted.

`tests/provision/run.sh` builds the image and checks the migrations (empty and existing databases), every account type, DDIs and CDRs against helper Asterisk containers.

#### SQL examples

Connect to the `provision` database as the application user (`MYSQL_USER`), for example:

```bash
docker compose exec avr-asterisk-db sh -c 'mysql -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" provision'
```

**Local accounts** (phones registering on this Asterisk). The SIP username is the account name unless `username` is given, and the realm is `asterisk`.

```sql
-- Generated password: read it back after the INSERT
INSERT INTO accounts (name, type, callerid) VALUES ('1000', 'local', 'Reception <1000>');
SELECT name, username, password FROM accounts WHERE name = '1000';

-- Your own password, two devices at once, and WebRTC (also creates 1001-webrtc,
-- whose SIP username is 1001-webrtc with the same password)
INSERT INTO accounts (name, type, password, max_contacts, transports, callerid)
VALUES ('1001', 'local', 'Choose-a-strong-1', 2, 'udp,tcp,tls,wss', 'Sales <1001>');

-- Several accounts in one statement
INSERT INTO accounts (name, type, callerid) VALUES
  ('1002', 'local', 'Support <1002>'),
  ('1003', 'local', 'Support <1003>');

-- Change the password, the caller ID or the allowed transports (rows regenerated at once)
UPDATE accounts SET password = 'Another-strong-2' WHERE name = '1000';
UPDATE accounts SET callerid = 'Front desk <1000>' WHERE name = '1000';
UPDATE accounts SET transports = 'tls,wss' WHERE name = '1001';

-- Send calls for 1002 to an AVR agent instead of the phone (internal/1002 -> GoSub avr)
UPDATE accounts SET agent_uuid = '01a13595-4f65-7d9c-83cd-88dc57dfbce3' WHERE name = '1002';
UPDATE accounts SET agent_uuid = NULL WHERE name = '1002';

-- Disable (removes the realtime rows, keeps the account) and enable again
UPDATE accounts SET enabled = 0 WHERE name = '1003';
UPDATE accounts SET enabled = 1 WHERE name = '1003';
```

**External extensions** (this Asterisk registers as an extension of another PBX). After the `INSERT`, start the registration with `pjsip show registration <name>-reg` (see above).

```sql
-- UDP 5060 (defaults)
INSERT INTO accounts (name, type, host, username, password)
VALUES ('pbx-128', 'external', 'pbx.example.com', '128', 'remote-secret');

-- TCP on a non-standard port; calls from that PBX to this extension go to an AVR agent
INSERT INTO accounts (name, type, host, port, transport, username, password, agent_uuid)
VALUES ('pbx-129', 'external', 'pbx.example.com', 5062, 'tcp', '129', 'remote-secret',
        '01a13595-4f65-7d9c-83cd-88dc57dfbce3');

-- TLS (port defaults to 5061)
INSERT INTO accounts (name, type, host, transport, username, password)
VALUES ('pbx-130', 'external', 'pbx.example.com', 'tls', '130', 'remote-secret');
```

**SIP trunks**

```sql
-- Authenticated by IP: calls from these addresses are this trunk (match_ips defaults to host)
INSERT INTO accounts (name, type, host, match_ips)
VALUES ('carrier1', 'trunk', 'sip.carrier.example', '203.0.113.10,203.0.113.11,198.51.100.0/24');

-- IP trunk that also asks for digest credentials on outbound calls
INSERT INTO accounts (name, type, host, match_ips, username, password)
VALUES ('carrier2', 'trunk', 'sip.carrier2.example', '192.0.2.20', 'acct42', 'trunk-secret');

-- Registering trunk over TLS (start it with: pjsip show registration voip1-reg)
INSERT INTO accounts (name, type, host, register, transport, username, password)
VALUES ('voip1', 'trunk', 'sip.provider.example', 1, 'tls', 'acct1', 'trunk-secret');
```

**WhatsApp Business calling**

```sql
INSERT INTO accounts (name, type, username, password, from_domain)
VALUES ('wa-main', 'whatsapp', '+34968000678', 'meta-sip-password', 'crm.example.com');
```

**DDIs** (become `incoming/<ddi>` in the realtime dialplan; trunk and WhatsApp calls follow them)

```sql
-- To an account, recorded on answer (record=1 by default)
INSERT INTO ddis (ddi, account) VALUES ('34968012704', '1000');

-- To an account, without recording and ringing for 20 seconds
INSERT INTO ddis (ddi, account, record, ring_timeout) VALUES ('34968012705', '1001', 0, 20);

-- To an AVR agent (also creates internal/<agent_uuid> if missing)
INSERT INTO ddis (ddi, agent_uuid) VALUES ('34968012706', '01a13595-4f65-7d9c-83cd-88dc57dfbce3');

-- The WhatsApp number to an agent
INSERT INTO ddis (ddi, agent_uuid) VALUES ('+34968000678', '01a13595-4f65-7d9c-83cd-88dc57dfbce3');

-- Move a DDI to another account, or from an account to an agent
UPDATE ddis SET account = '1001' WHERE ddi = '34968012704';
UPDATE ddis SET account = NULL, agent_uuid = '01a13595-4f65-7d9c-83cd-88dc57dfbce3' WHERE ddi = '34968012705';

-- Delete a DDI (removes its dialplan row)
DELETE FROM ddis WHERE ddi = '34968012706';
```

**Deleting accounts.** An account with DDIs cannot be deleted: move or delete its DDIs first. Deleting an `external` account or registering trunk queues an `unregister`; run `pjsip send unregister <name>-reg`.

```sql
DELETE FROM ddis WHERE account = '1000';
DELETE FROM accounts WHERE name = '1000';

-- Several at once
DELETE FROM accounts WHERE name IN ('1002', '1003');

DELETE FROM accounts WHERE name = 'pbx-128';
```

**Queries**

```sql
-- Accounts and their DDIs
SELECT a.name, a.type, a.enabled, a.username, a.host, a.agent_uuid,
       GROUP_CONCAT(d.ddi ORDER BY d.ddi) AS ddis
  FROM accounts a LEFT JOIN ddis d ON d.account = a.name
 GROUP BY a.name ORDER BY a.type, a.name;

-- DDIs and where they go
SELECT ddi, COALESCE(account, CONCAT('agent ', agent_uuid)) AS destination, ring_timeout, record FROM ddis ORDER BY ddi;

-- Registrations waiting for "pjsip show registration" / "pjsip send unregister"
SELECT id, registration_id, action, created_at FROM registration_queue WHERE processed_at IS NULL ORDER BY id;
UPDATE registration_queue SET processed_at = NOW() WHERE id = 1;

-- What the triggers wrote in the realtime database (MYSQL_DATABASE, here asterisk)
SELECT id, transport, context, aors, auth, outbound_auth FROM asterisk.ps_endpoints WHERE id LIKE '1001%';
SELECT context, exten, app, appdata FROM asterisk.extensions WHERE context IN ('incoming', 'internal') ORDER BY context, exten;
```

In the Asterisk console (`asterisk -rvvv`): `pjsip show endpoint 1001`, `pjsip show contacts`, `pjsip show registrations`, `dialplan show 34968012704@incoming`.

## Example Configuration Files

### pjsip.conf
```ini
[transport-tcp]
type=transport
protocol=tcp
bind=0.0.0.0:5060
external_media_address=127.0.0.1
external_signaling_address=127.0.0.1
external_signaling_port=5060
local_net=127.0.0.1/32

[endpoint-template](!)
type=endpoint
transport=transport-tcp
context=demo
disallow=all
allow=gsm
allow=ulaw
direct_media=no
force_rport=no
rewrite_contact=yes
rtp_symmetric=yes

[1000](endpoint-template)
auth=1000
aors=1000

[1000]
type=auth
auth_type=userpass
password=1000
username=1000

[1000]
type=aor
max_contacts=10
```

### extensions.conf
```ini
[avr]
exten => s,1,Ringing
 same => n,Wait(1)
 same => n,Answer()
 same => n,Set(UUID=${SHELL(uuidgen | tr -d '\n')})
 same => n,AudioSocket(${UUID},${ARG1})
 same => n,Hangup()
```

## Building from Source

If you want to build the image locally:

```bash
git clone https://github.com/operativeit/avr-asterisk.git
cd avr-asterisk
docker build -t operativeit/avr-asterisk:latest .
```

## Todo 
- Add some config examples for conference , chanspy, queues
- Create an UI to setup extensions, trunks, queues ...

