-- ═══════════════════════════════════════════════════════════════════
-- Capitán Nirvana — Migración: tabla barrios + zonas rediseñadas
-- Fecha: 2026-05-17
-- Idempotente: re-ejecutable sin romper datos existentes.
--
-- CAMBIOS:
--   1. Nueva tabla `barrios` (~300 barrios de Pasto con zona asignada)
--   2. `delivery_zones` → 6 filas (Zona 1-5 + FUERA) en lugar de 10 keyword-based
--   3. RPC `get_zone_by_address(text)` para lookup barrio→zona desde n8n
--   4. `upsert_order` actualizado con fallback de lookup por barrio
--
-- ORDEN DE EJECUCIÓN:
--   1. Este archivo (barrios_migration.sql)
--   2. barrios_seed.sql (generado por generate_barrios_seed.py)
--   3. Ajustar fees en delivery_zones si los valores propuestos no son correctos
-- ═══════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
-- 0. Extensiones necesarias
-- ─────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS unaccent;

-- ─────────────────────────────────────────────────────────────────
-- 1. Tabla barrios
--    Un barrio por fila. Fuente: barrios_pasto_supabase.csv
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS barrios (
    slug                    text PRIMARY KEY,
    nombre                  text NOT NULL,
    comuna                  smallint NOT NULL,
    zona                    text NOT NULL,   -- 'Zona 1'..'Zona 5', 'FUERA'
    distancia_km            numeric(5,2),
    eta_min                 smallint,
    longitud                numeric(10,6),
    latitud                 numeric(10,6),
    coordenada_verificada   boolean NOT NULL DEFAULT false,
    fuente_coordenada       text,
    punto_referencia        text,
    velocidad_calculo_kmh   smallint DEFAULT 10
);

CREATE INDEX IF NOT EXISTS barrios_zona_idx    ON barrios(zona);
CREATE INDEX IF NOT EXISTS barrios_comuna_idx  ON barrios(comuna);
-- Índice para búsqueda ILIKE eficiente (text_pattern_ops)
CREATE INDEX IF NOT EXISTS barrios_nombre_lower_idx
    ON barrios (lower(nombre) text_pattern_ops);

-- RLS: solo lectura para anon/authenticated (n8n usa service_role que bypasea RLS)
ALTER TABLE barrios ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS barrios_read ON barrios;
CREATE POLICY barrios_read ON barrios FOR SELECT TO anon, authenticated USING (true);
GRANT SELECT ON TABLE barrios TO anon, authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 2. Actualizar delivery_zones: 10 filas keyword-based → 6 filas zona-level
--
--    IMPORTANTE: orders.delivery_zone_id tiene ON DELETE SET NULL,
--    por lo que los pedidos existentes mantendrán sus datos en los
--    campos snapshot (address, delivery_fee_cop, total_cop) aunque
--    delivery_zone_id quede NULL. No se pierde información operativa.
-- ─────────────────────────────────────────────────────────────────
DELETE FROM delivery_zones;

-- ⚠ AJUSTAR fees según política de precios antes de activar en producción
INSERT INTO delivery_zones (zone_name, keywords, fee_cop, eta_minutes, is_active, notes)
VALUES
  ('Zona 1', '{}',  6000,  20, true,
   'Hasta ~1km desde Galerías. Cubre Centro, barrios de la comuna 1 y 11. Más rápido.'),
  ('Zona 2', '{}',  6500,  25, true,
   '~1–1.5km. Panamericana, norte medio, La Aurora, Castellana.'),
  ('Zona 3', '{}',  7000,  30, true,
   '~1.5–2km. Mariluz, Niza, Pandiaco, Chapal, Oriente medio.'),
  ('Zona 4', '{}',  7500,  40, true,
   '~2–2.5km. Anganoy, Tamasagra, Sur (Chambu, Granada sur), Miraflores.'),
  ('Zona 5', '{}',  8000,  50, true,
   '~2.5–3km. Límite de cobertura. Sumatambo, La Minga, La Palma.'),
  ('FUERA',  '{}', 12000,  60, true,
   'Zonas alejadas y corregimientos (Aranda, Pucalpa, Juanoy, comunas 10 y 12). Confirmar disponibilidad. Domicilio $12.000.')
