-- ═══════════════════════════════════════════════════════════════════
-- 2026-05-29 — Descartar "interesados" del tablero (soft-dismiss)
--
-- El gestor puede quitar un lead de la columna "Interesados" tras revisar
-- su chat. Es un OCULTAR reversible: marca dismissed_at, la fila permanece
-- (igual que los pedidos se cancelan en vez de borrarse) y se puede deshacer.
--
-- ⚠️ SIN MENSAJE: estas RPC solo hacen UPDATE. No tocan el webhook de nudge
-- ni YCloud, y bot_sessions no tiene triggers de mensajería → el cliente no
-- recibe nada. El bot tampoco se afecta (menu_state queda intacto).
--
-- Idempotente. Ejecutar en Supabase SQL Editor (una corrida).
-- ADITIVO: no toca el bot existente ni orders.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────
-- 1. Columna
-- ───────────────────────────────────────────────────────────────────
ALTER TABLE bot_sessions ADD COLUMN IF NOT EXISTS dismissed_at timestamptz;

-- Índice parcial: el tablero lee solo los NO descartados.
CREATE INDEX IF NOT EXISTS bot_sessions_active_lead_idx
    ON bot_sessions (restaurant_id, menu_state, created_at DESC)
    WHERE dismissed_at IS NULL;

-- ───────────────────────────────────────────────────────────────────
-- 2. RPCs (SECURITY DEFINER). Resuelven el tenant CN por slug.
--    Mismo patrón que bot_lead_invited. Solo UPDATE → no envían mensaje.
-- ───────────────────────────────────────────────────────────────────

-- 2.1 Oculta el lead del tablero (descartar).
CREATE OR REPLACE FUNCTION public.bot_dismiss_lead(p_phone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_cn bigint;
BEGIN
    SELECT id INTO v_cn FROM restaurants WHERE slug = 'capitan-nirvana';
    UPDATE bot_sessions
       SET dismissed_at = now(),
           updated_at   = now()
     WHERE restaurant_id = v_cn AND phone = p_phone;
    RETURN jsonb_build_object('ok', true, 'phone', p_phone);
END $$;
GRANT EXECUTE ON FUNCTION public.bot_dismiss_lead(text) TO authenticated, service_role;

-- 2.2 Restaura el lead (deshacer).
CREATE OR REPLACE FUNCTION public.bot_restore_lead(p_phone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_cn bigint;
BEGIN
    SELECT id INTO v_cn FROM restaurants WHERE slug = 'capitan-nirvana';
    UPDATE bot_sessions
       SET dismissed_at = NULL,
           updated_at   = now()
     WHERE restaurant_id = v_cn AND phone = p_phone;
    RETURN jsonb_build_object('ok', true, 'phone', p_phone);
END $$;
GRANT EXECUTE ON FUNCTION public.bot_restore_lead(text) TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- SELECT bot_set_session('573000000000', 'Prueba', 'domicilio');   -- lead interesado
-- SELECT bot_dismiss_lead('573000000000');                         -- {ok:true} → sale del tablero
-- SELECT phone, menu_state, dismissed_at FROM bot_sessions WHERE phone='573000000000';
-- SELECT bot_restore_lead('573000000000');                         -- vuelve al tablero
-- DELETE FROM bot_sessions WHERE phone='573000000000';             -- limpieza
-- ═══════════════════════════════════════════════════════════════════
