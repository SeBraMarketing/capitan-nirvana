# CRM — Mover etapa manual, tick de notificación y tarjeta por color

Implementación del 2026-06-13. Backend listo (SQL + workflow n8n `DgHRnNKolFrf74QE`).
Falta el frontend del CRM (esta spec).

---

## 1. Mover etapa del pedido + tick "Notificar al cliente"

### Endpoint
```
POST https://sebra-n8n.425urt.easypanel.host/webhook/crm-order-action
Header de auth:  (la misma credencial "CRM Webhook Auth" del webhook de nudges)
Content-Type: application/json
```

### Body
```json
{
  "order_id": "CN20260613123",
  "action":   "prep",
  "notify":   true,
  "actor":    "Nombre del gestor",
  "reason":   "",
  "new_address": ""
}
```

| Campo | Req | Notas |
|-------|-----|-------|
| `order_id` | sí | ID del pedido (CN…) |
| `action` | sí | una de: `verify` · `reject` · `prep` · `out` · `delivered` · `cancel` · `mark_incident` · `resolve_incident` · `change_address` |
| `notify` | no | **default `true`** → el cliente recibe WhatsApp. `false` → cambio silencioso (solo cocina). |
| `actor` | no | gestor que mueve la etapa (queda en el log y en el aviso de Telegram) |
| `reason` | no | requerido visualmente para `mark_incident` |
| `new_address` | no | requerido para `change_address` |

### Mapa de etapas (botón → action)
| Etapa / botón del CRM | `action` | Resultado en BD |
|---|---|---|
| Verificar pago | `verify` | payment_status=verified, order_status=accepted |
| Rechazar pago | `reject` | payment_status=rejected |
| En preparación | `prep` | order_status=preparing |
| Salió a entregar | `out` | order_status=out_for_delivery |
| Entregado | `delivered` | order_status=delivered |
| Cancelar | `cancel` | order_status=cancelled |
| Marcar novedad | `mark_incident` | has_incident=true (tarjeta roja) |
| Resolver novedad | `resolve_incident` | has_incident=false |

> Las transiciones respetan la **matriz de validez** del backend (ej. no se puede `prep` sin pago verificado). Si el gestor intenta una transición inválida, el endpoint responde `ok:false` con el motivo — el CRM debe mostrar ese mensaje y **no** cambiar la tarjeta.

### Respuesta (síncrona)
```jsonc
// éxito
{ "ok": true, "order_id": "CN…", "new_status": "preparing", "payment_status": "verified", "notified": true }
// transición inválida
{ "ok": false, "error": "⚠️ Falta verificar pago antes de preparar (pago: pending, estado: received)", "order_id": "CN…" }
```

### UI sugerida en la tarjeta
- Dropdown o botonera de etapas (deshabilita las inválidas según estado actual si quieres, o deja que el backend valide).
- Checkbox **"Notificar al cliente"** → **marcado por defecto**. Mapea a `notify`.
- Al responder `ok:true`: refresca la tarjeta a `new_status`. Al `ok:false`: toast con `error`.

---

## 2. Tarjeta cambia de color por intervención humana

### Fuente de datos: view `crm_cards` (una fila por cliente)
```sql
SELECT phone, customer_name, order_id, order_status, payment_status, total_cop,
       has_incident, needs_human, needs_human_reason, bot_paused, paused_until,
       card_color
FROM crm_cards
ORDER BY (card_color='red') DESC, updated_at DESC;
```

Vía PostgREST (lo que consume el frontend):
```
GET {SUPABASE_URL}/rest/v1/crm_cards?order=updated_at.desc
Headers:
  apikey: <SUPABASE_ANON_KEY>
  Authorization: Bearer <JWT del usuario autenticado>
```
> ⚠️ **`crm_cards` requiere sesión autenticada (rol `authenticated`), NO la anon key sola.** La view es `security_invoker = true`: aplica la RLS por tenant de `orders`/`bot_sessions` bajo el usuario que consulta, así que el JWT debe ser de un usuario del restaurante. Con solo la anon key → `permission denied` / 0 filas (tarjetas vacías). Si el CRM no autentica usuarios finales, consúmela desde un backend con `service_role`.

### `card_color`
| Valor | Cuándo | Color UI sugerido | Significado |
|---|---|---|---|
| `red` | `needs_human = true` **o** `has_incident = true` | 🔴 rojo | **Atender YA** — el cliente espera atención manual o hay novedad |
| `amber` | bot pausado (`bot_paused = true`) | 🟠 ámbar | Alguien ya está atendiendo (bot en pausa) |
| `normal` | resto | ⚪ normal | Bot operando solo |

`needs_human` se enciende automáticamente cuando:
- el cliente pide humano, se queja o cancela (rama HANDOFF del bot), o
- el bot tiene un error técnico procesando su mensaje.

`needs_human_reason` trae el motivo (ej. `QUEJA: comida fría` / `Error técnico del bot`).

### Apagar el rojo / reactivar el bot
El botón **"▶ Activar bot"** de la tarjeta debe llamar:
```
POST {SUPABASE_URL}/rest/v1/rpc/reanudar_bot
Headers:  apikey: <SUPABASE_ANON_KEY>   ·   Authorization: Bearer <SUPABASE_ANON_KEY o JWT>
Content-Type: application/json
Body: { "p_phone": "573108428308" }
```
`reanudar_bot` ahora **quita la pausa Y limpia `needs_human`** en una sola llamada → la tarjeta vuelve a verde. Es `SECURITY DEFINER`, así que funciona con la anon key (no necesita usuario autenticado para escribir).

Para encender/limpiar la bandera manualmente desde el CRM (opcional):
```
POST {SUPABASE_URL}/rest/v1/rpc/set_needs_human
Headers:  apikey: <SUPABASE_ANON_KEY>   ·   Authorization: Bearer <SUPABASE_ANON_KEY o JWT>
Body: { "p_phone": "573108428308", "p_value": true,  "p_reason": "motivo" }   // rojo
Body: { "p_phone": "573108428308", "p_value": false }                          // limpia
```

> `{SUPABASE_URL}` = la URL del proyecto Supabase CN (`https://vowuwpqahwrcvjqqgipc.supabase.co`). Ambas RPC (`reanudar_bot`, `set_needs_human`) están expuestas a `anon`, así que la anon key del CRM basta para llamarlas — los mismos headers que ya usas para el GET de `crm_cards`.
Las novedades de pedido se limpian con la acción `resolve_incident` (sección 1).

### Realtime (opcional)
`needs_human` vive en `bot_sessions` y `has_incident` en `orders` — ambas tablas son subscribibles por Supabase Realtime si el CRM quiere refrescar el color sin polling. La view `crm_cards` se consulta con un GET normal de PostgREST.

---

## 3. Despliegue
1. Ejecutar `supabase/add_crm_manual_stage_and_needs_human.sql` en el SQL Editor de Supabase CN (idempotente).
2. El workflow n8n ya está activo con la rama `crm-order-action` y los nodos `set_needs_human`.
3. Frontend del CRM: botonera de etapa + checkbox notificar + binding de `card_color`.
