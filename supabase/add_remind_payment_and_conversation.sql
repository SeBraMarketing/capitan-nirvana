-- ═══════════════════════════════════════════════════════════════════
-- Mini-CRM Capitán Nirvana — Migración: Recordar Pago + Historial conv.
-- Fecha: 2026-05-20
-- Ejecutar DESPUÉS de add_incident_and_address_change.sql.
-- Idempotente.
--
-- Cambios:
--   1. Acción cancel: nuevo reply_text + insert de marker [SISTEMA]
--      CANCELADO en chat memory para que Capi arranque limpio.
--   2. Acción nueva 'remind_payment': solo válida en payment_status='pending',
--      no cambia estado, manda recordatorio al cliente.
--   3. ALTER TABLE n8n_chat_memory_cn: agregar created_at para historial.
--   4. RPC get_customer_conversation: historial filtrado para el CRM.
-- ═══════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
-- 1. created_at en chat memory (necesario para historial con timestamps)
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE n8n_chat_memory_cn
    ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS n8n_chat_memory_cn_session_idx
    ON n8n_chat_memory_cn (session_id, id);


-- ─────────────────────────────────────────────────────────────────
-- 2. apply_order_action — CREATE OR REPLACE con cambios:
--    - cancel: nuevo reply_text + INSERT marker
--    - remind_payment: nueva acción
--    Mantiene TODAS las acciones previas (verify/reject/prep/out/delivered/
--    cancel/change_address/mark_incident/resolve_incident).
--    Firma sin cambios (mismos 6 params del plan 1).
-- ─────────────────────────────────────────────────────────────────
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
        WHEN 'change_address'   THEN v_pay = 'verified'
                                     AND v_status IN ('received','accepted','preparing')
                                     AND NULLIF(trim(p_new_address), '') IS NOT NULL
        WHEN 'mark_incident'    THEN true
        WHEN 'resolve_incident' THEN o.has_incident = true
        -- Nueva acción: recordar pago. Solo en pending. No cambia estado.
        WHEN 'remind_payment'   THEN v_pay = 'pending'
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
            WHEN 'remind_payment'   THEN format('⚠️ No tiene sentido recordar pago: el pedido ya está %s', v_pay)
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

        -- Marker en chat memory para que Capi sepa que el carrito quedó CERRADO.
        -- Mismo patrón que el marker CONFIRMADO que escribe Guardar Turno Pedido.
        INSERT INTO n8n_chat_memory_cn (session_id, message)
        VALUES (
            o.customer_phone,
            jsonb_build_object(
                'type', 'ai',
                'content', '[SISTEMA] Pedido ' || p_order_id || ' CANCELADO. El carrito anterior queda CERRADO. Si el cliente vuelve a escribir es un PEDIDO NUEVO, empezar carrito vacio.'
            )
        );

    ELSIF p_action = 'change_address' THEN
        v_old_address := o.address;
        v_old_fee     := o.delivery_fee_cop;
        v_old_total   := o.total_cop;
        v_old_zone_id := o.delivery_zone_id;

        SELECT zona, barrio_nombre, fee_cop
        INTO v_zone_row
        FROM public.get_zone_by_address(p_new_address);

        IF v_zone_row IS NULL THEN
            SELECT id, fee_cop INTO v_new_zone_id, v_new_fee
            FROM delivery_zones WHERE zone_name = 'FUERA' LIMIT 1;
        ELSE
            SELECT id INTO v_new_zone_id
            FROM delivery_zones WHERE zone_name = v_zone_row.zona LIMIT 1;
            v_new_fee := v_zone_row.fee_cop;
        END IF;

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

    -- remind_payment: no cambia estado, no hace UPDATE. Solo registra evento + reply.
    END IF;

    -- ═════════════════════════════════════════════════════════════
    -- Timeline
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
        -- Nuevo cancel message (más cálido, invita a volver)
        WHEN 'cancel'           THEN format('❌ Tu pedido *%s* fue cancelado. Cuando quieras hacer otro pedido, acá estamos al pie. ¡Vuelve a escribirme cuando quieras! 🎸🤘', p_order_id)
        WHEN 'change_address'   THEN format('✅ Actualicé tu pedido *%s* a la nueva dirección. Nuevo total: $%s.', p_order_id, to_char(v_new_total, 'FM999G999'))
        WHEN 'mark_incident'    THEN NULL
        WHEN 'resolve_incident' THEN NULL
        -- Recordatorio de pago (estilo Capi)
        WHEN 'remind_payment'   THEN format(
            '🎸 ¡Hola! Por acá te recuerdo que aún no hemos recibido tu pago del pedido *%s*. Cuando puedas, mándame la *captura* de tu transferencia (Nequi 3004647851 — Café Bar Capitán Nirvana) y mando tu pedido a cocina. 📸🤘',
            p_order_id)
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
        -- Auditoria TG del recordatorio
        WHEN 'remind_payment'   THEN format('🔔 *Recordatorio pago* enviado por %s (%s) — pedido *%s* sigue pending.', v_actor, v_hora, p_order_id)
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
        'old_address',     CASE WHEN p_action = 'change_address' THEN v_old_address   ELSE NULL END,
        'new_address',     CASE WHEN p_action = 'change_address' THEN p_new_address   ELSE NULL END,
        'old_fee_cop',     CASE WHEN p_action = 'change_address' THEN v_old_fee       ELSE NULL END,
        'new_fee_cop',     CASE WHEN p_action = 'change_address' THEN v_new_fee       ELSE NULL END,
        'old_total_cop',   CASE WHEN p_action = 'change_address' THEN v_old_total     ELSE NULL END,
        'new_total_cop',   CASE WHEN p_action = 'change_address' THEN v_new_total     ELSE NULL END,
        'new_zone',        CASE WHEN p_action = 'change_address' THEN COALESCE(v_zone_row.zona, 'FUERA') ELSE NULL END,
        'new_barrio',      CASE WHEN p_action = 'change_address' THEN v_zone_row.barrio_nombre ELSE NULL END,
        'has_incident',    CASE WHEN p_action IN ('mark_incident','resolve_incident')
                                THEN (p_action = 'mark_incident') ELSE NULL END,
        'incident_reason', CASE WHEN p_action = 'mark_incident'
                                THEN COALESCE(NULLIF(trim(p_reason), ''), o.incident_reason) ELSE NULL END
    );
