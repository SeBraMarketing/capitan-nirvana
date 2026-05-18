-- ============================================================
-- Capitán Nirvana — Funciones Postgres (SQL Functions)
-- Ejecutar DESPUÉS de schema.sql + seed.sql
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- upsert_order(payload jsonb) → jsonb
--
-- Función transaccional que en una sola llamada:
--   1. Upserta el customer (busca por phone, crea si no existe, actualiza nombre)
--   2. Resuelve la dirección:
--      - Si payload trae customer_address_id → usa esa
--      - Si no, busca dirección con mismo texto → reusa
--      - Si no existe → crea nueva (la primera del customer queda como default)
--   3. Incrementa times_used y last_used_at en la dirección usada
--   4. Resuelve delivery_zone_id por zone_name (puede ser NULL)
--   5. Inserta la order con todas las FKs ligadas
--   6. Retorna { order_id, order_pk, customer_id, address_id, delivery_zone_id, success }
--
-- Llamada desde n8n vía PostgREST RPC:
--   POST /rest/v1/rpc/upsert_order
--   body: { "payload": { "order_id": "CN...", "customer_phone": "573...", ... } }
--
-- Atómica: si cualquier paso falla, ROLLBACK completo.
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.upsert_order(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_customer_id   bigint;
    v_address_id    bigint;
    v_zone_id       bigint;
    v_order_pk      bigint;
    v_address_text  text;
    v_address_lat   numeric;
    v_address_lng   numeric;
    v_address_label text;
    v_address_is_first boolean;
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
        name = COALESCE(NULLIF(EXCLUDED.name, ''), customers.name),
        preferred_payment = COALESCE(EXCLUDED.preferred_payment, customers.preferred_payment),
        updated_at = now()
    RETURNING id INTO v_customer_id;

    -- ── 2. Resolver address
    v_address_text  := payload->>'address';
    v_address_lat   := NULLIF(payload->>'address_lat', '')::numeric;
    v_address_lng   := NULLIF(payload->>'address_lng', '')::numeric;
    v_address_label := NULLIF(payload->>'address_label', '');

    -- 2a. Si vino address_id explícito (cliente eligió una existente), usarlo
    IF NULLIF(payload->>'customer_address_id', '') IS NOT NULL THEN
        v_address_id := (payload->>'customer_address_id')::bigint;

    -- 2b. Si no, buscar dirección con mismo texto (case-insensitive, trim)
    ELSE
        SELECT id INTO v_address_id
        FROM customer_addresses
        WHERE customer_id = v_customer_id
          AND lower(trim(address)) = lower(trim(v_address_text))
        LIMIT 1;

        -- 2c. Si tampoco existe, crear nueva
        IF v_address_id IS NULL THEN
            -- ¿Es la primera dirección del customer? → marcarla default
            v_address_is_first := NOT EXISTS (
                SELECT 1 FROM customer_addresses WHERE customer_id = v_customer_id
            );

            INSERT INTO customer_addresses (
                customer_id, label, address, address_lat, address_lng, is_default
            ) VALUES (
                v_customer_id,
                v_address_label,
                v_address_text,
                v_address_lat,
                v_address_lng,
                v_address_is_first
            )
            RETURNING id INTO v_address_id;
        END IF;
    END IF;

    -- ── 3. Increment usage de la dirección elegida
    UPDATE customer_addresses
    SET times_used = times_used + 1,
        last_used_at = now()
    WHERE id = v_address_id;

    -- ── 4. Resolver delivery_zone_id (por nombre)
    SELECT id INTO v_zone_id
    FROM delivery_zones
    WHERE zone_name = payload->>'delivery_zone'
      AND is_active = true
    LIMIT 1;

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
        'success', true,
        'order_id', payload->>'order_id',
        'order_pk', v_order_pk,
        'customer_id', v_customer_id,
        'customer_address_id', v_address_id,
        'delivery_zone_id', v_zone_id
    );
END $$;

