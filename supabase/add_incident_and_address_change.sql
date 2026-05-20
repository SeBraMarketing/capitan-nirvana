-- ═══════════════════════════════════════════════════════════════════
-- Mini-CRM Capitán Nirvana — Migración: novedades + cambio dirección
-- Fecha: 2026-05-20
-- Ejecutar en Supabase SQL Editor DESPUÉS de crm_schema.sql + crm_functions.sql.
-- Idempotente. Reglas nuevas pedidas por dueños CN:
--   1. Cambio de dirección post-pago, antes de out_for_delivery
--   2. (Bot) bloquea cambios al menú post-pago
--   3. Daños/inconformidades → marcar has_incident + notificar
--   4. (CRM) tarjeta roja si has_incident, verde si scheduled_for
-- ═══════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
-- 1. Columnas nuevas en orders (idempotente con IF NOT EXISTS)
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE orders
    ADD COLUMN IF NOT EXISTS has_incident         boolean     NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS incident_reason      text,
    ADD COLUMN IF NOT EXISTS incident_at          timestamptz,
    ADD COLUMN IF NOT EXISTS incident_resolved_at timestamptz;

-- Índices parciales (solo indexan filas con el flag activo)
CREATE INDEX IF NOT EXISTS orders_has_incident_idx
    ON orders (has_incident) WHERE has_incident = true;
CREATE INDEX IF NOT EXISTS orders_scheduled_for_idx
    ON orders (scheduled_for) WHERE scheduled_for IS NOT NULL;


-- ─────────────────────────────────────────────────────────────────
-- 2. Reemplazar apply_order_action con 3 acciones nuevas:
--    change_address | mark_incident | resolve_incident
--    + parámetros opcionales (defaults NULL) → backwards compatible.
--    Firma cambia, por eso DROP+CREATE.
-- ─────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.apply_order_action(text, text, text, text);

