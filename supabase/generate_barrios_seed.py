#!/usr/bin/env python3
"""
Genera barrios_seed.sql con INSERT statements para la tabla barrios.

Uso:
    cd capitan-nirvana/supabase
    python3 generate_barrios_seed.py

El CSV se busca en:
  1. El mismo directorio que este script
  2. ~/Downloads/barrios_pasto_supabase.csv

Salida: barrios_seed.sql (listo para pegar en Supabase SQL Editor)
"""

import csv
import pathlib

CSV_FILENAME = "barrios_pasto_supabase.csv"
OUT_FILENAME = "barrios_seed.sql"

SCRIPT_DIR = pathlib.Path(__file__).parent.resolve()

CSV_PATHS = [
    SCRIPT_DIR / CSV_FILENAME,
    pathlib.Path.home() / "Downloads" / CSV_FILENAME,
]

csv_file = next((p for p in CSV_PATHS if p.exists()), None)
if not csv_file:
    raise FileNotFoundError(
        f"No se encontró {CSV_FILENAME}. "
        f"Colócalo en {SCRIPT_DIR} o en ~/Downloads/"
    )

print(f"Leyendo: {csv_file}")


def esc(s: str) -> str:
    """Escapa texto para SQL: NULL si vacío, quoted con '' para comillas simples."""
    if s is None or str(s).strip() == "":
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"


def esc_num(s: str) -> str:
    """Número o NULL."""
    try:
        v = float(s)
        return str(v)
    except (ValueError, TypeError):
        return "NULL"


def esc_int(s: str) -> str:
    """Entero o NULL."""
    try:
        return str(int(float(s)))
    except (ValueError, TypeError):
        return "NULL"


def esc_bool(s: str) -> str:
    return "true" if str(s).strip().lower() in ("true", "1", "yes", "t") else "false"


rows = []
with open(csv_file, encoding="utf-8") as f:
    reader = csv.DictReader(f)
    for row in reader:
        rows.append(row)

print(f"Filas encontradas: {len(rows)}")

out_path = SCRIPT_DIR / OUT_FILENAME
with open(out_path, "w", encoding="utf-8") as f:
    f.write("-- ══════════════════════════════════════════════════════════════\n")
    f.write(f"-- barrios_seed.sql — {len(rows)} barrios de Pasto, Nariño\n")
    f.write("-- Generado por generate_barrios_seed.py\n")
    f.write("-- Ejecutar DESPUÉS de barrios_migration.sql en Supabase SQL Editor\n")
    f.write("-- ══════════════════════════════════════════════════════════════\n\n")

    f.write(
        "INSERT INTO barrios (\n"
        "    slug, nombre, comuna, zona,\n"
        "    distancia_km, eta_min, longitud, latitud,\n"
        "    coordenada_verificada, fuente_coordenada, punto_referencia,\n"
        "    velocidad_calculo_kmh\n"
        ") VALUES\n"
    )

    values = []
    for row in rows:
        v = (
            f"  ({esc(row['slug'])}, "
            f"{esc(row['nombre'])}, "
            f"{esc_int(row['comuna'])}, "
            f"{esc(row['zona'])}, "
            f"{esc_num(row['distancia_km'])}, "
            f"{esc_int(row['eta_min'])}, "
            f"{esc_num(row['longitud'])}, "
            f"{esc_num(row['latitud'])}, "
            f"{esc_bool(row['coordenada_verificada'])}, "
            f"{esc(row['fuente_coordenada'])}, "
            f"{esc(row['punto_referencia'])}, "
            f"{esc_int(row['velocidad_calculo_kmh'])})"
        )
        values.append(v)

    f.write(",\n".join(values))
    f.write(
        "\nON CONFLICT (slug) DO UPDATE SET\n"
        "    nombre                = EXCLUDED.nombre,\n"
        "    zona                  = EXCLUDED.zona,\n"
        "    distancia_km          = EXCLUDED.distancia_km,\n"
        "    eta_min               = EXCLUDED.eta_min,\n"
        "    longitud              = EXCLUDED.longitud,\n"
        "    latitud               = EXCLUDED.latitud,\n"
        "    coordenada_verificada = EXCLUDED.coordenada_verificada,\n"
        "    fuente_coordenada     = EXCLUDED.fuente_coordenada;\n"
    )

print(f"Generado: {out_path}")
print(f"\nPróximos pasos:")
print(f"  1. Ejecutar barrios_migration.sql en Supabase SQL Editor")
print(f"  2. Ejecutar barrios_seed.sql en Supabase SQL Editor")
print(f"  3. Verificar: SELECT zona, count(*) FROM barrios GROUP BY zona ORDER BY zona;")
