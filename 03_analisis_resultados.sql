-- ============================================================================
-- ANALISIS DE RESULTADOS: Ejecutar DESPUES del spike
-- ============================================================================
-- Agrega y resume los datos capturados para encontrar los culpables.
-- Cada seccion responde una pregunta especifica.
-- ============================================================================

-- ============================================================================
-- A. TIMELINE DE DTU: Como evoluciono el spike?
-- ============================================================================
PRINT '=== [A] TIMELINE DE DTU DURANTE EL SPIKE ==='
PRINT ''

SELECT
    snapshot_utc,
    end_time,
    dtu_percent_approx          AS dtu_pct,
    avg_cpu_percent             AS cpu_pct,
    avg_data_io_percent         AS io_pct,
    avg_log_write_percent       AS log_pct,
    avg_memory_usage_percent    AS mem_pct,
    -- Indicador visual
    REPLICATE('|', CAST(dtu_percent_approx AS INT) / 2) AS dtu_bar
FROM dbo.diag_resource_stats
WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
ORDER BY end_time;

-- ============================================================================
-- B. QUIEN ESTUVO CONECTADO DURANTE EL SPIKE?
--    Usuarios, IPs y programas unicos
-- ============================================================================
PRINT ''
PRINT '=== [B] USUARIOS/IPS/PROGRAMAS UNICOS DURANTE EL SPIKE ==='
PRINT ''

SELECT
    login_name,
    ip_origen,
    host_name,
    program_name,
    COUNT(DISTINCT snapshot_utc)     AS visto_en_n_snapshots,
    COUNT(DISTINCT session_id)       AS sesiones_distintas,
    MIN(snapshot_utc)                AS primera_vez_visto,
    MAX(snapshot_utc)                AS ultima_vez_visto,
    MAX(cpu_time_ms)                 AS max_cpu_time_ms,
    MAX(logical_reads)               AS max_logical_reads
FROM dbo.diag_sessions
WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
GROUP BY login_name, ip_origen, host_name, program_name
ORDER BY MAX(cpu_time_ms) DESC;

-- ============================================================================
-- C. TOP QUERIES CAPTURADAS EN EJECUCION (las que "pescamos" corriendo)
-- ============================================================================
PRINT ''
PRINT '=== [C] QUERIES CAPTURADAS EN EJECUCION DURANTE EL SPIKE ==='
PRINT ''

SELECT
    snapshot_utc,
    session_id,
    login_name,
    ip_origen,
    program_name,
    command,
    elapsed_seconds,
    cpu_time_ms,
    logical_reads,
    physical_reads,
    writes,
    wait_type,
    wait_time_ms,
    blocking_session_id,
    granted_memory_kb,
    LEFT(query_statement, 500)       AS query_preview,
    database_name
FROM dbo.diag_active_queries
WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
ORDER BY cpu_time_ms DESC;

-- ============================================================================
-- D. QUERIES AGRUPADAS POR HASH (misma query ejecutada multiples veces)
--    ESTA ES LA SECCION MAS IMPORTANTE si la seccion C tiene datos
-- ============================================================================
PRINT ''
PRINT '=== [D] QUERIES AGRUPADAS POR PATRON (query_hash) ==='
PRINT ''

SELECT
    query_hash,
    COUNT(*)                                    AS veces_capturada,
    COUNT(DISTINCT session_id)                  AS sesiones_distintas,
    COUNT(DISTINCT snapshot_utc)                AS en_n_snapshots,
    MIN(login_name)                             AS login,
    MIN(ip_origen)                              AS ip,
    MIN(program_name)                           AS programa,
    AVG(cpu_time_ms)                            AS avg_cpu_ms,
    MAX(cpu_time_ms)                            AS max_cpu_ms,
    AVG(logical_reads)                          AS avg_logical_reads,
    MAX(logical_reads)                          AS max_logical_reads,
    AVG(elapsed_seconds)                        AS avg_elapsed_sec,
    MAX(elapsed_seconds)                        AS max_elapsed_sec,
    LEFT(MIN(query_statement), 300)             AS query_preview
FROM dbo.diag_active_queries
WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
  AND query_hash IS NOT NULL
GROUP BY query_hash
ORDER BY SUM(cpu_time_ms) DESC;

-- ============================================================================
-- E. TOP QUERIES DEL QUERY STORE (la fuente mas confiable)
--    Esto captura TODO lo que se ejecuto, incluso si fue rapido
-- ============================================================================
PRINT ''
PRINT '=== [E] TOP 15 QUERIES POR CPU TOTAL (Query Store) ==='
PRINT ''

SELECT TOP 15
    query_id,
    plan_id,
    MAX(count_executions)                       AS executions,
    MAX(avg_cpu_time_us)                        AS avg_cpu_us,
    MAX(max_cpu_time_us)                        AS max_cpu_us,
    MAX(avg_cpu_time_us) * MAX(count_executions) AS total_cpu_us_approx,
    MAX(avg_duration_us)                        AS avg_duration_us,
    MAX(avg_logical_io_reads)                   AS avg_reads,
    MAX(avg_rowcount)                           AS avg_rows,
    MAX(avg_memory_grant_kb)                    AS avg_mem_kb,
    MAX(last_execution_time)                    AS last_exec,
    LEFT(MAX(query_text), 500)                  AS query_preview
