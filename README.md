# IThreex Operations Dashboard — Backend Setup

## Arquitectura

```
GitHub Pages (dashboard HTML)
        ↕  fetch() HTTPS
   FastAPI (dashboard_api.py)     ← este repo
        ↕  asyncpg
   PostgreSQL (ithreex_ops)       ← Docker existente
```

## 1. Variables de entorno

Crear `.env` en la raíz del proyecto:

```env
DATABASE_URL=postgresql://dm_user:tu_password@localhost:5432/ithreex_ops
```

## 2. Base de datos

```bash
# Crear la base
psql -U postgres -c "CREATE DATABASE ithreex_ops;"
psql -U postgres -c "CREATE USER dm_user WITH PASSWORD 'tu_password';"
psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE ithreex_ops TO dm_user;"

# Aplicar el schema (tablas + datos iniciales de los Excel)
psql -U dm_user -d ithreex_ops -f schema.sql
```

## 3. Dependencias

```bash
pip install fastapi uvicorn asyncpg python-dotenv
```

## 4. Correr la API

```bash
# Desarrollo
uvicorn dashboard_api:app --reload --port 8000

# Producción (Docker existente)
# Agregar al docker-compose.yml:
#   dashboard-api:
#     build: .
#     command: uvicorn dashboard_api:app --host 0.0.0.0 --port 8000
#     env_file: .env
#     ports:
#       - "8000:8000"
```

## 5. Conectar el dashboard

Abrir `ithreex_dashboard.html` → tab **🔌 Conexión BD** → ingresar host donde corre la API → **Probar conexión**.

Para producción, cambiar en el HTML la variable `DB.apiBase` a la URL pública de tu servidor.

## Endpoints disponibles

| Endpoint | Descripción |
|---|---|
| `GET /api/health` | Estado de la API y DB |
| `GET /api/proyectos` | Todos los proyectos con KPIs |
| `GET /api/proyectos/{id}` | Detalle + equipo |
| `GET /api/productividad?mes=2026-06` | Productividad individual del mes |
| `GET /api/productividad/overview` | Semáforo semanal histórico |
| `GET /api/rentabilidad` | FORCAS, margen, costos |
| `GET /api/clockify?mes=2026-06` | Entradas Clockify |
| `GET /api/clockify/resumen` | Facturable vs OPEX por mes |
| `GET /api/costos/perfiles?mes=2026-04` | Costo hora por perfil |
| `GET /api/iso/status` | Indicadores ISO 9001 (FP02 §17) |
| `GET /api/equipo/evaluacion` | Evaluación individual |
| `POST /api/satisfaccion` | Registrar encuesta cliente |
| `GET /api/satisfaccion` | Historial encuestas |
| `POST /api/nc` | Registrar no conformidad |
| `GET /api/nc` | Listar no conformidades |

## Documentación interactiva

Con la API corriendo: `http://localhost:8000/docs`
