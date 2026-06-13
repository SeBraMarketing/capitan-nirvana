-- ═══════════════════════════════════════════════════════════════════
-- 2026-06-13 — CRM: mover etapa manual (+ tick notificar) y semáforo
--              de intervención humana en la tarjeta del cliente.
--
-- Objetivo (pedido de Manu):
--   1. Cada tarjeta puede mover la ETAPA del pedido manualmente desde el
--      CRM, con un tick "Notificar al cliente" (sí/no). → reutiliza el
--      motor existente apply_order_action (mismas acciones que Telegram);
--      el envío del WhatsApp lo decide el flujo n8n según el tick.
--   2. Si la conversación NECESITA INTERVENCIÓN HUMANA, la tarjeta cambia
--      de color. → nueva señal needs_human en bot_sessions + RPC.
--   3. Una view crm_cards entrega el estado consolidado por cliente
--      (etapa del pedido activo, needs_human, pausado, novedad, color).
--
-- ADITIVO e idempotente: no toca el bot ni orders; solo agrega columnas,
-- RPCs nuevos, extiende reanudar_bot (limpia needs_human) y crea la view.
-- Ejecutar en Supabase SQL Editor (una corrida).
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────
-- 1. Señal de intervención humana en bot_sessions
-- ───────────────────────────────────────────────────────────────────
ALTER TABLE public.bot_sessions
    ADD COLUMN IF NOT EXISTS needs_human        boolean     NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS needs_human_reason  text,
    ADD COLUMN IF NOT EXISTS needs_human_at      timestamptz;

CREATE INDEX IF NOT EXISTS bot_sessions_needs_human_idx
    ON public.bot_sessions (restaurant_id) WHERE needs_human = true;

