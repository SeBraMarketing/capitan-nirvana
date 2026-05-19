-- ═══════════════════════════════════════════════════════════════════
-- Mini-CRM — RLS de catálogo para la app (lectura de delivery_zones)
-- Fecha: 2026-05-18
-- Ejecutar en Supabase SQL Editor. Idempotente.
--
-- delivery_zones tiene RLS activa sin policy → la app autenticada no
-- puede leer los nombres de zona (para mostrarlos y filtrar en la
-- sección Domicilios). Es catálogo de negocio, no PII: lectura OK.
-- (barrios ya tiene policy de lectura desde barrios_migration.sql.)
-- ═══════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS delivery_zones_read_auth ON delivery_zones;
CREATE POLICY delivery_zones_read_auth ON delivery_zones
    FOR SELECT TO authenticated USING (true);

GRANT SELECT ON delivery_zones TO authenticated;

-- Verificación: como usuario autenticado, SELECT * FROM delivery_zones
-- debe devolver 6 filas (Zona 1-5 + FUERA).