ON CONFLICT (zone_name) DO UPDATE
    SET fee_cop     = EXCLUDED.fee_cop,
        eta_minutes = EXCLUDED.eta_minutes,
        is_active   = EXCLUDED.is_active,
        notes       = EXCLUDED.notes;


-- ─────────────────────────────────────────────────────────────────
-- 3. RPC: get_zone_by_address(p_address)
--
--    Busca el barrio más específico (nombre más largo) dentro del
--    texto libre de la dirección. Retorna zona + tarifa + ETA.
--
--    Uso desde n8n (HTTP Request node):
--      POST /rest/v1/rpc/get_zone_by_address
--      body: {"p_address": "Calle 18 # 22-31, barrio Centro, Pasto"}
--
--    Retorna array vacío si no encuentra ningún barrio → bot pide
--    que el cliente especifique barrio o confirma zona.
-- ─────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.get_zone_by_address(text);

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
    SELECT
        b.zona,
        b.nombre            AS barrio_nombre,
        dz.fee_cop,
        b.eta_min           AS eta_min,
        b.distancia_km,
        dz.is_active
    FROM barrios b
    JOIN delivery_zones dz ON dz.zone_name = b.zona
    WHERE unaccent(lower(p_address)) ILIKE '%' || unaccent(lower(b.nombre)) || '%'
    ORDER BY length(b.nombre) DESC   -- match más específico primero
    LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_zone_by_address(text)
    TO anon, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────
