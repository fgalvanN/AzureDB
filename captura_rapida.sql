-- ============================================================================
-- CAPTURA RAPIDA: Ejecutar cada 1-2 minutos durante el spike
-- ============================================================================
-- Version compacta que captura solo lo esencial para no perder tiempo
-- Ideal para ejecutar repetidamente y luego comparar los snapshots
-- ============================================================================

-- Snapshot de recursos + queries activas + IP/usuario en una sola consulta
SELECT
    GETUTCDATE()                                    AS snapshot_utc,
    '--- RECURSO ---'                               AS seccion,
    rs.end_time,
    CAST(GREATEST(rs.avg_cpu_percent, rs.avg_data_io_percent, rs.avg_log_write_percent) AS DECIMAL(5,2)) AS dtu_pct,
    rs.avg_cpu_percent,
    rs.avg_data_io_percent,
    rs.avg_log_write_percent,
    rs.avg_memory_usage_percent
FROM sys.dm_db_resource_stats rs
ORDER BY rs.end_time DESC;

-- Las queries ejecutandose AHORA con todo el contexto
SELECT
    GETUTCDATE()                                    AS snapshot_utc,
    r.session_id,
    s.login_name,
    c.client_net_address                            AS ip_origen,
    s.host_name,
    s.program_name,
    r.status,
    r.command,
    DATEDIFF(SECOND, r.start_time, GETUTCDATE())   AS elapsed_sec,
    r.cpu_time                                      AS cpu_ms,
    r.logical_reads,
    r.reads                                         AS physical_reads,
    r.writes,
    r.wait_type,
    r.wait_time                                     AS wait_ms,
    r.blocking_session_id,
    SUBSTRING(
        qt.text,
        (r.statement_start_offset / 2) + 1,
        CASE
            WHEN r.statement_end_offset = -1 THEN LEN(qt.text)
            ELSE (r.statement_end_offset - r.statement_start_offset) / 2 + 1
        END
    )                                               AS query_statement,
    qt.text                                         AS full_batch,
    qp.query_plan                                   AS plan_xml
FROM sys.dm_exec_requests r
INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
LEFT JOIN sys.dm_exec_connections c ON r.session_id = c.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) qt
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE s.is_user_process = 1
  AND r.session_id <> @@SPID
ORDER BY r.cpu_time DESC;
