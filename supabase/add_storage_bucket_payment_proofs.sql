-- ═══════════════════════════════════════════════════════════════════
-- Mini-CRM Capitán Nirvana — Bucket Storage para comprobantes de pago
-- Fecha: 2026-05-20
--
-- Crea el bucket 'payment-proofs' en Supabase Storage:
--   - Público (cualquiera con la URL puede ver la imagen)
--   - Solo imágenes (jpeg/png/webp)
--   - Max 10MB por archivo
--
-- Los uploads los hace el bot (con la credencial supabaseApi de n8n).
-- Las lecturas son públicas (las URLs son random/no enumerables — la
-- privacidad depende de no compartir la URL).
-- Idempotente.
-- ═══════════════════════════════════════════════════════════════════

-- Bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'payment-proofs',
    'payment-proofs',
    true,                                                       -- public read
    10485760,                                                   -- 10MB
    ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Policies sobre storage.objects (necesarias porque RLS está habilitado en esa tabla)

-- 1. Cualquiera (anon/auth/service_role) puede subir al bucket
DROP POLICY IF EXISTS "upload payment-proofs" ON storage.objects;
CREATE POLICY "upload payment-proofs"
    ON storage.objects FOR INSERT
    TO anon, authenticated, service_role
    WITH CHECK (bucket_id = 'payment-proofs');

-- 2. Cualquiera puede sobrescribir (upsert, para idempotencia del bot)
DROP POLICY IF EXISTS "update payment-proofs" ON storage.objects;
CREATE POLICY "update payment-proofs"
    ON storage.objects FOR UPDATE
    TO anon, authenticated, service_role
    USING (bucket_id = 'payment-proofs');

-- 3. Lectura pública
DROP POLICY IF EXISTS "read payment-proofs" ON storage.objects;
CREATE POLICY "read payment-proofs"
    ON storage.objects FOR SELECT
    TO public
    USING (bucket_id = 'payment-proofs');


-- ═══════════════════════════════════════════════════════════════════
-- VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════
-- 1. Confirmar bucket:
--    SELECT id, name, public FROM storage.buckets WHERE id = 'payment-proofs';
--
-- 2. Confirmar policies:
--    SELECT policyname, cmd, roles FROM pg_policies
--    WHERE tablename = 'objects' AND policyname LIKE '%payment-proofs%';
--
-- 3. URL del bucket (donde vivirán las imágenes):
--    https://vowuwpqahwrcvjqqgipc.supabase.co/storage/v1/object/public/payment-proofs/{order_id}.jpg
--    Cada pedido tendrá UNA imagen (la última que mande el cliente; upsert).
-- ═══════════════════════════════════════════════════════════════════
