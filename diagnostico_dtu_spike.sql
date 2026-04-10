-- ============================================================================
-- SCRIPT DE DIAGNOSTICO: Spike de DTU al 100% - Azure SQL Database
-- ============================================================================
-- USO: Ejecutar manualmente una o varias veces durante el spike (~7:00 AM)
--      Copiar y pegar cada seccion o ejecutar completo en SSMS/Azure Data Studio
--      Cada resultado viene etiquetado con timestamp para correlacionar despues
-- ============================================================================

-- ============================================================================
-- 1. SNAPSHOT GENERAL: Consumo actual de DTU y recursos
-- ============================================================================
PRINT '=== [1] CONSUMO ACTUAL DE RECURSOS (DTU/CPU/IO/LOG) ==='
PRINT 'Timestamp: ' + CONVERT(VARCHAR(30), GETUTCDATE(), 121)
PRINT ''

SELECT
    GETUTCDATE()                                    AS snapshot_utc,
    end_time,
    avg_cpu_percent,
    avg_data_io_percent,
    avg_log_write_percent,
    avg_memory_usage_percent,
    -- DTU% es el maximo entre CPU, Data IO y Log Write
    CAST(GREATEST(avg_cpu_percent, avg_data_io_percent, avg_log_write_percent) AS DECIMAL(5,2)) AS dtu_percent_approx,
    xtp_storage_percent,
    max_worker_percent,
    max_session_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;

-- ============================================================================
-- 2. SESIONES ACTIVAS: Quien esta conectado y que esta haciendo
-- ============================================================================
PRINT ''
PRINT '=== [2] SESIONES ACTIVAS CON DETALLE DE CONEXION ==='
PRINT ''

SELECT
    GETUTCDATE()                                    AS snapshot_utc,
    s.session_id,
    s.login_name,
    s.host_name,
    c.client_net_address                            AS ip_origen,
    c.client_tcp_port                               AS puerto_origen,
    s.program_name,
    s.status                                        AS session_status,
    s.cpu_time                                      AS session_cpu_time_ms,
    s.reads                                         AS session_reads,
    s.writes                                        AS session_writes,
    s.logical_reads                                 AS session_logical_reads,
    s.memory_usage                                  AS session_memory_pages,
    s.login_time,
    s.last_request_start_time,
    s.last_request_end_time,
    DB_NAME(s.database_id)                          AS database_name,
    c.auth_scheme,
    c.encrypt_option,
    c.net_transport
FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
WHERE s.is_user_process = 1
ORDER BY s.cpu_time DESC;

-- ============================================================================
-- 3. QUERIES EN EJECUCION: Las consultas corriendo AHORA MISMO
--    (esta es la seccion mas critica para identificar el proceso)
-- ============================================================================
PRINT ''
PRINT '=== [3] QUERIES EN EJECUCION AHORA MISMO (TOP CONSUMIDORAS) ==='
PRINT ''

SELECT
    GETUTCDATE()                                    AS snapshot_utc,
    r.session_id,
    r.request_id,
    r.status                                        AS request_status,
    r.command,
    r.start_time                                    AS request_start_time,
    DATEDIFF(SECOND, r.start_time, GETUTCDATE())   AS elapsed_seconds,
    r.cpu_time                                      AS request_cpu_time_ms,
    r.total_elapsed_time                            AS total_elapsed_ms,
    r.reads                                         AS request_reads,
    r.writes                                        AS request_writes,
    r.logical_reads                                 AS request_logical_reads,
    r.wait_type,
    r.wait_time                                     AS wait_time_ms,
    r.wait_resource,
    r.blocking_session_id,
    r.granted_query_memory                          AS granted_memory_kb,
    r.percent_complete,
    -- Info de conexion
    s.login_name,
    s.host_name,
    c.client_net_address                            AS ip_origen,
    s.program_name,
    DB_NAME(r.database_id)                          AS database_name,
    -- Texto de la query (completo)
    SUBSTRING(
        qt.text,
        (r.statement_start_offset / 2) + 1,
        CASE
            WHEN r.statement_end_offset = -1 THEN LEN(qt.text)
            ELSE (r.statement_end_offset - r.statement_start_offset) / 2 + 1
        END
    )                                               AS query_actual_statement,
    qt.text                                         AS query_full_batch,
    -- Plan handle para obtener el plan despues
    r.plan_handle,
    r.sql_handle,
    qp.query_plan                                   AS plan_ejecucion_xml
