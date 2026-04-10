-- ============================================================================
-- CAPTURA PERSISTENTE: Guarda todo en tablas para analisis posterior
-- ============================================================================
-- Ejecutar cada 1-2 minutos durante el spike de las 7am.
-- Cada ejecucion inserta un snapshot con timestamp unico.
-- Luego ejecutar: 03_analisis_resultados.sql
-- ============================================================================

DECLARE @snapshot DATETIME2 = GETUTCDATE();
PRINT 'Captura iniciada: ' + CONVERT(VARCHAR(30), @snapshot, 121)

-- ============================================================================
-- A. RECURSOS (DTU/CPU/IO)
-- ============================================================================
INSERT INTO dbo.diag_resource_stats
    (snapshot_utc, end_time, avg_cpu_percent, avg_data_io_percent,
     avg_log_write_percent, avg_memory_usage_percent, dtu_percent_approx,
     max_worker_percent, max_session_percent)
SELECT
    @snapshot,
    end_time,
    avg_cpu_percent,
    avg_data_io_percent,
    avg_log_write_percent,
    avg_memory_usage_percent,
    CAST(GREATEST(avg_cpu_percent, avg_data_io_percent, avg_log_write_percent) AS DECIMAL(5,2)),
    max_worker_percent,
    max_session_percent
FROM sys.dm_db_resource_stats
WHERE end_time >= DATEADD(MINUTE, -2, GETUTCDATE());

PRINT '  [A] Resource stats: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' filas'

-- ============================================================================
-- B. SESIONES ACTIVAS
-- ============================================================================
INSERT INTO dbo.diag_sessions
    (snapshot_utc, session_id, login_name, ip_origen, host_name,
     program_name, session_status, cpu_time_ms, reads, writes,
     logical_reads, login_time, last_request_start, last_request_end,
     database_name)
SELECT
    @snapshot,
    s.session_id,
    s.login_name,
    c.client_net_address,
    s.host_name,
    s.program_name,
    s.status,
    s.cpu_time,
    s.reads,
    s.writes,
    s.logical_reads,
    s.login_time,
    s.last_request_start_time,
    s.last_request_end_time,
    DB_NAME(s.database_id)
FROM sys.dm_exec_sessions s
LEFT JOIN sys.dm_exec_connections c ON s.session_id = c.session_id
WHERE s.is_user_process = 1;

PRINT '  [B] Sesiones: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' filas'

-- ============================================================================
-- C. QUERIES EN EJECUCION (punto en tiempo)
-- ============================================================================
INSERT INTO dbo.diag_active_queries
    (snapshot_utc, session_id, login_name, ip_origen, host_name,
     program_name, request_status, command, request_start_time,
     elapsed_seconds, cpu_time_ms, total_elapsed_ms, logical_reads,
     physical_reads, writes, wait_type, wait_time_ms, wait_resource,
     blocking_session_id, granted_memory_kb, query_statement,
     query_full_batch, query_plan_xml, query_hash, plan_handle,
     sql_handle, database_name)
SELECT
    @snapshot,
    r.session_id,
    s.login_name,
    c.client_net_address,
    s.host_name,
    s.program_name,
    r.status,
    r.command,
    r.start_time,
    DATEDIFF(SECOND, r.start_time, GETUTCDATE()),
    r.cpu_time,
    r.total_elapsed_time,
    r.logical_reads,
    r.reads,
    r.writes,
    r.wait_type,
    r.wait_time,
    r.wait_resource,
    r.blocking_session_id,
    r.granted_query_memory,
    SUBSTRING(
        qt.text,
        (r.statement_start_offset / 2) + 1,
        CASE
            WHEN r.statement_end_offset = -1 THEN LEN(qt.text)
            ELSE (r.statement_end_offset - r.statement_start_offset) / 2 + 1
        END
    ),
    qt.text,
    qp.query_plan,
    r.query_hash,
    r.plan_handle,
    r.sql_handle,
    DB_NAME(r.database_id)
FROM sys.dm_exec_requests r
INNER JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
LEFT JOIN sys.dm_exec_connections c ON r.session_id = c.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) qt
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE s.is_user_process = 1
  AND r.session_id <> @@SPID;

