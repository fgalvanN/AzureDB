-- ============================================================================
-- ANALISIS DE PLANES DESDE QUERY STORE (sin tablas de diagnostico)
-- ============================================================================
-- Este script NO necesita las tablas diag_*. Lee directamente del
-- Query Store de Azure SQL Database que guarda automaticamente todas
-- las queries ejecutadas con sus planes.
--
-- INSTRUCCION: Ajustar las fechas de @spike_inicio y @spike_fin
-- al rango exacto del spike que quieras analizar.
-- ============================================================================

-- ============================================================================
-- CONFIGURACION: Ajustar al rango del spike
-- ============================================================================
DECLARE @spike_inicio DATETIMEOFFSET = '2026-04-10 07:00:00 -03:00';  -- AJUSTAR fecha y zona horaria
DECLARE @spike_fin    DATETIMEOFFSET = '2026-04-10 07:15:00 -03:00';  -- AJUSTAR fecha y zona horaria

-- ============================================================================
-- 1. TOP 20 QUERIES POR CPU TOTAL DURANTE EL SPIKE
-- ============================================================================
PRINT '=== [1] TOP 20 QUERIES POR CPU TOTAL EN LA VENTANA DEL SPIKE ==='
PRINT ''

SELECT TOP 20
    qsq.query_id,
    qsp.plan_id,
    qsq.query_hash,
    rs.count_executions,
    rs.avg_cpu_time                                 AS avg_cpu_us,
    rs.max_cpu_time                                 AS max_cpu_us,
    rs.avg_cpu_time * rs.count_executions           AS total_cpu_us,
    rs.avg_duration                                 AS avg_duration_us,
    rs.avg_logical_io_reads,
    rs.avg_physical_io_reads,
    rs.avg_rowcount,
    rs.avg_query_max_used_memory                    AS avg_memory_grant_kb,
    rs.first_execution_time,
    rs.last_execution_time,
    CAST(qsqt.query_sql_text AS NVARCHAR(MAX))     AS query_text_completo,
    TRY_CAST(qsp.query_plan AS XML)                AS plan_xml
FROM sys.query_store_runtime_stats rs
INNER JOIN sys.query_store_plan qsp ON rs.plan_id = qsp.plan_id
INNER JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
INNER JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
INNER JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time <= @spike_fin
  AND rsi.end_time >= @spike_inicio
ORDER BY rs.avg_cpu_time * rs.count_executions DESC;

-- ============================================================================
-- 2. OPERADORES COSTOSOS DENTRO DE CADA PLAN
-- ============================================================================
PRINT ''
PRINT '=== [2] OPERADORES COSTOSOS POR QUERY (del plan XML) ==='
PRINT ''

;WITH top_queries AS (
    SELECT TOP 20
        qsq.query_id,
        qsp.plan_id,
        rs.count_executions,
        rs.avg_cpu_time,
        rs.avg_logical_io_reads,
        rs.avg_rowcount,
        rs.avg_query_max_used_memory,
        CAST(qsqt.query_sql_text AS NVARCHAR(MAX))         AS query_text,
        TRY_CAST(qsp.query_plan AS XML)                    AS plan_xml,
        ROW_NUMBER() OVER (PARTITION BY qsq.query_id ORDER BY rs.avg_cpu_time * rs.count_executions DESC) AS rn
    FROM sys.query_store_runtime_stats rs
    INNER JOIN sys.query_store_plan qsp ON rs.plan_id = qsp.plan_id
    INNER JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
    INNER JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
    INNER JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time <= @spike_fin
      AND rsi.end_time >= @spike_inicio
    ORDER BY rs.avg_cpu_time * rs.count_executions DESC
)
SELECT
    q.query_id,
    q.plan_id,
    q.count_executions,
    q.avg_cpu_time                                          AS avg_cpu_us,
    op.value('(@PhysicalOp)', 'NVARCHAR(128)')              AS operador_fisico,
    op.value('(@LogicalOp)', 'NVARCHAR(128)')               AS operador_logico,
    op.value('(@EstimateRows)', 'FLOAT')                    AS filas_estimadas,
    op.value('(@EstimateIO)', 'FLOAT')                      AS costo_io,
    op.value('(@EstimateCPU)', 'FLOAT')                     AS costo_cpu,
    op.value('(@EstimateIO)', 'FLOAT')
        + op.value('(@EstimateCPU)', 'FLOAT')               AS costo_total_operador,
    obj.value('(@Schema)', 'NVARCHAR(128)')                 AS schema_name,
    obj.value('(@Table)', 'NVARCHAR(128)')                  AS table_name,
    obj.value('(@Index)', 'NVARCHAR(128)')                  AS index_name,
    LEFT(q.query_text, 300)                                 AS query_preview
