#!/usr/bin/env python3
"""
Genera supabase/seed.sql desde los JSONs locales.
Lee:
    capitan-nirvana/menu-v2.json
    capitan-nirvana/faqs.json
    capitan-nirvana/delivery_zones.json
    capitan-nirvana/customers-current.json
    capitan-nirvana/orders-current.json
    capitan-nirvana/conversations-current.json

Output:
    capitan-nirvana/supabase/seed.sql

Uso:
    cd capitan-nirvana/supabase
    python3 generate_seed.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT  = Path(__file__).resolve().parent / "seed.sql"

def sql_str(v):
    """Escape Postgres string."""
    if v is None or v == "":
        return "NULL"
    return "'" + str(v).replace("'", "''") + "'"

def sql_int(v):
    if v is None or v == "":
        return "NULL"
    return str(int(v))

def sql_bool(v):
    if v in (True, 1, "1", "true", "True"):
        return "true"
    return "false"

def sql_array(v):
    """Postgres text[] desde lista o coma-separado."""
    if not v:
        return "NULL"
    if isinstance(v, str):
        items = [x.strip() for x in v.split(",") if x.strip()]
    else:
        items = list(v)
    if not items:
        return "NULL"
    escaped = ['"' + x.replace('"', '\\"') + '"' for x in items]
    return "'{" + ",".join(escaped) + "}'"

def sql_jsonb(v):
    if v is None or v == "":
        return "NULL"
    if isinstance(v, str):
        try:
            json.loads(v)
            return sql_str(v) + "::jsonb"
        except json.JSONDecodeError:
            return "NULL"
    return sql_str(json.dumps(v, ensure_ascii=False)) + "::jsonb"

def sql_ts(v):
    if v is None or v == "":
        return "NULL"
    return sql_str(v) + "::timestamptz"

def load(path):
    with open(ROOT / path, encoding="utf-8") as f:
        return json.load(f)

# ──────────────────────────────────────────────────────────────
out = ["-- Seed generado automáticamente por generate_seed.py",
       "-- NO editar a mano. Regenerar corriendo el script.",
       ""]

# ── menu ──────────────────────────────────────────────────────
menu = load("menu-v2.json")
out.append(f"-- {len(menu)} items en menu")
out.append("INSERT INTO menu (name, category, description, base_price_cop, "
           "variants_json, options_json, flavors, serves_people, available, "
           "prep_minutes, tags, modificable, modificaciones, adicionable, "
           "adiciones, vendible_solo) VALUES")
rows = []
for m in menu:
    rows.append("(" + ", ".join([
        sql_str(m["name"]),
        sql_str(m["category"]),
        sql_str(m.get("description")),
        sql_int(m["base_price_cop"]),
        sql_jsonb(m.get("variants_json")),
        sql_jsonb(m.get("options_json")),
        sql_array(m.get("flavors")),
        sql_int(m.get("serves_people", 1)),
        sql_bool(m.get("available", 1)),
        sql_int(m.get("prep_minutes", 5)),
        sql_array(m.get("tags")),
        sql_bool(m.get("modificable", 0)),
        sql_array(m.get("modificaciones")),
        sql_bool(m.get("adicionable", 0)),
        sql_array(m.get("adiciones")),
        sql_bool(m.get("vendible_solo", 1)),
    ]) + ")")
out.append(",\n".join(rows) + "\nON CONFLICT (name) DO NOTHING;\n")

# ── faqs ──────────────────────────────────────────────────────
faqs = load("faqs.json")
out.append(f"-- {len(faqs)} faqs")
out.append("INSERT INTO faqs (question, answer, keywords, category, priority, is_active) VALUES")
rows = []
for f in faqs:
    rows.append("(" + ", ".join([
        sql_str(f["question"]),
        sql_str(f["answer"]),
        sql_array(f.get("keywords")),
        sql_str(f["category"]),
        sql_int(f.get("priority", 5)),
        sql_bool(f.get("is_active", 1)),
    ]) + ")")
out.append(",\n".join(rows) + ";\n")

# ── delivery_zones ────────────────────────────────────────────
zones = load("delivery_zones.json")
out.append(f"-- {len(zones)} zonas")
out.append("INSERT INTO delivery_zones (zone_name, keywords, fee_cop, eta_minutes, is_active, notes) VALUES")
rows = []
for z in zones:
    rows.append("(" + ", ".join([
        sql_str(z["zone_name"]),
        sql_array(z.get("keywords")),
        sql_int(z["fee_cop"]),
        sql_int(z["eta_minutes"]),
        sql_bool(z.get("is_active", 1)),
        sql_str(z.get("notes")),
    ]) + ")")
out.append(",\n".join(rows) + "\nON CONFLICT (zone_name) DO NOTHING;\n")

# ── customers ─────────────────────────────────────────────────
# Solo importamos si hay data útil (no la fila "Cliente Demo" que era para borrar)
customers = load("customers-current.json")
real = [c for c in customers if "demo" not in (c.get("notes","") or "").lower()]
if real:
    out.append(f"-- {len(real)} customers")
    out.append("INSERT INTO customers (phone, name, preferred_payment, is_blocked, notes) VALUES")
    rows = []
    for c in real:
        pp = c.get("preferred_payment")
        if pp not in ("Nequi", "Bancolombia"):
            pp = None
        rows.append("(" + ", ".join([
            sql_str(c["phone"]),
            sql_str(c.get("name", "Sin nombre")),
            sql_str(pp) + "::payment_method_enum" if pp else "NULL",
            sql_bool(c.get("is_blocked", 0)),
            sql_str(c.get("notes")),
        ]) + ")")
    out.append(",\n".join(rows) + "\nON CONFLICT (phone) DO NOTHING;\n")
else:
    out.append("-- 0 customers reales (solo había fila demo, omitida)\n")

# ── customer_addresses, orders, conversations ────────────────
# Las orders y conversations actuales son demo, no las migramos.
# customer_addresses está vacía (concepto nuevo).
out.append("-- customer_addresses, orders y conversations:")
out.append("--   no se importan datos (eran demo o tabla nueva).")
out.append("--   El bot las llenará en producción.\n")

# ──────────────────────────────────────────────────────────────
OUT.write_text("\n".join(out), encoding="utf-8")
print(f"✓ Generado {OUT.relative_to(ROOT.parent)}")
print(f"  menu: {len(menu)} | faqs: {len(faqs)} | zones: {len(zones)} | customers: {len(real)}")