FROM dbo.diag_query_store_top
WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
GROUP BY query_id, plan_id
ORDER BY MAX(avg_cpu_time_us) * MAX(count_executions) DESC;

-- ============================================================================
-- F. COMPARACION DE WAIT STATS ENTRE SNAPSHOTS
--    Muestra que tipo de espera crecio durante el spike
-- ============================================================================
PRINT ''
PRINT '=== [F] WAIT STATS: CRECIMIENTO DURANTE EL SPIKE ==='
PRINT ''

;WITH primer_snapshot AS (
    SELECT wait_type, wait_time_ms, snapshot_utc
    FROM dbo.diag_wait_stats w1
    WHERE snapshot_utc = (SELECT MIN(snapshot_utc) FROM dbo.diag_wait_stats WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE()))
),
ultimo_snapshot AS (
    SELECT wait_type, wait_time_ms, snapshot_utc
    FROM dbo.diag_wait_stats w2
    WHERE snapshot_utc = (SELECT MAX(snapshot_utc) FROM dbo.diag_wait_stats WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE()))
)
SELECT
    COALESCE(u.wait_type, p.wait_type)          AS wait_type,
    ISNULL(p.wait_time_ms, 0)                   AS wait_ms_inicio,
    ISNULL(u.wait_time_ms, 0)                   AS wait_ms_final,
    ISNULL(u.wait_time_ms, 0) - ISNULL(p.wait_time_ms, 0) AS delta_wait_ms,
    p.snapshot_utc                              AS snapshot_inicio,
    u.snapshot_utc                              AS snapshot_final
FROM ultimo_snapshot u
FULL OUTER JOIN primer_snapshot p ON u.wait_type = p.wait_type
WHERE ISNULL(u.wait_time_ms, 0) - ISNULL(p.wait_time_ms, 0) > 0
ORDER BY ISNULL(u.wait_time_ms, 0) - ISNULL(p.wait_time_ms, 0) DESC;

-- ============================================================================
-- G. BLOQUEOS DETECTADOS
-- ============================================================================
PRINT ''
PRINT '=== [G] BLOQUEOS DETECTADOS ==='
PRINT ''

SELECT
    snapshot_utc,
    blocked_session,
    blocking_session,
    wait_type,
    wait_time_ms,
    blocked_login,
    blocked_ip,
    blocker_login,
    blocker_ip,
    LEFT(blocked_query, 300)                    AS blocked_query_preview,
    LEFT(blocker_last_query, 300)               AS blocker_query_preview
FROM dbo.diag_blocking
WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
ORDER BY wait_time_ms DESC;

-- ============================================================================
-- H. QUERY COMPLETA + PLAN DE EJECUCION
--    Para las top 5 queries por CPU, mostrar texto completo y plan
-- ============================================================================
PRINT ''
PRINT '=== [H] DETALLE COMPLETO DE LAS TOP 5 QUERIES MAS COSTOSAS ==='
PRINT ''

;WITH ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY avg_cpu_time_us * count_executions DESC) AS rn
    FROM dbo.diag_query_store_top
    WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
)
SELECT TOP 5
    query_id,
    plan_id,
    count_executions,
    avg_cpu_time_us,
    max_cpu_time_us,
    avg_duration_us,
    avg_logical_io_reads,
    avg_physical_io_reads,
    avg_rowcount,
    avg_memory_grant_kb,
    last_execution_time,
    query_text,         -- texto COMPLETO de la query
    query_plan_xml      -- plan COMPLETO en XML (click para ver grafico en SSMS)
FROM ranked
WHERE rn = 1
ORDER BY avg_cpu_time_us * count_executions DESC;

-- ============================================================================
-- I. RESUMEN EJECUTIVO
-- ============================================================================
PRINT ''
PRINT '=== [I] RESUMEN EJECUTIVO ==='
PRINT ''

SELECT 'Snapshots capturados' AS metrica, CAST(COUNT(DISTINCT snapshot_utc) AS VARCHAR) AS valor FROM dbo.diag_resource_stats WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
UNION ALL
SELECT 'DTU maximo observado', CAST(MAX(dtu_percent_approx) AS VARCHAR) FROM dbo.diag_resource_stats WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
UNION ALL
SELECT 'Queries activas capturadas', CAST(COUNT(*) AS VARCHAR) FROM dbo.diag_active_queries WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
UNION ALL
SELECT 'Logins unicos', CAST(COUNT(DISTINCT login_name) AS VARCHAR) FROM dbo.diag_sessions WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
UNION ALL
SELECT 'IPs unicas', CAST(COUNT(DISTINCT ip_origen) AS VARCHAR) FROM dbo.diag_sessions WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
UNION ALL
SELECT 'Bloqueos detectados', CAST(COUNT(*) AS VARCHAR) FROM dbo.diag_blocking WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE())
UNION ALL
SELECT 'Query Store entries', CAST(COUNT(DISTINCT query_id) AS VARCHAR) FROM dbo.diag_query_store_top WHERE snapshot_utc >= DATEADD(HOUR, -2, GETUTCDATE());

PRINT ''
PRINT '=== ANALISIS COMPLETO ==='
PRINT 'Revisar secciones E y H para las queries mas costosas con su plan de ejecucion.'
PRINT 'Compartir los resultados de secciones E, F y H para optimizacion.'
GO
