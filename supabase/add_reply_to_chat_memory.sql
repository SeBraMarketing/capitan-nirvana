-- ═══════════════════════════════════════════════════════════════════
-- 2026-05-23 — Registrar los mensajes de cambio de estado en el historial
--
-- Problema: los mensajes que el CRM dispara vía Action Bridge
-- (verify → "¡Pago verificado!", out → "salió en camino",
--  delivered → "entregado, gracias", remind_payment, change_address)
-- los envía apply_order_action en `reply_text`, pero NUNCA se guardaban en
-- n8n_chat_memory_cn. Como get_customer_conversation lee de esa tabla, el
-- historial de la ficha del CRM mostraba el pedido confirmado y el
-- comprobante (escritos por el bot principal) pero NO los cambios de estado.
--
-- Fix 1: apply_order_action inserta `v_reply` en n8n_chat_memory_cn (rol 'ai')
--        cada vez que hay un mensaje al cliente. mark_incident/resolve_incident
--        tienen v_reply NULL → no insertan (no son mensajes al cliente).
-- Fix 2: get_customer_conversation devuelve los ÚLTIMOS p_limit mensajes en
--        orden cronológico (antes tomaba los más viejos y cortaba los recientes).
--
-- Replace completo (idempotente). Basado en add_address_change_fee_diff.sql.
-- ═══════════════════════════════════════════════════════════════════

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
    v_old_address    text;
    v_old_fee        integer;
    v_old_total      integer;
    v_old_zone_id    bigint;
    v_zone_zona      text;
    v_zone_barrio    text;
    v_zone_fee       integer;
    v_new_zone_id    bigint;
    v_new_fee        integer;
    v_new_total      integer;
    v_diff           integer;