PRINT '  [C] Queries activas: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' filas'

-- ============================================================================
-- D. QUERY STORE - TOP QUERIES POR CPU (ultima hora)
-- ============================================================================
INSERT INTO dbo.diag_query_store_top
    (snapshot_utc, query_id, plan_id, query_hash, query_text,
     count_executions, avg_cpu_time_us, max_cpu_time_us, avg_duration_us,
     max_duration_us, avg_logical_io_reads, avg_physical_io_reads,
     avg_logical_io_writes, avg_rowcount, avg_memory_grant_kb,
     last_execution_time, first_execution_time, query_plan_xml)
SELECT TOP 30
    @snapshot,
    qsq.query_id,
    qsp.plan_id,
    qsq.query_hash,
    CAST(qsqt.query_sql_text AS NVARCHAR(MAX)),
    rs.count_executions,
    rs.avg_cpu_time,
    rs.max_cpu_time,
    rs.avg_duration,
    rs.max_duration,
    rs.avg_logical_io_reads,
    rs.avg_physical_io_reads,
    rs.avg_logical_io_writes,
    rs.avg_rowcount,
    rs.avg_query_max_used_memory,
    rs.last_execution_time,
    rs.first_execution_time,
    TRY_CAST(qsp.query_plan AS XML)
FROM sys.query_store_runtime_stats rs
INNER JOIN sys.query_store_plan qsp ON rs.plan_id = qsp.plan_id
INNER JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
INNER JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
WHERE rs.last_execution_time >= DATEADD(HOUR, -1, GETUTCDATE())
ORDER BY rs.avg_cpu_time * rs.count_executions DESC;

PRINT '  [D] Query Store top: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' filas'

-- ============================================================================
-- E. WAIT STATS
-- ============================================================================
INSERT INTO dbo.diag_wait_stats
    (snapshot_utc, wait_type, waiting_tasks_count, wait_time_ms,
     max_wait_time_ms, signal_wait_time_ms)
SELECT
    @snapshot,
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    max_wait_time_ms,
    signal_wait_time_ms
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
AND wait_time_ms > 0;

PRINT '  [E] Wait stats: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' filas'

-- ============================================================================
-- F. BLOQUEOS
-- ============================================================================
INSERT INTO dbo.diag_blocking
    (snapshot_utc, blocked_session, blocking_session, wait_type,
     wait_time_ms, wait_resource, blocked_login, blocked_ip,
     blocked_program, blocked_query, blocker_login, blocker_ip,
     blocker_program, blocker_last_query)
SELECT
    @snapshot,
    r.session_id,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time,
    r.wait_resource,
    s_blocked.login_name,
    c_blocked.client_net_address,
    s_blocked.program_name,
    SUBSTRING(
        qt_blocked.text,
        (r.statement_start_offset / 2) + 1,
        CASE
            WHEN r.statement_end_offset = -1 THEN LEN(qt_blocked.text)
            ELSE (r.statement_end_offset - r.statement_start_offset) / 2 + 1
        END
    ),
    s_blocker.login_name,
    c_blocker.client_net_address,
    s_blocker.program_name,
    qt_blocker.text
FROM sys.dm_exec_requests r
INNER JOIN sys.dm_exec_sessions s_blocked ON r.session_id = s_blocked.session_id
LEFT JOIN sys.dm_exec_connections c_blocked ON r.session_id = c_blocked.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) qt_blocked
LEFT JOIN sys.dm_exec_sessions s_blocker ON r.blocking_session_id = s_blocker.session_id
LEFT JOIN sys.dm_exec_connections c_blocker ON r.blocking_session_id = c_blocker.session_id
OUTER APPLY sys.dm_exec_sql_text(c_blocker.most_recent_sql_handle) qt_blocker
WHERE r.blocking_session_id <> 0;

PRINT '  [F] Bloqueos: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' filas'

PRINT ''
PRINT 'Captura completada: ' + CONVERT(VARCHAR(30), GETUTCDATE(), 121)
PRINT 'Ejecutar nuevamente en 1-2 minutos.'
GO
