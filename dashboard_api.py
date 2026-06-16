"""
IThreex Operations Dashboard — FastAPI Backend
Endpoints alineados al dashboard HTML + FP02 Rev.09

Instalar dependencias:
    pip install fastapi uvicorn asyncpg python-dotenv

Correr:
    uvicorn app.routers.dashboard:app --reload --port 8000

O integrar al main.py existente:
    from app.routers.dashboard import router as dashboard_router
    app.include_router(dashboard_router, prefix="/api")
"""

from fastapi import FastAPI, APIRouter, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional
from datetime import date
import asyncpg
import os
from dotenv import load_dotenv

load_dotenv()

# ─────────────────────────────────────────
# CONFIGURACIÓN DB
# ─────────────────────────────────────────
DB_DSN = os.getenv(
    "DATABASE_URL",
    "postgresql://dm_user:password@localhost:5432/ithreex_ops"
)

# Pool global (se inicializa en startup)
_pool: asyncpg.Pool = None

async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(DB_DSN, min_size=2, max_size=10)
    return _pool

# ─────────────────────────────────────────
# APP + CORS (permite requests desde GitHub Pages)
# ─────────────────────────────────────────
app = FastAPI(title="IThreex Dashboard API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],   # En producción: ["https://rochiciccarello.github.io"]
    allow_methods=["*"],
    allow_headers=["*"],
)

router = APIRouter()

# ─────────────────────────────────────────
# SCHEMAS PYDANTIC
# ─────────────────────────────────────────
class SatisfaccionIn(BaseModel):
    proyecto_id: Optional[int] = None
    tipo: str   # 'interna', 'clutch', 'feedback'
    score: float
    comentarios: Optional[str] = None

class NCIn(BaseModel):
    proyecto_id: Optional[int] = None
    tipo: str
    descripcion: str
    responsable: Optional[str] = None
    accion: Optional[str] = None
    fecha_objetivo: Optional[date] = None

# ─────────────────────────────────────────
# HEALTH CHECK
# ─────────────────────────────────────────
@router.get("/health")
async def health():
    """Verifica conexión DB — usado por el dashboard para detectar la API."""
    try:
        pool = await get_pool()
        async with pool.acquire() as conn:
            await conn.fetchval("SELECT 1")
        return {"status": "ok", "db": "connected"}
    except Exception as e:
        raise HTTPException(503, detail=str(e))

# ─────────────────────────────────────────
# PROYECTOS
# ─────────────────────────────────────────
@router.get("/proyectos")
async def get_proyectos():
    """
    Lista todos los proyectos con KPIs calculados (FORCAS, margen, avance).
    Alimenta la tabla de proyectos y los KPIs del overview.
    """
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT
                id, nombre, cliente, squad, estado,
                inicio, fin_plan,
                hs_estimadas, presupuesto_ars,
                hs_reales, hs_restantes,
                costo_real_ars, forcas_costo_final,
                ROUND(forcas_margen_pct * 100, 2)  AS margen_pct,
                costo_prom_hora, pct_avance_horas,
                semaforo_margen,
                -- ISO checklist
                tiene_propuesta, tiene_estimacion, tiene_kickoff,
                tiene_gitlab, tiene_drive, tiene_arquitectura,
                tiene_riesgos, tiene_plan_pruebas, tiene_cierre,
                score_satisfaccion,
                clockify_id, odoo_url, gitlab_url
            FROM v_kpi_proyectos
            ORDER BY estado, nombre
        """)
        return [dict(r) for r in rows]

@router.get("/proyectos/{proyecto_id}")
async def get_proyecto(proyecto_id: int):
    """Detalle de un proyecto con horas por colaborador."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        p = await conn.fetchrow(
            "SELECT * FROM v_kpi_proyectos WHERE id = $1", proyecto_id
        )
        if not p:
            raise HTTPException(404, "Proyecto no encontrado")

        horas = await conn.fetch("""
            SELECT colaborador, rol,
                   SUM(hs_reales) AS hs_total,
                   COUNT(DISTINCT mes) AS meses_trabajados
            FROM horas_proyecto
            WHERE proyecto_id = $1
            GROUP BY colaborador, rol
            ORDER BY hs_total DESC
        """, proyecto_id)

        return {**dict(p), "equipo": [dict(h) for h in horas]}

