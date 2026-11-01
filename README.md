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
- `ASTERISK_LANGUAGE`: Default language of the prompts (`defaultlanguage` in `asterisk.conf`), such as `es`, `fr` or `pt_BR` (default: `en`). Endpoints with their own `language` keep it. The prompts must be in `/var/lib/asterisk/sounds/<language>/`; otherwise Asterisk plays the English ones and the container logs a warning.
- `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`: database server, realtime database and application user.
- `MYSQL_ROOT_PASSWORD`: lets the container create and migrate the databases at startup (see [Databases](#databases)). Without it, migrations are skipped.
- `CDR_DATABASE` (default `cdr`), `RECORDINGS_DATABASE` (default `recordings`): names of the other databases.
- `DB_MIGRATE=no`: skip the migrations (for example when they are managed elsewhere).
- `DB_MIGRATE_TIMEOUT` (default `120`): seconds to wait for MySQL before failing.

## Databases

At startup, before Asterisk, `entrypoint.sh` runs `avr-db-migrate`, which applies the migrations shipped in the image (`db/migrations/`) once each and records them in `<MYSQL_DATABASE>.schema_migrations`. It connects as root (`MYSQL_ROOT_PASSWORD`) and grants the application user (`MYSQL_USER`) access to the databases it creates. If a migration fails, the container stops with the error in its log.

| Database | Content |
|---|---|
| `MYSQL_DATABASE` (`asterisk`) | Realtime configuration: PJSIP (`ps_*`), dialplan (`extensions`), queues, voicemail |
| `CDR_DATABASE` (`cdr`) | Call detail records, written by `cdr_adaptive_odbc` through a second ODBC connection named `cdr` |
| `RECORDINGS_DATABASE` (`recordings`) | Call recording metadata |

There is one migration per database: `0001-asterisk.sql` (realtime), `0002-cdr.sql` and `0003-recordings.sql`. They were squashed before any data had to be kept, so a database created by an older image (with `0004`-`0014` recorded) or before migrations existed (a realtime schema without `schema_migrations`) is refused with an error: recreate it.

**Accounts, trunks and DDIs** are not created here: [elokia-provision](https://github.com/elokia-hq/elokia-provision) owns the `provision` database, whose triggers write the realtime rows (`ps_*`, `extensions`) of this image, and its demo data. This image only reads the realtime tables. Databases that applied the old provision migrations (`0004`, `0005`, `0008`, `0010`, `0012`, `0014`) keep their rows in `schema_migrations`; `avr-db-migrate` only looks at the files it ships.

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

`tests/cdr/run.sh` and `tests/recordings/run.sh` simulate the calendar (partition creation, archiving, late rows, purge, settings).

### CDR tags: tenant, agent, direction and trunks

Every call leg is tagged in the CDR at call time and rated afterwards by elokia-billing, twice: what the tenant pays and what the carrier charges, so the margin of each call is known.

**Tags** (written by `cdr_adaptive_odbc`, which fills every `cdr` column named like a CDR variable):

| Column | Set by |
|---|---|
| `tenant_id` | elokia-provision: `ddis.tenant_uuid` (the incoming extension runs `Set(CDR(tenant_id)=…)` before the `Dial`), or `accounts.tenant_uuid` (the endpoint's `set_var=__TENANT_ID=…`, copied by the dialplan) |
| `agent_id` | elokia-provision: `ddis.agent_uuid` (`Set(CDR(agent_id)=…)`) or `accounts.agent_uuid` (`set_var=__AGENT_ID=…`) |
| `direction` | dialplan: `in` (`from-trunk`), `out` (to a carrier), `internal` |
| `source_trunk` | dialplan: the account (endpoint) of the carrier the call came in on (`${CHANNEL(endpoint)}` in `from-trunk` / `from-whatsapp`) |
| `destination_trunk` | dialplan: the account of the carrier the call went out on (the trunk `outgoing` dials). A transfer's `out` leg has both |
| `linkedid` | Asterisk: the same for every leg of one call |

elokia-provision writes `tenant_id` and `agent_id` (in the DDI's extension and the endpoint's `set_var`); `tests/cdr-tags/test-pjsip.conf` and `test-extensions.conf` show them as static configuration. The dialplan sets the rest (see `tests/cdr-tags/test-extensions.conf`):

```
[from-trunk]
exten => _X.,1,Set(CDR(direction)=in)
 same => n,Set(CDR(source_trunk)=${CHANNEL(endpoint)})
 ...
[from-phones]
exten => _X.,1,ExecIf($["${TENANT_ID}" != ""]?Set(CDR(tenant_id)=${TENANT_ID}))
 same => n,ExecIf($["${AGENT_ID}" != ""]?Set(CDR(agent_id)=${AGENT_ID}))
 same => n,GotoIf($[${DIALPLAN_EXISTS(internal,${EXTEN},1)}]?internal)
 same => n,Set(CDR(direction)=out)
 same => n,Goto(outgoing,${EXTEN},1)
 same => n(internal),Set(CDR(direction)=internal)
 same => n,Goto(internal,${EXTEN},1)
[outgoing]
exten => _[6-9]XXXXXXXX,1,Goto(outgoing,34${EXTEN},1)   ; dst in E.164: it is the rated number
exten => _34X.,1,Set(CDR(destination_trunk)=carrier1)
 same => n,Dial(PJSIP/${EXTEN}@carrier1)
```

Asterisk writes one CDR per pair of channels in a bridge. A call the agent transfers to an outside number leaves two legs with the same `uniqueid` and `linkedid`: `in` (caller ↔ agent) and `out` (caller ↔ outside number, with `Set(CDR(direction)=out)` before going to `outgoing`). The `out` leg keeps the CDR variables of the first one, so it is billed to the same tenant and agent. Legs of Local channels carry no tags and are ignored.

**Rating** is not done here: elokia-billing only reads `cdr`, copies the tagged legs to its own database and rates them there (price lists, tenants, carriers, balances). The `cdr` table has the tags only, no rating columns.

`tests/cdr-tags/run.sh` places real calls (DDI to an account and to an agent, a transfer, an outgoing and an internal call) between static accounts and checks the tags they leave.

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

