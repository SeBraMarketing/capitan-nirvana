-- ═══════════════════════════════════════════════════════════════════
-- 2026-05-29 — Capi: gate de mediodía (11:45am–2:59pm Bogotá)
--
-- Capi solo está activo desde las 3:00pm. Entre 11:45am y 2:59pm el bot
-- manda UNA imagen del menú de almuerzos por teléfono por día y luego
-- guarda silencio (el equipo manual atiende esos pedidos). Antes de
-- 11:45am: silencio total. Esta migración aporta el dedup atómico que
-- usa el workflow n8n DgHRnNKolFrf74QE.
--
-- Idempotente: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE FUNCTION.
-- ═══════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS public.bot_lunch_menu_dispatch (
    phone     text NOT NULL,
    date_sent date NOT NULL DEFAULT (now() AT TIME ZONE 'America/Bogota')::date,
    sent_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (phone, date_sent)
);

CREATE OR REPLACE FUNCTION public.bot_lunch_menu_try_dispatch(p_phone text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    WITH ins AS (
        INSERT INTO public.bot_lunch_menu_dispatch (phone, date_sent)
        VALUES (p_phone, (now() AT TIME ZONE 'America/Bogota')::date)
        ON CONFLICT DO NOTHING
        RETURNING 1
    )
    SELECT EXISTS (SELECT 1 FROM ins);
$$;

GRANT EXECUTE ON FUNCTION public.bot_lunch_menu_try_dispatch(text)
    TO anon, authenticated, service_role;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- 1. Primer intento del día:
--    SELECT bot_lunch_menu_try_dispatch('573001112233');  -- → t
--    SELECT bot_lunch_menu_try_dispatch('573001112233');  -- → f (ya marcado)
--    SELECT * FROM bot_lunch_menu_dispatch WHERE phone='573001112233';
--
-- 2. Otro teléfono el mismo día:
--    SELECT bot_lunch_menu_try_dispatch('573009998877');  -- → t
--
-- 3. Reset manual (debug):
--    DELETE FROM bot_lunch_menu_dispatch
--    WHERE date_sent = (now() AT TIME ZONE 'America/Bogota')::date;
-- ═══════════════════════════════════════════════════════════════════
