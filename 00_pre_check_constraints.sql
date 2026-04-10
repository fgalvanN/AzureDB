-- ============================================================================
-- PRE-CHECK: Detectar constraints en columnas que vamos a redimensionar
-- ============================================================================
-- Ejecutar ANTES de 00_redimensionar_varchar_max.sql
-- Muestra todas las constraints que hay que dropear y recrear.
-- ============================================================================

-- ============================================================================
-- 1. LISTAR TODAS LAS CONSTRAINTS AFECTADAS
-- ============================================================================
PRINT '=== [1] CONSTRAINTS ENCONTRADAS EN COLUMNAS A REDIMENSIONAR ==='
PRINT ''

;WITH columnas_a_cambiar AS (
    SELECT schema_name, table_name, column_name
    FROM (VALUES
        ('dbo', 'BranchSystem',              'CreatedBy'),
        ('dbo', 'BranchSystem',              'UpdatedBy'),
        ('dbo', 'BranchSystem',              'Code'),
        ('dbo', 'Container',                 'CreatedBy'),
        ('dbo', 'Container',                 'UpdatedBy'),
        ('dbo', 'ContainerIngestError',      'Message'),
        ('dbo', 'DistributionConcept',       'UpdatedBy'),
        ('dbo', 'DistributionConcept',       'SegmentationName'),
        ('dbo', 'DistributionConcept',       'QuantityType'),
        ('dbo', 'FuelDiscount',              'Origin'),
        ('dbo', 'PayableItem',              'RecipientName'),
        ('dbo', 'PayableItem',              'CreatedBy'),
        ('dbo', 'PayableItem',              'UpdatedBy'),
        ('dbo', 'PayableItem',              'PolygonCodeH3R11'),
        ('dbo', 'PayableItem',              'PolygonCodeH3R12'),
        ('dbo', 'PayableItem',              'PolygonCodeH3R9'),
        ('dbo', 'PayableItem',              'VisitReason'),
        ('dbo', 'PrePayableItem',           'VisitReason'),
        ('dbo', 'PriceBook',                'Name'),
        ('dbo', 'PriceBook',                'PriceBookId'),
        ('dbo', 'PriceBookCategory',        'PriceBookCategoryType'),
        ('dbo', 'Settlement',               'SettlementIdentifier'),
        ('dbo', 'SettlementGenerationError', 'ErrorMessage'),
        ('dbo', 'TransmittedSettlement',     'SettlementIdentifier')
    ) AS v(schema_name, table_name, column_name)
)

-- DEFAULT constraints
SELECT
    'DEFAULT'                           AS constraint_type,
    dc.name                             AS constraint_name,
    c.schema_name,
    c.table_name,
    c.column_name,
    dc.definition                       AS constraint_definition
FROM columnas_a_cambiar c
INNER JOIN sys.tables t ON t.name = c.table_name
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id AND s.name = c.schema_name
INNER JOIN sys.columns col ON col.object_id = t.object_id AND col.name = c.column_name
INNER JOIN sys.default_constraints dc ON dc.parent_object_id = t.object_id AND dc.parent_column_id = col.column_id

UNION ALL

-- CHECK constraints
SELECT
    'CHECK',
    cc.name,
    c.schema_name,
    c.table_name,
    c.column_name,
    cc.definition
FROM columnas_a_cambiar c
INNER JOIN sys.tables t ON t.name = c.table_name
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id AND s.name = c.schema_name
INNER JOIN sys.columns col ON col.object_id = t.object_id AND col.name = c.column_name
INNER JOIN sys.check_constraints cc ON cc.parent_object_id = t.object_id AND cc.parent_column_id = col.column_id

UNION ALL

-- FOREIGN KEY constraints (donde la columna es parte de la FK)
SELECT
    'FOREIGN KEY',
    fk.name,
    c.schema_name,
    c.table_name,
    c.column_name,
    'REFERENCES ' + OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id)
FROM columnas_a_cambiar c
INNER JOIN sys.tables t ON t.name = c.table_name
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id AND s.name = c.schema_name
INNER JOIN sys.columns col ON col.object_id = t.object_id AND col.name = c.column_name
INNER JOIN sys.foreign_key_columns fkc ON fkc.parent_object_id = t.object_id AND fkc.parent_column_id = col.column_id
INNER JOIN sys.foreign_keys fk ON fk.object_id = fkc.constraint_object_id

UNION ALL

-- INDICES (no clustered) que incluyen la columna
SELECT
    'INDEX',
    i.name,
    c.schema_name,
    c.table_name,
    c.column_name,
    i.type_desc + CASE WHEN i.is_unique = 1 THEN ' UNIQUE' ELSE '' END
FROM columnas_a_cambiar c
INNER JOIN sys.tables t ON t.name = c.table_name
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id AND s.name = c.schema_name
INNER JOIN sys.columns col ON col.object_id = t.object_id AND col.name = c.column_name
INNER JOIN sys.index_columns ic ON ic.object_id = t.object_id AND ic.column_id = col.column_id
INNER JOIN sys.indexes i ON i.object_id = t.object_id AND i.index_id = ic.index_id AND i.is_primary_key = 0

UNION ALL

-- STATISTICS asociadas a la columna
SELECT
    'STATISTICS',
    st.name,
    c.schema_name,
    c.table_name,
    c.column_name,
    'auto_created=' + CAST(st.auto_created AS VARCHAR)
FROM columnas_a_cambiar c
INNER JOIN sys.tables t ON t.name = c.table_name
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id AND s.name = c.schema_name
INNER JOIN sys.columns col ON col.object_id = t.object_id AND col.name = c.column_name
INNER JOIN sys.stats_columns sc ON sc.object_id = t.object_id AND sc.column_id = col.column_id
INNER JOIN sys.stats st ON st.object_id = t.object_id AND st.stats_id = sc.stats_id
    AND st.auto_created = 0 AND st.user_created = 1

