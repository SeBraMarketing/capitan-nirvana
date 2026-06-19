-- ═══════════════════════════════════════════════════════════════════
-- 2026-06-19 — Analítica: gráfico de barrios + arreglo de tiempos
--
-- A) crm_orders_by_barrio: reemplaza el mapa de calor. Cuenta pedidos por
--    barrio (match del nombre dentro de orders.address, igual criterio que
--    get_zone_by_address) + zona + INGRESOS. Top N, ordenado por pedidos.
--
-- B) crm_time_metrics (REESCRITO): el anterior pedía la acción 'prep' que
--    el personal NUNCA marca (van verify -> out -> delivered), así que daba 0.
--    Ahora mide las 3 etapas que SÍ se registran en order_status_events:
--      - Pedido -> Verificado   (created_at -> primer 'verify')
--      - Verificado -> Salida   (primer 'verify' -> primer 'out')
--      - Salida -> Entrega      (primer 'out' -> primer 'delivered')
--
-- Idempotente. Ejecutar UNA vez en el SQL Editor de Supabase.
-- ═══════════════════════════════════════════════════════════════════

-- ─── A) Pedidos por barrio (reemplaza crm_heatmap en la UI) ───────────
CREATE OR REPLACE FUNCTION public.crm_orders_by_barrio(
    p_restaurant_id bigint,
    p_from  timestamptz DEFAULT (now() - interval '30 days'),
    p_to    timestamptz DEFAULT now(),
    p_limit int         DEFAULT 15
)
RETURNS TABLE(barrio text, zona text, pedidos bigint, ingresos_cop bigint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM public._crm_assert_member(p_restaurant_id);
    RETURN QUERY
    SELECT b.nombre, b.zona, count(*)::bigint, COALESCE(sum(o.total_cop), 0)::bigint
    FROM orders o
    JOIN LATERAL (
        SELECT bx.nombre, bx.zona
        FROM barrios bx
        WHERE unaccent(lower(o.address)) ILIKE '%' || unaccent(lower(bx.nombre)) || '%'
        ORDER BY length(bx.nombre) DESC
        LIMIT 1
    ) b ON true
    WHERE o.restaurant_id = p_restaurant_id
      AND o.created_at BETWEEN p_from AND p_to
      AND o.order_status <> 'cancelled'
    GROUP BY b.nombre, b.zona
    ORDER BY count(*) DESC, sum(o.total_cop) DESC NULLS LAST
    LIMIT GREATEST(p_limit, 1);
END $$;
GRANT EXECUTE ON FUNCTION public.crm_orders_by_barrio(bigint,timestamptz,timestamptz,int) TO authenticated, service_role;


-- ─── B) Tiempos promedio (REESCRITO) ─────────────────────────────────
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
    WITH t AS (
        SELECT
            o.order_id,
            o.created_at                                            AS t_pedido,
            MIN(e.created_at) FILTER (WHERE e.action = 'verify')    AS t_verify,
            MIN(e.created_at) FILTER (WHERE e.action = 'out')       AS t_out,
            MIN(e.created_at) FILTER (WHERE e.action = 'delivered') AS t_delivered
        FROM orders o
        JOIN order_status_events e ON e.order_id = o.order_id
        WHERE o.restaurant_id = p_restaurant_id
          AND o.created_at BETWEEN p_from AND p_to
        GROUP BY o.order_id, o.created_at
    )
    SELECT jsonb_build_object(
        'avg_min_pedido_verificado', COALESCE(round(
            avg(EXTRACT(epoch FROM (t_verify - t_pedido)))
              FILTER (WHERE t_verify IS NOT NULL AND t_verify >= t_pedido) / 60.0)::int, 0),
        'avg_min_verificado_salida', COALESCE(round(
            avg(EXTRACT(epoch FROM (t_out - t_verify)))
              FILTER (WHERE t_out IS NOT NULL AND t_verify IS NOT NULL AND t_out >= t_verify) / 60.0)::int, 0),
        'avg_min_salida_entrega', COALESCE(round(
            avg(EXTRACT(epoch FROM (t_delivered - t_out)))
              FILTER (WHERE t_delivered IS NOT NULL AND t_out IS NOT NULL AND t_delivered >= t_out) / 60.0)::int, 0)
    ) INTO r FROM t;
    RETURN r;
END $$;
GRANT EXECUTE ON FUNCTION public.crm_time_metrics(bigint,timestamptz,timestamptz) TO authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN (debe devolver filas / minutos > 0):
--   SELECT * FROM crm_orders_by_barrio((SELECT id FROM restaurants WHERE slug='capitan-nirvana'),
--                                       now() - interval '30 days', now(), 15);
--   SELECT crm_time_metrics((SELECT id FROM restaurants WHERE slug='capitan-nirvana'),
--                           now() - interval '30 days', now());
-- ═══════════════════════════════════════════════════════════════════
