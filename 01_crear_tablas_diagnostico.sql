-- ============================================================================
-- PASO 1: CREAR TABLAS DE DIAGNOSTICO (ejecutar una sola vez)
-- ============================================================================
-- Estas tablas persisten los snapshots para analisis posterior.
-- Ejecutar ANTES del spike.
-- ============================================================================

IF OBJECT_ID('dbo.diag_resource_stats', 'U') IS NULL
CREATE TABLE dbo.diag_resource_stats (
    capture_id          INT IDENTITY(1,1) PRIMARY KEY,
    snapshot_utc        DATETIME2        NOT NULL DEFAULT GETUTCDATE(),
    end_time            DATETIME2,
    avg_cpu_percent     DECIMAL(5,2),
    avg_data_io_percent DECIMAL(5,2),
    avg_log_write_percent DECIMAL(5,2),
    avg_memory_usage_percent DECIMAL(5,2),
    dtu_percent_approx  DECIMAL(5,2),
    max_worker_percent  DECIMAL(5,2),
    max_session_percent DECIMAL(5,2)
);

IF OBJECT_ID('dbo.diag_active_queries', 'U') IS NULL
CREATE TABLE dbo.diag_active_queries (
    capture_id          INT IDENTITY(1,1) PRIMARY KEY,
    snapshot_utc        DATETIME2        NOT NULL DEFAULT GETUTCDATE(),
    session_id          INT,
    login_name          NVARCHAR(128),
    ip_origen           VARCHAR(48),
    host_name           NVARCHAR(128),
    program_name        NVARCHAR(128),
    request_status      NVARCHAR(30),
    command             NVARCHAR(32),
    request_start_time  DATETIME2,
    elapsed_seconds     INT,
    cpu_time_ms         INT,
    total_elapsed_ms    INT,
    logical_reads       BIGINT,
    physical_reads      BIGINT,
    writes              BIGINT,
    wait_type           NVARCHAR(60),
    wait_time_ms        INT,
    wait_resource       NVARCHAR(256),
    blocking_session_id INT,
    granted_memory_kb   INT,
    query_statement     NVARCHAR(MAX),
    query_full_batch    NVARCHAR(MAX),
    query_plan_xml      XML,
    query_hash          BINARY(8),
    plan_handle         VARBINARY(64),
    sql_handle          VARBINARY(64),
    database_name       NVARCHAR(128)
);

IF OBJECT_ID('dbo.diag_query_store_top', 'U') IS NULL
CREATE TABLE dbo.diag_query_store_top (
    capture_id          INT IDENTITY(1,1) PRIMARY KEY,
    snapshot_utc        DATETIME2        NOT NULL DEFAULT GETUTCDATE(),
    query_id            BIGINT,
    plan_id             BIGINT,
    query_hash          BINARY(8),
    query_text          NVARCHAR(MAX),
    count_executions    BIGINT,
    avg_cpu_time_us     FLOAT,
    max_cpu_time_us     FLOAT,
    avg_duration_us     FLOAT,
    max_duration_us     FLOAT,
    avg_logical_io_reads  FLOAT,
    avg_physical_io_reads FLOAT,
    avg_logical_io_writes FLOAT,
    avg_rowcount        FLOAT,
    avg_memory_grant_kb FLOAT,
    last_execution_time DATETIMEOFFSET,
    first_execution_time DATETIMEOFFSET,
    query_plan_xml      XML
);

IF OBJECT_ID('dbo.diag_wait_stats', 'U') IS NULL
CREATE TABLE dbo.diag_wait_stats (
    capture_id          INT IDENTITY(1,1) PRIMARY KEY,
    snapshot_utc        DATETIME2        NOT NULL DEFAULT GETUTCDATE(),
    wait_type           NVARCHAR(60),
    waiting_tasks_count BIGINT,
    wait_time_ms        BIGINT,
    max_wait_time_ms    BIGINT,
    signal_wait_time_ms BIGINT
);

IF OBJECT_ID('dbo.diag_blocking', 'U') IS NULL
CREATE TABLE dbo.diag_blocking (
    capture_id          INT IDENTITY(1,1) PRIMARY KEY,
    snapshot_utc        DATETIME2        NOT NULL DEFAULT GETUTCDATE(),
    blocked_session     INT,
    blocking_session    INT,
    wait_type           NVARCHAR(60),
    wait_time_ms        INT,
    wait_resource       NVARCHAR(256),
    blocked_login       NVARCHAR(128),
    blocked_ip          VARCHAR(48),
    blocked_program     NVARCHAR(128),
    blocked_query       NVARCHAR(MAX),
    blocker_login       NVARCHAR(128),
    blocker_ip          VARCHAR(48),
    blocker_program     NVARCHAR(128),
    blocker_last_query  NVARCHAR(MAX)
);

IF OBJECT_ID('dbo.diag_sessions', 'U') IS NULL
CREATE TABLE dbo.diag_sessions (
    capture_id          INT IDENTITY(1,1) PRIMARY KEY,
    snapshot_utc        DATETIME2        NOT NULL DEFAULT GETUTCDATE(),
    session_id          INT,
    login_name          NVARCHAR(128),
    ip_origen           VARCHAR(48),
    host_name           NVARCHAR(128),
    program_name        NVARCHAR(128),
    session_status      NVARCHAR(30),
    cpu_time_ms         INT,
    reads               BIGINT,
    writes              BIGINT,
    logical_reads       BIGINT,
    login_time          DATETIME2,
    last_request_start  DATETIME2,
    last_request_end    DATETIME2,
    database_name       NVARCHAR(128)
);

PRINT 'Tablas de diagnostico creadas correctamente.'
PRINT 'Ahora ejecutar: captura_persistente.sql durante el spike.'
GO
