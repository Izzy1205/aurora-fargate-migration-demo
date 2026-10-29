#!/bin/sh
# Creates or updates the app and Flyway logins. Runs as a one-off ECS task
# with the master credentials, before Flyway on every deploy. Re-running it
# is safe.
#
# Connection settings come from the standard PG* variables. The two login
# passwords come from APP_DB_PASSWORD and MIGRATOR_DB_PASSWORD. They are read
# inside psql (\getenv), so they never show up on a command line, and this
# script never echoes them.
set -eu

: "${PGHOST:?}" "${PGDATABASE:?}" "${PGUSER:?}" "${PGPASSWORD:?}"
: "${APP_DB_PASSWORD:?}" "${MIGRATOR_DB_PASSWORD:?}"
export APP_DB_USER="${APP_DB_USER:-app_user}"
export MIGRATOR_DB_USER="${MIGRATOR_DB_USER:-migrator}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"

# Aurora may be paused at zero ACUs. The first connection wakes it, so keep
# trying for about two minutes, the same as Flyway's connect retries.
tries=0
until psql -X -q -t -c 'SELECT 1' >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge 12 ]; then
    echo "Could not connect to ${PGHOST}:${PGPORT:-5432}/${PGDATABASE} after ${tries} tries." >&2
    exit 1
  fi
  echo "Database not reachable yet, retrying (${tries}/12)."
  sleep 10
done

psql -X -q -v ON_ERROR_STOP=1 -f "$(dirname "$0")/db-logins.sql"
echo "DB logins ready: ${APP_DB_USER} (rows only), ${MIGRATOR_DB_USER} (schema owner)."