END $$;

GRANT EXECUTE ON FUNCTION public.apply_order_action(text, text, text, text, text, text)
    TO anon, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────
-- 3. RPC get_customer_conversation(p_phone, p_limit)
--    Retorna el historial limpio (sin markers internos) de un cliente.
--    Para uso desde el OrderSheet del CRM.
-- ─────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.get_customer_conversation(text, int);

CREATE OR REPLACE FUNCTION public.get_customer_conversation(
    p_phone text,
    p_limit int DEFAULT 50
)
RETURNS TABLE(
    id          bigint,
    created_at  timestamptz,
    role        text,
    content     text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        cm.id,
        cm.created_at,
        cm.message->>'type'    AS role,
        cm.message->>'content' AS content
    FROM n8n_chat_memory_cn cm
    WHERE cm.session_id = p_phone
      AND NOT (
          cm.message->>'content' LIKE '[SISTEMA]%'
          OR cm.message->>'content' LIKE '[INTERNAL]%'
      )
    ORDER BY cm.id ASC
    LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.get_customer_conversation(text, int)
    TO anon, authenticated, service_role;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- 1. Confirmar columna created_at:
--    SELECT column_name FROM information_schema.columns
--    WHERE table_name = 'n8n_chat_memory_cn' AND column_name = 'created_at';
--
-- 2. Probar remind_payment sobre un pedido pending:
--    SELECT apply_order_action(
--      (SELECT order_id FROM orders WHERE payment_status='pending' ORDER BY created_at DESC LIMIT 1),
--      'remind_payment', 'manu_test', 'crm'
--    );
--    -> ok:true, reply_text con el recordatorio, tg_status_text con auditoría.
--    -> El estado NO cambia (sigue pending).
--    -> Fila nueva en order_status_events con action='remind_payment'.
--
-- 3. Probar cancel sobre un pedido pending:
--    SELECT apply_order_action(
--      (SELECT order_id FROM orders WHERE payment_status='pending' ORDER BY created_at DESC LIMIT 1),
--      'cancel', 'manu_test', 'crm'
--    );
--    -> reply_text con mensaje cálido nuevo.
--    -> Fila nueva en n8n_chat_memory_cn con [SISTEMA] Pedido CN... CANCELADO ...
--
-- 4. Probar get_customer_conversation:
--    SELECT * FROM get_customer_conversation('573195665728', 20);
--    -> filas sin markers [SISTEMA] ni [INTERNAL], ordenadas por id ASC.
-- ═══════════════════════════════════════════════════════════════════
