# Supabase migration — Capitán Nirvana

Setup completo de Postgres en Supabase reemplazando NocoDB.

## Archivos

| Archivo | Qué hace |
|---|---|
| `schema.sql` | DDL completo: 7 tablas + enums + índices + triggers + RLS + 2 vistas. **Idempotente** (re-ejecutable). |
| `generate_seed.py` | Script Python que lee los JSONs locales y produce `seed.sql`. |
| `seed.sql` | INSERTs de datos seed (menu 107, faqs 25, zones 10). Generado, no editar a mano. |
| `barrios_migration.sql` | **Migración barrios (2026-05-17)**: crea tabla `barrios`, reemplaza `delivery_zones` con 6 zonas, agrega RPC `get_zone_by_address`, actualiza `upsert_order`. Ejecutar antes del seed de barrios. |
| `generate_barrios_seed.py` | Script Python que lee `barrios_pasto_supabase.csv` y produce `barrios_seed.sql`. |
| `barrios_seed.sql` | INSERTs de 396 barrios de Pasto. Generado, no editar a mano. |
| `barrios_pasto_supabase.csv` | Fuente CSV original de barrios (slug, nombre, comuna, zona, coords). |
| `security_fixes.sql` | Fixes de los 4 errores del Supabase Security Linter (vistas security_invoker + RLS en n8n_chat_memory_cn). |
| `crm_schema.sql` | **Mini-CRM Fase 0**: multi-tenant (restaurants, restaurant_members, restaurant_id), `order_status_events`, RLS. Aditivo, no rompe el bot. |
| `crm_functions.sql` | **Mini-CRM Fase 0**: `apply_order_action` (transición+mensaje, fuente única) + analítica (`crm_kpis`, `crm_top_dishes`, `crm_time_metrics`, `crm_heatmap`). |
| `crm_catalog_rls.sql` | RLS de solo-lectura sobre `delivery_zones` para usuarios `authenticated` (el CRM muestra los nombres de zona). |
| `reset_test_data.sql` | Utilitario de QA: `TRUNCATE` de pedidos/conversaciones/clientes para arrancar pruebas E2E limpias. Conserva menú, barrios, zonas, restaurantes. |

## Orden de ejecución

### 1. Schema (5 min)

1. Supabase Studio → **SQL Editor** → **New query**
2. Pegar todo el contenido de `schema.sql`
3. **Run**
4. Verificar:
   ```sql
   SELECT table_name FROM information_schema.tables
   WHERE table_schema = 'public' ORDER BY table_name;
   ```
   Debe devolver: `conversations, customer_addresses, customers, delivery_zones, faqs, menu, orders` (7 tablas).

### 2. Seed (2 min)

1. SQL Editor → **New query**
2. Pegar contenido de `seed.sql`
3. **Run**
4. Verificar counts:
   ```sql
   SELECT 'menu' AS t, count(*) FROM menu
   UNION ALL SELECT 'faqs', count(*) FROM faqs
   UNION ALL SELECT 'delivery_zones', count(*) FROM delivery_zones;
   ```
   Esperado: menu 107, faqs 25, delivery_zones 6 (post-migración barrios).

### 3. Migración barrios (2026-05-17)

**Solo si ya tienes el schema + seed cargado.**

1. SQL Editor → pegar `barrios_migration.sql` → **Run**
2. SQL Editor → pegar `barrios_seed.sql` → **Run**
3. Verificar:
   ```sql
   SELECT zona, count(*) FROM barrios GROUP BY zona ORDER BY zona;
   -- Esperado: FUERA 66, Zona 1 49, Zona 2 41, Zona 3 135, Zona 4 70, Zona 5 35

   SELECT zone_name, fee_cop, eta_minutes, is_active FROM delivery_zones ORDER BY zone_name;
   -- 6 filas: Zona 1($6000), Zona 2($6500), Zona 3($7000), Zona 4($7500), Zona 5($8000), FUERA($12000)

   SELECT * FROM get_zone_by_address('barrio Centro de Pasto');
   -- Zona 1, fee 3500
   SELECT * FROM get_zone_by_address('Mariluz II');
   -- Zona 3, fee 7000
   SELECT * FROM get_zone_by_address('barrio Aranda');
   -- FUERA, fee 0, is_active false
   ```

**Ajustar fees** en `delivery_zones` si los valores no coinciden con la política de precios:
```sql
UPDATE delivery_zones SET fee_cop = XXXXX WHERE zone_name = 'Zona X';
```

### 4. Verificar vistas

```sql
SELECT * FROM customer_stats LIMIT 5;
SELECT count(*) FROM pending_orders;
```

## Regenerar seed

Si modificas los JSONs locales (e.g. nuevos items en menu):

```sh
cd capitan-nirvana/supabase
python3 generate_seed.py
```

Regenera `seed.sql` con la data fresca. Puedes re-correrlo en Supabase (los INSERT de menu/zones tienen `ON CONFLICT DO NOTHING` para no duplicar).

## Diferencias clave vs NocoDB

| | NocoDB | Supabase Postgres |
|---|---|---|
| FK con cascade | ❌ No nativo | ✅ `ON DELETE CASCADE` |
| Enums validados | ❌ SingleSelect frágil | ✅ Tipos enum nativos |
| Constraints CHECK | ❌ | ✅ Validación a nivel DB |
| Índices custom | ❌ | ✅ B-tree + GIN para arrays |
| Vistas / Materialized views | ❌ | ✅ `customer_stats`, `pending_orders` |
| Auto `updated_at` | Parcial | ✅ Trigger genérico |
| Soft delete (cancellation) | Manual | Status enum + check |
| Idempotencia (seed) | No | `ON CONFLICT DO NOTHING` |

## Próximos pasos (después del schema + seed)

Ver el plan completo en el chat. Resumen:

1. Reapuntar n8n: nodos NocoDB → nodos Supabase/Postgres.
2. Modificar AI Agent para nombre obligatorio + flujo direcciones + ubicación WA.
3. Sub-workflow: upsert customer + customer_address antes de insert order.
4. Borrar stack NocoDB de EasyPanel.
5. Setup backup diario `pg_dump` → Storage.
6. Test E2E.
