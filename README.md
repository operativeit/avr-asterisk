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

You can override these configurations by mounting your own configuration files to `/etc/asterisk/` in the container.

### Default Ports

- 5038: Asterisk Manager Interface (AMI)
- 8088: HTTP API
- 10000-20000: RTP ports for media streaming

## Environment Variables

- `TZ`: Timezone (default: Europe/Rome)

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

