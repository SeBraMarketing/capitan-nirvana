-- ═══════════════════════════════════════════════════════════════════
-- Capitán Nirvana - Migración para arquitectura Hyundai-style
-- Fecha: 2026-05-14
-- Idempotente: re-ejecutable sin romper estado existente.
-- ═══════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────
-- 1. TABLA: bot_pauses
--    Pausa el bot para un cliente específico cuando un cajero toma
--    control desde el grupo de Telegram.
-- ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bot_pauses (
    phone           text PRIMARY KEY,
    paused_until    timestamptz NOT NULL,
    reason          text,
    paused_by       text,            -- TG username/id del cajero
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bot_pauses_until_idx
    ON bot_pauses(paused_until);


-- ───────────────────────────────────────────────────────────────────
-- 2. RPC: is_bot_paused(phone)
--    Consulta en cada turno antes de invocar LLMs.
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION is_bot_paused(p_phone text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM bot_pauses
        WHERE phone = p_phone
          AND paused_until > now()
    );
$$;


-- ───────────────────────────────────────────────────────────────────
-- 3. RPC: pausar_bot(phone, reason, paused_by, hours)
--    Cajero hace click en botón "⏸️ Pausar bot 2h" del grupo TG.
--    Default: 2 horas.
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pausar_bot(
    p_phone     text,
    p_reason    text DEFAULT NULL,
    p_paused_by text DEFAULT NULL,
    p_hours     int  DEFAULT 2
)
RETURNS timestamptz
LANGUAGE plpgsql
AS $$
DECLARE
    v_until timestamptz;
BEGIN
    v_until := now() + (p_hours || ' hours')::interval;

    INSERT INTO bot_pauses (phone, paused_until, reason, paused_by)
    VALUES (p_phone, v_until, p_reason, p_paused_by)
    ON CONFLICT (phone) DO UPDATE
        SET paused_until = EXCLUDED.paused_until,
            reason       = COALESCE(EXCLUDED.reason, bot_pauses.reason),
            paused_by    = COALESCE(EXCLUDED.paused_by, bot_pauses.paused_by);

    RETURN v_until;
END;
$$;


-- ───────────────────────────────────────────────────────────────────
-- 4. RPC: reanudar_bot(phone)
--    Cajero hace click en botón "▶️ Reanudar bot".
-- ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION reanudar_bot(p_phone text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM bot_pauses WHERE phone = p_phone;
    RETURN FOUND;
END;
$$;


-- ───────────────────────────────────────────────────────────────────
-- 5. RPC: get_historial_limpio(phone, limit)
--    Devuelve el historial formateado para los chainLlms (Cliente: / Capi:).
--    Lee de n8n_chat_memory_cn (tabla autogestionada por Postgres Chat Memory
--    de LangChain en el agente Capi). Una sola fuente de verdad.
--    Schema esperado:
--      n8n_chat_memory_cn(id, session_id text, message jsonb)
--      message: {"type":"human"|"ai", "content":"..."}
-- ───────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS get_historial_limpio(text, int);

CREATE OR REPLACE FUNCTION get_historial_limpio(
    p_phone text,
    p_limit int DEFAULT 20
)
RETURNS TABLE(historial_limpio text)
LANGUAGE sql
STABLE
AS $$
    WITH ultimas AS (
        SELECT message, id
        FROM n8n_chat_memory_cn
        WHERE session_id = p_phone
        ORDER BY id DESC
        LIMIT p_limit
    )
    SELECT string_agg(
        CASE message->>'type'
            WHEN 'human' THEN 'Cliente: '
            WHEN 'ai'    THEN 'Capi: '
            ELSE ''
        END || (message->>'content'),
        E'\n'
        ORDER BY id ASC
    )
    FROM ultimas;
$$;


-- ───────────────────────────────────────────────────────────────────
-- 6. TABLA: analytics_turns
--    Snapshot del análisis por turno. Útil para métricas y debug.
-- ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS analytics_turns (
    id                      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone                   text NOT NULL,
    intencion               text,
    etapa_pedido            text,
    sentimiento             text,
    items_mencionados       jsonb NOT NULL DEFAULT '[]'::jsonb,
    metodo_pago             text,
    direccion_dada          boolean,
    comprobante_detectado   boolean,
    mensaje_explicado       text,
    raw_user_message        text,
    raw_bot_response        text,
    created_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS analytics_turns_phone_idx
    ON analytics_turns(phone, created_at DESC);
CREATE INDEX IF NOT EXISTS analytics_turns_intencion_idx
    ON analytics_turns(intencion, created_at DESC);


-- ───────────────────────────────────────────────────────────────────
-- 7. RLS + GRANTS
--    Permitir lectura/escritura a través de la anon key que usa n8n.
-- ───────────────────────────────────────────────────────────────────
ALTER TABLE bot_pauses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bot_pauses_all ON bot_pauses;
CREATE POLICY bot_pauses_all ON bot_pauses
    FOR ALL TO anon, authenticated
    USING (true) WITH CHECK (true);

ALTER TABLE analytics_turns ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS analytics_turns_all ON analytics_turns;
CREATE POLICY analytics_turns_all ON analytics_turns
    FOR ALL TO anon, authenticated
    USING (true) WITH CHECK (true);

GRANT EXECUTE ON FUNCTION is_bot_paused(text)                    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION pausar_bot(text, text, text, int)      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION reanudar_bot(text)                     TO anon, authenticated;
GRANT EXECUTE ON FUNCTION get_historial_limpio(text, int)        TO anon, authenticated;


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN (ejecutar después)
-- ═══════════════════════════════════════════════════════════════════
-- SELECT is_bot_paused('test');                                -- false
-- SELECT pausar_bot('test', 'prueba', 'manuel', 1);            -- timestamptz
-- SELECT is_bot_paused('test');                                -- true
-- SELECT reanudar_bot('test');                                 -- true
-- SELECT is_bot_paused('test');                                -- false
-- SELECT * FROM get_historial_limpio('573004647851');          -- formatted history
