-- ═══════════════════════════════════════════════════════════════════
-- 2026-06-16 — get_zone_by_address TOLERANTE (supera a fix_get_zone_by_address_base_match.sql)
--
-- PROBLEMA: el RPC solo matcheaba por contención exacta del nombre. Falló con
-- "Belarcazar" (el cliente escribió mal "Belalcázar") → no devolvió fee →
-- el bot se colgó (max iterations) y cotizó mal el domicilio.
--
-- ESTE FIX combina 3 niveles, de más preciso a más tolerante:
--   (1) Nombre COMPLETO contenido en la dirección  ("...Miraflores I")
--   (2) Nombre BASE contenido (sufijo I/II/Norte/número quitado)  ("Miraflores")
--   (3) FUZZY: similitud por trigramas (word_similarity) → tolera errores de
--       ortografía: 'belarcazar' ~ 'belalcazar', 'tamazagra' ~ 'tamasagra', etc.
--
-- Si NADA matchea, NO devuelve fila (igual que antes) → el bot aplica el PISO
-- de $7.000 aguas abajo (Recalcular Totales / Capi). Es decir: este RPC nunca
-- inventa una zona; solo amplía cuántos barrios reconoce.
--
-- Idempotente. Ejecutar UNA vez en Supabase SQL Editor. Reemplaza la función.
-- ═══════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

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
    ),
    scored AS (
        SELECT
            m.zona, m.nombre, m.eta_min, m.distancia_km, m.nfull, m.nbase,
            (q.addr ILIKE '%' || m.nfull || '%')                            AS hit_full,
            (length(m.nbase) >= 4 AND q.addr ILIKE '%' || m.nbase || '%')   AS hit_base,
            (length(q.addr)  >= 4 AND m.nfull ILIKE '%' || q.addr || '%')   AS hit_rev,
            -- (3) similitud difusa del nombre base dentro de la dirección escrita
            word_similarity(m.nbase, q.addr)                                AS sim
        FROM m CROSS JOIN q
    )
    SELECT
        s.zona,
        s.nombre        AS barrio_nombre,
        dz.fee_cop,
        s.eta_min,
        s.distancia_km,
        dz.is_active
    FROM scored s
    JOIN delivery_zones dz ON dz.zone_name = s.zona
    WHERE s.hit_full
       OR s.hit_base
       OR s.hit_rev
       OR (length(s.nbase) >= 5 AND s.sim >= 0.55)   -- fallback difuso (tolera typos). Subir umbral si sobre-matchea.
    ORDER BY
        s.hit_full DESC,                    -- 1º coincidencia exacta del nombre completo
        (s.hit_base OR s.hit_rev) DESC,     -- 2º coincidencia por nombre base / reverso
        s.sim DESC,                         -- 3º mejor similitud difusa
        length(s.nfull) DESC                -- 4º barrio más específico
    LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_zone_by_address(text) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN — corre esto y revisa que cada uno devuelva fila con fee_cop:
--   SELECT * FROM get_zone_by_address('Calle 26b #23-04 Belarcazar');  -- ⚠️ el caso de Paola (typo) → debe resolver Belalcázar
--   SELECT * FROM get_zone_by_address('Belalcazar');                   -- bien escrito
--   SELECT * FROM get_zone_by_address('Miraflores');                   -- base (Miraflores I/II)
--   SELECT * FROM get_zone_by_address('Tamazagra');                    -- typo de Tamasagra
--   SELECT * FROM get_zone_by_address('Centro');                       -- los que ya servían deben seguir igual
--   SELECT * FROM get_zone_by_address('asdfqwer zzz');                 -- basura → CERO filas (cae al piso $7.000) ✅
-- Si algún barrio real conocido sale con la zona equivocada, sube 0.55 → 0.62.
-- ═══════════════════════════════════════════════════════════════════
