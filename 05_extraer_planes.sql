-- ============================================================================
-- EXTRACTOR DE PLANES DE EJECUCION: Convierte el XML en datos tabulares
-- ============================================================================
-- Este script extrae los puntos criticos de los planes de ejecucion
-- sin necesidad de abrir el XML. Los datos salen en formato tabular
-- que se puede copiar a Excel sin problemas.
-- ============================================================================

-- ============================================================================
-- A. TOP QUERIES + OPERACIONES MAS COSTOSAS DE CADA PLAN
--    Extrae del XML: table scans, sorts, hash joins, spills, etc.
-- ============================================================================
PRINT '=== [A] OPERACIONES COSTOSAS DENTRO DE CADA PLAN (Query Store) ==='
PRINT ''

;WITH top_queries AS (
    SELECT
        query_id,
        plan_id,
        query_text,
        count_executions,
        avg_cpu_time_us,
        max_cpu_time_us,
        avg_duration_us,
        avg_logical_io_reads,
        avg_physical_io_reads,
        avg_rowcount,
        avg_memory_grant_kb,
        last_execution_time,
        query_plan_xml,
        ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY avg_cpu_time_us * count_executions DESC) AS rn
    FROM dbo.diag_query_store_top
    WHERE snapshot_utc >= DATEADD(HOUR, -4, GETUTCDATE())
      AND query_plan_xml IS NOT NULL
)
SELECT
    q.query_id,
    q.plan_id,
    q.count_executions,
    q.avg_cpu_time_us,
    q.avg_logical_io_reads,
    q.avg_rowcount,
    q.avg_memory_grant_kb,
    -- Operador del plan
    op.value('(@PhysicalOp)', 'NVARCHAR(128)')              AS operador_fisico,
    op.value('(@LogicalOp)', 'NVARCHAR(128)')               AS operador_logico,
    op.value('(@EstimateRows)', 'FLOAT')                    AS filas_estimadas,
    op.value('(@EstimateIO)', 'FLOAT')                      AS costo_io_estimado,
    op.value('(@EstimateCPU)', 'FLOAT')                     AS costo_cpu_estimado,
    op.value('(@EstimateIO)', 'FLOAT')
        + op.value('(@EstimateCPU)', 'FLOAT')               AS costo_total_operador,
    -- Warnings del plan (spills, implicit conversions, etc)
    op.value('(@Parallel)', 'BIT')                          AS es_paralelo,
    -- Objeto (tabla/indice) involucrado
    obj.value('(@Database)', 'NVARCHAR(128)')               AS objeto_database,
    obj.value('(@Schema)', 'NVARCHAR(128)')                 AS objeto_schema,
    obj.value('(@Table)', 'NVARCHAR(128)')                  AS objeto_tabla,
    obj.value('(@Index)', 'NVARCHAR(128)')                  AS objeto_indice,
    LEFT(q.query_text, 300)                                 AS query_preview
FROM top_queries q
CROSS APPLY q.query_plan_xml.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    //RelOp') AS plan_nodes(op)
OUTER APPLY op.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    .//Object') AS obj_nodes(obj)
WHERE q.rn = 1
  AND (op.value('(@EstimateIO)', 'FLOAT') + op.value('(@EstimateCPU)', 'FLOAT')) > 0.01
ORDER BY q.avg_cpu_time_us * q.count_executions DESC,
    (op.value('(@EstimateIO)', 'FLOAT') + op.value('(@EstimateCPU)', 'FLOAT')) DESC;

-- ============================================================================
-- B. DETECCION DE TABLE SCANS Y CLUSTERED INDEX SCANS COSTOSOS
--    Estos son los "red flags" mas comunes
-- ============================================================================
PRINT ''
PRINT '=== [B] TABLE SCANS / CLUSTERED INDEX SCANS DETECTADOS ==='
PRINT ''

