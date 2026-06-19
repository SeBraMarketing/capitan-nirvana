# Integración Bot WhatsApp (Capitán Nirvana) → Loggro RestoBar — Listado de preguntas

**Objetivo de la integración:** cuando un cliente confirme su pedido en nuestro bot de WhatsApp, el pedido debe entrar **automáticamente a Loggro** y generar la **comanda en cocina**, sin digitación manual.

**Lo que ya entendimos de la documentación** (https://developer.loggro.com), para que estas preguntas vayan al grano:

- El módulo **RestoBar corre sobre PirPOS**, base URL `https://api.pirpos.com`.
- **Autenticación:** `POST https://api.pirpos.com/login` con `{ email, password }` → devuelve `tokenCurrent` (JWT) y `business._id`; se usa como `Authorization: Bearer <tokenCurrent>`.
- En la referencia pública **solo encontramos documentados**: `login`, `GET/POST/PUT/DELETE /waiterOrderAreas` (áreas de pedido) y `GET /cashRegisters` (cajas).
- La introducción de RestoBar **menciona** además: Productos, Ingredientes, Inventario, Categorías, Facturas, **Pedidos de mesa (Orders)**, Clientes, Métodos de pago, Impuestos y Mesas — pero **no encontramos publicados esos endpoints**. El endpoint para **crear el pedido/comanda** es justamente lo que más necesitamos (ver pregunta 8).
- Notamos que existe un segundo sistema, **Loggro Pymes / Facturación** (`https://api.loggro.com/apik/loggro-facturacion`, basado en UUID, con `factura-venta`) para facturación electrónica DIAN. Queremos entender cómo se relaciona con el pedido de RestoBar (ver pregunta 21).

---

## Parte A — Preguntas para Loggro (equipo técnico / soporte de integraciones)

### Acceso y entorno
1. ¿Existe un **entorno de pruebas (sandbox)** separado de producción para `api.pirpos.com`? ¿Cuáles son las URLs y cómo obtenemos credenciales de prueba?
2. Al hacer login obtuvimos el error *"Usuario de POS Tienda. Por favor ingrese a la aplicación correcta (pos.loggro.com)"*. ¿Qué **tipo de usuario/rol** debemos usar para consumir la API de RestoBar? ¿Recomiendan crear un **usuario de servicio dedicado** para el bot?
3. ¿Hay alguna restricción de acceso por **IP (allowlist)**? Si la hay, ¿necesitan la IP saliente de nuestro servidor (n8n)?
4. El campo `business._id`: ¿es único por local/sede? Capitán Nirvana, ¿a qué `business` debe apuntar la integración (uno o varios locales)?

### Autenticación y manejo de sesión
5. ¿Cuánto **dura el `tokenCurrent`** (JWT)? ¿Existe *refresh token* o hay que volver a hacer login? ¿Con qué frecuencia?
6. ¿Se permiten **sesiones concurrentes** con el mismo usuario, o un nuevo login **invalida el token anterior** (vimos el campo `lastTokenDevice`)? Lo preguntamos porque el bot mantendrá una sesión de servicio permanente.
7. ¿Hay **límite de tasa (rate limit)** de peticiones por minuto o políticas de *throttling* que debamos respetar?

### Creación del pedido / comanda — **lo más importante**
8. La introducción menciona *"Orders — gestión de pedidos de mesa"*, pero en la referencia pública solo vemos `login`, `/waiterOrderAreas` y `/cashRegisters`. **¿Cuál es el endpoint para CREAR un pedido/comanda?** (path, método HTTP y estructura completa del *body*). Idealmente, ¿pueden compartirnos la **colección de Postman o el archivo OpenAPI completo** de `api.pirpos.com`?
9. Al crear el pedido, ¿la **comanda se envía a cocina automáticamente** (impresión / KDS), o se requiere una acción o cambio de estado adicional ("enviar a cocina")?
10. ¿El pedido **requiere una mesa (table) y/o un mesero**? Para **domicilios / para llevar**, ¿existe un **tipo de pedido "delivery"/"takeout"** que no dependa de una mesa?
11. ¿Cómo se **enrutan los ítems a las áreas de pedido** (`/waiterOrderAreas`)? ¿El área se define a nivel de producto, de categoría, o se envía dentro del pedido?
12. ¿Podemos enviar un **identificador externo propio** (nuestro `order_id`, formato `CN20260529###`) dentro del pedido para conciliación? ¿El endpoint maneja **idempotencia** o cómo evitamos pedidos **duplicados** ante reintentos de red?

### Catálogo / productos
13. ¿Cuál es el **endpoint de Productos** en `api.pirpos.com` (consultar y crear)? ¿Cómo se identifican los productos (`_id`)? Necesitamos esos IDs para armar las líneas del pedido.
14. ¿Cómo se representan en un producto y en una línea de pedido: **variantes** (ej. "Sencilla 200gr / Doble 400gr"), **modificaciones** ("Sin cebolla"), **adiciones** y **sabores**? ¿Cada uno tiene su propio `_id` y precio?
15. El **precio de cada línea**: ¿lo toma el POS del catálogo automáticamente, o lo enviamos nosotros? ¿Se permite *override* de precio?
16. ¿Cómo se representa el **costo del domicilio** (tarifa variable por zona) dentro del pedido? ¿Es un producto/cargo especial, un campo dedicado, o no aplica en RestoBar?

### Cliente y datos de domicilio
17. ¿Existe **endpoint de Clientes**? ¿El cliente se asocia al pedido **por teléfono**? ¿Se crea/actualiza automáticamente usando el teléfono (nuestro formato es `573XXXXXXXXX`, sin `+`)?
18. ¿En qué campos del pedido van: **nombre, teléfono de contacto, dirección de entrega, barrio/zona, coordenadas (lat/lng)** e **instrucciones especiales** ("tocar timbre", "sin cebolla")?

### Pagos
19. ¿Existe **endpoint de Métodos de pago**? ¿Cómo mapeamos **Nequi, Daviplata, Bancolombia (transferencia) y Efectivo** a los métodos de PirPOS?
20. Flujo de pago: el bot confirma el pedido, pero el pago puede quedar **pendiente** (transferencia por verificar con comprobante) o **verificado** (efectivo contra entrega). ¿Se puede crear el pedido como **no pagado** y registrar el pago después? ¿El envío de la **comanda a cocina depende del estado de pago**?
21. Al crear el pedido en RestoBar, ¿se **genera automáticamente la factura / documento electrónico DIAN**, o eso es un paso aparte (módulo de Facturación, `api.loggro.com`)?

### Estado del pedido y sincronización de vuelta
22. ¿Podemos **consultar el estado** de un pedido por su `_id` o código? ¿Qué **estados** maneja el ciclo (recibido, en preparación, listo, despachado, entregado, cancelado)?
23. ¿Existen **webhooks / callbacks** que nos notifiquen cuando cambia el estado (por ejemplo, cuando cocina marca "listo")? Si no, ¿la única opción es hacer *polling*? Esto es clave para que el bot le avise al cliente "tu pedido va en camino".
24. ¿Se puede **cancelar/anular** un pedido por API, y en qué estados es posible?

### Operación y soporte
25. ¿Manejan **versionado de la API** y **changelog**? ¿Cómo nos avisan de cambios que puedan romper la integración?
26. ¿Cuál es el **canal de soporte técnico** para integraciones y su SLA? ¿Hay un contacto o ingeniero asignado al que podamos escribir?

---

## Parte B — Preguntas para Capitán Nirvana (operativo / administración del Loggro)

27. ¿Los **107 ítems del menú** ya están cargados en Loggro/PirPOS con **nombre y precio idénticos** a los del bot? ¿Quién mantiene el catálogo: ustedes en el POS, o lo sincronizamos por API?
28. ¿**Quién administra la cuenta de Loggro/PirPOS** y tiene permisos para generar credenciales y configurar áreas de pedido, cajas y menú?
29. ¿La cocina **usa hoy la comanda/KDS de Loggro**, o trabajan con papel? ¿Cómo entran **hoy los domicilios** al sistema (manual)? Queremos espejar exactamente ese flujo.
30. ¿Hay una **caja registradora** (`/cashRegisters`) y un **área de pedido** específicas que deba usar el bot? ¿Cuáles son sus `_id`?
31. ¿Capitán Nirvana **requiere factura electrónica DIAN** por cada pedido del bot, o basta con el documento POS / tirilla interna?

---

*Documento generado para preparar la integración. Una vez tengamos las respuestas (sobre todo a las preguntas 8 y 13), podemos construir y probar la conexión.*