FROM top_queries q
CROSS APPLY q.plan_xml.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    //RelOp') AS plan_nodes(op)
OUTER APPLY op.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    .//Object') AS obj_nodes(obj)
WHERE q.rn = 1
  AND q.plan_xml IS NOT NULL
  AND (op.value('(@EstimateIO)', 'FLOAT') + op.value('(@EstimateCPU)', 'FLOAT')) > 0.01
ORDER BY q.avg_cpu_time * q.count_executions DESC,
    (op.value('(@EstimateIO)', 'FLOAT') + op.value('(@EstimateCPU)', 'FLOAT')) DESC;

-- ============================================================================
-- 3. TABLE SCANS / INDEX SCANS (red flags)
-- ============================================================================
PRINT ''
PRINT '=== [3] TABLE SCANS / INDEX SCANS DETECTADOS ==='
PRINT ''

;WITH top_queries AS (
    SELECT TOP 20
        qsq.query_id,
        qsp.plan_id,
        rs.count_executions,
        rs.avg_cpu_time,
        rs.avg_logical_io_reads,
        CAST(qsqt.query_sql_text AS NVARCHAR(MAX))         AS query_text,
        TRY_CAST(qsp.query_plan AS XML)                    AS plan_xml,
        ROW_NUMBER() OVER (PARTITION BY qsq.query_id ORDER BY rs.avg_cpu_time * rs.count_executions DESC) AS rn
    FROM sys.query_store_runtime_stats rs
    INNER JOIN sys.query_store_plan qsp ON rs.plan_id = qsp.plan_id
    INNER JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
    INNER JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
    INNER JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time <= @spike_fin
      AND rsi.end_time >= @spike_inicio
    ORDER BY rs.avg_cpu_time * rs.count_executions DESC
)
SELECT
    q.query_id,
    q.plan_id,
    q.count_executions,
    q.avg_cpu_time                                          AS avg_cpu_us,
    q.avg_logical_io_reads,
    op.value('(@PhysicalOp)', 'NVARCHAR(128)')              AS scan_type,
    op.value('(@EstimateRows)', 'FLOAT')                    AS filas_estimadas,
    op.value('(@EstimateIO)', 'FLOAT')
        + op.value('(@EstimateCPU)', 'FLOAT')               AS costo_operador,
    obj.value('(@Schema)', 'NVARCHAR(128)')                 AS schema_name,
    obj.value('(@Table)', 'NVARCHAR(128)')                  AS table_name,
    obj.value('(@Index)', 'NVARCHAR(128)')                  AS index_name,
    LEFT(q.query_text, 500)                                 AS query_text
FROM top_queries q
CROSS APPLY q.plan_xml.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    //RelOp') AS plan_nodes(op)
OUTER APPLY op.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    .//Object') AS obj_nodes(obj)
WHERE q.rn = 1
  AND q.plan_xml IS NOT NULL
  AND op.value('(@PhysicalOp)', 'NVARCHAR(128)') IN (
      'Table Scan', 'Clustered Index Scan', 'Index Scan'
  )
ORDER BY q.avg_cpu_time * q.count_executions DESC;

-- ============================================================================
-- 4. WARNINGS EN LOS PLANES
-- ============================================================================
PRINT ''
PRINT '=== [4] WARNINGS EN LOS PLANES ==='
PRINT ''