CREATE OR REPLACE FUNCTION public.apply_order_action(
    p_order_id    text,
    p_action      text,
    p_actor       text DEFAULT NULL,
    p_source      text DEFAULT 'crm',
    p_new_address text DEFAULT NULL,
    p_reason      text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    o                orders%ROWTYPE;
    v_pay            text;
    v_status         text;
    v_ok             boolean := false;
    v_reason         text;
    v_new_status     text;
    v_new_pay        text;
    v_reply          text;
    v_tg             text;
    v_actor          text := COALESCE(NULLIF(trim(p_actor), ''), 'el equipo');
    v_hora           text := to_char(now() AT TIME ZONE 'America/Bogota', 'HH24:MI');
    -- change_address scratch
    v_old_address    text;
    v_old_fee        integer;
    v_old_total      integer;
    v_old_zone_id    bigint;
    v_zone_row       record;
    v_new_zone_id    bigint;
    v_new_fee        integer;
    v_new_total      integer;
BEGIN
    -- Lock the order row to prevent concurrent transitions
    SELECT * INTO o FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', '⚠️ Pedido no encontrado');
    END IF;

    v_pay    := o.payment_status::text;
    v_status := o.order_status::text;

    -- ═════════════════════════════════════════════════════════════
    -- Validación de transición
    -- ═════════════════════════════════════════════════════════════
    v_ok := CASE p_action
        WHEN 'verify'           THEN v_pay = 'pending'
        WHEN 'reject'           THEN v_pay = 'pending'
        WHEN 'prep'             THEN v_pay = 'verified' AND v_status IN ('accepted','received')
        WHEN 'out'              THEN v_pay = 'verified' AND v_status IN ('accepted','preparing')
        WHEN 'delivered'        THEN v_pay <> 'rejected' AND v_status NOT IN ('delivered','cancelled')
        WHEN 'cancel'           THEN v_status NOT IN ('delivered','cancelled')
        -- Nuevas acciones:
        WHEN 'change_address'   THEN v_pay = 'verified'
                                     AND v_status IN ('received','accepted','preparing')
                                     AND NULLIF(trim(p_new_address), '') IS NOT NULL
        WHEN 'mark_incident'    THEN true                        -- en cualquier estado
        WHEN 'resolve_incident' THEN o.has_incident = true
        ELSE false
    END;

    IF NOT v_ok THEN
        v_reason := CASE p_action
            WHEN 'verify'           THEN format('⚠️ Este pedido ya tiene pago %s (no pending)', v_pay)
            WHEN 'reject'           THEN format('⚠️ El pago ya está %s, no se puede rechazar de nuevo', v_pay)
            WHEN 'prep'             THEN format('⚠️ Falta verificar pago antes de preparar (pago: %s, estado: %s)', v_pay, v_status)
            WHEN 'out'              THEN format('⚠️ No se puede marcar Salida (pago: %s, estado: %s)', v_pay, v_status)
            WHEN 'delivered'        THEN format('⚠️ No se puede marcar Entregado (estado: %s)', v_status)
            WHEN 'cancel'           THEN format('⚠️ Pedido ya está en estado terminal (%s)', v_status)
            WHEN 'change_address'   THEN
                CASE
                    WHEN NULLIF(trim(p_new_address), '') IS NULL
                        THEN '⚠️ Falta p_new_address para cambiar la dirección'
                    WHEN v_pay <> 'verified'
                        THEN format('⚠️ El pedido aún no tiene pago verificado (pago: %s)', v_pay)
                    ELSE format('⚠️ Ya no se puede cambiar la dirección (estado: %s — pedido en camino o cerrado)', v_status)
                END
            WHEN 'resolve_incident' THEN '⚠️ Este pedido no tiene una novedad activa'
            ELSE format('⚠️ Acción ''%s'' no permitida', p_action)
        END;
        RETURN jsonb_build_object('ok', false, 'error', v_reason,
                                  'order_id', p_order_id);
    END IF;

    -- ═════════════════════════════════════════════════════════════
    -- Aplicar transición
    -- ═════════════════════════════════════════════════════════════
    v_new_status := v_status;
    v_new_pay    := v_pay;

    IF p_action = 'verify' THEN
        UPDATE orders SET payment_status='verified', order_status='accepted',
               accepted_at = now() WHERE id = o.id;
        v_new_status := 'accepted'; v_new_pay := 'verified';

    ELSIF p_action = 'reject' THEN
        UPDATE orders SET payment_status='rejected' WHERE id = o.id;
        v_new_pay := 'rejected';

    ELSIF p_action = 'prep' THEN
        UPDATE orders SET order_status='preparing' WHERE id = o.id;
        v_new_status := 'preparing';

    ELSIF p_action = 'out' THEN
        UPDATE orders SET order_status='out_for_delivery' WHERE id = o.id;
        v_new_status := 'out_for_delivery';

    ELSIF p_action = 'delivered' THEN
        UPDATE orders SET order_status='delivered', delivered_at = now() WHERE id = o.id;
        v_new_status := 'delivered';

    ELSIF p_action = 'cancel' THEN
        UPDATE orders SET order_status='cancelled', cancelled_at = now() WHERE id = o.id;
        v_new_status := 'cancelled';

    ELSIF p_action = 'change_address' THEN
        v_old_address := o.address;
        v_old_fee     := o.delivery_fee_cop;
        v_old_total   := o.total_cop;
        v_old_zone_id := o.delivery_zone_id;

        -- Resolver nueva zona/fee desde get_zone_by_address (lookup barrio)
        SELECT zona, barrio_nombre, fee_cop
        INTO v_zone_row
        FROM public.get_zone_by_address(p_new_address);

        IF v_zone_row IS NULL THEN
            -- Sin match: usar FUERA como fallback. fee_cop viene de delivery_zones.
            SELECT id, fee_cop INTO v_new_zone_id, v_new_fee
            FROM delivery_zones WHERE zone_name = 'FUERA' LIMIT 1;
        ELSE
            SELECT id INTO v_new_zone_id
            FROM delivery_zones WHERE zone_name = v_zone_row.zona LIMIT 1;
            v_new_fee := v_zone_row.fee_cop;
        END IF;

        -- Piso de seguridad: nunca domicilio en $0
        IF v_new_fee IS NULL OR v_new_fee = 0 THEN
            v_new_fee := COALESCE(v_old_fee, 6000);
        END IF;

        v_new_total := o.subtotal_cop + v_new_fee;

        UPDATE orders
        SET address          = p_new_address,
            delivery_zone_id = v_new_zone_id,
            delivery_fee_cop = v_new_fee,
            total_cop        = v_new_total
        WHERE id = o.id;

    ELSIF p_action = 'mark_incident' THEN
        UPDATE orders
        SET has_incident         = true,
            incident_reason      = COALESCE(NULLIF(trim(p_reason), ''), o.incident_reason),
            incident_at          = COALESCE(o.incident_at, now()),
            incident_resolved_at = NULL
        WHERE id = o.id;

    ELSIF p_action = 'resolve_incident' THEN
        UPDATE orders
        SET has_incident         = false,
            incident_resolved_at = now()
        WHERE id = o.id;
    END IF;

    -- ═════════════════════════════════════════════════════════════
    -- Timeline (order_status_events)
    -- ═════════════════════════════════════════════════════════════
    INSERT INTO order_status_events (order_id, restaurant_id, action,
            from_status, to_status, payment_status, actor, source)
    VALUES (p_order_id, o.restaurant_id, p_action,
            v_status, v_new_status, v_new_pay, v_actor, p_source);

    -- ═════════════════════════════════════════════════════════════
    -- Mensajes al cliente (reply_text) y al grupo TG (tg_status_text)
    -- ═════════════════════════════════════════════════════════════
    v_reply := CASE p_action
        WHEN 'verify'           THEN format('✅ ¡Pago verificado! Tu pedido *%s* ya entró a cocina. 🎸', p_order_id)
        WHEN 'reject'           THEN format('⚠️ No pudimos verificar tu pago del pedido *%s*. Reenvía el comprobante o llama al 3004647851.', p_order_id)
        WHEN 'prep'             THEN format('👨‍🍳 Tu pedido *%s* está en preparación.', p_order_id)
        WHEN 'out'              THEN format('🛵 Tu pedido *%s* salió en camino. ¡Atento al timbre!', p_order_id)
        WHEN 'delivered'        THEN format('📦 ¡Pedido *%s* entregado! Gracias por pedir en Capitán Nirvana. 🤘', p_order_id)
        WHEN 'cancel'           THEN format('❌ Tu pedido *%s* fue cancelado. Cualquier duda llama al 3004647851.', p_order_id)
        WHEN 'change_address'   THEN format('✅ Actualicé tu pedido *%s* a la nueva dirección. Nuevo total: $%s.', p_order_id, to_char(v_new_total, 'FM999G999'))
        WHEN 'mark_incident'    THEN NULL  -- no se notifica al cliente automáticamente
        WHEN 'resolve_incident' THEN NULL
    END;

    v_tg := CASE p_action
        WHEN 'verify'           THEN format('✅ *Pago verificado* por %s (%s) — pedido *%s* a cocina.', v_actor, v_hora, p_order_id)
        WHEN 'reject'           THEN format('❌ *Pago RECHAZADO* por %s (%s) — pedido *%s*.', v_actor, v_hora, p_order_id)
        WHEN 'prep'             THEN format('👨‍🍳 *En preparación* (%s %s) — *%s*.', v_actor, v_hora, p_order_id)
        WHEN 'out'              THEN format('🛵 *En camino* (%s %s) — *%s*.', v_actor, v_hora, p_order_id)
        WHEN 'delivered'        THEN format('✅ *Entregado* (%s %s) — *%s*.', v_actor, v_hora, p_order_id)
        WHEN 'cancel'           THEN format('❌ *Cancelado* (%s %s) — *%s*.', v_actor, v_hora, p_order_id)
        WHEN 'change_address'   THEN format(
            E'🔄 *CAMBIO DE DIRECCIÓN* — *%s* (%s %s)\n📍 De: %s\n📍 A: %s\n🛵 Domicilio: $%s (antes $%s)\n*TOTAL: $%s* (antes $%s)',
            p_order_id, v_actor, v_hora,
            v_old_address, p_new_address,
            to_char(v_new_fee, 'FM999G999'),  to_char(v_old_fee, 'FM999G999'),
            to_char(v_new_total, 'FM999G999'), to_char(v_old_total, 'FM999G999'))
        WHEN 'mark_incident'    THEN format(
            E'⚠️ *NOVEDAD MARCADA* — *%s* (%s %s)\n📝 %s',
            p_order_id, v_actor, v_hora,
            COALESCE(NULLIF(trim(p_reason), ''), '(sin razón)'))
        WHEN 'resolve_incident' THEN format('✅ *Novedad resuelta* (%s %s) — *%s*.', v_actor, v_hora, p_order_id)
    END;

    -- ═════════════════════════════════════════════════════════════
    -- Retorno
    -- ═════════════════════════════════════════════════════════════
    RETURN jsonb_build_object(
        'ok',              true,
        'order_id',        p_order_id,
        'customer_phone',  o.customer_phone,
        'customer_name',   o.customer_name,
        'action',          p_action,
        'to_status',       v_new_status,
        'payment_status',  v_new_pay,
        'reply_text',      v_reply,
        'tg_status_text',  v_tg,
        -- Solo poblados en change_address:
        'old_address',     CASE WHEN p_action = 'change_address' THEN v_old_address   ELSE NULL END,
        'new_address',     CASE WHEN p_action = 'change_address' THEN p_new_address   ELSE NULL END,
        'old_fee_cop',     CASE WHEN p_action = 'change_address' THEN v_old_fee       ELSE NULL END,
        'new_fee_cop',     CASE WHEN p_action = 'change_address' THEN v_new_fee       ELSE NULL END,
        'old_total_cop',   CASE WHEN p_action = 'change_address' THEN v_old_total     ELSE NULL END,
        'new_total_cop',   CASE WHEN p_action = 'change_address' THEN v_new_total     ELSE NULL END,
        'new_zone',        CASE WHEN p_action = 'change_address' THEN COALESCE(v_zone_row.zona, 'FUERA') ELSE NULL END,
        'new_barrio',      CASE WHEN p_action = 'change_address' THEN v_zone_row.barrio_nombre ELSE NULL END,
        -- Solo en mark/resolve_incident:
        'has_incident',    CASE WHEN p_action IN ('mark_incident','resolve_incident')
                                THEN (p_action = 'mark_incident') ELSE NULL END,
        'incident_reason', CASE WHEN p_action = 'mark_incident'
                                THEN COALESCE(NULLIF(trim(p_reason), ''), o.incident_reason) ELSE NULL END
    );
END $$;

GRANT EXECUTE ON FUNCTION public.apply_order_action(text, text, text, text, text, text)
    TO anon, authenticated, service_role;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- 1. Confirmar columnas:
--    SELECT column_name, data_type, is_nullable, column_default
--    FROM information_schema.columns
--    WHERE table_name = 'orders'
--      AND column_name IN ('has_incident','incident_reason','incident_at','incident_resolved_at','scheduled_for');
--    Esperado: 5 filas (4 nuevas + scheduled_for ya existente).
--
-- 2. Probar mark_incident sobre un pedido cualquiera:
--    SELECT apply_order_action(
--      (SELECT order_id FROM orders ORDER BY created_at DESC LIMIT 1),
--      'mark_incident', 'manu_test', 'crm',
--      NULL,                       -- p_new_address
--      'producto llegó frío'       -- p_reason
--    );
--    → ok:true, has_incident:true, tg_status_text con la razón.
--
-- 3. Probar resolve_incident sobre el mismo:
--    SELECT apply_order_action((mismo order_id), 'resolve_incident', 'manu_test', 'crm');
--    → ok:true, has_incident:false.
--
-- 4. Probar change_address sobre un pedido en estado 'accepted' o 'preparing':
--    SELECT apply_order_action(
--      (SELECT order_id FROM orders WHERE order_status='accepted' AND payment_status='verified' LIMIT 1),
--      'change_address', 'manu_test', 'crm',
--      'Carrera 30 #15-20 Mariluz, Pasto'   -- p_new_address
--    );
--    → ok:true, new_zone, new_fee_cop, new_total_cop, tg_status_text con el diff.
--
-- 5. Probar change_address en estado 'out_for_delivery' (debe FALLAR):
--    SELECT apply_order_action(
--      (SELECT order_id FROM orders WHERE order_status='out_for_delivery' LIMIT 1),
--      'change_address', 'manu_test', 'crm',
--      'Nueva direccion'
--    );
--    → ok:false, error: "Ya no se puede cambiar la dirección...".
-- ═══════════════════════════════════════════════════════════════════
