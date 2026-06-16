-- ============================================================
-- IThreex Operations Dashboard — Schema PostgreSQL
-- Alineado a FP02 Rev.09 + datos reales Excel
-- ============================================================

-- ────────────────────────────────────────
-- 1. PROYECTOS
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS proyectos (
    id              SERIAL PRIMARY KEY,
    nombre          TEXT NOT NULL,
    cliente         TEXT,
    squad           TEXT,
    estado          TEXT CHECK (estado IN ('En Curso','Finalizado','Planificado','Pausado')),
    inicio          DATE,
    fin_plan        DATE,
    hs_estimadas    NUMERIC(10,2),
    presupuesto_ars NUMERIC(15,2),
    costo_real_ars  NUMERIC(15,2) DEFAULT 0,
    clockify_id     TEXT,
    odoo_url        TEXT,
    gitlab_url      TEXT,
    drive_url       TEXT,
    -- ISO checklist (FP02 §8.4)
    tiene_propuesta     BOOLEAN DEFAULT FALSE,
    tiene_estimacion    BOOLEAN DEFAULT FALSE,
    tiene_oc_cliente    BOOLEAN DEFAULT FALSE,
    tiene_kickoff       BOOLEAN DEFAULT FALSE,
    tiene_gitlab        BOOLEAN DEFAULT FALSE,
    tiene_drive         BOOLEAN DEFAULT FALSE,
    tiene_arquitectura  BOOLEAN DEFAULT FALSE,
    tiene_riesgos       BOOLEAN DEFAULT FALSE,
    tiene_plan_pruebas  BOOLEAN DEFAULT FALSE,
    tiene_cierre        BOOLEAN DEFAULT FALSE,
    -- Satisfacción cliente (FP02 §14.1)
    score_satisfaccion  NUMERIC(3,1),
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ────────────────────────────────────────
-- 2. HORAS POR COLABORADOR / SEMANA
-- Fuente: Seguimiento_Operaciones_1.xlsx → REGISTRO_HORAS_*
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS horas_semana (
    id              SERIAL PRIMARY KEY,
    colaborador     TEXT NOT NULL,
    mes             DATE NOT NULL,          -- primer día del mes
    semana          INT  NOT NULL,
    inicio_semana   DATE,
    fin_semana      DATE,
    hs_objetivo     NUMERIC(6,2),
    hs_ausencias    NUMERIC(6,2) DEFAULT 0,
    hs_capacidad    NUMERIC(6,2),
    hs_productivas  NUMERIC(6,2),
    productividad   NUMERIC(5,4),           -- 0.9625 = 96.25%
    estado_carga    TEXT,                   -- '🟢 OK', '🟡 Ausente', etc.
    productividad_prom TEXT,                -- '🟢 ok', '🟡 Atencion', '🔴 Peligro'
    observaciones   TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_horas_mes       ON horas_semana(mes);
CREATE INDEX IF NOT EXISTS idx_horas_colab     ON horas_semana(colaborador);
CREATE INDEX IF NOT EXISTS idx_horas_mes_colab ON horas_semana(mes, colaborador);

-- ────────────────────────────────────────
-- 3. ENTRADAS CLOCKIFY (raw export)
-- Fuente: Jun_2026, May_2026, Clocky_*
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS clockify_entries (
    id              SERIAL PRIMARY KEY,
    proyecto        TEXT,
    cliente         TEXT,
    descripcion     TEXT,
    usuario         TEXT,
    email           TEXT,
    grupo           TEXT,
    facturable      BOOLEAN DEFAULT TRUE,
    fecha           DATE NOT NULL,
    hora_inicio     TIME,
    hora_fin        TIME,
    duracion_h      NUMERIC(6,2),
    mes             DATE,                   -- primer día del mes
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_clock_mes      ON clockify_entries(mes);
CREATE INDEX IF NOT EXISTS idx_clock_usuario  ON clockify_entries(usuario);
CREATE INDEX IF NOT EXISTS idx_clock_proyecto ON clockify_entries(proyecto);
CREATE INDEX IF NOT EXISTS idx_clock_fact     ON clockify_entries(facturable);

-- ────────────────────────────────────────
-- 4. HORAS POR PROYECTO (resumen mensual)
-- Fuente: Seguimiento_Horas_ZAP, _DIF, _Evol_DIF
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS horas_proyecto (
    id              SERIAL PRIMARY KEY,
    proyecto_id     INT REFERENCES proyectos(id) ON DELETE CASCADE,
    colaborador     TEXT NOT NULL,
    rol             TEXT,
    mes             DATE NOT NULL,
    hs_reales       NUMERIC(8,2) DEFAULT 0,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_hrsproy_proy ON horas_proyecto(proyecto_id);
CREATE INDEX IF NOT EXISTS idx_hrsproy_mes  ON horas_proyecto(mes);

-- ────────────────────────────────────────
-- 5. COSTOS POR PERFIL / MES
-- Fuente: Costo_Abril_2026, Costo_Marzo_2026, Costo_Febrero_2026
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS costos_perfil (
    id              SERIAL PRIMARY KEY,
    mes             DATE NOT NULL,
    perfil          TEXT NOT NULL,          -- 'DESARROLLADOR', 'QA', 'DEVOPS', etc.
    costo_hora      NUMERIC(12,2),          -- costo COGS por hora (ARS)
    costo_opex      NUMERIC(12,2),          -- costo OPEX por hora (ARS)
    total           NUMERIC(12,2),          -- costo_hora + costo_opex
    costo_venta     NUMERIC(12,2),          -- precio facturado al cliente
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (mes, perfil)
);

-- ────────────────────────────────────────
-- 6. RENTABILIDAD (FACT_OPEX / FORCAS)
-- Calculado: un registro por proyecto por snapshot
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rentabilidad (
    id                  SERIAL PRIMARY KEY,
    proyecto_id         INT REFERENCES proyectos(id) ON DELETE CASCADE,
    snapshot_date       DATE NOT NULL DEFAULT CURRENT_DATE,
    hs_estimadas        NUMERIC(10,2),
    hs_reales           NUMERIC(10,2),
    hs_restantes        NUMERIC(10,2),
    costo_real_ars      NUMERIC(15,2),
    costo_prom_hora     NUMERIC(12,2),
    proy_costo_rest     NUMERIC(15,2),      -- proyección costo restante
    forcas_costo_final  NUMERIC(15,2),      -- FORCAS: costo final proyectado
    forcas_margen_pct   NUMERIC(6,4),       -- margen % proyectado
    hs_facturables      NUMERIC(10,2),
    hs_no_facturables   NUMERIC(10,2),
    costo_cogs          NUMERIC(15,2),
    costo_opex          NUMERIC(15,2),
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rent_proy ON rentabilidad(proyecto_id);
CREATE INDEX IF NOT EXISTS idx_rent_snap ON rentabilidad(snapshot_date);

-- ────────────────────────────────────────
-- 7. SATISFACCIÓN CLIENTE (FP02 §14.1)
-- Meta interna ≥ 8 · CLUTCH ≥ 4.5
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS satisfaccion (
    id              SERIAL PRIMARY KEY,
    proyecto_id     INT REFERENCES proyectos(id) ON DELETE SET NULL,
    fecha           DATE NOT NULL DEFAULT CURRENT_DATE,
    tipo            TEXT CHECK (tipo IN ('interna','clutch','feedback')),
    score           NUMERIC(4,1),
    comentarios     TEXT,
    requiere_nc     BOOLEAN DEFAULT FALSE,  -- score ≤ 3 → NC (FP02 §14.1)
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ────────────────────────────────────────
-- 8. EVALUACIÓN INDIVIDUAL (FP02 §16)
-- Fuente: EVALUACION_INDIVIDUAL sheet
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS evaluacion_individual (
    id              SERIAL PRIMARY KEY,
    colaborador     TEXT NOT NULL,
    periodo         TEXT NOT NULL,          -- '2025-2S', '2026-1S'
    registra_trabajo BOOLEAN,
    avisa_desvios   BOOLEAN,
    participa       BOOLEAN,
    resultado       TEXT,                   -- '🟢 Cumple Compromiso', '🟡 Riesgo', '🔴 No Cumple'
    nota            TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ────────────────────────────────────────
-- 9. OVERVIEW SEMANAL
-- Fuente: OVERVIEW sheet
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS overview_semanal (
    id                  SERIAL PRIMARY KEY,
    mes                 DATE NOT NULL,
    semana              INT  NOT NULL,
    inicio              DATE,
    fin                 DATE,
    productividad_pond  NUMERIC(6,4),       -- promedio ponderado del equipo
    pedida_opex         NUMERIC(6,4),       -- % horas OPEX
    pct_no_cargo        NUMERIC(6,4),       -- % colaboradores sin carga
    score_salud         NUMERIC(6,2),       -- 0–100+
    semaforo            TEXT,               -- '🟢 Saludable', '🟡 Riesgo', etc.
    escalabilidad       TEXT,               -- 'Escalable', 'Ajustar', etc.
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (mes, semana)
);

-- ────────────────────────────────────────
-- 10. NO CONFORMIDADES (FP02 §13 / R01 PG04)
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS no_conformidades (
    id              SERIAL PRIMARY KEY,
    proyecto_id     INT REFERENCES proyectos(id) ON DELETE SET NULL,
    tipo            TEXT CHECK (tipo IN (
                        'Interno - SLA incidentes',
                        'Interno - Cumplimiento Sprint',
                        'Interno - Calidad',
                        'Externo - Satisfacción',
                        'Externo - Reclamo cliente',
                        'Externo - Entrega'
                    )),
    descripcion     TEXT,
    fecha_deteccion DATE DEFAULT CURRENT_DATE,
    responsable     TEXT,
    accion          TEXT,
    fecha_objetivo  DATE,
    estado          TEXT CHECK (estado IN ('Abierta','En proceso','Cerrada')) DEFAULT 'Abierta',
    eficacia_ok     BOOLEAN,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ────────────────────────────────────────
-- VISTAS ÚTILES
-- ────────────────────────────────────────

-- KPIs ejecutivos por proyecto
CREATE OR REPLACE VIEW v_kpi_proyectos AS
SELECT
    p.id,
    p.nombre,
    p.cliente,
    p.estado,
    p.inicio,
    p.fin_plan,
    p.hs_estimadas,
    p.presupuesto_ars,
    COALESCE(r.hs_reales, 0)           AS hs_reales,
    COALESCE(r.hs_restantes, 0)        AS hs_restantes,
    COALESCE(r.costo_real_ars, 0)      AS costo_real_ars,
    COALESCE(r.forcas_costo_final, 0)  AS forcas_costo_final,
    COALESCE(r.forcas_margen_pct, 0)   AS forcas_margen_pct,
    COALESCE(r.costo_prom_hora, 0)     AS costo_prom_hora,
    CASE
        WHEN r.forcas_margen_pct >= 0.35 THEN 'verde'
        WHEN r.forcas_margen_pct >= 0.10 THEN 'amarillo'
        ELSE 'rojo'
    END AS semaforo_margen,
    CASE
        WHEN p.hs_estimadas > 0
        THEN ROUND(COALESCE(r.hs_reales,0) / p.hs_estimadas * 100, 1)
        ELSE 0
    END AS pct_avance_horas
FROM proyectos p
LEFT JOIN LATERAL (
    SELECT * FROM rentabilidad
    WHERE proyecto_id = p.id
    ORDER BY snapshot_date DESC
    LIMIT 1
) r ON TRUE;

-- Productividad mensual del equipo
CREATE OR REPLACE VIEW v_productividad_mes AS
SELECT
    mes,
    COUNT(DISTINCT colaborador)                     AS total_colaboradores,
    ROUND(AVG(productividad) * 100, 2)             AS prod_promedio_pct,
    SUM(hs_productivas)                             AS hs_productivas_total,
    SUM(hs_objetivo)                                AS hs_objetivo_total,
    SUM(hs_ausencias)                               AS hs_ausencias_total,
    COUNT(*) FILTER (WHERE productividad_prom LIKE '%Peligro%') AS colaboradores_peligro
FROM horas_semana
GROUP BY mes
ORDER BY mes;

-- Facturable vs no facturable por mes
CREATE OR REPLACE VIEW v_facturable_mes AS
SELECT
    mes,
    proyecto,
    cliente,
    SUM(duracion_h) FILTER (WHERE facturable = TRUE)  AS hs_facturables,
    SUM(duracion_h) FILTER (WHERE facturable = FALSE) AS hs_no_facturables,
    SUM(duracion_h)                                    AS hs_total,
    ROUND(
        SUM(duracion_h) FILTER (WHERE facturable = TRUE) /
        NULLIF(SUM(duracion_h), 0) * 100, 1
    ) AS pct_facturable
FROM clockify_entries
GROUP BY mes, proyecto, cliente
ORDER BY mes, hs_total DESC;

-- ────────────────────────────────────────
-- DATOS INICIALES (de los Excel reales)
-- ────────────────────────────────────────
INSERT INTO proyectos (nombre, cliente, squad, estado, inicio, fin_plan, hs_estimadas, presupuesto_ars,
    tiene_propuesta, tiene_estimacion, tiene_oc_cliente, tiene_kickoff, tiene_gitlab,
    tiene_drive, tiene_arquitectura, tiene_riesgos, tiene_plan_pruebas,
    clockify_id, odoo_url)
VALUES
(
    'Agente Proactivo de Minutas y Control de Alcance',
    'ZAP Arquitectos', 'Squad Proyecto', 'En Curso',
    '2026-02-25', '2026-05-19', 155, 9136680,
    TRUE, FALSE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE,
    NULL, NULL
),
(
    'Agente Determinación de Oficio',
    'DIF', 'Squad Proyecto', 'En Curso',
    '2025-12-15', '2026-03-26', 1960, 159392133,
    TRUE, TRUE, FALSE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE,
    'https://app.clockify.me/projects/693ab2ff7f42766563ba7823/',
    'https://odoo.ithreexglobal.com/web#action=198&active_id=64'
),
(
    'Evolutivo Agente Determinación de Oficio',
    'DIF', NULL, 'Planificado',
    '2026-06-08', '2026-08-28', 708, 60464466,
    FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE,
    NULL, NULL
)
ON CONFLICT DO NOTHING;

INSERT INTO costos_perfil (mes, perfil, costo_hora, costo_opex, total, costo_venta) VALUES
('2026-04-01','ML',          20502.71, 8703.54, 29206.25, 51256.78),
('2026-04-01','DESARROLLADOR',12500.00, 8703.54, 21203.54, 31250.00),
('2026-04-01','QA',          18683.56, 8703.54, 27387.10, 46708.90),
('2026-04-01','BIG DATA',    12364.05, 8703.54, 21067.59, 30910.13),
('2026-04-01','DEVOPS',      19895.96, 8703.54, 28599.50, 49739.90),
('2026-04-01','DELIVERY MANAGER',32931.36,8703.54,41634.90,82328.40),
('2026-04-01','ARQUITECTO',  32931.36, 8703.54, 41634.90, 82328.40),
('2026-03-01','ML',          20462.17, 7556.23, 28018.40, 51155.43),
('2026-03-01','DESARROLLADOR',21875.00, 7556.23, 29431.23, 54687.50),
('2026-03-01','QA',          20371.72, 7556.23, 27927.95, 50929.30),
('2026-03-01','BIG DATA',    12364.05, 7556.23, 19920.28, 30910.13),
('2026-03-01','DEVOPS',      25000.00, 7556.23, 32556.23, 62500.00),
('2026-03-01','DELIVERY MANAGER',25975.02,7556.23,33531.25,64937.55),
('2026-03-01','ARQUITECTO',  25625.00, 7556.23, 33181.23, 64062.50),
('2026-02-01','ML',          20462.17, 6867.39, 27329.56, 51155.43),
('2026-02-01','DESARROLLADOR',21875.00, 6867.39, 28742.39, 54687.50),
('2026-02-01','QA',          20371.12, 6867.39, 27239.11, 50927.80),
('2026-02-01','BIG DATA',    12364.05, 6867.39, 19231.44, 30910.13),
('2026-02-01','DEVOPS',      25000.00, 6867.39, 31867.39, 62500.00),
('2026-02-01','DELIVERY MANAGER',25975.02,6867.39,32842.41,64937.55),
('2026-02-01','ARQUITECTO',  25625.00, 6867.39, 32492.39, 64062.50)
ON CONFLICT (mes, perfil) DO NOTHING;

INSERT INTO overview_semanal (mes, semana, inicio, fin, productividad_pond, pedida_opex, pct_no_cargo, score_salud, semaforo, escalabilidad) VALUES
('2026-01-01', 1, '2026-01-05','2026-01-11', 0.9698, 0.0302, 0, 112.5, '🟢 Saludable', 'Escalable'),
('2026-01-01', 2, '2026-01-12','2026-01-18', 0.9585, 0.0415, 0, 112.5, '🟢 Saludable', 'Escalable'),
('2026-01-01', 3, '2026-01-19','2026-01-25', 0.9730, 0.0270, 0, 112.5, '🟢 Saludable', 'Escalable')
ON CONFLICT (mes, semana) DO NOTHING;

INSERT INTO evaluacion_individual (colaborador, periodo, registra_trabajo, avisa_desvios, participa, resultado, nota) VALUES
('Anabel Alarcon',      '2025-2S', TRUE,  FALSE, TRUE,  '🟡 Riesgo',              'No hay voluntad para hacer pruebas de otros proyectos. Centralizada 100% con cliente en Uruguay.'),
('Naira Garibay',       '2025-2S', TRUE,  FALSE, TRUE,  '🟡 Riesgo',              'No hay voluntad para hacer pruebas de otros proyectos.'),
('Daniel Martinez',     '2025-2S', TRUE,  TRUE,  TRUE,  '🟢 Cumple Compromiso',   NULL),
('Marco Saggiorato',    '2025-2S', TRUE,  TRUE,  TRUE,  '🟢 Cumple Compromiso',   NULL),
('Mariano Bozzoletti',  '2025-2S', TRUE,  FALSE, FALSE, '🔴 No Cumple Compromisos','No es proactivo, no consulta, no levanta la mano.'),
('Mario Reyna',         '2025-2S', TRUE,  FALSE, FALSE, '🔴 No Cumple Compromisos','No participa en dailys. Hay que estarle encima.'),
('Melisa Sajoza',       '2025-2S', TRUE,  TRUE,  TRUE,  '🟢 Cumple Compromiso',   NULL)
ON CONFLICT DO NOTHING;
