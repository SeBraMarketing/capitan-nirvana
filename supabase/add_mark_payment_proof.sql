-- ═══════════════════════════════════════════════════════════════════
-- Mini-CRM Capitán Nirvana — RPC mark_payment_proof
-- Fecha: 2026-05-20
-- Propósito: cuando el bot recibe la foto del comprobante de pago,
-- marca la orden con la referencia del mensaje (cualquier valor no-null).
-- El CRM usa este flag para pintar el botón "Verificar" en verde.
-- Idempotente.
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.mark_payment_proof(
    p_order_id text,
    p_ref      text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_phone text;
BEGIN
    UPDATE orders
    SET payment_proof_url = p_ref
    WHERE order_id = p_order_id
    RETURNING customer_phone INTO v_phone;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'Pedido no encontrado', 'order_id', p_order_id);
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'order_id', p_order_id,
        'customer_phone', v_phone,
        'payment_proof_url', p_ref
    );
END $$;

GRANT EXECUTE ON FUNCTION public.mark_payment_proof(text, text)
    TO anon, authenticated, service_role;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- SELECT mark_payment_proof(
--   (SELECT order_id FROM orders WHERE payment_status='pending' LIMIT 1),
--   'wamid.test123'
-- );
-- → ok:true, payment_proof_url='wamid.test123'.
--
-- Confirmar en orders:
-- SELECT order_id, payment_proof_url FROM orders WHERE payment_proof_url IS NOT NULL;
-- ═══════════════════════════════════════════════════════════════════
