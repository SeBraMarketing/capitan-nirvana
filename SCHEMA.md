# SCHEMA — Capitán Nirvana NocoDB

Schema completo de las 6 tablas. **Crear en este orden** (las relaciones dependen de tablas existentes).

NocoDB añade automáticamente a cada tabla:
- `Id` (Number, autoincrement, PK técnica)
- `CreatedAt`, `UpdatedAt` (DateTime, automáticos)

---

## Orden de creación

1. `menu`
2. `faqs`
3. `delivery_zones`
4. `customers`
5. `customer_addresses` (link a `customers`, HasMany)
6. `orders` (link a `customers` + `delivery_zones` + `customer_address`)
7. `conversations` (link a `customers`)
8. **Después** de tener `orders` con datos: agregar Rollups en `customers`

---

## 1. `menu`

| Campo | Tipo | Notas |
|---|---|---|
| `name` | SingleLineText | Único. Marca **Unique**. |
| `category` | SingleSelect | Opciones: `Bebidas`, `Sodas Especiales`, `Tostones`, `Hamburguesas`, `Mexican Food`, `Pastas`, `Sandwich`, `Comida Rápida`, `Picadas`, `Cajita Rockera`, `Acompañamientos`, `Proteínas`, `Salsas`, `Bubbles` |
| `description` | LongText | — |
| `base_price_cop` | Currency | Locale `es-CO`, símbolo `$`, sin decimales |
| `variants_json` | LongText | JSON serializado (e.g. tamaños con precios). Acepta null |
| `options_json` | LongText | JSON serializado (opciones de configuración). Acepta null |
| `flavors` | LongText | Lista coma-separada. Ej: `Mora,Mango,Maracuya,Fresa`. Acepta null |
| `serves_people` | Number | Entero. Default `1` |
| `available` | Checkbox | Boolean. Default `true` (1) |
| `prep_minutes` | Number | Entero |
| `tags` | LongText | Lista coma-separada. Ej: `sin-alcohol,vegetariano,picante`. **No SingleSelect** porque hay muchos tags y son flexibles |
| `modificable` | Checkbox | Boolean. Default `false` |
| `modificaciones` | LongText | Lista coma-separada. Ej: `Sin Azúcar,Sin Hielo`. Acepta null |
| `adicionable` | Checkbox | Boolean. Default `false` |
| `adiciones` | LongText | Lista coma-separada con precios JSON inline si aplica |
| `vendible_solo` | Checkbox | Boolean. Si false, solo es adición, no se puede pedir solo |

**Sin relaciones directas.** Los items se referencian en `orders.items_json` por nombre.

---

## 2. `faqs`

| Campo | Tipo | Notas |
|---|---|---|
| `question` | SingleLineText | — |
| `answer` | LongText | Soporta WhatsApp formatting (`*bold*`, emojis) |
| `keywords` | LongText | Lista coma-separada para matching |
| `category` | SingleSelect | Opciones: `Horarios y ubicación`, `Domicilio`, `Pagos`, `Menú`, `Cancelaciones`, `Servicio` |
| `priority` | Number | Entero 1-10. Mayor = más prioritario en respuesta |
| `is_active` | Checkbox | Default `true` |

**Sin relaciones.**

---

## 3. `delivery_zones`

| Campo | Tipo | Notas |
|---|---|---|
| `zone_name` | SingleLineText | Único. Marca **Unique** |
| `keywords` | LongText | Lista coma-separada para matching de barrios |
| `fee_cop` | Currency | Locale `es-CO`, sin decimales |
| `eta_minutes` | Number | Entero |
| `is_active` | Checkbox | Default `true`. Zona "Fuera de cobertura" va en `false` |
| `notes` | LongText | Acepta null |

**Relación que se agregará desde `orders`**: HasMany → orders.

---

## 4. `customers`

| Campo | Tipo | Notas |
|---|---|---|
| `phone` | SingleLineText | **Unique**. Formato `573XXXXXXXXX` (sin +). Captura del webhook WA |
| `name` | SingleLineText | **Obligatorio**. Bot no crea order sin nombre |
| `preferred_payment` | SingleSelect | Opciones: `Nequi`, `Bancolombia` |
| `is_blocked` | Checkbox | Default `false` |
| `notes` | LongText | — |

**Direcciones**: viven en tabla `customer_addresses` (HasMany). Ver sección 4b.

**Campos calculados (Rollup) — agregar DESPUÉS de crear `orders`:**

| Campo | Tipo | Configuración |
|---|---|---|
| `total_orders` | **Rollup** | Función: `COUNT`, sobre relación con `orders` |
| `total_spent_cop` | **Rollup** | Función: `SUM`, campo `orders.total_cop` |
| `last_order_at` | **Rollup** | Función: `MAX`, campo `orders.created_at` |

**Relación**: HasMany → orders + HasMany → customer_addresses.

---

## 4b. `customer_addresses`

Una fila por dirección. Un customer puede tener N direcciones (sin límite duro).

| Campo | Tipo | Notas |
|---|---|---|
| `customer` | **LinkToAnotherRecord** | Hacia `customers`. Many To One |
| `label` | SingleLineText | Etiqueta opcional: "Casa", "Mamá", "Trabajo". Acepta null |
| `address` | LongText | Dirección textual completa |
| `address_lat` | Decimal | Precisión 6. Viene de mensaje `location` de WhatsApp |
| `address_lng` | Decimal | Precisión 6. Viene de mensaje `location` de WhatsApp |
| `is_default` | Checkbox | Marca la dirección preferida |
| `times_used` | Number | Contador de uso (incrementado por n8n en cada order) |
| `last_used_at` | DateTime | Timestamp de última order a esta dirección |

