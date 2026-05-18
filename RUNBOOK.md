# RUNBOOK — Disaster Recovery Capitán Nirvana

Procedimientos para incidentes. **Leer en frío, ejecutar en caliente.** Si lees esto en pánico, respira, sigue los pasos en orden y NO improvises.

Cada procedimiento incluye RTO target (tiempo máximo aceptable de recuperación).

---

## Pre-requisitos comunes

Antes de cualquier restore necesitas a la mano:

1. Acceso SSH al host EasyPanel (Hetzner).
2. Credenciales del Hetzner Storage Box (SFTP user + path).
3. **Restic repository password** — vive en password manager personal (vault "CN-Infra"). Sin esto, los backups son ilegibles.
4. Acceso a panel EasyPanel (admin).
5. Repo git privado de workflows n8n (URL en INFRA.md).

---

## Procedimiento 1: NocoDB perdido o corrupto

**RTO: < 1 hora**

### Síntomas
- NocoDB UI no carga / error 500.
- Tablas aparecen vacías o con menos filas que las esperadas.
- Login admin no funciona.

### Diagnóstico rápido (5 min)
```sh
# En consola Sh del contenedor NocoDB
ls -lh /usr/app/data/
# Si noco.db existe pero corrupto: tamaño 0 o mtime sospechoso
sqlite3 /usr/app/data/noco.db "SELECT count(*) FROM nc_models;"
# Si tira error de "file is not a database" → corrupción confirmada
```

### Restore desde restic (SQLite)
```sh
# Desde host EasyPanel, NO dentro del contenedor NocoDB
export RESTIC_REPOSITORY=sftp:u123456@u123456.your-storagebox.de:/restic-repo-cn
export RESTIC_PASSWORD=$(cat /root/.secrets/restic-password)

# Listar snapshots
restic snapshots --tag nocodb

# Restaurar el más reciente a un staging dir
restic restore latest --tag nocodb --target /tmp/nocodb-restore

# Detener NocoDB en EasyPanel UI (botón Stop)
# Reemplazar el archivo
docker volume inspect <nombre-volumen-nocodb>  # confirmar mountpoint
cp /tmp/nocodb-restore/usr/app/data/noco.db /var/lib/docker/volumes/<volumen>/_data/noco.db
chown root:root /var/lib/docker/volumes/<volumen>/_data/noco.db

# Arrancar NocoDB en EasyPanel UI
# Validar: login + count de filas en cada tabla
```

### Restore desde restic (Postgres, post-migración)
```sh
restic dump latest --tag nocodb-pg nocodb.sql > /tmp/nocodb.sql
# Recrear DB
psql -U postgres -c "DROP DATABASE nocodb;"
psql -U postgres -c "CREATE DATABASE nocodb;"
psql -U postgres nocodb < /tmp/nocodb.sql
# Restart NocoDB
```

### Post-restore
- [ ] Login admin OK
- [ ] Cada tabla muestra count esperado (comparar contra último daily summary)
- [ ] **Reseleccionar credencial NocoDB en cada nodo n8n** si los IDs de tabla cambiaron
- [ ] Lanzar pedido de prueba end-to-end
- [ ] Notificar a Telegram `🚨 Alertas Infra CN`: "Restore NocoDB completado a snapshot YYYY-MM-DD"

---

## Procedimiento 2: n8n perdido o corrupto

**RTO: < 2 horas**

### Crítico
n8n encripta credenciales con `N8N_ENCRYPTION_KEY`. **Sin esta key, las credentials del backup son basura inservible.** La key vive en `/home/node/.n8n/config` y se respalda con el resto.

### Restore
```sh
# Restaurar Postgres DB n8n
restic dump latest --tag n8n-pg n8n.sql > /tmp/n8n.sql
psql -U postgres -c "DROP DATABASE n8n;"
psql -U postgres -c "CREATE DATABASE n8n;"
psql -U postgres n8n < /tmp/n8n.sql

# Restaurar /home/node/.n8n (encryption key + binary data)
restic restore latest --tag n8n-data --target /tmp/n8n-restore
# Reemplazar volumen vía host (n8n stopped en EasyPanel)
cp -r /tmp/n8n-restore/home/node/.n8n/* /var/lib/docker/volumes/<volumen-n8n>/_data/

# Arrancar n8n en EasyPanel
```

### Post-restore
- [ ] Login OK
- [ ] Workflows aparecen con su estado (active/inactive) correcto
- [ ] Probar 1 credencial (e.g., NocoDB) — si pide reauth, la encryption key se perdió
- [ ] Trigger manual de "Capitan Nirvana - WA API Cloud" y validar respuesta