;WITH top_queries AS (
    SELECT TOP 20
        qsq.query_id,
        qsp.plan_id,
        rs.count_executions,
        rs.avg_cpu_time,
        CAST(qsqt.query_sql_text AS NVARCHAR(MAX))         AS query_text,
        TRY_CAST(qsp.query_plan AS XML)                    AS plan_xml,
        ROW_NUMBER() OVER (PARTITION BY qsq.query_id ORDER BY rs.avg_cpu_time * rs.count_executions DESC) AS rn
    FROM sys.query_store_runtime_stats rs
    INNER JOIN sys.query_store_plan qsp ON rs.plan_id = qsp.plan_id
    INNER JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
    INNER JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
    INNER JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time <= @spike_fin
      AND rsi.end_time >= @spike_inicio
    ORDER BY rs.avg_cpu_time * rs.count_executions DESC
)
SELECT
    q.query_id,
    q.plan_id,
    q.count_executions,
    q.avg_cpu_time                                          AS avg_cpu_us,
    CASE WHEN q.plan_xml.exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        //Warnings/NoJoinPredicate') = 1 THEN 'SI' ELSE '-' END
                                                            AS no_join_predicate,
    CASE WHEN q.plan_xml.exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        //SpillToTempDb') = 1 THEN 'SI' ELSE '-' END
                                                            AS spill_tempdb,
    CASE WHEN q.plan_xml.exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        //Warnings/PlanAffectingConvert') = 1 THEN 'SI' ELSE '-' END
                                                            AS implicit_conversion,
    CASE WHEN q.plan_xml.exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        //Warnings/ColumnsWithNoStatistics') = 1 THEN 'SI' ELSE '-' END
                                                            AS missing_stats,
    q.plan_xml.value('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        (//MemoryGrantInfo/@SerialDesiredMemory)[1]', 'BIGINT')
                                                            AS memory_desired_kb,
    q.plan_xml.value('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        (//MemoryGrantInfo/@SerialRequiredMemory)[1]', 'BIGINT')
                                                            AS memory_required_kb,
    LEFT(q.query_text, 400)                                 AS query_preview
FROM top_queries q
WHERE q.rn = 1
  AND q.plan_xml IS NOT NULL
ORDER BY q.avg_cpu_time * q.count_executions DESC;

-- ============================================================================
-- 5. INDICES FALTANTES SUGERIDOS POR LOS PLANES
-- ============================================================================
PRINT ''
PRINT '=== [5] INDICES FALTANTES QUE LOS PLANES SUGIEREN ==='
PRINT ''

;WITH top_queries AS (
    SELECT TOP 20
        qsq.query_id,
        qsp.plan_id,
        rs.count_executions,
        rs.avg_cpu_time,
        CAST(qsqt.query_sql_text AS NVARCHAR(MAX))         AS query_text,
        TRY_CAST(qsp.query_plan AS XML)                    AS plan_xml,
        ROW_NUMBER() OVER (PARTITION BY qsq.query_id ORDER BY rs.avg_cpu_time * rs.count_executions DESC) AS rn
    FROM sys.query_store_runtime_stats rs
    INNER JOIN sys.query_store_plan qsp ON rs.plan_id = qsp.plan_id
    INNER JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
    INNER JOIN sys.query_store_query_text qsqt ON qsq.query_text_id = qsqt.query_text_id
    INNER JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    WHERE rsi.start_time <= @spike_fin
      AND rsi.end_time >= @spike_inicio
    ORDER BY rs.avg_cpu_time * rs.count_executions DESC
)
SELECT
    q.query_id,
    q.count_executions,
    q.avg_cpu_time                                          AS avg_cpu_us,
    mi.value('(@Impact)', 'FLOAT')                          AS impacto_pct,
    mi.value('(MissingIndexGroup/MissingIndex/@Schema)[1]', 'NVARCHAR(128)')    AS schema_name,
    mi.value('(MissingIndexGroup/MissingIndex/@Table)[1]', 'NVARCHAR(128)')     AS table_name,
    mi.value('(MissingIndexGroup/MissingIndex/ColumnGroup[@Usage="EQUALITY"]/Column/@Name)[1]', 'NVARCHAR(MAX)')
                                                            AS equality_columns,
    mi.value('(MissingIndexGroup/MissingIndex/ColumnGroup[@Usage="INEQUALITY"]/Column/@Name)[1]', 'NVARCHAR(MAX)')
                                                            AS inequality_columns,
    mi.value('(MissingIndexGroup/MissingIndex/ColumnGroup[@Usage="INCLUDE"]/Column/@Name)[1]', 'NVARCHAR(MAX)')
                                                            AS include_columns,
    LEFT(q.query_text, 300)                                 AS query_preview
FROM top_queries q
CROSS APPLY q.plan_xml.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    //MissingIndexes/MissingIndexGroup') AS idx(mi)
WHERE q.rn = 1
  AND q.plan_xml IS NOT NULL
ORDER BY mi.value('(@Impact)', 'FLOAT') DESC;

PRINT ''
PRINT '=== EXTRACCION COMPLETA ==='
PRINT 'Todos los resultados son tabulares, copiables a Excel.'
PRINT 'Compartir las secciones 1 a 5 para analizar juntos.'
GO
