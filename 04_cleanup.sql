-- ============================================================================
-- LIMPIEZA: Eliminar tablas de diagnostico cuando ya no se necesiten
-- ============================================================================

DROP TABLE IF EXISTS dbo.diag_resource_stats;
DROP TABLE IF EXISTS dbo.diag_active_queries;
DROP TABLE IF EXISTS dbo.diag_query_store_top;
DROP TABLE IF EXISTS dbo.diag_wait_stats;
DROP TABLE IF EXISTS dbo.diag_blocking;
DROP TABLE IF EXISTS dbo.diag_sessions;

PRINT 'Tablas de diagnostico eliminadas.'
GO
