-- ═══════════════════════════════════════════════════════════════════
-- Mini-CRM Capitán Nirvana — Fase 0: schema multi-tenant-ready + timeline
-- Fecha: 2026-05-17
-- Idempotente. Ejecutar en Supabase SQL Editor (una corrida).
-- ADITIVA: no rompe el bot (columnas nullable + default, workflow intacto).
-- Orden: este archivo PRIMERO, luego crm_functions.sql.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────
-- 1. TENANT: restaurants
-- ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS restaurants (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug                text NOT NULL UNIQUE,
    name                text NOT NULL,
    brand_accent        text NOT NULL DEFAULT '#E5484D',  -- color de acento para white-label
    wa_phone_number_id  text,                              -- phoneNumberId de WhatsApp Cloud por tenant
    timezone            text NOT NULL DEFAULT 'America/Bogota',
    is_active           boolean NOT NULL DEFAULT true,
    created_at          timestamptz NOT NULL DEFAULT now()
);

-- Seed del tenant Capitán Nirvana (idempotente)
INSERT INTO restaurants (slug, name, wa_phone_number_id)
VALUES ('capitan-nirvana', 'Capitán Nirvana', '1172762645910681')
ON CONFLICT (slug) DO NOTHING;

-- ───────────────────────────────────────────────────────────────────
-- 2. restaurant_members: auth.users ↔ restaurant + rol
-- ───────────────────────────────────────────────────────────────────
DO $$ BEGIN
    CREATE TYPE crm_role AS ENUM ('owner', 'manager', 'gestor', 'cocina');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS restaurant_members (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    restaurant_id   bigint NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
    user_id         uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role            crm_role NOT NULL DEFAULT 'gestor',
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (restaurant_id, user_id)
);
CREATE INDEX IF NOT EXISTS restaurant_members_user_idx ON restaurant_members(user_id);

-- Helper: restaurantes del usuario autenticado (para RLS, sin recursión)
CREATE OR REPLACE FUNCTION public.current_user_restaurants()
RETURNS SETOF bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT restaurant_id FROM restaurant_members WHERE user_id = auth.uid();
$$;
GRANT EXECUTE ON FUNCTION public.current_user_restaurants() TO authenticated;

-- ───────────────────────────────────────────────────────────────────
-- 3. restaurant_id (FK nullable) en tablas de dominio + backfill + default
--    Default = id del tenant CN → inserts del bot (upsert_order) lo
--    heredan sin tocar el workflow.
-- ───────────────────────────────────────────────────────────────────
ALTER TABLE orders          ADD COLUMN IF NOT EXISTS restaurant_id bigint REFERENCES restaurants(id) ON DELETE SET NULL;
ALTER TABLE customers       ADD COLUMN IF NOT EXISTS restaurant_id bigint REFERENCES restaurants(id) ON DELETE SET NULL;
ALTER TABLE menu            ADD COLUMN IF NOT EXISTS restaurant_id bigint REFERENCES restaurants(id) ON DELETE SET NULL;
ALTER TABLE delivery_zones  ADD COLUMN IF NOT EXISTS restaurant_id bigint REFERENCES restaurants(id) ON DELETE SET NULL;
ALTER TABLE barrios         ADD COLUMN IF NOT EXISTS restaurant_id bigint REFERENCES restaurants(id) ON DELETE SET NULL;

DO $$
DECLARE
    v_cn bigint;
    t text;
BEGIN
    SELECT id INTO v_cn FROM restaurants WHERE slug = 'capitan-nirvana';
    FOREACH t IN ARRAY ARRAY['orders','customers','menu','delivery_zones','barrios'] LOOP
        EXECUTE format('UPDATE %I SET restaurant_id = %L WHERE restaurant_id IS NULL', t, v_cn);
        EXECUTE format('ALTER TABLE %I ALTER COLUMN restaurant_id SET DEFAULT %L', t, v_cn);
    END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS orders_restaurant_idx ON orders(restaurant_id, created_at DESC);

-- ───────────────────────────────────────────────────────────────────
-- 4. order_status_events: timeline (auditoría + métricas de tiempo)
-- ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS order_status_events (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id        text NOT NULL,
    restaurant_id   bigint REFERENCES restaurants(id) ON DELETE SET NULL,
    action          text NOT NULL,             -- verify|reject|prep|out|delivered|cancel
    from_status     text,
    to_status       text,
    payment_status  text,
    actor           text,                      -- nombre del gestor / 'bot'
    source          text NOT NULL DEFAULT 'crm',  -- crm|telegram|bot
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ose_order_idx       ON order_status_events(order_id, created_at);
CREATE INDEX IF NOT EXISTS ose_restaurant_idx  ON order_status_events(restaurant_id, created_at DESC);

-- ───────────────────────────────────────────────────────────────────
-- 5. RLS — la app (Supabase Auth) ve solo lo de SUS restaurantes.
--    n8n/bot usan service_role → bypass RLS (no se rompe nada).
-- ───────────────────────────────────────────────────────────────────
ALTER TABLE restaurants          ENABLE ROW LEVEL SECURITY;
ALTER TABLE restaurant_members   ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_status_events  ENABLE ROW LEVEL SECURITY;
-- orders ya tiene RLS habilitada desde schema.sql (sin policies → solo le agregamos SELECT para miembros)

DROP POLICY IF EXISTS restaurants_member_read ON restaurants;
CREATE POLICY restaurants_member_read ON restaurants
    FOR SELECT TO authenticated
    USING (id IN (SELECT public.current_user_restaurants()));

DROP POLICY IF EXISTS rm_self_read ON restaurant_members;
CREATE POLICY rm_self_read ON restaurant_members
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());

DROP POLICY IF EXISTS orders_member_read ON orders;
CREATE POLICY orders_member_read ON orders
    FOR SELECT TO authenticated
    USING (restaurant_id IN (SELECT public.current_user_restaurants()));

DROP POLICY IF EXISTS ose_member_read ON order_status_events;
CREATE POLICY ose_member_read ON order_status_events
    FOR SELECT TO authenticated
    USING (restaurant_id IN (SELECT public.current_user_restaurants()));

GRANT SELECT ON orders, order_status_events, restaurants, restaurant_members TO authenticated;

-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- SELECT * FROM restaurants;                                  -- 1 fila: capitan-nirvana
-- SELECT count(*) FILTER (WHERE restaurant_id IS NULL) FROM orders;  -- 0 (todo backfilled)
-- \d+ orders   -- restaurant_id con DEFAULT al id de CN
-- El bot sigue funcionando: upsert_order inserta y restaurant_id se autollena por DEFAULT.
-- ═══════════════════════════════════════════════════════════════════