FROM sys.dm_exec_requests r
INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
LEFT JOIN sys.dm_exec_connections c ON r.session_id = c.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) qt
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE s.is_user_process = 1
  AND r.session_id <> @@SPID  -- excluir esta misma sesion
ORDER BY r.cpu_time DESC;

-- ============================================================================
-- 4. TOP QUERIES POR CPU (acumulado reciente del Query Store)
-- ============================================================================
PRINT ''
PRINT '=== [4] TOP 20 QUERIES POR CPU - QUERY STORE (ultima hora) ==='
PRINT ''

SELECT TOP 20
    GETUTCDATE()                                    AS snapshot_utc,
    qsq.query_id,
    qsp.plan_id,
    qsq.query_hash,
    CAST(qsqt.query_sql_text AS NVARCHAR(4000))    AS query_text,
    rs.count_executions,
    rs.avg_cpu_time                                 AS avg_cpu_time_us,
    rs.max_cpu_time                                 AS max_cpu_time_us,
    rs.avg_duration                                 AS avg_duration_us,
    rs.max_duration                                 AS max_duration_us,
    rs.avg_logical_io_reads,
    rs.max_logical_io_reads,
    rs.avg_logical_io_writes,
    rs.avg_physical_io_reads,
    rs.avg_rowcount,
    rs.avg_query_max_used_memory                    AS avg_memory_grant_kb,
    rs.last_execution_time,
    rs.first_execution_time,
    -- Plan en XML
    TRY_CAST(qsp.query_plan AS XML)                AS plan_ejecucion_xml
FROM sys.query_store_runtime_stats rs
INNER JOIN sys.query_store_plan qsp ON rs.plan_id = qsp.plan_id
INNER JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
INNER JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
WHERE rs.last_execution_time >= DATEADD(HOUR, -1, GETUTCDATE())
ORDER BY rs.avg_cpu_time * rs.count_executions DESC;

-- ============================================================================
-- 5. WAITS ACTUALES: Donde esta esperando el servidor
-- ============================================================================
PRINT ''
PRINT '=== [5] WAIT STATS ACTUALES (por tipo de espera) ==='
PRINT ''

SELECT
    GETUTCDATE()                                    AS snapshot_utc,
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms,
    wait_time_ms - signal_wait_time_ms              AS resource_wait_time_ms,
    CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER (), 0) AS DECIMAL(5,2)) AS pct_total_wait
FROM sys.dm_db_wait_stats
WHERE wait_type NOT IN (
    'SLEEP_TASK', 'BROKER_TASK_STOP', 'BROKER_IO_FLUSH',
    'SQLTRACE_BUFFER_FLUSH', 'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT',
    'LAZYWRITER_SLEEP', 'CHECKPOINT_QUEUE', 'WAITFOR',
    'BROKER_EVENTHANDLER', 'XE_TIMER_EVENT', 'XE_DISPATCHER_WAIT',
    'FT_IFTS_SCHEDULER_IDLE_WAIT', 'BROKER_TRANSMITTER',
    'SP_SERVER_DIAGNOSTICS_SLEEP', 'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'DIRTY_PAGE_POLL', 'REQUEST_FOR_DEADLOCK_SEARCH'
)
AND wait_time_ms > 0
ORDER BY wait_time_ms DESC;

-- ============================================================================
-- 6. BLOQUEOS: Sesiones bloqueando a otras
-- ============================================================================
PRINT ''
PRINT '=== [6] CADENA DE BLOQUEOS ACTIVOS ==='
PRINT ''