# ─────────────────────────────────────────
# PRODUCTIVIDAD DEL EQUIPO
# ─────────────────────────────────────────
@router.get("/productividad")
async def get_productividad(
    mes: Optional[str] = Query(None, description="YYYY-MM, ej: 2026-06")
):
    """
    Productividad mensual del equipo.
    Si se pasa ?mes=2026-06 devuelve el detalle individual de ese mes.
    Sin parámetro devuelve el resumen de todos los meses.
    """
    pool = await get_pool()
    async with pool.acquire() as conn:
        if mes:
            mes_date = f"{mes}-01"
            rows = await conn.fetch("""
                SELECT
                    colaborador,
                    SUM(hs_objetivo)    AS hs_objetivo,
                    SUM(hs_ausencias)   AS hs_ausencias,
                    SUM(hs_capacidad)   AS hs_capacidad,
                    SUM(hs_productivas) AS hs_productivas,
                    ROUND(AVG(productividad) * 100, 2) AS productividad_pct,
                    MODE() WITHIN GROUP (ORDER BY productividad_prom) AS estado
                FROM horas_semana
                WHERE mes = $1
                GROUP BY colaborador
                ORDER BY productividad_pct DESC
            """, mes_date)
        else:
            rows = await conn.fetch("""
                SELECT
                    TO_CHAR(mes, 'YYYY-MM') AS mes,
                    prod_promedio_pct,
                    hs_productivas_total,
                    hs_objetivo_total,
                    colaboradores_peligro
                FROM v_productividad_mes
                ORDER BY mes
            """)
        return [dict(r) for r in rows]

@router.get("/productividad/overview")
async def get_overview_semanal(
    limit: int = Query(20, description="Últimas N semanas")
):
    """Semáforo semanal del equipo (score de salud, productividad ponderada)."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT
                TO_CHAR(mes, 'YYYY-MM') AS mes,
                semana, inicio, fin,
                ROUND(productividad_pond * 100, 2) AS prod_pct,
                ROUND(pedida_opex * 100, 2)        AS opex_pct,
                score_salud, semaforo, escalabilidad
            FROM overview_semanal
            ORDER BY mes DESC, semana DESC
            LIMIT $1
        """, limit)
        return [dict(r) for r in rows]

# ─────────────────────────────────────────
# RENTABILIDAD
# ─────────────────────────────────────────
@router.get("/rentabilidad")
async def get_rentabilidad():
    """
    FORCAS, margen y costos de todos los proyectos activos.
    Alimenta el tab Rentabilidad del dashboard.
    """
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("""
            SELECT
                p.nombre, p.cliente, p.estado,
                p.presupuesto_ars,
                r.hs_estimadas, r.hs_reales, r.hs_restantes,
                r.costo_real_ars, r.costo_prom_hora,
                r.proy_costo_rest,
                r.forcas_costo_final,
                ROUND(r.forcas_margen_pct * 100, 2) AS margen_pct,
                r.hs_facturables, r.hs_no_facturables,
                r.costo_cogs, r.costo_opex,
                r.snapshot_date
            FROM rentabilidad r
            JOIN proyectos p ON p.id = r.proyecto_id
            WHERE r.snapshot_date = (
                SELECT MAX(r2.snapshot_date)
                FROM rentabilidad r2
                WHERE r2.proyecto_id = r.proyecto_id
            )
            ORDER BY p.nombre
        """)

        # Totales globales
        totals = await conn.fetchrow("""
            SELECT
                COUNT(DISTINCT p.id) FILTER (WHERE p.estado = 'En Curso') AS proyectos_activos,
                SUM(p.presupuesto_ars)                                      AS presupuesto_total,
                SUM(r.costo_real_ars)                                       AS costo_real_total,
                SUM(r.hs_estimadas)                                         AS hs_estimadas_total,
                SUM(r.hs_reales)                                            AS hs_reales_total,
                SUM(r.hs_restantes)                                         AS hs_restantes_total,
                ROUND(AVG(r.forcas_margen_pct) * 100, 2)                   AS margen_promedio_pct
            FROM proyectos p
            LEFT JOIN LATERAL (
                SELECT * FROM rentabilidad WHERE proyecto_id = p.id
                ORDER BY snapshot_date DESC LIMIT 1
            ) r ON TRUE
            WHERE p.estado IN ('En Curso','Planificado')
        """)

        return {
            "totales": dict(totals),
            "proyectos": [dict(r) for r in rows]
        }

