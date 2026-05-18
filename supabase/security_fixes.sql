-- ═══════════════════════════════════════════════════════════════════
-- Capitán Nirvana — Fixes de los 4 errores del Supabase Security Linter
-- Fecha: 2026-05-17
-- Idempotente. Ejecutar en Supabase SQL Editor de una sola corrida.
--
-- NINGUNO de estos 4 errores viene de la migración de barrios.
--   #1, #2  → vistas de schema.sql (pre-existentes desde el día 1)
--   #3, #4  → tabla n8n_chat_memory_cn (autocreada por LangChain)
-- ═══════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────────
-- FIX #1 y #2 — security_definer_view en customer_stats y pending_orders
--
-- Problema: las vistas corren con permisos del CREADOR (postgres),
-- saltándose la RLS del usuario que consulta. Supabase lo marca ERROR.
--
-- Solución: security_invoker = true → la vista respeta la RLS del
-- que consulta. n8n usa service_role (bypassa RLS igual), así que
-- NO se rompe nada. anon/authenticated quedan correctamente bloqueados
-- (orders/customers ya tienen RLS sin policies para anon).
-- ───────────────────────────────────────────────────────────────────
ALTER VIEW public.customer_stats  SET (security_invoker = true);
ALTER VIEW public.pending_orders  SET (security_invoker = true);


-- ───────────────────────────────────────────────────────────────────
-- FIX #3 y #4 — RLS deshabilitada + columna sensible (session_id = teléfono)
--               expuesta vía API en n8n_chat_memory_cn
--
-- session_id contiene el CELULAR del cliente (PII). Hoy cualquiera con
-- la anon key puede leer TODO el historial de conversaciones vía
-- PostgREST. Hay que cerrar ese acceso SIN romper la memoria del bot.
--
-- Cómo accede n8n a esta tabla (3 caminos, ninguno por PostgREST anon):
--   1. Postgres Chat Memory1  → conexión directa PG (rol postgres = OWNER)
--   2. Guardar Turno Pedido/Queja/Comprobante → conexión directa PG (OWNER)
--   3. Cargar Historial → RPC get_historial_limpio (vía PostgREST)
--
-- El OWNER (postgres) saltea RLS automáticamente (no usamos FORCE RLS),
-- así que los caminos 1 y 2 siguen funcionando.
-- El camino 3 lo blindamos haciendo la función SECURITY DEFINER:
-- corre como su dueño (postgres) → lee la tabla aunque RLS la bloquee
-- para el rol anon. PostgREST con anon key pierde el acceso DIRECTO a
-- la tabla (el hueco real), pero la RPC scoped por p_phone sigue OK.
-- ───────────────────────────────────────────────────────────────────

-- 3a. get_historial_limpio → SECURITY DEFINER + search_path fijo
--     (mismo cuerpo que migration_hyundai_pattern.sql, solo se endurece)
CREATE OR REPLACE FUNCTION public.get_historial_limpio(
    p_phone text,
    p_limit int DEFAULT 20
)
RETURNS TABLE(historial_limpio text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    WITH ultimas AS (
        SELECT message, id
        FROM public.n8n_chat_memory_cn
        WHERE session_id = p_phone
        ORDER BY id DESC
        LIMIT p_limit
    )
    SELECT string_agg(
        CASE message->>'type'
            WHEN 'human' THEN 'Cliente: '
            WHEN 'ai'    THEN 'Capi: '
            ELSE ''
        END || (message->>'content'),
        E'\n'
        ORDER BY id ASC
    )
    FROM ultimas;
$$;

GRANT EXECUTE ON FUNCTION public.get_historial_limpio(text, int)
    TO anon, authenticated, service_role;

-- 3b. Encender RLS y quitar el acceso directo de anon/authenticated.
--     SIN policies permisivas → PostgREST directo queda denegado.
--     El owner (postgres, usado por n8n) saltea RLS igual → writes OK.
ALTER TABLE public.n8n_chat_memory_cn ENABLE ROW LEVEL SECURITY;

-- Limpia cualquier policy previa (idempotente)
DROP POLICY IF EXISTS n8n_chat_memory_cn_no_anon ON public.n8n_chat_memory_cn;

-- Revoca el privilegio de tabla para los roles de la API pública.
REVOKE ALL ON public.n8n_chat_memory_cn FROM anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- 1. Vistas ya NO security definer:
--    SELECT relname, reloptions FROM pg_class
--    WHERE relname IN ('customer_stats','pending_orders');
--    -> reloptions debe incluir {security_invoker=true}
--
-- 2. RLS activa en la tabla de memoria:
--    SELECT relname, relrowsecurity FROM pg_class
--    WHERE relname = 'n8n_chat_memory_cn';   -- relrowsecurity = true
--
-- 3. La RPC sigue devolviendo historial (probar con un teléfono real):
--    SELECT * FROM get_historial_limpio('573195665728');
--
-- 4. Re-correr el linter de Supabase → los 4 ERROR deben desaparecer.
--
-- Tras esto, manda un mensaje de WhatsApp de prueba: si "Cargar Historial"
-- sigue trayendo el historial, el blindaje no rompió nada.
-- ═══════════════════════════════════════════════════════════════════
