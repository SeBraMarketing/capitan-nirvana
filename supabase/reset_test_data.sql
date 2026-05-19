-- ═══════════════════════════════════════════════════════════════════
-- Capitán Nirvana — Reset de DATOS DE PRUEBA (empezar de cero limpio)
-- Fecha: 2026-05-18
-- Ejecutar en Supabase SQL Editor. Re-ejecutable.
--
-- BORRA (datos transaccionales/de prueba):
--   orders, order_status_events, conversations,
--   n8n_chat_memory_cn (memoria del bot), customers,
--   customer_addresses, bot_pauses, analytics_turns
--
-- CONSERVA (NO se toca):
--   menu (107), faqs, delivery_zones (6), barrios (396),
--   restaurants + restaurant_members (tu usuario gestor sigue
--   enlazado → CRM login + RLS siguen funcionando),
--   TODAS las funciones/RPC.
--
-- Resultado: bot arranca sin memoria (chat 100% nuevo), tablero CRM
-- vacío hasta que entren pedidos nuevos, sistema intacto y listo.
-- ═══════════════════════════════════════════════════════════════════

TRUNCATE
    orders,
    order_status_events,
    conversations,
    n8n_chat_memory_cn,
    customers,
    customer_addresses,
    bot_pauses,
    analytics_turns
RESTART IDENTITY CASCADE;

-- ─── Verificación (todo debe dar 0) ───────────────────────────────
SELECT 'orders'              AS tabla, count(*) FROM orders
UNION ALL SELECT 'order_status_events', count(*) FROM order_status_events
UNION ALL SELECT 'conversations',       count(*) FROM conversations
UNION ALL SELECT 'n8n_chat_memory_cn',  count(*) FROM n8n_chat_memory_cn
UNION ALL SELECT 'customers',           count(*) FROM customers
UNION ALL SELECT 'customer_addresses',  count(*) FROM customer_addresses
UNION ALL SELECT 'bot_pauses',          count(*) FROM bot_pauses
UNION ALL SELECT 'analytics_turns',     count(*) FROM analytics_turns;

-- ─── Confirmar que lo importante SIGUE ahí (no deben dar 0) ───────
SELECT 'menu' AS tabla, count(*) FROM menu
UNION ALL SELECT 'barrios',         count(*) FROM barrios
UNION ALL SELECT 'delivery_zones',  count(*) FROM delivery_zones
UNION ALL SELECT 'restaurants',     count(*) FROM restaurants
UNION ALL SELECT 'restaurant_members', count(*) FROM restaurant_members;
-- Esperado: menu 107, barrios 396, delivery_zones 6,
--           restaurants 1, restaurant_members ≥1 (tu gestor).
