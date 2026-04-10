-- ============================================================================
-- PASO 0: REDIMENSIONAR COLUMNAS VARCHAR(MAX) A TAMAÑO REAL
-- ============================================================================
-- Prerequisito antes de crear indices. Las columnas varchar(MAX) no pueden
-- participar en indices (ni como key ni como INCLUDE).
--
-- Los tamaños se definieron en base al max_length_in_data_chars real de
-- cada columna, con margen de seguridad.
--
-- IMPORTANTE: Ejecutar en horario de baja carga. Cada ALTER puede tomar
-- un schema modification lock breve. Las tablas grandes (Settlement,
-- PayableItem) pueden demorar mas.
-- ============================================================================


-- ============================================================================
-- BranchSystem
-- ============================================================================
ALTER TABLE dbo.BranchSystem ALTER COLUMN CreatedBy NVARCHAR(100) NULL;
ALTER TABLE dbo.BranchSystem ALTER COLUMN UpdatedBy NVARCHAR(100) NULL;
ALTER TABLE dbo.BranchSystem ALTER COLUMN Code NVARCHAR(100) NULL;

-- ============================================================================
-- Container
-- ============================================================================
ALTER TABLE dbo.Container ALTER COLUMN CreatedBy NVARCHAR(100) NULL;
ALTER TABLE dbo.Container ALTER COLUMN UpdatedBy NVARCHAR(100) NULL;

-- ============================================================================
-- ContainerIngestError
-- ============================================================================
ALTER TABLE dbo.ContainerIngestError ALTER COLUMN Message NVARCHAR(500) NULL;

-- ============================================================================
-- DistributionConcept
-- ============================================================================
ALTER TABLE dbo.DistributionConcept ALTER COLUMN UpdatedBy NVARCHAR(100) NULL;
ALTER TABLE dbo.DistributionConcept ALTER COLUMN SegmentationName NVARCHAR(100) NULL;
ALTER TABLE dbo.DistributionConcept ALTER COLUMN QuantityType NVARCHAR(100) NULL;

-- ============================================================================
-- FuelDiscount
-- ============================================================================
ALTER TABLE dbo.FuelDiscount ALTER COLUMN Origin NVARCHAR(100) NULL;

-- ============================================================================
-- PayableItem
-- ============================================================================
ALTER TABLE dbo.PayableItem ALTER COLUMN RecipientName NVARCHAR(500) NULL;
ALTER TABLE dbo.PayableItem ALTER COLUMN CreatedBy NVARCHAR(100) NULL;
ALTER TABLE dbo.PayableItem ALTER COLUMN UpdatedBy NVARCHAR(100) NULL;
ALTER TABLE dbo.PayableItem ALTER COLUMN PolygonCodeH3R11 NVARCHAR(100) NULL;
ALTER TABLE dbo.PayableItem ALTER COLUMN PolygonCodeH3R12 NVARCHAR(100) NULL;
ALTER TABLE dbo.PayableItem ALTER COLUMN PolygonCodeH3R9 NVARCHAR(100) NULL;
ALTER TABLE dbo.PayableItem ALTER COLUMN VisitReason NVARCHAR(300) NULL;

-- ============================================================================
-- PrePayableItem
-- ============================================================================
ALTER TABLE dbo.PrePayableItem ALTER COLUMN VisitReason NVARCHAR(300) NULL;

-- ============================================================================
-- PriceBook
-- ============================================================================
ALTER TABLE dbo.PriceBook ALTER COLUMN Name NVARCHAR(200);
ALTER TABLE dbo.PriceBook ALTER COLUMN PriceBookId NVARCHAR(100);

-- ============================================================================
-- PriceBookCategory
-- ============================================================================
ALTER TABLE dbo.PriceBookCategory ALTER COLUMN PriceBookCategoryType NVARCHAR(100);

-- ============================================================================
-- Settlement (tabla critica para el indice del PASO 1)
-- ============================================================================
ALTER TABLE dbo.Settlement ALTER COLUMN SettlementIdentifier NVARCHAR(100);

-- ============================================================================
-- SettlementGenerationError
-- ============================================================================
ALTER TABLE dbo.SettlementGenerationError ALTER COLUMN ErrorMessage NVARCHAR(500) NULL;

-- ============================================================================
-- TransmittedSettlement (tabla critica para el indice del PASO 1)
-- ============================================================================
ALTER TABLE dbo.TransmittedSettlement ALTER COLUMN SettlementIdentifier NVARCHAR(100);


PRINT ''
PRINT '=== REDIMENSIONAMIENTO COMPLETO ==='
PRINT 'Todas las columnas varchar(MAX) fueron ajustadas a su tamaño real.'
PRINT 'Ahora se pueden crear los indices del PASO 1.'
PRINT ''
GO