;WITH top_queries AS (
    SELECT
        query_id, plan_id, query_text, count_executions,
        avg_cpu_time_us, avg_logical_io_reads, query_plan_xml,
        ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY avg_cpu_time_us * count_executions DESC) AS rn
    FROM dbo.diag_query_store_top
    WHERE snapshot_utc >= DATEADD(HOUR, -4, GETUTCDATE())
      AND query_plan_xml IS NOT NULL
)
SELECT
    q.query_id,
    q.plan_id,
    q.count_executions,
    q.avg_cpu_time_us,
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
CROSS APPLY q.query_plan_xml.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    //RelOp') AS plan_nodes(op)
OUTER APPLY op.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    .//Object') AS obj_nodes(obj)
WHERE q.rn = 1
  AND op.value('(@PhysicalOp)', 'NVARCHAR(128)') IN (
      'Table Scan', 'Clustered Index Scan', 'Index Scan'
  )
ORDER BY q.avg_cpu_time_us * q.count_executions DESC;

-- ============================================================================
-- C. WARNINGS DEL PLAN: Implicit conversions, spills, no join predicate
-- ============================================================================
PRINT ''
PRINT '=== [C] WARNINGS DETECTADOS EN LOS PLANES ==='
PRINT ''

;WITH top_queries AS (
    SELECT
        query_id, plan_id, query_text, count_executions,
        avg_cpu_time_us, avg_logical_io_reads, query_plan_xml,
        ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY avg_cpu_time_us * count_executions DESC) AS rn
    FROM dbo.diag_query_store_top
    WHERE snapshot_utc >= DATEADD(HOUR, -4, GETUTCDATE())
      AND query_plan_xml IS NOT NULL
)
SELECT
    q.query_id,
    q.plan_id,
    q.count_executions,
    q.avg_cpu_time_us,
    -- No Join Predicate
    CASE WHEN q.query_plan_xml.exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        //Warnings/NoJoinPredicate') = 1 THEN 'SI' ELSE 'no' END
                                                            AS warning_no_join_predicate,
    -- SpillToTempDb
    CASE WHEN q.query_plan_xml.exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        //SpillToTempDb') = 1 THEN 'SI' ELSE 'no' END
                                                            AS warning_spill_tempdb,
    -- Implicit Conversions (ColumnsWithNoStatistics, etc)
    CASE WHEN q.query_plan_xml.exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        //Warnings/PlanAffectingConvert') = 1 THEN 'SI' ELSE 'no' END
                                                            AS warning_implicit_conversion,
    -- Hash spills / Sort warnings
    CASE WHEN q.query_plan_xml.exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        //Warnings[@SortSpillLevel]') = 1 THEN 'SI' ELSE 'no' END
                                                            AS warning_sort_spill,
    -- Missing column statistics
    CASE WHEN q.query_plan_xml.exist('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        //Warnings/ColumnsWithNoStatistics') = 1 THEN 'SI' ELSE 'no' END
                                                            AS warning_missing_stats,
    -- Memory grant
    q.query_plan_xml.value('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        (//MemoryGrantInfo/@SerialDesiredMemory)[1]', 'FLOAT')
                                                            AS memory_grant_desired_kb,
    q.query_plan_xml.value('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
        (//MemoryGrantInfo/@SerialRequiredMemory)[1]', 'FLOAT')
                                                            AS memory_grant_required_kb,
    LEFT(q.query_text, 400)                                 AS query_preview
FROM top_queries q
WHERE q.rn = 1
ORDER BY q.avg_cpu_time_us * q.count_executions DESC;

-- ============================================================================
-- D. INDICES FALTANTES SUGERIDOS POR LOS PLANES
-- ============================================================================
PRINT ''
PRINT '=== [D] INDICES FALTANTES SUGERIDOS DENTRO DE LOS PLANES ==='
PRINT ''

;WITH top_queries AS (
    SELECT
        query_id, plan_id, query_text, count_executions,
        avg_cpu_time_us, query_plan_xml,
        ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY avg_cpu_time_us * count_executions DESC) AS rn
    FROM dbo.diag_query_store_top
    WHERE snapshot_utc >= DATEADD(HOUR, -4, GETUTCDATE())
      AND query_plan_xml IS NOT NULL
)
SELECT
    q.query_id,
    q.count_executions,
    q.avg_cpu_time_us,
    mi.value('(@Impact)', 'FLOAT')                          AS impacto_pct,
    mi.value('(MissingIndexGroup/MissingIndex/@Database)[1]', 'NVARCHAR(128)')  AS database_name,
    mi.value('(MissingIndexGroup/MissingIndex/@Schema)[1]', 'NVARCHAR(128)')    AS schema_name,
    mi.value('(MissingIndexGroup/MissingIndex/@Table)[1]', 'NVARCHAR(128)')     AS table_name,
    -- Columnas del indice sugerido
    mi.value('(MissingIndexGroup/MissingIndex/ColumnGroup[@Usage="EQUALITY"]/Column/@Name)[1]', 'NVARCHAR(MAX)')
                                                            AS equality_columns,
    mi.value('(MissingIndexGroup/MissingIndex/ColumnGroup[@Usage="INEQUALITY"]/Column/@Name)[1]', 'NVARCHAR(MAX)')
                                                            AS inequality_columns,
    mi.value('(MissingIndexGroup/MissingIndex/ColumnGroup[@Usage="INCLUDE"]/Column/@Name)[1]', 'NVARCHAR(MAX)')
                                                            AS include_columns,
    LEFT(q.query_text, 300)                                 AS query_preview
FROM top_queries q
CROSS APPLY q.query_plan_xml.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    //MissingIndexes/MissingIndexGroup') AS idx(mi)
WHERE q.rn = 1
ORDER BY mi.value('(@Impact)', 'FLOAT') DESC;

-- ============================================================================
-- E. ESTIMACIONES vs REALIDAD (detectar bad cardinality estimates)
-- ============================================================================
PRINT ''
PRINT '=== [E] POSIBLES BAD CARDINALITY ESTIMATES ==='
PRINT ''

;WITH top_queries AS (
    SELECT
        query_id, plan_id, count_executions,
        avg_cpu_time_us, avg_rowcount, query_plan_xml,
        ROW_NUMBER() OVER (PARTITION BY query_id ORDER BY avg_cpu_time_us * count_executions DESC) AS rn
    FROM dbo.diag_query_store_top
    WHERE snapshot_utc >= DATEADD(HOUR, -4, GETUTCDATE())
      AND query_plan_xml IS NOT NULL
)
SELECT
    q.query_id,
    q.plan_id,
    q.count_executions,
    q.avg_cpu_time_us,
    op.value('(@PhysicalOp)', 'NVARCHAR(128)')              AS operador,
    op.value('(@EstimateRows)', 'FLOAT')                    AS filas_estimadas,
    -- La columna ActualRows solo existe si el plan se capturo con estadisticas reales
    op.value('(@ActualRows)', 'FLOAT')                      AS filas_reales,
    obj.value('(@Table)', 'NVARCHAR(128)')                  AS tabla,
    obj.value('(@Index)', 'NVARCHAR(128)')                  AS indice,
    CASE
        WHEN op.value('(@EstimateRows)', 'FLOAT') > 0
         AND op.value('(@EstimateRows)', 'FLOAT') < 100
         AND q.avg_rowcount > 10000
        THEN 'POSIBLE SUBESTIMACION'
        ELSE ''
    END                                                     AS alerta
FROM top_queries q
CROSS APPLY q.query_plan_xml.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    //RelOp') AS plan_nodes(op)
OUTER APPLY op.nodes('declare default element namespace "http://schemas.microsoft.com/sqlserver/2004/07/showplan";
    .//Object') AS obj_nodes(obj)
WHERE q.rn = 1
  AND op.value('(@PhysicalOp)', 'NVARCHAR(128)') IN (
      'Table Scan', 'Clustered Index Scan', 'Index Scan',
      'Hash Match', 'Sort', 'Nested Loops', 'Merge Join'
  )
ORDER BY q.avg_cpu_time_us * q.count_executions DESC,
    op.value('(@EstimateRows)', 'FLOAT') DESC;

PRINT ''
PRINT '=== EXTRACCION COMPLETA ==='
PRINT 'Todos los resultados son tabulares y se pueden copiar a Excel.'
PRINT 'Compartir secciones A, B, C y D para que analicemos juntos.'
GO
