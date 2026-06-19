-- ═══════════════════════════════════════════════════════════════════
-- 2026-06-03 — FIX get_zone_by_address: match por NOMBRE BASE del barrio
--
-- BUG: los barrios están guardados con sufijo ("Miraflores I", "Miraflores II",
-- "Tamasagra I", "Mariluz II", ...). El RPC original exigía que la dirección del
-- cliente CONTUVIERA el nombre completo (incl. el "I"/"II"). Como el cliente
-- escribe solo "Miraflores", `'miraflores' ILIKE '%miraflores i%'` = FALSO →
-- no devuelve fee_cop → Capi entra en bucle pidiendo el barrio.
--
-- FIX: matchear también por el nombre BASE (sufijo I/II/Norte/Sur/número quitado),
-- en ambas direcciones (la dirección contiene el barrio, o el barrio contiene lo
-- escrito). Prioriza la coincidencia de nombre completo (más específica).
--
-- Idempotente. Ejecutar en Supabase SQL Editor (una corrida). Reemplaza la función.
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.get_zone_by_address(p_address text)
RETURNS TABLE(
    zona            text,
    barrio_nombre   text,
    fee_cop         integer,
    eta_min         integer,
    distancia_km    numeric,
    is_active       boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    WITH q AS (
        SELECT unaccent(lower(trim(p_address))) AS addr
    ),
    m AS (
        SELECT
            b.zona, b.nombre, b.eta_min, b.distancia_km,
            unaccent(lower(b.nombre)) AS nfull,
            -- nombre base: quita sufijo final tipo " I", " II", " 2", " Norte", " Sur", ...
            regexp_replace(
                unaccent(lower(b.nombre)),
                '\s+(i{1,3}|[0-9]+|norte|sur|oriental|occidental)$', ''
            ) AS nbase
        FROM barrios b
    )
    SELECT
        m.zona,
        m.nombre        AS barrio_nombre,
        dz.fee_cop,
        m.eta_min       AS eta_min,
        m.distancia_km,
        dz.is_active
    FROM m
    JOIN delivery_zones dz ON dz.zone_name = m.zona
    CROSS JOIN q
    WHERE q.addr ILIKE '%' || m.nfull || '%'                              -- (1) la dirección contiene el nombre completo ("...Miraflores I")
       OR (length(m.nbase) >= 4 AND q.addr ILIKE '%' || m.nbase || '%')   -- (2) la dirección contiene el nombre BASE ("Miraflores" → "Miraflores I/II")
       OR (length(q.addr) >= 4 AND m.nfull ILIKE '%' || q.addr || '%')    -- (3) el barrio contiene lo que escribió el cliente
    ORDER BY
        (q.addr ILIKE '%' || m.nfull || '%') DESC,   -- 1º: coincidencia del nombre completo (más específica)
        length(m.nfull) DESC                          -- 2º: el barrio más específico
    LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_zone_by_address(text) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN (debe devolver una fila con fee_cop para cada uno):
--   SELECT * FROM get_zone_by_address('Miraflores');
--   SELECT * FROM get_zone_by_address('Carrera 6e # 16bis - 75 Casa. Miraflores');
--   SELECT * FROM get_zone_by_address('Tamasagra');
--   SELECT * FROM get_zone_by_address('Mariluz');
--   SELECT * FROM get_zone_by_address('Centro');   -- los que ya funcionaban deben seguir igual
-- ═══════════════════════════════════════════════════════════════════
