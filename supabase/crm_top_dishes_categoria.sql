-- ═══════════════════════════════════════════════════════════════════
-- 2026-06-19 — Filtro por categoría en "Platos más pedidos"
--
-- A) crm_top_dishes: agrega parámetro p_categoria (NULL = todas, default →
--    comportamiento actual). Une cada plato a menu.category por nombre y
--    filtra cuando se pide una categoría.
-- B) crm_menu_categories: lista las categorías del menú para el selector.
--
-- crm_top_dishes cambia su firma (nuevo parámetro) → DROP del de 4 args antes.
-- Idempotente. Ejecutar UNA vez en el SQL Editor de Supabase.
-- ═══════════════════════════════════════════════════════════════════

-- ─── A) crm_top_dishes con filtro por categoría ──────────────────────
DROP FUNCTION IF EXISTS public.crm_top_dishes(bigint, timestamptz, timestamptz, int);

CREATE OR REPLACE FUNCTION public.crm_top_dishes(
    p_restaurant_id bigint,
    p_from      timestamptz DEFAULT (now() - interval '30 days'),
    p_to        timestamptz DEFAULT now(),
    p_limit     int         DEFAULT 15,
    p_categoria text        DEFAULT NULL
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
         LEFT JOIN menu m ON m.name = it->>'name'
    WHERE o.restaurant_id = p_restaurant_id
      AND o.created_at BETWEEN p_from AND p_to
      AND o.order_status <> 'cancelled'
      AND it->>'name' IS NOT NULL
      AND (p_categoria IS NULL OR m.category::text = p_categoria)
    GROUP BY it->>'name'
    ORDER BY qty DESC
    LIMIT p_limit;
END $$;
GRANT EXECUTE ON FUNCTION public.crm_top_dishes(bigint,timestamptz,timestamptz,int,text) TO authenticated, service_role;


-- ─── B) Categorías del menú (para el selector del front) ─────────────
CREATE OR REPLACE FUNCTION public.crm_menu_categories(p_restaurant_id bigint)
RETURNS TABLE(categoria text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    PERFORM public._crm_assert_member(p_restaurant_id);
    RETURN QUERY
    SELECT DISTINCT m.category::text
    FROM menu m
    ORDER BY 1;
END $$;
GRANT EXECUTE ON FUNCTION public.crm_menu_categories(bigint) TO authenticated, service_role;

-- VERIFICACIÓN:
--   SELECT * FROM crm_menu_categories((SELECT id FROM restaurants WHERE slug='capitan-nirvana'));
--   SELECT * FROM crm_top_dishes((SELECT id FROM restaurants WHERE slug='capitan-nirvana'),
--                                now()-interval '30 days', now(), 15, 'Hamburguesas');