SELECT
    GETUTCDATE()                                    AS snapshot_utc,
    r.session_id                                    AS blocked_session,
    r.blocking_session_id                           AS blocking_session,
    r.wait_type,
    r.wait_time                                     AS wait_time_ms,
    r.wait_resource,
    -- Info de la sesion bloqueada
    s_blocked.login_name                            AS blocked_login,
    c_blocked.client_net_address                    AS blocked_ip,
    s_blocked.program_name                          AS blocked_program,
    SUBSTRING(
        qt_blocked.text,
        (r.statement_start_offset / 2) + 1,
        CASE
            WHEN r.statement_end_offset = -1 THEN LEN(qt_blocked.text)
            ELSE (r.statement_end_offset - r.statement_start_offset) / 2 + 1
        END
    )                                               AS blocked_query,
    -- Info de la sesion que bloquea
    s_blocker.login_name                            AS blocker_login,
    c_blocker.client_net_address                    AS blocker_ip,
    s_blocker.program_name                          AS blocker_program,
    qt_blocker.text                                 AS blocker_last_query
FROM sys.dm_exec_requests r
INNER JOIN sys.dm_exec_sessions s_blocked ON r.session_id = s_blocked.session_id
LEFT JOIN sys.dm_exec_connections c_blocked ON r.session_id = c_blocked.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) qt_blocked
-- Info del bloqueador
LEFT JOIN sys.dm_exec_sessions s_blocker ON r.blocking_session_id = s_blocker.session_id
LEFT JOIN sys.dm_exec_connections c_blocker ON r.blocking_session_id = c_blocker.session_id
OUTER APPLY sys.dm_exec_sql_text(c_blocker.most_recent_sql_handle) qt_blocker
WHERE r.blocking_session_id <> 0
ORDER BY r.wait_time DESC;

-- ============================================================================
-- 7. INDICES: Indices faltantes que podrian estar causando scans costosos
-- ============================================================================
PRINT ''
PRINT '=== [7] TOP 10 INDICES FALTANTES SUGERIDOS ==='
PRINT ''

SELECT TOP 10
    GETUTCDATE()                                    AS snapshot_utc,
    CAST(gs.avg_total_user_cost * gs.avg_user_impact * (gs.user_seeks + gs.user_scans) AS DECIMAL(18,2))
                                                    AS improvement_measure,
    DB_NAME(id.database_id)                         AS database_name,
    id.statement                                    AS table_name,
    id.equality_columns,
    id.inequality_columns,
    id.included_columns,
    gs.unique_compiles,
    gs.user_seeks,
    gs.user_scans,
    gs.avg_total_user_cost,
    gs.avg_user_impact
FROM sys.dm_db_missing_index_group_stats gs
INNER JOIN sys.dm_db_missing_index_groups ig ON gs.group_handle = ig.index_group_handle
INNER JOIN sys.dm_db_missing_index_details id ON ig.index_handle = id.index_handle
ORDER BY improvement_measure DESC;

-- ============================================================================
-- 8. ESTADISTICAS DE IO POR TABLA (sesion actual del servidor)
-- ============================================================================
PRINT ''
PRINT '=== [8] TOP 20 TABLAS POR IO ACUMULADO ==='
PRINT ''

SELECT TOP 20
    GETUTCDATE()                                    AS snapshot_utc,
    OBJECT_SCHEMA_NAME(ios.object_id)               AS schema_name,
    OBJECT_NAME(ios.object_id)                      AS table_name,
    i.name                                          AS index_name,
    i.type_desc                                     AS index_type,
    ios.leaf_insert_count + ios.leaf_update_count + ios.leaf_delete_count
                                                    AS total_writes,
    ios.range_scan_count + ios.singleton_lookup_count
                                                    AS total_reads,
    ios.leaf_allocation_count                        AS page_splits,
    ios.row_lock_count,
    ios.row_lock_wait_count,
    ios.row_lock_wait_in_ms,
    ios.page_lock_count,
    ios.page_lock_wait_count,
    ios.page_lock_wait_in_ms
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) ios
INNER JOIN sys.indexes i ON ios.object_id = i.object_id AND ios.index_id = i.index_id
WHERE OBJECTPROPERTY(ios.object_id, 'IsUserTable') = 1
ORDER BY (ios.range_scan_count + ios.singleton_lookup_count + ios.leaf_insert_count + ios.leaf_update_count + ios.leaf_delete_count) DESC;