**Lógica del bot**:
- Cliente nuevo → pide nombre + dirección + ubicación WA → crea customer + crea customer_address (is_default=true)
- Cliente recurrente con 1 dirección → "¿pedido para [dirección]?" → si sí, usa esa
- Cliente recurrente con N direcciones → lista todas, cliente elige
- Cliente da dirección nueva → "¿quieres registrarla para futuros pedidos?" → si sí, pide compartir ubicación WA → crea customer_address
- Cliente dice "borra dirección X" → eliminar customer_address

---

## 5. `orders`

| Campo | Tipo | Notas |
|---|---|---|
| `order_id` | SingleLineText | **Unique**. Formato `CN<YYYYMMDD><###>` (e.g. `CN20260510047`) |
| `customer` | **LinkToAnotherRecord** | Hacia `customers`. BelongsTo. Display: `phone` |
| `customer_address` | **LinkToAnotherRecord** | Hacia `customer_addresses`. BelongsTo. Cuál de las direcciones del customer se usa en este pedido |
| `customer_phone` | SingleLineText | Cache para búsquedas rápidas |
| `customer_name` | SingleLineText | Cache del nombre |
| `address` | LongText | Snapshot textual de la dirección al momento del pedido |
| `address_lat` | Decimal | Snapshot lat (de customer_address.address_lat al momento) |
| `address_lng` | Decimal | Snapshot lng |
| `delivery_zone` | **LinkToAnotherRecord** | Hacia `delivery_zones`. BelongsTo |
| `items_json` | LongText | JSON con array de items pedidos. Esquema: `[{name, qty, variant, price, notes}]` |
| `subtotal_cop` | Currency | Suma items |
| `delivery_fee_cop` | Currency | Tarifa zona |
| `total_cop` | Currency | subtotal + delivery_fee |
| `payment_method` | SingleSelect | Opciones: `Nequi`, `Bancolombia` |
| `payment_proof_url` | URL | URL del comprobante (foto enviada por WA). Acepta null |
| `payment_status` | SingleSelect | Opciones: `pending`, `verified`, `rejected`. Default `pending` |
| `order_status` | SingleSelect | Opciones: `received`, `accepted`, `preparing`, `out_for_delivery`, `delivered`, `cancelled`. Default `received` |
| `scheduled_for` | DateTime | Para pedidos programados. Acepta null |
| `special_instructions` | LongText | Acepta null |
| `accepted_at` | DateTime | Acepta null |
| `delivered_at` | DateTime | Acepta null |
| `cancelled_at` | DateTime | Acepta null |
| `cancellation_reason` | LongText | Acepta null |
| `telegram_message_id` | SingleLineText | ID del mensaje en chat de gestores. Para editar/responder. Acepta null |

**Relaciones (BelongsTo)**:
- `customer` → `customers` (por phone)
- `delivery_zone` → `delivery_zones` (por zone_name)

---

## 6. `conversations`

| Campo | Tipo | Notas |
|---|---|---|
| `phone` | SingleLineText | Indexado para queries por sesión |
| `direction` | SingleSelect | Opciones: `in`, `out` |
| `message_text` | LongText | — |
| `wa_message_id` | SingleLineText | ID de WhatsApp para idempotencia. **Unique** |
| `tokens_in` | Number | Entero. Default `0` |
| `tokens_out` | Number | Entero. Default `0` |
| `model_used` | SingleLineText | Ej: `openai/gpt-4o-mini` |
| `cost_usd` | Decimal | Precisión 6 |

**Relación opcional**: BelongsTo → `customers` por phone (útil para vista "todas las convers de un cliente").

---

## Pasos post-creación de tablas

### 1. Ajustar Display Field de cada tabla
- `menu` → display = `name`
- `faqs` → display = `question`
- `delivery_zones` → display = `zone_name`
- `customers` → display = `phone` (único y estable; `name` puede repetirse o cambiar)
- `orders` → display = `order_id`
- `conversations` → display = `wa_message_id`

### 2. Crear vistas útiles
- `orders` → vista filtrada "Pedidos pendientes" (`payment_status = pending` OR `order_status IN (received, accepted, preparing)`)
- `customers` → vista "Top spenders" ordenada por `total_spent_cop` desc
- `menu` → vista "Disponibles" filtrada (`available = true AND vendible_solo = true`)

### 3. Generar API token
NocoDB UI → Account Settings → Tokens → New Token. Guardar en password manager + actualizar credencial `NocoDB CN` en n8n.

### 4. Reseleccionar bases en nodos n8n
Los IDs de tabla cambiaron al recrear NocoDB. En cada workflow, abrir cada nodo NocoDB y reseleccionar:
- Workspace
- Base
- Tabla

Workflows afectados:
- `Capitan Nirvana - WA API Cloud` (`n67Thsqagux08OM2`) — múltiples nodos
- `Capitan Nirvana - Order Tools (Sub)` (`ncDjKZNPGj3lGdeu`) — 2 nodos

---

## Importación de datos

Los JSONs locales tienen exactamente la estructura de los campos de arriba. Para cada tabla:

1. NocoDB UI → tabla → menú `…` → Import → Upload JSON
2. Mapear columnas (auto-mapea por nombre, verificar)
3. Import

JSONs:
- `menu-v2.json` → tabla `menu`
- `faqs.json` → tabla `faqs`
- `delivery_zones.json` → tabla `delivery_zones`
- `customers-current.json` → tabla `customers`
- `orders-current.json` → tabla `orders`
- `conversations-current.json` → tabla `conversations`

**Importar `orders` después** de tener `customers` y `delivery_zones` para que las relaciones se resuelvan.
