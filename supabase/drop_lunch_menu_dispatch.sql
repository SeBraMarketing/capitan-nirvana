-- ═══════════════════════════════════════════════════════════════════
-- 2026-06-12 — Capi: eliminación del gate de mediodía / menú de almuerzos
--
-- El workflow n8n DgHRnNKolFrf74QE ya no tiene la rama de mediodía:
-- desde el 2026-06-12 el bot solo opera a partir de las 4:00pm (Bogotá)
-- y antes de esa hora guarda silencio total. Los nodos "Try Dispatch
-- Lunch Menu", "¿Primer mensaje del día?" y "WA Menú Almuerzos" fueron
-- eliminados, por lo que la RPC y la tabla de dedup quedaron huérfanas.
--
-- Revierte la migración lunch_menu_dispatch.sql (2026-05-29).
-- Idempotente: DROP ... IF EXISTS.
-- ═══════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.bot_lunch_menu_try_dispatch(text);

DROP TABLE IF EXISTS public.bot_lunch_menu_dispatch;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- 1. La función ya no existe:
--    SELECT proname FROM pg_proc WHERE proname = 'bot_lunch_menu_try_dispatch';
--    -- → 0 filas
--
-- 2. La tabla ya no existe:
--    SELECT tablename FROM pg_tables WHERE tablename = 'bot_lunch_menu_dispatch';
--    -- → 0 filas
-- ═══════════════════════════════════════════════════════════════════
