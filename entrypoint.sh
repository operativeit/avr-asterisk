#!/bin/sh

set -e

cat <<EOF > /etc/odbc.ini
[asterisk]
Description = MySQL Server
Driver = MySQL ODBC Driver
Database = ${MYSQL_DATABASE}
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

exec "$@"