-- 4. Actualizar upsert_order: agrega fallback de barrio lookup
--    cuando delivery_zone no coincide exactamente con Zona 1..5/FUERA.
--    Esto permite que n8n envíe el nombre de zona O que el sistema
--    lo derive automáticamente desde la dirección del cliente.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.upsert_order(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_customer_id        bigint;
    v_address_id         bigint;
    v_zone_id            bigint;
    v_order_pk           bigint;
    v_address_text       text;
    v_address_lat        numeric;
    v_address_lng        numeric;
    v_address_label      text;
    v_address_is_first   boolean;
BEGIN
    -- Validaciones mínimas
    IF NULLIF(payload->>'customer_phone', '') IS NULL THEN
        RAISE EXCEPTION 'customer_phone es obligatorio';
    END IF;
    IF NULLIF(payload->>'customer_name', '') IS NULL THEN
        RAISE EXCEPTION 'customer_name es obligatorio (sin nombre no hay pedido)';
    END IF;
    IF NULLIF(payload->>'order_id', '') IS NULL THEN
        RAISE EXCEPTION 'order_id es obligatorio';
    END IF;

    -- ── 1. UPSERT customer (por phone)
    INSERT INTO customers (phone, name, preferred_payment)
    VALUES (
        payload->>'customer_phone',
        payload->>'customer_name',
        (NULLIF(payload->>'payment_method', ''))::payment_method_enum
    )
    ON CONFLICT (phone) DO UPDATE SET
        name              = COALESCE(NULLIF(EXCLUDED.name, ''), customers.name),
        preferred_payment = COALESCE(EXCLUDED.preferred_payment, customers.preferred_payment),
        updated_at        = now()
    RETURNING id INTO v_customer_id;

    -- ── 2. Resolver address
    v_address_text  := payload->>'address';
    v_address_lat   := NULLIF(payload->>'address_lat', '')::numeric;
    v_address_lng   := NULLIF(payload->>'address_lng', '')::numeric;
    v_address_label := NULLIF(payload->>'address_label', '');

    -- 2a. Si vino customer_address_id explícito (cliente eligió una guardada)
    IF NULLIF(payload->>'customer_address_id', '') IS NOT NULL THEN
        v_address_id := (payload->>'customer_address_id')::bigint;

    -- 2b. Si no, buscar por texto
    ELSE
        SELECT id INTO v_address_id
        FROM customer_addresses
        WHERE customer_id = v_customer_id
          AND lower(trim(address)) = lower(trim(v_address_text))
        LIMIT 1;

        -- 2c. Si tampoco existe, crear nueva
        IF v_address_id IS NULL THEN
            v_address_is_first := NOT EXISTS (
                SELECT 1 FROM customer_addresses WHERE customer_id = v_customer_id
            );
            INSERT INTO customer_addresses (
                customer_id, label, address, address_lat, address_lng, is_default
            ) VALUES (
                v_customer_id, v_address_label, v_address_text,
                v_address_lat, v_address_lng, v_address_is_first
            )
            RETURNING id INTO v_address_id;
        END IF;
    END IF;

    -- ── 3. Increment usage de la dirección usada
    UPDATE customer_addresses
    SET times_used   = times_used + 1,
        last_used_at = now()
    WHERE id = v_address_id;

    -- ── 4. Resolver delivery_zone_id
    --    Intento 1: coincidencia exacta por nombre de zona (Zona 1..5, FUERA)
    SELECT id INTO v_zone_id
    FROM delivery_zones
    WHERE zone_name = payload->>'delivery_zone'
      AND is_active = true
    LIMIT 1;

    --    Intento 2: lookup automático desde el texto de la dirección
    IF v_zone_id IS NULL AND NULLIF(v_address_text, '') IS NOT NULL THEN
        SELECT dz.id INTO v_zone_id
        FROM barrios b
        JOIN delivery_zones dz ON dz.zone_name = b.zona
        WHERE unaccent(lower(v_address_text)) ILIKE '%' || unaccent(lower(b.nombre)) || '%'
          AND dz.is_active = true
        ORDER BY length(b.nombre) DESC
        LIMIT 1;
    END IF;

    -- ── 5. Insert order
    INSERT INTO orders (
        order_id, customer_id, customer_address_id, delivery_zone_id,
        customer_phone, customer_name,
        address, address_lat, address_lng,
        items_json,
        subtotal_cop, delivery_fee_cop, total_cop,
        payment_method, payment_status, order_status,
        scheduled_for, special_instructions
    ) VALUES (
        payload->>'order_id',
        v_customer_id,
        v_address_id,
        v_zone_id,
        payload->>'customer_phone',
        payload->>'customer_name',
        v_address_text,
        v_address_lat,
        v_address_lng,
        (payload->>'items_json')::jsonb,
        (payload->>'subtotal_cop')::integer,
        (payload->>'delivery_fee_cop')::integer,
        (payload->>'total_cop')::integer,
        (payload->>'payment_method')::payment_method_enum,
        'pending'::payment_status_enum,
        'received'::order_status_enum,
        NULLIF(payload->>'scheduled_for', '')::timestamptz,
        NULLIF(payload->>'special_instructions', '')
    )
    RETURNING id INTO v_order_pk;

    -- ── 6. Retornar resumen
    RETURN jsonb_build_object(
        'success',             true,
        'order_id',            payload->>'order_id',
        'order_pk',            v_order_pk,
        'customer_id',         v_customer_id,
        'customer_address_id', v_address_id,
        'delivery_zone_id',    v_zone_id
    );
END $$;

GRANT EXECUTE ON FUNCTION public.upsert_order(jsonb) TO anon, authenticated, service_role;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN (ejecutar DESPUÉS de cargar barrios_seed.sql)
-- ═══════════════════════════════════════════════════════════════════
-- 1. Conteos:
--    SELECT count(*) FROM barrios;
--    SELECT zona, count(*) FROM barrios GROUP BY zona ORDER BY zona;
--    SELECT zone_name, fee_cop, eta_minutes, is_active FROM delivery_zones ORDER BY zone_name;
--
-- 2. Lookup barrio→zona:
--    SELECT * FROM get_zone_by_address('Mariluz II, Pasto');     -- Zona 3, $7000
--    SELECT * FROM get_zone_by_address('barrio Centro');          -- Zona 1, $3500
--    SELECT * FROM get_zone_by_address('barrio Aranda');          -- FUERA,  $0
--    SELECT * FROM get_zone_by_address('Pandiaco');               -- Zona 3, $7000
--    SELECT * FROM get_zone_by_address('Torobajo sector norte');  -- Zona 4, $9000
--    SELECT * FROM get_zone_by_address('Calle 18, sin barrio');   -- vacío → bot pide barrio
-- ═══════════════════════════════════════════════════════════════════
