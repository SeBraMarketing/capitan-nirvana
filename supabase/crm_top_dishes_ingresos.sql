-- ═══════════════════════════════════════════════════════════════════
-- 2026-06-19 — crm_top_dishes: agregar ingresos_cop (valor facturado por plato)
-- Para que "Platos más pedidos" muestre el facturado bajo el nombre, igual
-- que "Barrios con más pedidos". ingresos_cop = suma de qty * price por plato.
--
-- Cambia el tipo de retorno (agrega columna) → hay que DROP antes del CREATE.
-- Idempotente. Ejecutar UNA vez en el SQL Editor de Supabase.
-- ═══════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.crm_top_dishes(bigint, timestamptz, timestamptz, int);

CREATE OR REPLACE FUNCTION public.crm_top_dishes(
    p_restaurant_id bigint,
    p_from timestamptz DEFAULT (now() - interval '30 days'),
    p_to   timestamptz DEFAULT now(),
    p_limit int DEFAULT 15
)
RETURNS TABLE(name text, qty bigint, orders bigint, ingresos_cop bigint)
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
            count(DISTINCT o.id)::bigint AS orders,
            sum(COALESCE((it->>'qty')::numeric, 1) * COALESCE((it->>'price')::numeric, 0))::bigint AS ingresos_cop
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

-- VERIFICACIÓN:
--   SELECT * FROM crm_top_dishes((SELECT id FROM restaurants WHERE slug='capitan-nirvana'),
--                                now() - interval '30 days', now(), 15);
