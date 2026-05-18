-- ============================================================
-- Capitán Nirvana — Schema completo Postgres / Supabase
-- Ejecutar en Supabase SQL Editor (una sola corrida).
-- Idempotente: usa IF NOT EXISTS / DROP IF EXISTS donde aplica.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- ENUMS (tipos cerrados, validados a nivel DB)
-- ─────────────────────────────────────────────────────────────

DO $$ BEGIN
    CREATE TYPE menu_category AS ENUM (
        'Bebidas', 'Sodas Especiales', 'Tostones', 'Hamburguesas',
        'Mexican Food', 'Pastas', 'Sandwich', 'Comida Rápida',
        'Picadas', 'Cajita Rockera', 'Acompañamientos', 'Proteínas',
        'Salsas', 'Bubbles'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE faq_category AS ENUM (
        'Horarios y ubicación', 'Domicilio', 'Pagos',
        'Menú', 'Cancelaciones', 'Servicio'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE payment_method_enum AS ENUM ('Nequi', 'Bancolombia');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE payment_status_enum AS ENUM ('pending', 'verified', 'rejected');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE order_status_enum AS ENUM (
        'received', 'accepted', 'preparing',
        'out_for_delivery', 'delivered', 'cancelled'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE conversation_direction AS ENUM ('in', 'out');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────────────────
-- Trigger genérico para updated_at
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END $$;

-- ─────────────────────────────────────────────────────────────
-- 1. menu
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS menu (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            text NOT NULL UNIQUE,
    category        menu_category NOT NULL,
    description     text,
    base_price_cop  integer NOT NULL CHECK (base_price_cop >= 0),
    variants_json   jsonb,
    options_json    jsonb,
    flavors         text[],                         -- antes coma-separado
    serves_people   smallint NOT NULL DEFAULT 1 CHECK (serves_people > 0),
    available       boolean NOT NULL DEFAULT true,
    prep_minutes    smallint NOT NULL DEFAULT 5 CHECK (prep_minutes >= 0),
    tags            text[],                         -- antes coma-separado
    modificable     boolean NOT NULL DEFAULT false,
    modificaciones  text[],
    adicionable     boolean NOT NULL DEFAULT false,
    adiciones       text[],
    vendible_solo   boolean NOT NULL DEFAULT true,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS menu_category_idx ON menu(category);
CREATE INDEX IF NOT EXISTS menu_available_idx ON menu(available) WHERE available = true;
CREATE INDEX IF NOT EXISTS menu_tags_gin ON menu USING GIN(tags);
DROP TRIGGER IF EXISTS menu_updated_at ON menu;
CREATE TRIGGER menu_updated_at BEFORE UPDATE ON menu
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- 2. faqs
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS faqs (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    question    text NOT NULL,
    answer      text NOT NULL,
    keywords    text[],
    category    faq_category NOT NULL,
    priority    smallint NOT NULL DEFAULT 5 CHECK (priority BETWEEN 1 AND 10),
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS faqs_active_priority_idx ON faqs(is_active, priority DESC);
CREATE INDEX IF NOT EXISTS faqs_keywords_gin ON faqs USING GIN(keywords);
DROP TRIGGER IF EXISTS faqs_updated_at ON faqs;
CREATE TRIGGER faqs_updated_at BEFORE UPDATE ON faqs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- 3. delivery_zones
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS delivery_zones (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    zone_name    text NOT NULL UNIQUE,
    keywords     text[],
    fee_cop      integer NOT NULL CHECK (fee_cop >= 0),
    eta_minutes  smallint NOT NULL CHECK (eta_minutes >= 0),
    is_active    boolean NOT NULL DEFAULT true,
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS delivery_zones_active_idx ON delivery_zones(is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS delivery_zones_keywords_gin ON delivery_zones USING GIN(keywords);
DROP TRIGGER IF EXISTS delivery_zones_updated_at ON delivery_zones;
CREATE TRIGGER delivery_zones_updated_at BEFORE UPDATE ON delivery_zones
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- 4. customers
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS customers (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone               text NOT NULL UNIQUE,           -- formato 573XXXXXXXXX
    name                text NOT NULL,                  -- obligatorio
    preferred_payment   payment_method_enum,
    is_blocked          boolean NOT NULL DEFAULT false,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS customers_phone_idx ON customers(phone);
DROP TRIGGER IF EXISTS customers_updated_at ON customers;
CREATE TRIGGER customers_updated_at BEFORE UPDATE ON customers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- 5. customer_addresses (1 customer → N direcciones)
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS customer_addresses (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     bigint NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    label           text,                                -- "Casa", "Mamá", null
    address         text NOT NULL,
    address_lat     numeric(9,6),                        -- precisión ~10cm
    address_lng     numeric(9,6),
    is_default      boolean NOT NULL DEFAULT false,
    times_used      integer NOT NULL DEFAULT 0,
    last_used_at    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS customer_addresses_customer_idx ON customer_addresses(customer_id);
-- Solo 1 default por customer
CREATE UNIQUE INDEX IF NOT EXISTS customer_addresses_one_default
    ON customer_addresses(customer_id) WHERE is_default = true;
DROP TRIGGER IF EXISTS customer_addresses_updated_at ON customer_addresses;
CREATE TRIGGER customer_addresses_updated_at BEFORE UPDATE ON customer_addresses
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- 6. orders
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS orders (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id                text NOT NULL UNIQUE,        -- CN20260510047
    customer_id             bigint REFERENCES customers(id) ON DELETE SET NULL,
    customer_address_id     bigint REFERENCES customer_addresses(id) ON DELETE SET NULL,
    delivery_zone_id        bigint REFERENCES delivery_zones(id) ON DELETE SET NULL,
    -- Snapshots (para que aunque borren customer/zone, la order conserve la info)
    customer_phone          text NOT NULL,
    customer_name           text NOT NULL,
    address                 text NOT NULL,
    address_lat             numeric(9,6),
    address_lng             numeric(9,6),
    -- Items
    items_json              jsonb NOT NULL,              -- [{name, qty, variant, price, notes}]
    subtotal_cop            integer NOT NULL CHECK (subtotal_cop >= 0),
    delivery_fee_cop        integer NOT NULL CHECK (delivery_fee_cop >= 0),
    total_cop               integer NOT NULL CHECK (total_cop >= 0),
    -- Pago
    payment_method          payment_method_enum NOT NULL,
    payment_proof_url       text,
    payment_status          payment_status_enum NOT NULL DEFAULT 'pending',
    -- Estado
    order_status            order_status_enum NOT NULL DEFAULT 'received',
    scheduled_for           timestamptz,
    special_instructions    text,
    accepted_at             timestamptz,
    delivered_at            timestamptz,
    cancelled_at            timestamptz,
    cancellation_reason     text,
    -- Telegram
    telegram_message_id     text,
    -- Timestamps
    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS orders_customer_idx ON orders(customer_id);
CREATE INDEX IF NOT EXISTS orders_status_idx ON orders(order_status);
CREATE INDEX IF NOT EXISTS orders_payment_status_idx ON orders(payment_status);
CREATE INDEX IF NOT EXISTS orders_created_at_idx ON orders(created_at DESC);
CREATE INDEX IF NOT EXISTS orders_phone_idx ON orders(customer_phone);
DROP TRIGGER IF EXISTS orders_updated_at ON orders;
CREATE TRIGGER orders_updated_at BEFORE UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- 7. conversations (log de mensajes WA)
-- ─────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS conversations (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone           text NOT NULL,
    customer_id     bigint REFERENCES customers(id) ON DELETE SET NULL,
    direction       conversation_direction NOT NULL,
    message_text    text NOT NULL,
    wa_message_id   text NOT NULL UNIQUE,        -- idempotency key
    tokens_in       integer NOT NULL DEFAULT 0,
    tokens_out      integer NOT NULL DEFAULT 0,
    model_used      text,
    cost_usd        numeric(12,6) NOT NULL DEFAULT 0,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS conversations_phone_idx ON conversations(phone, created_at DESC);
CREATE INDEX IF NOT EXISTS conversations_customer_idx ON conversations(customer_id);
CREATE INDEX IF NOT EXISTS conversations_wa_msg_idx ON conversations(wa_message_id);

-- ─────────────────────────────────────────────────────────────
-- VIEWS útiles
-- ─────────────────────────────────────────────────────────────

-- Métricas por customer (reemplaza los Rollups de NocoDB)
CREATE OR REPLACE VIEW customer_stats AS
SELECT
    c.id,
    c.phone,
    c.name,
    COUNT(o.id) FILTER (WHERE o.order_status NOT IN ('cancelled')) AS total_orders,
    COALESCE(SUM(o.total_cop) FILTER (WHERE o.order_status = 'delivered'), 0) AS total_spent_cop,
    MAX(o.accepted_at) AS last_order_at
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.id
GROUP BY c.id, c.phone, c.name;

-- Pedidos pendientes (para dashboard operativo)
CREATE OR REPLACE VIEW pending_orders AS
SELECT *
FROM orders
WHERE payment_status = 'pending'
   OR order_status IN ('received', 'accepted', 'preparing', 'out_for_delivery')
ORDER BY created_at;

-- ─────────────────────────────────────────────────────────────
-- ROW LEVEL SECURITY (RLS)
-- ─────────────────────────────────────────────────────────────
-- Habilitamos RLS en TODAS las tablas. Las policies actuales
-- permiten todo a la `service_role` (lo que usa n8n) y nada
-- a `anon`. Ajustar después si se agrega frontend público.

ALTER TABLE menu ENABLE ROW LEVEL SECURITY;
ALTER TABLE faqs ENABLE ROW LEVEL SECURITY;
ALTER TABLE delivery_zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE customer_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;

-- service_role tiene bypass automático en Supabase, no necesita policy.
-- Si en algún momento expones a anon (p.ej. menú público), agregar policy específica:
-- CREATE POLICY menu_public_read ON menu FOR SELECT TO anon USING (available = true);

-- ============================================================
-- FIN del schema. Verificar con:
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public' ORDER BY table_name;
-- Esperado: 7 tablas (customer_addresses, customers, conversations,
--                      delivery_zones, faqs, menu, orders)
-- ============================================================