# ─────────────────────────────────────────
# CLOCKIFY
# ─────────────────────────────────────────
@router.get("/clockify")
async def get_clockify(
    mes: Optional[str] = Query(None, description="YYYY-MM, ej: 2026-06"),
    usuario: Optional[str] = Query(None),
    proyecto: Optional[str] = Query(None)
):
    """Entradas Clockify con filtros opcionales."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        conditions = []
        params = []
        i = 1
        if mes:
            conditions.append(f"mes = ${i}")
            params.append(f"{mes}-01")
            i += 1
        if usuario:
            conditions.append(f"usuario ILIKE ${i}")
            params.append(f"%{usuario}%")
            i += 1
        if proyecto:
            conditions.append(f"proyecto ILIKE ${i}")
            params.append(f"%{proyecto}%")
            i += 1

        where = ("WHERE " + " AND ".join(conditions)) if conditions else ""
        rows = await conn.fetch(f"""
            SELECT
                proyecto, cliente, usuario, facturable,
                fecha, descripcion,
                SUM(duracion_h) AS duracion_h
            FROM clockify_entries
            {where}
            GROUP BY proyecto, cliente, usuario, facturable, fecha, descripcion
            ORDER BY fecha DESC
            LIMIT 500
        """, *params)
        return [dict(r) for r in rows]

@router.get("/clockify/resumen")
async def get_clockify_resumen(
    mes: Optional[str] = Query(None, description="YYYY-MM")
):
    """Resumen facturable vs no facturable por proyecto y mes."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        where = f"WHERE mes = '{mes}-01'" if mes else ""
        rows = await conn.fetch(f"""
            SELECT * FROM v_facturable_mes {where} ORDER BY mes DESC, hs_total DESC
        """)
        return [dict(r) for r in rows]

# ─────────────────────────────────────────
# COSTOS POR PERFIL
# ─────────────────────────────────────────
@router.get("/costos/perfiles")
async def get_costos_perfiles(
    mes: Optional[str] = Query(None, description="YYYY-MM, ej: 2026-04")
):
    """Costo por hora por perfil. Sin mes devuelve todos los meses."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        if mes:
            rows = await conn.fetch(
                "SELECT * FROM costos_perfil WHERE mes = $1 ORDER BY perfil",
                f"{mes}-01"
            )
        else:
            rows = await conn.fetch(
                "SELECT * FROM costos_perfil ORDER BY mes DESC, perfil"
            )
        return [dict(r) for r in rows]

# ─────────────────────────────────────────
# ISO STATUS
# ─────────────────────────────────────────
@router.get("/iso/status")
async def get_iso_status():
    """
    Estado de los indicadores ISO 9001 (FP02 §17).
    Alimenta el tab ISO del dashboard.
    """
    pool = await get_pool()
    async with pool.acquire() as conn:
        # Indicadores calculados dinámicamente
        prod = await conn.fetchrow("""
            SELECT ROUND(AVG(productividad) * 100, 2) AS prod_pct
            FROM horas_semana
            WHERE mes = DATE_TRUNC('month', CURRENT_DATE)
        """)

        carga = await conn.fetchrow("""
            SELECT
                COUNT(DISTINCT colaborador)                                      AS total,
                COUNT(DISTINCT colaborador) FILTER (WHERE hs_productivas > 0)   AS con_carga
            FROM horas_semana
            WHERE mes = DATE_TRUNC('month', CURRENT_DATE)
              AND semana = (
                  SELECT MAX(semana) FROM horas_semana
                  WHERE mes = DATE_TRUNC('month', CURRENT_DATE)
              )
        """)

        margen = await conn.fetchrow("""
            SELECT ROUND(AVG(forcas_margen_pct) * 100, 2) AS margen_pct
            FROM rentabilidad r
            JOIN proyectos p ON p.id = r.proyecto_id
            WHERE p.estado = 'En Curso'
              AND r.snapshot_date = (
                  SELECT MAX(snapshot_date) FROM rentabilidad r2
                  WHERE r2.proyecto_id = r.proyecto_id
              )
        """)

        nc_abiertas = await conn.fetchval(
            "SELECT COUNT(*) FROM no_conformidades WHERE estado = 'Abierta'"
        )

        proyectos_sin_riesgos = await conn.fetchval("""
            SELECT COUNT(*) FROM proyectos
            WHERE estado = 'En Curso' AND tiene_riesgos = FALSE
        """)

        prod_pct   = float(prod["prod_pct"] or 0)
        margen_pct = float(margen["margen_pct"] or 0)
        carga_pct  = (float(carga["con_carga"]) / float(carga["total"]) * 100
                      if carga["total"] else 0)

        indicadores = [
            {
                "nombre": "% Cumplimiento de Sprint",
                "meta": "≥ 90%",
                "valor": f"{prod_pct:.1f}%",
                "estado": "verde" if prod_pct >= 90 else ("amarillo" if prod_pct >= 75 else "rojo"),
                "referencia": "FP02 §17"
            },
            {
                "nombre": "Margen de rentabilidad",
                "meta": "≥ 35%",
                "valor": f"{margen_pct:.1f}%",
                "estado": "verde" if margen_pct >= 35 else ("amarillo" if margen_pct >= 10 else "rojo"),
                "referencia": "FP02 §17"
            },
            {
                "nombre": "Carga horas Clockify",
                "meta": "≥ 95% colaboradores",
                "valor": f"{carga_pct:.1f}%",
                "estado": "verde" if carga_pct >= 95 else ("amarillo" if carga_pct >= 80 else "rojo"),
                "referencia": "FP02 §17"
            },
            {
                "nombre": "No conformidades abiertas",
                "meta": "0",
                "valor": str(nc_abiertas),
                "estado": "verde" if nc_abiertas == 0 else ("amarillo" if nc_abiertas <= 2 else "rojo"),
                "referencia": "FP02 §13"
            },
            {
                "nombre": "Riesgos actualizados",
                "meta": "100% proyectos activos",
                "valor": f"{proyectos_sin_riesgos} sin riesgos",
                "estado": "verde" if proyectos_sin_riesgos == 0 else "rojo",
                "referencia": "FP02 §9"
            },
        ]

        verdes    = sum(1 for i in indicadores if i["estado"] == "verde")
        amarillos = sum(1 for i in indicadores if i["estado"] == "amarillo")
        rojos     = sum(1 for i in indicadores if i["estado"] == "rojo")

        return {
            "resumen": {"verde": verdes, "amarillo": amarillos, "rojo": rojos},
            "indicadores": indicadores,
            "nc_abiertas": nc_abiertas
        }

# ─────────────────────────────────────────
# EQUIPO — EVALUACIÓN INDIVIDUAL
# ─────────────────────────────────────────
@router.get("/equipo/evaluacion")
async def get_evaluacion(
    periodo: Optional[str] = Query(None, description="ej: 2025-2S")
):
    """Evaluaciones individuales del equipo."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        where = "WHERE periodo = $1" if periodo else ""
        params = [periodo] if periodo else []
        rows = await conn.fetch(
            f"SELECT * FROM evaluacion_individual {where} ORDER BY resultado, colaborador",
            *params
        )
        return [dict(r) for r in rows]