### Si la encryption key se perdió
Recuperar workflows desde el repo git privado (Procedimiento 5) y recrear credentials a mano desde el password manager.

---

## Procedimiento 3: Servidor Hetzner caído completo

**RTO: < 4 horas**

Asume el server entero perdido (disco corrupto, hack, baremetal failure).

### Pasos
1. **Provisión nuevo server Hetzner** (mismo o mayor tier, Ubuntu LTS).
2. **Instalar EasyPanel** según docs oficiales.
3. **Instalar restic** en el host:
   ```sh
   apt install restic
   export RESTIC_REPOSITORY=sftp:u123456@u123456.your-storagebox.de:/restic-repo-cn
   export RESTIC_PASSWORD=$(cat /root/.secrets/restic-password)
   restic snapshots
   ```
4. **Recrear servicios en EasyPanel** uno a uno (NocoDB, n8n, Postgres) con los mismos nombres de volumen que tenía el original (ver INFRA.md).
5. **Restaurar volúmenes** (Procedimiento 1 + 2).
6. **Restaurar Postgres master**:
   ```sh
   restic dump latest --tag postgres-all dumpall.sql > /tmp/dumpall.sql
   psql -U postgres < /tmp/dumpall.sql
   ```
7. **Reapuntar DNS** en Cloudflare (o registrador) al nuevo IP.
8. **Reactivar webhook WhatsApp** en Meta Developers Dashboard al nuevo dominio.
9. **Reactivar workflows** en n8n.

### Post-restore
- [ ] Pedido de prueba end-to-end completo
- [ ] Telegram callback funciona
- [ ] WhatsApp recibe mensajes de cliente
- [ ] Notificar al equipo de gestores que servicio está back

---

## Procedimiento 4: API token NocoDB invalidado

**RTO: < 15 min**

### Síntomas
- Workflows n8n con error `401 Unauthorized` en nodos NocoDB.

### Pasos
1. NocoDB UI → Account Settings → Tokens → **Generate new token**.
2. Copiar token, guardar en password manager (vault "CN-Infra" → entrada "NocoDB API").
3. n8n → Credentials → "NocoDB CN" → pegar nuevo token → Save.
4. Reactivar workflows si quedaron inactivos por errores en cadena.

---

## Procedimiento 5: Workflows n8n corruptos / borrados accidentalmente

**RTO: < 30 min**

### Restore desde git
Los workflows están versionados en repo privado (cron diario los exporta — ver INFRA.md para URL).

```sh
git clone <repo-url> /tmp/wf-restore
cd /tmp/wf-restore
# Cada archivo es un workflow.json
# Importar en n8n vía UI: Workflows → Import → seleccionar JSON
# O vía API:
curl -X POST https://n8n.tudominio/api/v1/workflows \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d @capitan-nirvana-wa-cloud.json
```

### Post-restore
- [ ] Reseleccionar credenciales en cada nodo (las credentials no se exportan al JSON)
- [ ] Reactivar workflow

---

## Procedimiento 6: Storage Box Hetzner caído / inaccesible

**RTO: depende de Hetzner — generalmente < 4h en su SLA**

Mientras esté caído **NO se ejecutan backups nuevos** y **NO se pueden restaurar** los existentes. Es un single point of failure conocido.

### Mitigación a futuro (TODO post-MVP)
- Sync semanal del Storage Box a un segundo destino (Backblaze B2 o S3 Glacier) usando `rclone`.

### Si Storage Box queda permanentemente perdido
- Última línea de defensa: snapshots locales del `noco.db` en el propio volumen (creados con `cp` por el script).
- **No es backup real**, pero protege contra resets accidentales que es el escenario más frecuente.

---

## Apéndice: contactos críticos

| Quién | Rol | Cuándo escribirle |
|---|---|---|
| Manuel Serrano | Owner técnico | Cualquier incidente P0/P1 |
| Hetzner support | Provider | Server caído, Storage Box inaccesible |
| Soporte n8n cloud | (si aplica) | Issues específicos de n8n no resolubles localmente |

---

## Apéndice: comandos restic más usados

```sh
# Ver todos los snapshots
restic snapshots

# Ver snapshots de un servicio
restic snapshots --tag nocodb

# Ver qué hay en un snapshot
restic ls <snapshot-id>

# Restore selectivo
restic restore <snapshot-id> --target /tmp/restore --include /usr/app/data/noco.db

# Verificar integridad del repo (correr mensual)
restic check

# Ver espacio usado
restic stats

# Forget manual (cuidado)
restic forget --keep-daily 30 --keep-weekly 12 --prune
```
