#!/bin/sh

set -e

# Create or update the databases (realtime, cdr, recordings, provision)
# before Asterisk connects. Needs MYSQL_ROOT_PASSWORD; DB_MIGRATE=no skips it.
if [ "${DB_MIGRATE:-yes}" != "no" ]; then
    if [ -n "${MYSQL_ROOT_PASSWORD:-}" ]; then
        avr-db-migrate
    else
        echo "entrypoint: MYSQL_ROOT_PASSWORD not set, skipping database migrations" >&2
    fi
fi

cat <<EOF > /etc/odbc.ini
[asterisk]
Description = MySQL Server
Driver = MySQL ODBC Driver
Database = ${MYSQL_DATABASE}
Server =  ${MYSQL_HOST}
User = ${MYSQL_USER}
Password = ${MYSQL_PASSWORD}
Port = ${MYSQL_PORT}

[cdr]
Description = MySQL Server (CDR)
Driver = MySQL ODBC Driver
Database = ${CDR_DATABASE:-cdr}
Server =  ${MYSQL_HOST}
User = ${MYSQL_USER}
Password = ${MYSQL_PASSWORD}
Port = ${MYSQL_PORT}

EOF

cat <<EOF > /etc/asterisk/res_odbc.conf
[asterisk]
enabled => yes
dsn => asterisk
username => ${MYSQL_USER}
password => ${MYSQL_PASSWORD}
pre-connect => yes

[cdr]
enabled => yes
dsn => cdr
username => ${MYSQL_USER}
password => ${MYSQL_PASSWORD}
pre-connect => yes

EOF

# Default country for indication tones (dial, busy, ring...), e.g. es, fr, it.
# Must be a section of indications.conf; otherwise the image default is kept.
if [ -n "${ASTERISK_COUNTRY:-}" ]; then
    country="$(printf '%s' "$ASTERISK_COUNTRY" | tr '[:upper:]' '[:lower:]')"
    case "$country" in
        *[!a-z]*) echo "WARNING: invalid ASTERISK_COUNTRY '$ASTERISK_COUNTRY', keeping the default" >&2 ;;
        *)
            if grep -q "^\[$country\]" /etc/asterisk/indications.conf; then
                sed -i "s/^country=[a-z]*/country=$country/" /etc/asterisk/indications.conf
            else
                echo "WARNING: ASTERISK_COUNTRY '$country' has no section in indications.conf, keeping the default" >&2
            fi
            ;;
    esac
fi

# Default language of the prompts (sounds/<language>/), e.g. es, fr, it.
# Endpoints with their own language keep it. Without sounds for it, Asterisk
# falls back to the English prompts, so that only warns.
if [ -n "${ASTERISK_LANGUAGE:-}" ]; then
    language="$ASTERISK_LANGUAGE"
    case "$language" in
        [a-z][a-z]|[a-z][a-z]_[A-Z][A-Z])
            sed -i "s/^;*defaultlanguage *=.*/defaultlanguage = $language/" /etc/asterisk/asterisk.conf
            if [ ! -d "/var/lib/asterisk/sounds/$language" ]; then
                echo "WARNING: no prompts in /var/lib/asterisk/sounds/$language; Asterisk will play the English ones" >&2
            fi
            ;;
        *) echo "WARNING: invalid ASTERISK_LANGUAGE '$ASTERISK_LANGUAGE' (expected e.g. es or pt_BR), keeping the default" >&2 ;;
    esac
fi

exec "$@"

