-- ═══════════════════════════════════════════════════════════════════
-- 2026-05-24 — Pago en EFECTIVO (contra entrega) + Teléfono de entrega
--
-- 1) Efectivo: tercer método de pago. NO hay transferencia que verificar →
--    el pedido nace payment_status='verified' + order_status='accepted' y
--    entra directo a "En cocina" (el cajero cobra al entregar). El flujo de
--    comprobante (Get Latest Pending Order filtra payment_status='pending')
--    nunca se dispara para efectivo.
-- 2) contact_phone: teléfono de contacto para la entrega (puede ser de quien
--    recibe). Separado de customer_phone (el WhatsApp/clave de sesión).
--
-- Idempotente. Ejecutar en Supabase SQL Editor.
-- ═══════════════════════════════════════════════════════════════════

-- ── 1. Nuevo valor del enum de método de pago ──────────────────────
--    (text-compare en la función; el cast a enum solo corre en runtime,
--     así que es seguro en la misma corrida.)
ALTER TYPE payment_method_enum ADD VALUE IF NOT EXISTS 'Efectivo';

-- ── 2. Columna de teléfono de entrega ──────────────────────────────
ALTER TABLE orders ADD COLUMN IF NOT EXISTS contact_phone text;

-- ── 3. upsert_order: guarda contact_phone y, si es Efectivo, crea la
--       orden ya verificada + aceptada (entra a cocina sin verificación).
-- ═══════════════════════════════════════════════════════════════════
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
    v_is_cash            boolean := (payload->>'payment_method') = 'Efectivo';
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
    --    Efectivo → verified + accepted (sin verificación de transferencia).
    --    Resto (Nequi/Bancolombia) → pending + received (flujo de comprobante).
    INSERT INTO orders (
        order_id, customer_id, customer_address_id, delivery_zone_id,
        customer_phone, customer_name, contact_phone,
        address, address_lat, address_lng,
        items_json,
        subtotal_cop, delivery_fee_cop, total_cop,
        payment_method, payment_status, order_status, accepted_at,
        scheduled_for, special_instructions
    ) VALUES (
        payload->>'order_id',
        v_customer_id,
        v_address_id,
        v_zone_id,
        payload->>'customer_phone',
        payload->>'customer_name',
        COALESCE(NULLIF(payload->>'contact_phone', ''), payload->>'customer_phone'),
        v_address_text,
        v_address_lat,
        v_address_lng,
        (payload->>'items_json')::jsonb,
        (payload->>'subtotal_cop')::integer,
        (payload->>'delivery_fee_cop')::integer,
        (payload->>'total_cop')::integer,
        (payload->>'payment_method')::payment_method_enum,
        (CASE WHEN v_is_cash THEN 'verified' ELSE 'pending' END)::payment_status_enum,
        (CASE WHEN v_is_cash THEN 'accepted' ELSE 'received' END)::order_status_enum,
        (CASE WHEN v_is_cash THEN now() ELSE NULL END),
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
        'delivery_zone_id',    v_zone_id,
        'is_cash',             v_is_cash
    );
END $$;

GRANT EXECUTE ON FUNCTION public.upsert_order(jsonb) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- SELECT enum_range(NULL::payment_method_enum);  -- {Nequi,Bancolombia,Efectivo}
-- SELECT upsert_order('{"order_id":"CNTEST001","customer_phone":"573000000000",
--   "customer_name":"Prueba","contact_phone":"573111111111","address":"Centro",
--   "delivery_zone":"Zona 1","items_json":[{"name":"X","qty":1,"price":10000}],
--   "subtotal_cop":10000,"delivery_fee_cop":6000,"total_cop":16000,
--   "payment_method":"Efectivo"}'::jsonb);
-- SELECT order_id, payment_method, payment_status, order_status, contact_phone
--   FROM orders WHERE order_id='CNTEST001';
--   -- Esperado: Efectivo | verified | accepted | 573111111111
-- DELETE FROM orders WHERE order_id='CNTEST001';
-- ═══════════════════════════════════════════════════════════════════
