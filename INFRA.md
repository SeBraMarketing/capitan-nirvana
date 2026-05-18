# INFRA — Capitán Nirvana

Inventario vivo del stack. Actualizar cada vez que algo cambie. **No guardar secretos aquí** — solo referencias (nombre de la credencial, dónde vive el secreto real).

---

## Diagnóstico inicial (2026-05-10)

Resultado de la auditoría post data-loss del 8-9 de mayo:

| Hallazgo | Detalle |
|---|---|
| **Backend NocoDB** | **SQLite** — `/usr/app/data/noco.db` (3.0 MB, mtime activo 2026-05-10 19:39) |
| **Env vars Postgres** | **NO existen** en el contenedor (`env \| grep -iE 'NC_DB\|DATABASE\|POSTGRES'` vacío) |
| **Conclusión** | NocoDB **nunca** estuvo en Postgres. La pérdida no fue "fallback silencioso" sino corrupción del SQLite tras el reset de password. Llevaba semanas en SQLite por defecto sin que nadie lo supiera |
| **Volumen** | `/usr/app/data` (verificar mapping en EasyPanel → Mounts) |
| **Proceso** | `node docker/index.js` (PID 13) |
| **Backups previos** | **Ninguno**. Recuperación a mano desde `capitan-nirvana/*-current.json` |

---

## Servicios en EasyPanel (Hetzner)

| Servicio | Versión | Endpoint | Volumen / Data | Backend DB |
|---|---|---|---|---|
| NocoDB | (rellenar) | (rellenar URL) | `/usr/app/data/noco.db` | SQLite (migrar a Postgres pendiente) |
| n8n | (rellenar) | (rellenar URL) | `/home/node/.n8n` | Postgres `n8n` (verificar) |
| Postgres (master) | (rellenar) | interno EasyPanel | `/var/lib/postgresql/data` | — |
| Uptime Kuma | pendiente deploy | — | — | SQLite interno |
| restic (backup) | pendiente deploy | — | — | — |

---

## Bases NocoDB y bindings en n8n

Workflows que dependen de NocoDB. Si los IDs de tabla cambian, hay que reseleccionar en cada nodo.

| Workflow n8n | ID | Tablas NocoDB usadas |
|---|---|---|
| Capitan Nirvana - WA API Cloud | `n67Thsqagux08OM2` | menu, faqs, delivery_zones, customers, orders, conversations |
| Capitan Nirvana - Order Tools (Sub) | `ncDjKZNPGj3lGdeu` | orders, customers |

---

## Credenciales (referencias, NO valores)

| Credencial n8n | Servicio externo | Token / secreto vive en | Rotación |
|---|---|---|---|
| NocoDB CN | NocoDB API | password manager (1Password vault "CN-Infra") | 90d |
| WhatsApp Cloud CN | Meta WhatsApp API | password manager | 60d (Meta tokens caducan) |
| OpenRouter CN | OpenRouter | password manager | 90d |
| Telegram CN | `@cn_pedidos_bot` | BotFather + password manager | manual on compromise |
| Telegram SeBra Log Bot | `yIZigF832nkG4cRp` (id n8n) | BotFather | — |
| Postgres Chat Memory | Postgres `n8n` DB | EasyPanel env | con master Postgres |

---

## Telegram chats

| Chat | ID | Propósito | Bot |
|---|---|---|---|
| 🎸 Pedidos Capitán Nirvana | `-5277698778` | Notificaciones operativas a gestores | `@cn_pedidos_bot` |
| 🚨 Alertas Infra CN | (pendiente crear) | Alertas técnicas (backups, healthchecks) | `@cn_pedidos_bot` o bot logs |

---

## Volúmenes EasyPanel a respaldar

| Servicio | Path en contenedor | Volumen EasyPanel | Tamaño actual |
|---|---|---|---|
| NocoDB | `/usr/app/data` | (rellenar nombre) | ~3 MB |
| n8n | `/home/node/.n8n` | (rellenar nombre) | (rellenar) |
| Postgres | `/var/lib/postgresql/data` | (rellenar nombre) | (rellenar) |

---

## Backup destination

- **Hetzner Storage Box**: pendiente provisión (BX11, 1TB, ~€3.81/mes).
- Subuser dedicado para EasyPanel.
- Path layout: `/restic-repo-cn/` (un solo repo restic, namespaces internos por host/tag).

---

## Pendientes (orden P0 → P2)

- [x] Diagnóstico backend NocoDB
- [ ] **P0**: Snapshot manual del `noco.db` actual (en volumen + copia local)
- [ ] **P1**: Provisionar Hetzner Storage Box
- [ ] **P1**: Deploy contenedor restic + primer backup automático
- [ ] **P1**: Deploy Uptime Kuma + alertas Telegram
- [ ] **P2**: Migrar NocoDB SQLite → Postgres
- [ ] **P2**: Workflows n8n versionados a git privado
- [ ] **P2**: Primer restore drill
