-- ═══════════════════════════════════════════════════════════════════
-- Mini-CRM Capitán Nirvana — Fase 0: lógica central + analítica
-- Fecha: 2026-05-17
-- Ejecutar DESPUÉS de crm_schema.sql. Idempotente (CREATE OR REPLACE).
--
-- apply_order_action = ÚNICA fuente de verdad para transiciones de
-- estado + mensaje al cliente. Lógica portada de los nodos n8n
-- `Validate Action` y `Build Customer Message`.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────
-- apply_order_action(order_id, action, actor, source) → jsonb
--   action ∈ verify|reject|prep|out|delivered|cancel
--   Devuelve: { ok, order_id, customer_phone, reply_text,
--               tg_status_text, error }
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.apply_order_action(
    p_order_id  text,
    p_action    text,
    p_actor     text DEFAULT NULL,
    p_source    text DEFAULT 'crm'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    o              orders%ROWTYPE;
    v_pay          text;
    v_status       text;
    v_ok           boolean := false;
    v_reason       text;
    v_new_status   text;
    v_new_pay      text;
    v_reply        text;
    v_tg           text;
    v_actor        text := COALESCE(NULLIF(trim(p_actor), ''), 'el equipo');
    v_hora         text := to_char(now() AT TIME ZONE 'America/Bogota', 'HH24:MI');
BEGIN
    SELECT * INTO o FROM orders WHERE order_id = p_order_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', '⚠️ Pedido no encontrado');
    END IF;

    v_pay    := o.payment_status::text;
    v_status := o.order_status::text;

    -- ── Validación de transición (portada de `Validate Action`)
    v_ok := CASE p_action
        WHEN 'verify'    THEN v_pay = 'pending'
        WHEN 'reject'    THEN v_pay = 'pending'
        WHEN 'prep'      THEN v_pay = 'verified' AND v_status IN ('accepted','received')
        WHEN 'out'       THEN v_pay = 'verified' AND v_status IN ('accepted','preparing')
        WHEN 'delivered' THEN v_pay <> 'rejected' AND v_status NOT IN ('delivered','cancelled')
        WHEN 'cancel'    THEN v_status NOT IN ('delivered','cancelled')
        ELSE false
    END;

    IF NOT v_ok THEN
        v_reason := CASE p_action
            WHEN 'verify'    THEN format('⚠️ Este pedido ya tiene pago %s (no pending)', v_pay)
            WHEN 'reject'    THEN format('⚠️ El pago ya está %s, no se puede rechazar de nuevo', v_pay)
            WHEN 'prep'      THEN format('⚠️ Falta verificar pago antes de preparar (pago: %s, estado: %s)', v_pay, v_status)
            WHEN 'out'       THEN format('⚠️ No se puede marcar Salida (pago: %s, estado: %s)', v_pay, v_status)
            WHEN 'delivered' THEN format('⚠️ No se puede marcar Entregado (estado: %s)', v_status)
            WHEN 'cancel'    THEN format('⚠️ Pedido ya está en estado terminal (%s)', v_status)
            ELSE format('⚠️ Acción ''%s'' no permitida', p_action)
        END;
        RETURN jsonb_build_object('ok', false, 'error', v_reason,
                                  'order_id', p_order_id);
    END IF;

    -- ── Aplicar transición (portada de los nodos Update *)
    v_new_status := v_status;
    v_new_pay    := v_pay;

    IF p_action = 'verify' THEN
        UPDATE orders SET payment_status='verified', order_status='accepted',
               accepted_at = now() WHERE id = o.id;
        v_new_status := 'accepted'; v_new_pay := 'verified';
    ELSIF p_action = 'reject' THEN
        UPDATE orders SET payment_status='rejected' WHERE id = o.id;
        v_new_pay := 'rejected';
    ELSIF p_action = 'prep' THEN
        UPDATE orders SET order_status='preparing' WHERE id = o.id;
        v_new_status := 'preparing';
    ELSIF p_action = 'out' THEN
        UPDATE orders SET order_status='out_for_delivery' WHERE id = o.id;
        v_new_status := 'out_for_delivery';
    ELSIF p_action = 'delivered' THEN
        UPDATE orders SET order_status='delivered', delivered_at = now() WHERE id = o.id;
        v_new_status := 'delivered';
    ELSIF p_action = 'cancel' THEN
        UPDATE orders SET order_status='cancelled', cancelled_at = now() WHERE id = o.id;
        v_new_status := 'cancelled';
    END IF;

    -- ── Timeline
    INSERT INTO order_status_events (order_id, restaurant_id, action,
            from_status, to_status, payment_status, actor, source)
    VALUES (p_order_id, o.restaurant_id, p_action,
            v_status, v_new_status, v_new_pay, v_actor, p_source);

    -- ── Mensajes (portados de `Build Customer Message`)
    v_reply := CASE p_action
        WHEN 'verify'    THEN format('✅ ¡Pago verificado! Tu pedido *%s* ya entró a cocina. 🎸', p_order_id)
        WHEN 'reject'    THEN format('⚠️ No pudimos verificar tu pago del pedido *%s*. Reenvía el comprobante o llama al 3004647851.', p_order_id)
        WHEN 'prep'      THEN format('👨‍🍳 Tu pedido *%s* está en preparación.', p_order_id)
        WHEN 'out'       THEN format('🛵 Tu pedido *%s* salió en camino. ¡Atento al timbre!', p_order_id)
        WHEN 'delivered' THEN format('📦 ¡Pedido *%s* entregado! Gracias por pedir en Capitán Nirvana. 🤘', p_order_id)
        WHEN 'cancel'    THEN format('❌ Tu pedido *%s* fue cancelado. Cualquier duda llama al 3004647851.', p_order_id)
    END;

    v_tg := CASE p_action
        WHEN 'verify'    THEN format('✅ *Pago verificado* por %s (%s) — pedido *%s* a cocina.', v_actor, v_hora, p_order_id)
        WHEN 'reject'    THEN format('❌ *Pago RECHAZADO* por %s (%s) — pedido *%s*.', v_actor, v_hora, p_order_id)
        WHEN 'prep'      THEN format('👨‍🍳 *En preparación* (%s %s) — *%s*.', v_actor, v_hora, p_order_id)
        WHEN 'out'       THEN format('🛵 *En camino* (%s %s) — *%s*.', v_actor, v_hora, p_order_id)
        WHEN 'delivered' THEN format('✅ *Entregado* (%s %s) — *%s*.', v_actor, v_hora, p_order_id)
        WHEN 'cancel'    THEN format('❌ *Cancelado* (%s %s) — *%s*.', v_actor, v_hora, p_order_id)
    END;

    RETURN jsonb_build_object(
        'ok', true,
        'order_id', p_order_id,
        'customer_phone', o.customer_phone,
        'customer_name', o.customer_name,
        'action', p_action,
        'to_status', v_new_status,
        'payment_status', v_new_pay,
        'reply_text', v_reply,
        'tg_status_text', v_tg
    );
END $$;

GRANT EXECUTE ON FUNCTION public.apply_order_action(text,text,text,text)
    TO anon, authenticated, service_role;


-- ───────────────────────────────────────────────────────────────────
-- Guard reusable: bloquea a un authenticated que pida otro tenant.
-- service_role / n8n (auth.uid() NULL) pasa.
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._crm_assert_member(p_restaurant_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF auth.uid() IS NOT NULL
       AND p_restaurant_id NOT IN (
           SELECT restaurant_id FROM restaurant_members WHERE user_id = auth.uid())
    THEN
        RAISE EXCEPTION 'forbidden: no eres miembro de ese restaurante';
    END IF;
END $$;


-- ───────────────────────────────────────────────────────────────────
-- crm_kpis(restaurant_id, from, to) → jsonb
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crm_kpis(
    p_restaurant_id bigint,
    p_from timestamptz DEFAULT (now() - interval '30 days'),
    p_to   timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r jsonb;
BEGIN
    PERFORM public._crm_assert_member(p_restaurant_id);
    SELECT jsonb_build_object(
        'orders_total',      count(*),
        'delivered',         count(*) FILTER (WHERE order_status = 'delivered'),
        'cancelled',         count(*) FILTER (WHERE order_status = 'cancelled'),
        'pending_payment',   count(*) FILTER (WHERE payment_status = 'pending' AND order_status <> 'cancelled'),
        'revenue_cop',       COALESCE(sum(total_cop) FILTER (WHERE order_status = 'delivered'), 0),
        'aov_cop',           COALESCE(round(avg(total_cop) FILTER (WHERE order_status = 'delivered')), 0),
        'cancel_rate',       round(
                                100.0 * count(*) FILTER (WHERE order_status = 'cancelled')
                                / GREATEST(count(*), 1), 1)
    ) INTO r
    FROM orders
    WHERE restaurant_id = p_restaurant_id
      AND created_at BETWEEN p_from AND p_to;
    RETURN r;
END $$;
GRANT EXECUTE ON FUNCTION public.crm_kpis(bigint,timestamptz,timestamptz) TO authenticated, service_role;


-- ───────────────────────────────────────────────────────────────────
-- crm_top_dishes(restaurant_id, from, to, limit) → setof
--   Agrega orders.items_json ([{name, qty, ...}]).
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crm_top_dishes(
    p_restaurant_id bigint,
    p_from timestamptz DEFAULT (now() - interval '30 days'),
    p_to   timestamptz DEFAULT now(),
    p_limit int DEFAULT 15
)
RETURNS TABLE(name text, qty bigint, orders bigint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM public._crm_assert_member(p_restaurant_id);
    RETURN QUERY
    SELECT  it->>'name' AS name,
            sum(COALESCE((it->>'qty')::numeric, 1))::bigint AS qty,
            count(DISTINCT o.id)::bigint AS orders
    FROM orders o
         CROSS JOIN LATERAL jsonb_array_elements(o.items_json) AS it
    WHERE o.restaurant_id = p_restaurant_id
      AND o.created_at BETWEEN p_from AND p_to
      AND o.order_status <> 'cancelled'
      AND it->>'name' IS NOT NULL
    GROUP BY it->>'name'
    ORDER BY qty DESC
    LIMIT p_limit;
END $$;
GRANT EXECUTE ON FUNCTION public.crm_top_dishes(bigint,timestamptz,timestamptz,int) TO authenticated, service_role;


-- ───────────────────────────────────────────────────────────────────
-- crm_time_metrics(restaurant_id, from, to) → jsonb
--   Minutos promedio entre eventos (de order_status_events).
--   pago→cocina = verify→prep | cocina→salida = prep→out
--   salida→entrega = out→delivered
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crm_time_metrics(
    p_restaurant_id bigint,
    p_from timestamptz DEFAULT (now() - interval '30 days'),
    p_to   timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r jsonb;
BEGIN
    PERFORM public._crm_assert_member(p_restaurant_id);
    WITH ev AS (
        SELECT order_id, action, created_at
        FROM order_status_events
        WHERE restaurant_id = p_restaurant_id
          AND created_at BETWEEN p_from AND p_to
    ),
    pairs AS (
        SELECT
          e1.order_id,
          MIN(e2.created_at) FILTER (WHERE e1.action='verify' AND e2.action='prep')      - MIN(e1.created_at) FILTER (WHERE e1.action='verify')    AS pago_cocina,
          MIN(e2.created_at) FILTER (WHERE e1.action='prep'   AND e2.action='out')       - MIN(e1.created_at) FILTER (WHERE e1.action='prep')      AS cocina_salida,
          MIN(e2.created_at) FILTER (WHERE e1.action='out'    AND e2.action='delivered') - MIN(e1.created_at) FILTER (WHERE e1.action='out')       AS salida_entrega
        FROM ev e1 JOIN ev e2 USING (order_id)
        GROUP BY e1.order_id
    )
    SELECT jsonb_build_object(
        'avg_min_pago_cocina',   COALESCE(round(avg(EXTRACT(epoch FROM pago_cocina))/60.0)::int, 0),
        'avg_min_cocina_salida', COALESCE(round(avg(EXTRACT(epoch FROM cocina_salida))/60.0)::int, 0),
        'avg_min_salida_entrega',COALESCE(round(avg(EXTRACT(epoch FROM salida_entrega))/60.0)::int, 0)
    ) INTO r FROM pairs;
    RETURN r;
END $$;
GRANT EXECUTE ON FUNCTION public.crm_time_metrics(bigint,timestamptz,timestamptz) TO authenticated, service_role;


-- ───────────────────────────────────────────────────────────────────
-- crm_heatmap(restaurant_id, from, to) → setof
--   Conteo de pedidos por barrio (match del nombre del barrio dentro
--   de orders.address, igual criterio que get_zone_by_address) +
--   lat/lng del barrio para pintar el mapa de calor.
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crm_heatmap(
    p_restaurant_id bigint,
    p_from timestamptz DEFAULT (now() - interval '30 days'),
    p_to   timestamptz DEFAULT now()
)
RETURNS TABLE(barrio text, zona text, lat numeric, lng numeric, pedidos bigint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM public._crm_assert_member(p_restaurant_id);
    RETURN QUERY
    SELECT b.nombre, b.zona, b.latitud, b.longitud, count(*)::bigint
    FROM orders o
    JOIN LATERAL (
        SELECT bx.nombre, bx.zona, bx.latitud, bx.longitud
        FROM barrios bx
        WHERE unaccent(lower(o.address)) ILIKE '%' || unaccent(lower(bx.nombre)) || '%'
        ORDER BY length(bx.nombre) DESC
        LIMIT 1
    ) b ON true
    WHERE o.restaurant_id = p_restaurant_id
      AND o.created_at BETWEEN p_from AND p_to
      AND o.order_status <> 'cancelled'
    GROUP BY b.nombre, b.zona, b.latitud, b.longitud
    ORDER BY count(*) DESC;
END $$;
GRANT EXECUTE ON FUNCTION public.crm_heatmap(bigint,timestamptz,timestamptz) TO authenticated, service_role;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN  (usa pedidos REALES; no hardcodear order_id)
-- ═══════════════════════════════════════════════════════════════════
-- 0. Ver pedidos disponibles y su estado:
--    SELECT order_id, payment_status, order_status, customer_phone
--    FROM orders ORDER BY created_at DESC LIMIT 10;
--
-- 1. Probar el ciclo sobre un pedido con pago pendiente:
--    SELECT apply_order_action(
--      (SELECT order_id FROM orders WHERE payment_status='pending'
--       ORDER BY created_at DESC LIMIT 1), 'verify', 'tester', 'crm');
--    -> { ok:true, customer_phone, reply_text:'✅ ...', tg_status_text } + fila en order_status_events
--    Repetir con 'prep' -> 'out' -> 'delivered' sobre el MISMO order_id.
--    (Si el pedido no está en el estado correcto -> ok:false con el motivo: es lo esperado.)
--
-- 2. Analítica:
--    SELECT crm_kpis((SELECT id FROM restaurants WHERE slug='capitan-nirvana'));
--    SELECT * FROM crm_top_dishes((SELECT id FROM restaurants WHERE slug='capitan-nirvana'));
--    SELECT crm_time_metrics((SELECT id FROM restaurants WHERE slug='capitan-nirvana'));
--    SELECT * FROM crm_heatmap((SELECT id FROM restaurants WHERE slug='capitan-nirvana'));
-- ═══════════════════════════════════════════════════════════════════
