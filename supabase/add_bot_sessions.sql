-- ═══════════════════════════════════════════════════════════════════
-- 2026-05-24 — bot_sessions: estado del menú de triage (1/2/3) + funnel de leads
--
-- El número de WhatsApp (YCloud) se usa para domicilios, reservas y temas
-- administrativos. El bot ahora muestra un menú inicial 1/2/3 y recuerda la
-- elección por contacto. Esta tabla guarda ese estado y, a la vez, sirve como
-- registro de "interesados" en domicilio (marcaron 1) para el tablero del CRM.
--
-- Idempotente. Ejecutar en Supabase SQL Editor (una corrida).
-- ADITIVO: no toca el bot existente ni orders.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────
-- 1. Tabla
-- ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bot_sessions (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    restaurant_id      bigint NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
    phone              text NOT NULL,
    customer_name      text,
    menu_state         text NOT NULL DEFAULT 'awaiting_choice',  -- awaiting_choice | domicilio | reserva | admin
    invited_count      int  NOT NULL DEFAULT 0,
    last_invited_at    timestamptz,
    converted_order_id text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (restaurant_id, phone)
);

CREATE INDEX IF NOT EXISTS bot_sessions_lead_idx
    ON bot_sessions (restaurant_id, menu_state, created_at DESC);

-- ───────────────────────────────────────────────────────────────────
-- 2. RPCs (SECURITY DEFINER). Resuelven el tenant CN por slug.
--    Grants a anon/authenticated/service_role (mismo patrón que pausar_bot).
-- ───────────────────────────────────────────────────────────────────

-- 2.1 Lee la sesión del contacto (para el gate del bot). NULL si no existe.
CREATE OR REPLACE FUNCTION public.bot_get_session(p_phone text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT to_jsonb(bs)
    FROM bot_sessions bs
    JOIN restaurants r ON r.id = bs.restaurant_id
    WHERE r.slug = 'capitan-nirvana' AND bs.phone = p_phone;
$$;
GRANT EXECUTE ON FUNCTION public.bot_get_session(text) TO anon, authenticated, service_role;

-- 2.2 Upsert del estado del menú (no toca converted_order_id ni invited_count).
CREATE OR REPLACE FUNCTION public.bot_set_session(
    p_phone text,
    p_name  text DEFAULT NULL,
    p_state text DEFAULT 'awaiting_choice'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_cn  bigint;
    v_row bot_sessions%ROWTYPE;
BEGIN
    SELECT id INTO v_cn FROM restaurants WHERE slug = 'capitan-nirvana';

    INSERT INTO bot_sessions (restaurant_id, phone, customer_name, menu_state)
    VALUES (v_cn, p_phone, NULLIF(trim(p_name), ''), p_state)
    ON CONFLICT (restaurant_id, phone) DO UPDATE
        SET menu_state    = EXCLUDED.menu_state,
            customer_name = COALESCE(NULLIF(trim(EXCLUDED.customer_name), ''), bot_sessions.customer_name),
            updated_at    = now()
    RETURNING * INTO v_row;

    RETURN to_jsonb(v_row);
END $$;
GRANT EXECUTE ON FUNCTION public.bot_set_session(text, text, text) TO anon, authenticated, service_role;

-- 2.3 Marca la sesión como convertida (al crear la orden). Sale de "Interesados".
CREATE OR REPLACE FUNCTION public.bot_mark_converted(p_phone text, p_order_id text)
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
       SET converted_order_id = p_order_id,
           menu_state         = 'domicilio',
           updated_at         = now()
     WHERE restaurant_id = v_cn AND phone = p_phone;
    RETURN jsonb_build_object('ok', true, 'phone', p_phone, 'order_id', p_order_id);
END $$;
GRANT EXECUTE ON FUNCTION public.bot_mark_converted(text, text) TO anon, authenticated, service_role;

-- 2.4 Registra una invitación a continuar (botón del CRM / webhook nudge).
CREATE OR REPLACE FUNCTION public.bot_lead_invited(p_phone text)
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
       SET invited_count   = invited_count + 1,
           last_invited_at = now(),
           updated_at      = now()
     WHERE restaurant_id = v_cn AND phone = p_phone;
    RETURN jsonb_build_object('ok', true, 'phone', p_phone);
END $$;
GRANT EXECUTE ON FUNCTION public.bot_lead_invited(text) TO anon, authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────
-- 3. RLS — los miembros del restaurante LEEN sus sesiones (tablero CRM).
--    Escrituras solo vía RPC (SECURITY DEFINER) / service_role (n8n).
-- ───────────────────────────────────────────────────────────────────
ALTER TABLE bot_sessions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bot_sessions_member_read ON bot_sessions;
CREATE POLICY bot_sessions_member_read ON bot_sessions
    FOR SELECT TO authenticated
    USING (restaurant_id IN (SELECT public.current_user_restaurants()));

GRANT SELECT ON bot_sessions TO authenticated;

-- ───────────────────────────────────────────────────────────────────
-- 4. Realtime (tablero en vivo): REPLICA IDENTITY FULL + publicación.
--    (Mismo gotcha que orders: sin esto los UPDATE no llegan al cliente.)
-- ───────────────────────────────────────────────────────────────────
ALTER TABLE bot_sessions REPLICA IDENTITY FULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'bot_sessions'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE bot_sessions;
    END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- SELECT bot_set_session('573000000000', 'Prueba', 'awaiting_choice');  -- crea
-- SELECT bot_get_session('573000000000');                               -- {... awaiting_choice}
-- SELECT bot_set_session('573000000000', NULL, 'domicilio');            -- lead interesado
-- SELECT * FROM bot_sessions WHERE phone='573000000000';
-- SELECT bot_mark_converted('573000000000', 'CN20260524999');           -- sale de interesados
-- DELETE FROM bot_sessions WHERE phone='573000000000';                  -- limpieza
-- ═══════════════════════════════════════════════════════════════════
