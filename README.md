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

- A `local` account without `password` gets a generated one: 16 characters from a cryptographically secure source (`RANDOM_BYTES`), with at least one lowercase letter, uppercase letter, digit and symbol. Symbols are limited to `! % * + - . ^ _ ~`, which need no quoting in phone configs, `.env` files, URLs or shells. Asterisk only stores its hash (`md5_cred`); `provision.accounts` keeps it readable.
- `transport` (`udp`, `tcp`, `tls`) and `port` (any) describe the remote side of `external`, `trunk` and `whatsapp` accounts; defaults are `udp` (`tls` for WhatsApp) and 5060 (5061 with `tls`).
- Default contexts: `local` → `from-phones`, `external` → `internal`, `trunk` → `from-trunk`, `whatsapp` → `from-whatsapp`.
- `agent_uuid` adds `internal/<username>` → `GoSub(avr,<agent_uuid>,1(avr-core:5001))`. DDIs become `incoming/<ddi>` → `Dial(PJSIP/<account>,…)` or `Dial(local/<agent_uuid>@internal,…)`.
- The dialplan must provide those contexts: `internal` and `incoming` with `switch => Realtime/@`, and `from-trunk` / `from-whatsapp` going to `incoming` for known DDIs.
- `UPDATE` regenerates the rows, `enabled=0` or `DELETE` removes them; `name` and `type` cannot change; accounts with DDIs cannot be deleted. Invalid rows fail with a `provision: …` error and nothing is written; names already used in Asterisk are refused.
- **Outbound registrations** (`external`, `trunk` with `register=1`): Asterisk starts a new realtime registration only once it loads it (`pjsip show registration <name>-reg`; `pjsip send register` fails with "Unable to retrieve registration" until then) and renews it by itself afterwards; a deleted one keeps running until `pjsip send unregister <name>-reg`. The triggers queue these actions in `provision.registration_queue` (`processed_at IS NULL`) for an external worker.
- PJSIP cannot restrict per endpoint the transport a request arrives on: `transports` decides which endpoints exist, not which transport is accepted.

`tests/provision/run.sh` builds the image and checks the migrations (empty and existing databases), every account type, DDIs and CDRs against helper Asterisk containers.

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