ORDER BY constraint_type, table_name, column_name;

-- ============================================================================
-- 2. GENERAR SCRIPTS DE DROP Y RECREATE AUTOMATICAMENTE
-- ============================================================================
PRINT ''
PRINT '=== [2] SCRIPTS GENERADOS: DROP CONSTRAINTS ==='
PRINT '    Copiar y ejecutar ANTES de redimensionar'
PRINT ''

;WITH columnas_a_cambiar AS (
    SELECT schema_name, table_name, column_name
    FROM (VALUES
        ('dbo', 'BranchSystem',              'CreatedBy'),
        ('dbo', 'BranchSystem',              'UpdatedBy'),
        ('dbo', 'BranchSystem',              'Code'),
        ('dbo', 'Container',                 'CreatedBy'),
        ('dbo', 'Container',                 'UpdatedBy'),
        ('dbo', 'ContainerIngestError',      'Message'),
        ('dbo', 'DistributionConcept',       'UpdatedBy'),
        ('dbo', 'DistributionConcept',       'SegmentationName'),
        ('dbo', 'DistributionConcept',       'QuantityType'),
        ('dbo', 'FuelDiscount',              'Origin'),
        ('dbo', 'PayableItem',              'RecipientName'),
        ('dbo', 'PayableItem',              'CreatedBy'),
        ('dbo', 'PayableItem',              'UpdatedBy'),
        ('dbo', 'PayableItem',              'PolygonCodeH3R11'),
        ('dbo', 'PayableItem',              'PolygonCodeH3R12'),
        ('dbo', 'PayableItem',              'PolygonCodeH3R9'),
        ('dbo', 'PayableItem',              'VisitReason'),
        ('dbo', 'PrePayableItem',           'VisitReason'),
        ('dbo', 'PriceBook',                'Name'),
        ('dbo', 'PriceBook',                'PriceBookId'),
        ('dbo', 'PriceBookCategory',        'PriceBookCategoryType'),
        ('dbo', 'Settlement',               'SettlementIdentifier'),
        ('dbo', 'SettlementGenerationError', 'ErrorMessage'),
        ('dbo', 'TransmittedSettlement',     'SettlementIdentifier')
    ) AS v(schema_name, table_name, column_name)
)

-- DROP DEFAULT constraints
SELECT
    1                                   AS execution_order,
    'DROP_BEFORE'                       AS phase,
    c.table_name,
    c.column_name,
    'ALTER TABLE ' + c.schema_name + '.' + c.table_name
        + ' DROP CONSTRAINT ' + dc.name + ';'
                                        AS script_to_run,
    -- Script para recrear despues
    'ALTER TABLE ' + c.schema_name + '.' + c.table_name
        + ' ADD CONSTRAINT ' + dc.name
        + ' DEFAULT ' + dc.definition
        + ' FOR ' + c.column_name + ';'
                                        AS recreate_script
FROM columnas_a_cambiar c
INNER JOIN sys.tables t ON t.name = c.table_name
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id AND s.name = c.schema_name
INNER JOIN sys.columns col ON col.object_id = t.object_id AND col.name = c.column_name
INNER JOIN sys.default_constraints dc ON dc.parent_object_id = t.object_id AND dc.parent_column_id = col.column_id

UNION ALL

-- DROP CHECK constraints
SELECT
    2,
    'DROP_BEFORE',
    c.table_name,
    c.column_name,
    'ALTER TABLE ' + c.schema_name + '.' + c.table_name
        + ' DROP CONSTRAINT ' + cc.name + ';',
    'ALTER TABLE ' + c.schema_name + '.' + c.table_name
        + ' ADD CONSTRAINT ' + cc.name
        + ' CHECK ' + cc.definition + ';'
FROM columnas_a_cambiar c
INNER JOIN sys.tables t ON t.name = c.table_name
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id AND s.name = c.schema_name
INNER JOIN sys.columns col ON col.object_id = t.object_id AND col.name = c.column_name
INNER JOIN sys.check_constraints cc ON cc.parent_object_id = t.object_id AND cc.parent_column_id = col.column_id

UNION ALL

-- DROP INDEX (no clustered)
SELECT
    3,
    'DROP_BEFORE',
    c.table_name,
    c.column_name,
    'DROP INDEX ' + i.name + ' ON ' + c.schema_name + '.' + c.table_name + ';',
    '-- RECREAR INDEX: ' + i.name + ' en ' + c.schema_name + '.' + c.table_name + ' (revisar definicion original)'
FROM columnas_a_cambiar c
INNER JOIN sys.tables t ON t.name = c.table_name
INNER JOIN sys.schemas s ON s.schema_id = t.schema_id AND s.name = c.schema_name
INNER JOIN sys.columns col ON col.object_id = t.object_id AND col.name = c.column_name
INNER JOIN sys.index_columns ic ON ic.object_id = t.object_id AND ic.column_id = col.column_id
INNER JOIN sys.indexes i ON i.object_id = t.object_id AND i.index_id = ic.index_id AND i.is_primary_key = 0

ORDER BY execution_order, table_name, column_name;


PRINT ''
PRINT '=== INSTRUCCIONES ==='
PRINT '1. Revisar seccion [1] para ver todas las constraints encontradas'
PRINT '2. Copiar los scripts de la columna "script_to_run" de seccion [2]'
PRINT '3. Ejecutar los DROP'
PRINT '4. Ejecutar 00_redimensionar_varchar_max.sql'
PRINT '5. Copiar y ejecutar los scripts de la columna "recreate_script"'
PRINT ''
GO