-- Permitir invocar la función vía PostgREST RPC (api anon y service_role)
GRANT EXECUTE ON FUNCTION public.upsert_order(jsonb) TO anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- list_customer_addresses(p_phone text) → setof customer_addresses
-- Helper para el AI Agent: lista direcciones de un customer.
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.list_customer_addresses(p_phone text)
RETURNS TABLE(
    id bigint,
    label text,
    address text,
    is_default boolean,
    times_used integer,
    last_used_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT ca.id, ca.label, ca.address, ca.is_default, ca.times_used, ca.last_used_at
    FROM customer_addresses ca
    JOIN customers c ON c.id = ca.customer_id
    WHERE c.phone = p_phone
    ORDER BY ca.is_default DESC, ca.times_used DESC;
$$;

GRANT EXECUTE ON FUNCTION public.list_customer_addresses(text) TO anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- delete_customer_address(p_phone text, p_address_id bigint) → boolean
-- Helper para el AI Agent: borra una dirección, validando que pertenezca al customer.
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.delete_customer_address(p_phone text, p_address_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_customer_id bigint;
    v_deleted boolean;
BEGIN
    SELECT id INTO v_customer_id FROM customers WHERE phone = p_phone;
    IF v_customer_id IS NULL THEN
        RETURN false;
    END IF;

    DELETE FROM customer_addresses
    WHERE id = p_address_id AND customer_id = v_customer_id
    RETURNING true INTO v_deleted;

    RETURN COALESCE(v_deleted, false);
END $$;

GRANT EXECUTE ON FUNCTION public.delete_customer_address(text, bigint) TO anon, authenticated, service_role;

-- ============================================================
-- Test rápido (descomentar para probar):
-- SELECT public.upsert_order('{
--     "order_id": "CN20260510TEST",
--     "customer_phone": "573000000000",
--     "customer_name": "Test Cliente",
--     "address": "Calle 18 #25-43, Pasto",
--     "address_lat": "1.218470",
--     "address_lng": "-77.278490",
--     "delivery_zone": "Centro Histórico",
--     "items_json": "[{\"name\":\"Hamburguesa del Capitán\",\"qty\":1,\"price\":31900}]",
--     "subtotal_cop": 31900,
--     "delivery_fee_cop": 6000,
--     "total_cop": 37900,
--     "payment_method": "Nequi"
-- }'::jsonb);
-- ============================================================


-- ─────────────────────────────────────────────────────────────
-- search_menu(p_query text) → setof items
-- Busca items del menú por nombre, descripción, tags, flavors o categoría.
-- Filtra solo items disponibles (available=true) y vendibles solos (vendible_solo=true).
-- Para incluir adiciones, usar search_menu_all.
-- Devuelve max 15 items ordenados por relevancia (prioriza match en nombre).
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.search_menu(p_query text)
RETURNS TABLE(
    id bigint,
    name text,
    category menu_category,
    description text,
    base_price_cop integer,
    flavors text[],
    variants_json jsonb,
    tags text[],
    modificable boolean,
    modificaciones text[],
    adicionable boolean,
    adiciones text[]
)
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT
        m.id, m.name, m.category, m.description, m.base_price_cop,
        m.flavors, m.variants_json, m.tags,
        m.modificable, m.modificaciones, m.adicionable, m.adiciones
    FROM menu m
    WHERE m.available = true
      AND m.vendible_solo = true
      AND (
        m.name ILIKE '%' || p_query || '%'
        OR m.description ILIKE '%' || p_query || '%'
        OR m.category::text ILIKE '%' || p_query || '%'
        OR EXISTS (SELECT 1 FROM unnest(m.tags) t WHERE t ILIKE '%' || p_query || '%')
        OR EXISTS (SELECT 1 FROM unnest(COALESCE(m.flavors, ARRAY[]::text[])) f WHERE f ILIKE '%' || p_query || '%')
      )
    ORDER BY
        CASE WHEN m.name ILIKE p_query || '%' THEN 0
             WHEN m.name ILIKE '%' || p_query || '%' THEN 1
             ELSE 2 END,
        m.base_price_cop
    LIMIT 15;
$$;

GRANT EXECUTE ON FUNCTION public.search_menu(text) TO anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- get_menu_item(p_name text) → 1 item completo
-- Busca un item específico por nombre exacto (case insensitive).
-- Devuelve TODOS los campos incluyendo adiciones, modificaciones, etc.
-- Útil cuando el bot ya identificó el item y necesita precio/variantes exactas.
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.get_menu_item(p_name text)
RETURNS TABLE(
    id bigint,
    name text,
    category menu_category,
    description text,
    base_price_cop integer,
    flavors text[],
    variants_json jsonb,
    options_json jsonb,
    serves_people smallint,
    available boolean,
    prep_minutes smallint,
    tags text[],
    modificable boolean,
    modificaciones text[],
    adicionable boolean,
    adiciones text[],
    vendible_solo boolean
)
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT
        m.id, m.name, m.category, m.description, m.base_price_cop,
        m.flavors, m.variants_json, m.options_json,
        m.serves_people, m.available, m.prep_minutes,
        m.tags, m.modificable, m.modificaciones,
        m.adicionable, m.adiciones, m.vendible_solo
    FROM menu m
    WHERE lower(m.name) = lower(p_name)
       OR m.name ILIKE p_name || '%'
       OR p_name ILIKE m.name || '%'
    ORDER BY
        CASE WHEN lower(m.name) = lower(p_name) THEN 0 ELSE 1 END
    LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_menu_item(text) TO anon, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────
-- upsert_customer_address(p_phone, p_name, p_address, p_label) → bigint
-- Guarda/actualiza una direccion del cliente SIN requerir un pedido.
-- Llamada por el nodo determinista "Guardar Direccion" del workflow.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.upsert_customer_address(
    p_phone text, p_name text, p_address text, p_label text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_customer_id bigint; v_addr_id bigint; v_count int;
BEGIN
  SELECT id INTO v_customer_id FROM customers WHERE phone = p_phone;
  IF v_customer_id IS NULL THEN
    INSERT INTO customers (phone, name)
    VALUES (p_phone, COALESCE(NULLIF(trim(p_name),''),'Cliente'))
    RETURNING id INTO v_customer_id;
  ELSIF NULLIF(trim(p_name),'') IS NOT NULL THEN
    UPDATE customers SET name = p_name
    WHERE id = v_customer_id AND (name IS NULL OR name = 'Cliente');
  END IF;
  SELECT count(*) INTO v_count FROM customer_addresses WHERE customer_id = v_customer_id;
  SELECT id INTO v_addr_id FROM customer_addresses
    WHERE customer_id = v_customer_id
      AND lower(coalesce(label,'')) = lower(coalesce(p_label,'')) LIMIT 1;
  IF v_addr_id IS NULL THEN
    INSERT INTO customer_addresses (customer_id, label, address, is_default)
    VALUES (v_customer_id, NULLIF(trim(p_label),''), p_address, (v_count = 0))
    RETURNING id INTO v_addr_id;
  ELSE
    UPDATE customer_addresses
    SET address = p_address, label = COALESCE(NULLIF(trim(p_label),''), label)
    WHERE id = v_addr_id;
  END IF;
  RETURN v_addr_id;
END $$;
GRANT EXECUTE ON FUNCTION public.upsert_customer_address(text,text,text,text)
  TO anon, authenticated, service_role;