-- ============================================================================
-- 9. TEMPDB: Uso de tempdb por sesion (posibles spills)
-- ============================================================================
-- Usa dm_db_session_space_usage que ACUMULA datos de toda la sesion,
-- incluso despues de que las tareas individuales terminen.
-- Esto devuelve datos aunque no haya tareas activas en este instante.
PRINT ''
PRINT '=== [9] USO DE TEMPDB POR SESION ==='
PRINT ''

SELECT
    GETUTCDATE()                                    AS snapshot_utc,
    ssu.session_id,
    s.login_name,
    s.host_name,
    c.client_net_address                            AS ip_origen,
    s.program_name,
    ssu.user_objects_alloc_page_count               AS user_objects_alloc_pages,
    ssu.user_objects_dealloc_page_count             AS user_objects_dealloc_pages,
    (ssu.user_objects_alloc_page_count - ssu.user_objects_dealloc_page_count) AS user_objects_net_pages,
    ssu.internal_objects_alloc_page_count            AS internal_objects_alloc_pages,
    ssu.internal_objects_dealloc_page_count          AS internal_objects_dealloc_pages,
    (ssu.internal_objects_alloc_page_count - ssu.internal_objects_dealloc_page_count) AS internal_objects_net_pages,
    (ssu.user_objects_alloc_page_count + ssu.internal_objects_alloc_page_count) * 8 / 1024
                                                    AS total_alloc_mb,
    (ssu.user_objects_alloc_page_count - ssu.user_objects_dealloc_page_count
     + ssu.internal_objects_alloc_page_count - ssu.internal_objects_dealloc_page_count) * 8 / 1024
                                                    AS net_current_usage_mb
FROM sys.dm_db_session_space_usage ssu
INNER JOIN sys.dm_exec_sessions s ON ssu.session_id = s.session_id
LEFT JOIN sys.dm_exec_connections c ON ssu.session_id = c.session_id
WHERE s.is_user_process = 1
  AND (ssu.user_objects_alloc_page_count + ssu.internal_objects_alloc_page_count) > 0
ORDER BY (ssu.user_objects_alloc_page_count + ssu.internal_objects_alloc_page_count) DESC;

-- ============================================================================
-- 10. QUERIES COSTOSAS RECIENTES (completadas en los ultimos 15 min)
-- ============================================================================
PRINT ''
PRINT '=== [10] QUERIES COSTOSAS COMPLETADAS RECIENTEMENTE (Query Store - ultimos 15 min) ==='
PRINT ''

SELECT TOP 30
    GETUTCDATE()                                    AS snapshot_utc,
    qsq.query_id,
    qsp.plan_id,
    CAST(qsqt.query_sql_text AS NVARCHAR(4000))    AS query_text,
    rs.last_execution_time,
    rs.count_executions,
    rs.last_cpu_time                                AS last_cpu_time_us,
    rs.last_duration                                AS last_duration_us,
    rs.last_logical_io_reads,
    rs.last_logical_io_writes,
    rs.last_physical_io_reads,
    rs.last_rowcount,
    rs.last_query_max_used_memory                   AS last_memory_grant_kb,
    rs.last_tempdb_space_used                       AS last_tempdb_used_kb,
    TRY_CAST(qsp.query_plan AS XML)                AS plan_ejecucion_xml
FROM sys.query_store_runtime_stats rs
INNER JOIN sys.query_store_plan qsp ON rs.plan_id = qsp.plan_id
INNER JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
INNER JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
WHERE rs.last_execution_time >= DATEADD(MINUTE, -15, GETUTCDATE())
ORDER BY rs.last_cpu_time DESC;

-- ============================================================================
-- FIN DEL DIAGNOSTICO
-- ============================================================================
PRINT ''
PRINT '=== DIAGNOSTICO COMPLETO ==='
PRINT 'Timestamp final: ' + CONVERT(VARCHAR(30), GETUTCDATE(), 121)
PRINT 'Ejecutar nuevamente en 2-3 minutos para comparar snapshots.'
PRINT ''