# ─────────────────────────────────────────
# SATISFACCIÓN CLIENTE (FP02 §14.1)
# ─────────────────────────────────────────
@router.post("/satisfaccion", status_code=201)
async def post_satisfaccion(body: SatisfaccionIn):
    """Registra una encuesta de satisfacción de cliente."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        requiere_nc = body.score <= 3
        row = await conn.fetchrow("""
            INSERT INTO satisfaccion (proyecto_id, tipo, score, comentarios, requiere_nc)
            VALUES ($1, $2, $3, $4, $5)
            RETURNING id, fecha
        """, body.proyecto_id, body.tipo, body.score, body.comentarios, requiere_nc)
        return {
            "id": row["id"],
            "fecha": row["fecha"],
            "requiere_nc": requiere_nc,
            "mensaje": "⚠ Score ≤ 3: registrar NC en R01 PG04" if requiere_nc else "Registrado correctamente"
        }

@router.get("/satisfaccion")
async def get_satisfaccion(proyecto_id: Optional[int] = None):
    """Historial de encuestas de satisfacción."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        if proyecto_id:
            rows = await conn.fetch(
                "SELECT * FROM satisfaccion WHERE proyecto_id = $1 ORDER BY fecha DESC",
                proyecto_id
            )
        else:
            rows = await conn.fetch("SELECT * FROM satisfaccion ORDER BY fecha DESC")
        return [dict(r) for r in rows]

# ─────────────────────────────────────────
# NO CONFORMIDADES (FP02 §13)
# ─────────────────────────────────────────
@router.post("/nc", status_code=201)
async def post_nc(body: NCIn):
    """Registra una no conformidad (R01 PG04)."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("""
            INSERT INTO no_conformidades
              (proyecto_id, tipo, descripcion, responsable, accion, fecha_objetivo)
            VALUES ($1, $2, $3, $4, $5, $6)
            RETURNING id
        """, body.proyecto_id, body.tipo, body.descripcion,
             body.responsable, body.accion, body.fecha_objetivo)
        return {"id": row["id"], "mensaje": "NC registrada en R01 PG04"}

@router.get("/nc")
async def get_nc(estado: Optional[str] = None):
    """Lista no conformidades, filtrable por estado."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        where = "WHERE n.estado = $1" if estado else ""
        params = [estado] if estado else []
        rows = await conn.fetch(f"""
            SELECT n.*, p.nombre AS proyecto_nombre, p.cliente
            FROM no_conformidades n
            LEFT JOIN proyectos p ON p.id = n.proyecto_id
            {where}
            ORDER BY n.created_at DESC
        """, *params)
        return [dict(r) for r in rows]

# ─────────────────────────────────────────
# REGISTRAR LA APP Y EL ROUTER
# ─────────────────────────────────────────
app.include_router(router, prefix="/api")

# Startup / shutdown del pool
@app.on_event("startup")
async def startup():
    await get_pool()

@app.on_event("shutdown")
async def shutdown():
    if _pool:
        await _pool.close()


# ─────────────────────────────────────────
# CORRER EN LOCAL (para desarrollo)
# ─────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    uvicorn.run("dashboard_api:app", host="0.0.0.0", port=8000, reload=True)