-- ───────────────────────────────────────────────────────────────────
-- 2. RPC: set_needs_human(phone, value, reason)
--    Enciende/apaga la bandera de la tarjeta. Upsert (crea la sesión si
--    aún no existe). Mismo patrón SECURITY DEFINER que bot_set_session.
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_needs_human(
    p_phone  text,
    p_value  boolean DEFAULT true,
    p_reason text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_cn  bigint;
    v_row public.bot_sessions%ROWTYPE;
BEGIN
    SELECT id INTO v_cn FROM public.restaurants WHERE slug = 'capitan-nirvana';

    INSERT INTO public.bot_sessions (restaurant_id, phone, needs_human,
            needs_human_reason, needs_human_at)
    VALUES (
        v_cn, p_phone, COALESCE(p_value, false),
        CASE WHEN COALESCE(p_value, false) THEN NULLIF(trim(p_reason), '') END,
        CASE WHEN COALESCE(p_value, false) THEN now() END
    )
    ON CONFLICT (restaurant_id, phone) DO UPDATE
        SET needs_human        = COALESCE(p_value, false),
            needs_human_reason  = CASE WHEN COALESCE(p_value, false)
                                       THEN COALESCE(NULLIF(trim(p_reason), ''),
                                                     public.bot_sessions.needs_human_reason)
                                       ELSE NULL END,
            needs_human_at      = CASE WHEN COALESCE(p_value, false)
                                       THEN COALESCE(public.bot_sessions.needs_human_at, now())
                                       ELSE NULL END,
            updated_at          = now()
    RETURNING * INTO v_row;

    RETURN jsonb_build_object(
        'ok',          true,
        'phone',       p_phone,
        'needs_human', v_row.needs_human,
        'reason',      v_row.needs_human_reason
    );
END $$;
GRANT EXECUTE ON FUNCTION public.set_needs_human(text, boolean, text)
    TO anon, authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────
-- 3. reanudar_bot: además de quitar la pausa, limpia needs_human.
--    "▶ Activar bot" (Telegram y CRM) deja la tarjeta en verde.
--    Mantiene la firma y el retorno (boolean = se quitó una pausa).
-- ───────────────────────────────────────────────────────────────────
-- SECURITY DEFINER: el UPDATE toca bot_sessions, que tiene RLS sin policy de
-- escritura. Sin definer, una llamada con anon key (ej. el botón "Activar bot"
-- del CRM vía PostgREST) limpiaría 0 filas en silencio y la tarjeta quedaría
-- roja. Con definer funciona igual desde n8n (service_role) y desde el CRM.
CREATE OR REPLACE FUNCTION public.reanudar_bot(p_phone text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_unpaused boolean;
BEGIN
    DELETE FROM public.bot_pauses WHERE phone = p_phone;
    v_unpaused := FOUND;

    UPDATE public.bot_sessions
       SET needs_human        = false,
           needs_human_reason  = NULL,
           needs_human_at      = NULL,
           updated_at          = now()
     WHERE phone = p_phone AND needs_human = true;

    RETURN v_unpaused;
END;
$$;
GRANT EXECUTE ON FUNCTION public.reanudar_bot(text) TO anon, authenticated, service_role;

-- ───────────────────────────────────────────────────────────────────
-- 4. View crm_cards: estado consolidado por cliente para la tarjeta.
--    Spine = bot_sessions (registro de clientes del bot). Por cada
--    teléfono trae el pedido activo (no entregado/cancelado) más reciente,
--    su etapa, novedad, pausa y el COLOR de la tarjeta:
--      red    → needs_human o novedad (atender YA)
--      amber  → bot pausado (alguien ya está atendiendo)
--      normal → bot operando
--    security_invoker: respeta la RLS de orders/bot_sessions por tenant.
-- ───────────────────────────────────────────────────────────────────
DROP VIEW IF EXISTS public.crm_cards;
CREATE VIEW public.crm_cards
WITH (security_invoker = true) AS
WITH active_order AS (
    SELECT DISTINCT ON (o.customer_phone)
        o.customer_phone,
        o.order_id,
        o.order_status::text  AS order_status,
        o.payment_status::text AS payment_status,
        o.has_incident,
        o.total_cop,
        o.scheduled_for,
        o.created_at          AS order_created_at
    FROM public.orders o
    WHERE o.order_status NOT IN ('delivered', 'cancelled')
    ORDER BY o.customer_phone, o.created_at DESC
)
SELECT
    s.restaurant_id,
    s.phone,
    s.customer_name,
    s.menu_state,
    -- Pedido activo (si hay)
    ao.order_id,
    ao.order_status,
    ao.payment_status,
    ao.total_cop,
    ao.scheduled_for,
    COALESCE(ao.has_incident, false)                              AS has_incident,
    -- Intervención humana (conversación)
    s.needs_human,
    s.needs_human_reason,
    s.needs_human_at,
    -- Pausa del bot
    (p.phone IS NOT NULL AND p.paused_until > now())              AS bot_paused,
    p.paused_until,
    -- Color de la tarjeta
    CASE
        WHEN s.needs_human OR COALESCE(ao.has_incident, false)    THEN 'red'
        WHEN (p.phone IS NOT NULL AND p.paused_until > now())     THEN 'amber'
        ELSE 'normal'
    END                                                          AS card_color,
    s.updated_at
FROM public.bot_sessions s
LEFT JOIN active_order ao ON ao.customer_phone = s.phone
LEFT JOIN public.bot_pauses p ON p.phone = s.phone;

GRANT SELECT ON public.crm_cards TO authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- 1. Columnas nuevas:
--    SELECT column_name FROM information_schema.columns
--    WHERE table_name='bot_sessions'
--      AND column_name IN ('needs_human','needs_human_reason','needs_human_at');
--    -- → 3 filas
--
-- 2. Encender / apagar la bandera:
--    SELECT set_needs_human('573001112233', true, 'queja: comida fría');
--    -- → { ok:true, needs_human:true, reason:'queja: comida fría' }
--    SELECT reanudar_bot('573001112233');     -- limpia needs_human + pausa
--    SELECT needs_human FROM bot_sessions WHERE phone='573001112233';  -- → false
--
-- 3. Mover etapa manual (reusa apply_order_action; el tick lo aplica n8n):
--    SELECT apply_order_action('CN20260613XXX', 'prep', 'CRM: Manu', 'crm');
--    -- → { ok:true, to_status:'preparing', reply_text:'👨‍🍳 ...' }
--    -- transición inválida → { ok:false, error:'⚠️ ...' }
--
-- 4. Tarjetas con color:
--    SELECT phone, order_status, needs_human, bot_paused, card_color
--    FROM crm_cards ORDER BY (card_color='red') DESC, updated_at DESC;
-- ═══════════════════════════════════════════════════════════════════