BEGIN
    SELECT * INTO o FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', '⚠️ Pedido no encontrado');
    END IF;

    v_pay    := o.payment_status::text;
    v_status := o.order_status::text;

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
        INTO v_zone_zona, v_zone_barrio, v_zone_fee
        FROM public.get_zone_by_address(p_new_address);

        IF v_zone_zona IS NULL THEN
            SELECT id, fee_cop INTO v_new_zone_id, v_new_fee
            FROM delivery_zones WHERE zone_name = 'FUERA' LIMIT 1;
            v_zone_zona := 'FUERA';
        ELSE
            SELECT id INTO v_new_zone_id
            FROM delivery_zones WHERE zone_name = v_zone_zona LIMIT 1;
            v_new_fee := v_zone_fee;
        END IF;

        IF v_new_fee IS NULL OR v_new_fee = 0 THEN
            v_new_fee := COALESCE(v_old_fee, 6000);
        END IF;

        v_new_total := o.subtotal_cop + v_new_fee;
        v_diff      := v_new_total - v_old_total;

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

    INSERT INTO order_status_events (order_id, restaurant_id, action,
            from_status, to_status, payment_status, actor, source)
    VALUES (p_order_id, o.restaurant_id, p_action,
            v_status, v_new_status, v_new_pay, v_actor, p_source);

    v_reply := CASE p_action
        WHEN 'verify'           THEN format('✅ ¡Pago verificado! Tu pedido *%s* ya entró a cocina. 🎸', p_order_id)
        WHEN 'reject'           THEN format('⚠️ No pudimos verificar tu pago del pedido *%s*. Reenvía el comprobante o llama al 3004647851.', p_order_id)
        WHEN 'prep'             THEN format('👨‍🍳 Tu pedido *%s* está en preparación.', p_order_id)
        WHEN 'out'              THEN format('🛵 Tu pedido *%s* salió en camino. ¡Atento al timbre!', p_order_id)
        WHEN 'delivered'        THEN format('📦 ¡Pedido *%s* entregado! Gracias por pedir en Capitán Nirvana. 🤘', p_order_id)
        WHEN 'cancel'           THEN format('❌ Tu pedido *%s* fue cancelado. Cuando quieras hacer otro pedido, acá estamos al pie. ¡Vuelve a escribirme cuando quieras! 🎸🤘', p_order_id)
        WHEN 'change_address'   THEN format(
            '✅ Actualicé tu pedido *%s* a la nueva dirección. Nuevo total: $%s.%s',
            p_order_id,
            to_char(v_new_total, 'FM999G999'),
            CASE
                WHEN v_diff > 0 THEN format(
                    E'\n👉 Como ya pagaste $%s, *quedan $%s pendientes que pagas en efectivo al domiciliario al entregar.* 🤘',
                    to_char(v_old_total, 'FM999G999'),
                    to_char(v_diff, 'FM999G999'))
                WHEN v_diff < 0 THEN format(
                    E'\n👉 Como ya pagaste $%s, *te devolvemos $%s en efectivo al entregar.* 🤘',
                    to_char(v_old_total, 'FM999G999'),
                    to_char(abs(v_diff), 'FM999G999'))
                ELSE ''
            END)
        WHEN 'mark_incident'    THEN NULL
        WHEN 'resolve_incident' THEN NULL
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
            E'🔄 *CAMBIO DE DIRECCIÓN* — *%s* (%s %s)\n📍 De: %s\n📍 A: %s\n🛵 Domicilio: $%s (antes $%s)\n*TOTAL: $%s* (antes $%s)%s',
            p_order_id, v_actor, v_hora,
            v_old_address, p_new_address,
            to_char(v_new_fee, 'FM999G999'),  to_char(v_old_fee, 'FM999G999'),
            to_char(v_new_total, 'FM999G999'), to_char(v_old_total, 'FM999G999'),
            CASE
                WHEN v_diff > 0 THEN format(E'\n⚠️ *Cobrar $%s en efectivo al entregar*', to_char(v_diff, 'FM999G999'))
                WHEN v_diff < 0 THEN format(E'\n⚠️ *Devolver $%s en efectivo al entregar*', to_char(abs(v_diff), 'FM999G999'))
                ELSE ''
            END)
        WHEN 'mark_incident'    THEN format(
            E'⚠️ *NOVEDAD MARCADA* — *%s* (%s %s)\n📝 %s',
            p_order_id, v_actor, v_hora,
            COALESCE(NULLIF(trim(p_reason), ''), '(sin razón)'))
        WHEN 'resolve_incident' THEN format('✅ *Novedad resuelta* (%s %s) — *%s*.', v_actor, v_hora, p_order_id)
        WHEN 'remind_payment'   THEN format('🔔 *Recordatorio pago* enviado por %s (%s) — pedido *%s* sigue pending.', v_actor, v_hora, p_order_id)
    END;

    -- ── Registrar el mensaje al cliente en el historial de chat ──────────
    -- Para que el CRM (get_customer_conversation) muestre TODOS los mensajes,
    -- incluidos los cambios de estado que dispara el CRM/bot (verificado,
    -- en camino, entregado, recordatorio, cambio de dirección).
    -- mark_incident/resolve_incident tienen v_reply NULL → no insertan.
    IF v_reply IS NOT NULL THEN
        INSERT INTO n8n_chat_memory_cn (session_id, message)
        VALUES (o.customer_phone, jsonb_build_object('type', 'ai', 'content', v_reply));
    END IF;

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
        'old_address',     CASE WHEN p_action = 'change_address' THEN v_old_address ELSE NULL END,
        'new_address',     CASE WHEN p_action = 'change_address' THEN p_new_address ELSE NULL END,
        'old_fee_cop',     CASE WHEN p_action = 'change_address' THEN v_old_fee     ELSE NULL END,
        'new_fee_cop',     CASE WHEN p_action = 'change_address' THEN v_new_fee     ELSE NULL END,
        'old_total_cop',   CASE WHEN p_action = 'change_address' THEN v_old_total   ELSE NULL END,
        'new_total_cop',   CASE WHEN p_action = 'change_address' THEN v_new_total   ELSE NULL END,
        'diff_cop',        CASE WHEN p_action = 'change_address' THEN v_diff        ELSE NULL END,
        'new_zone',        CASE WHEN p_action = 'change_address' THEN COALESCE(v_zone_zona, 'FUERA') ELSE NULL END,
        'new_barrio',      CASE WHEN p_action = 'change_address' THEN v_zone_barrio ELSE NULL END,
        'has_incident',    CASE WHEN p_action IN ('mark_incident','resolve_incident')
                                THEN (p_action = 'mark_incident') ELSE NULL END,
        'incident_reason', CASE WHEN p_action = 'mark_incident'
                                THEN COALESCE(NULLIF(trim(p_reason), ''), o.incident_reason) ELSE NULL END
    );
END $$;

GRANT EXECUTE ON FUNCTION public.apply_order_action(text, text, text, text, text, text)
    TO anon, authenticated, service_role;


-- ── Fix 2: get_customer_conversation devuelve los ÚLTIMOS p_limit en orden
--           cronológico (subquery DESC + LIMIT, luego re-ordena ASC).
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
    SELECT id, created_at, role, content
    FROM (
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
        ORDER BY cm.id DESC
        LIMIT p_limit
    ) recientes
    ORDER BY id ASC;
$$;
GRANT EXECUTE ON FUNCTION public.get_customer_conversation(text, int)
    TO anon, authenticated, service_role;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- 1. Aplicar el migration.
-- 2. Sobre un pedido pending, correr la cadena de estados desde el CRM
--    (Verificar → En cocina → Salió → Entregado) o vía SQL:
--      SELECT apply_order_action('CN2026...', 'verify',    'manu', 'crm');
--      SELECT apply_order_action('CN2026...', 'out',       'manu', 'crm');
--      SELECT apply_order_action('CN2026...', 'delivered', 'manu', 'crm');
-- 3. SELECT * FROM get_customer_conversation('573195665728', 50);
--    -> deben aparecer, en orden, los mensajes 'ai':
--       "¡Pago verificado! ... entró a cocina"
--       "Tu pedido ... salió en camino"
--       "¡Pedido ... entregado! Gracias ..."
-- 4. En el CRM, abrir la ficha del pedido -> el Historial de conversación
--    ahora muestra esos cambios de estado.
-- ═══════════════════════════════════════════════════════════════════
