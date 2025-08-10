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

exec "$@"

