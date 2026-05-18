#!/bin/sh
# restic-backup.sh — Backup diario de Capitán Nirvana
# Diseñado para correr dentro de un contenedor Alpine con restic instalado.
# Variables esperadas (vía env): RESTIC_REPOSITORY, RESTIC_PASSWORD, HEALTHCHECK_URL,
# POSTGRES_HOST, POSTGRES_USER, POSTGRES_PASSWORD, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID

set -eu

LOG_PREFIX="[$(date -Iseconds)] [restic-backup]"
log() { echo "$LOG_PREFIX $*"; }

notify_telegram() {
    [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && return 0
    [ -z "${TELEGRAM_CHAT_ID:-}" ] && return 0
    msg="$1"
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${msg}" \
        -d "parse_mode=HTML" > /dev/null || true
}

ping_healthcheck() {
    [ -z "${HEALTHCHECK_URL:-}" ] && return 0
    suffix="${1:-}"
    curl -fsS --retry 3 "${HEALTHCHECK_URL}${suffix}" > /dev/null || true
}

trap_err() {
    code=$?
    log "FAILED with exit code $code"
    notify_telegram "🚨 <b>Backup CN FAILED</b>%0Aexit=$code%0Asee logs"
    ping_healthcheck "/fail"
    exit $code
}
trap trap_err ERR

ping_healthcheck "/start"
log "Backup start"

# 1. Init repo si no existe (idempotente)
restic snapshots > /dev/null 2>&1 || {
    log "Initializing restic repo"
    restic init
}

# 2. NocoDB SQLite (mientras esté en SQLite)
if [ -f /mnt/nocodb-data/noco.db ]; then
    log "Backing up NocoDB SQLite"
    restic backup /mnt/nocodb-data \
        --tag nocodb --tag sqlite \
        --host capitan-nirvana
fi

# 3. NocoDB Postgres (cuando se migre)
if [ -n "${POSTGRES_HOST:-}" ] && [ -n "${POSTGRES_DB_NOCODB:-}" ]; then
    log "Dumping NocoDB Postgres"
    PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
        -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB_NOCODB" \
        | restic backup --stdin --stdin-filename "nocodb-${POSTGRES_DB_NOCODB}.sql" \
            --tag nocodb --tag postgres --host capitan-nirvana
fi

# 4. n8n volumen (encryption key + binary data)
if [ -d /mnt/n8n-data ]; then
    log "Backing up n8n volume"
    restic backup /mnt/n8n-data \
        --tag n8n --tag data \
        --host capitan-nirvana
fi

# 5. n8n Postgres
if [ -n "${POSTGRES_HOST:-}" ] && [ -n "${POSTGRES_DB_N8N:-}" ]; then
    log "Dumping n8n Postgres"
    PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
        -h "$POSTGRES_HOST" -U "$POSTGRES_USER" "$POSTGRES_DB_N8N" \
        | restic backup --stdin --stdin-filename "n8n-${POSTGRES_DB_N8N}.sql" \
            --tag n8n --tag postgres --host capitan-nirvana
fi

# 6. Postgres master (dumpall) — todas las DBs juntas
if [ -n "${POSTGRES_HOST:-}" ]; then
    log "pg_dumpall master"
    PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall \
        -h "$POSTGRES_HOST" -U "$POSTGRES_USER" \
        | restic backup --stdin --stdin-filename "postgres-dumpall.sql" \
            --tag postgres --tag dumpall --host capitan-nirvana
fi

# 7. Retención
log "Pruning old snapshots"
restic forget \
    --keep-daily 30 \
    --keep-weekly 12 \
    --keep-monthly 12 \
    --prune

# 8. Integridad rápida (subset, full check mensual)
log "Quick integrity check"
restic check --read-data-subset=5%

log "Backup OK"
ping_healthcheck
notify_telegram "✅ Backup CN OK $(date -Iseconds)"
