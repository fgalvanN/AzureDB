-- ============================================================================
-- HALLAZGOS Y RECOMENDACIONES: Spike DTU 100% a las 7:00 AM
-- Database: dms-prod-distribution-settlement
-- Fecha de analisis: 2026-04-10
-- ============================================================================

-- ============================================================================
-- RESUMEN EJECUTIVO
-- ============================================================================
-- Se identificaron 2 queries responsables del spike diario de DTU al 100%.
-- Ambas comparten el mismo patron: uso de OR en el WHERE que impide al
-- optimizador usar indices y fuerza Clustered Index Scans de millones de filas.
--
-- Impacto combinado: ~2.6 millones de filas leidas innecesariamente por ejecucion.
-- Correccion estimada: reduccion del scan a seeks puntuales (<1% de las filas).
-- ============================================================================


-- ============================================================================
-- HALLAZGO 1: Query sobre Settlement + TransmittedSettlement
-- Severidad: ALTA
-- Filas escaneadas: 936,587
-- Costo IO: 42.14 (97% del costo total de la query)
-- Tabla afectada: dbo.Settlement (Clustered Index Scan sobre PK_Settlement)
-- ============================================================================

-- QUERY ORIGINAL (problematica):
-- SELECT top(20) sl.Id, al.Description as ActionDescription, sl.CreatedAt,
--        sl.CreatedBy, sl.SettlementId, s.SettlementIdentifier,
--        TS.SettlementIdentifier as TransmittedSettlementIdentifier
-- FROM SettlementLog sl
-- INNER JOIN ActionLog al ON AL.id = sl.ActionLogId
-- INNER JOIN Settlement S ON S.ID = SL.SettlementId
-- LEFT JOIN TransmittedSettlement TS ON TS.Id = S.TransmittedSettlementId
-- WHERE S.SettlementIdentifier = @SettlementIdentifier
--    OR TS.SettlementIdentifier = @TransmittedSettlementIdentifier
-- ORDER BY sl.CreatedAt DESC

-- CAUSA RAIZ:
-- El OR entre columnas de 2 tablas distintas (Settlement y TransmittedSettlement)
-- impide que el optimizador haga seek en ninguna de las dos. Opta por un
-- Clustered Index Scan completo de Settlement (936K filas) y evalua ambas
-- condiciones fila por fila.

-- SOLUCION 1A: Crear indices
CREATE NONCLUSTERED INDEX IX_Settlement_SettlementIdentifier
ON dbo.Settlement (SettlementIdentifier)
INCLUDE (TransmittedSettlementId);

CREATE NONCLUSTERED INDEX IX_TransmittedSettlement_SettlementIdentifier
ON dbo.TransmittedSettlement (SettlementIdentifier)
INCLUDE (Id);

-- SOLUCION 1B: Reescribir la query reemplazando OR por UNION
-- Cada rama del UNION puede hacer Index Seek independiente.

-- QUERY RECOMENDADA:
/*
SELECT TOP(20) *
FROM (
    SELECT sl.Id, al.Description AS ActionDescription,
           sl.CreatedAt, sl.CreatedBy, sl.SettlementId,
           S.SettlementIdentifier,
           TS.SettlementIdentifier AS TransmittedSettlementIdentifier
    FROM SettlementLog sl
    INNER JOIN ActionLog al ON al.Id = sl.ActionLogId
    INNER JOIN Settlement S ON S.Id = sl.SettlementId
    LEFT JOIN TransmittedSettlement TS ON TS.Id = S.TransmittedSettlementId
    WHERE S.SettlementIdentifier = @SettlementIdentifier

    UNION

    SELECT sl.Id, al.Description AS ActionDescription,
           sl.CreatedAt, sl.CreatedBy, sl.SettlementId,
           S.SettlementIdentifier,
           TS.SettlementIdentifier AS TransmittedSettlementIdentifier
    FROM SettlementLog sl
    INNER JOIN ActionLog al ON al.Id = sl.ActionLogId
    INNER JOIN Settlement S ON S.Id = sl.SettlementId
    LEFT JOIN TransmittedSettlement TS ON TS.Id = S.TransmittedSettlementId
    WHERE TS.SettlementIdentifier = @TransmittedSettlementIdentifier
) AS combined
ORDER BY CreatedAt DESC;
*/


-- ============================================================================
-- HALLAZGO 2: Query sobre AditionalConcept (2 variantes, misma causa)
-- Severidad: ALTA
-- Filas escaneadas: 1,669,200 (variante 1) / 1,619,050 (variante 2)
-- Costo IO: 93.82 / 82.01
-- Tabla afectada: dbo.AditionalConcept (Clustered Index Scan sobre PK_AditionalConcept)
-- ============================================================================

-- QUERY ORIGINAL (problematica):
-- SELECT AC.Id, AC.AditionalConcepts, AC.Formula, AC.Description, ...
-- FROM AditionalConcept AS AC
-- LEFT JOIN AdditionalConceptPerDay AS ACPD ON ACPD.AditionalConceptId = AC.ID
-- LEFT JOIN ServiceDirectType AS SDT ON SDT.Id = AC.ServiceDirectTypeId
-- LEFT JOIN Periodicity AS P ON P.Id = AC.PeriodicityId
-- LEFT JOIN PeriodicityType AS PT ON PT.Id = AC.PeriodicityTypeId
-- LEFT JOIN DaysOfTheWeek DW ON ACPD.DaysOfTheWeekId = DW.Id
-- LEFT JOIN ServiceCondition SC ON SC.Id = AC.ServiceConditionId
-- WHERE PT.IsDeleted IS NULL OR PT.IsDeleted = 0
--   AND AC.PriceBookId IN (@PriceBookIds1)

-- CAUSA RAIZ (2 problemas):
--
-- PROBLEMA A: Precedencia de operadores (posible bug logico)
-- SQL interpreta el WHERE como:
--     WHERE PT.IsDeleted IS NULL
--        OR (PT.IsDeleted = 0 AND AC.PriceBookId IN (@PriceBookIds1))
--
-- La rama "PT.IsDeleted IS NULL" no filtra por PriceBookId, devolviendo
-- potencialmente TODOS los registros donde el LEFT JOIN a PeriodicityType
-- no matchea (PT es NULL). Probablemente la intencion era:
--     WHERE (PT.IsDeleted IS NULL OR PT.IsDeleted = 0)
--       AND AC.PriceBookId IN (@PriceBookIds1)
--
-- PROBLEMA B: Incluso corrigiendo los parentesis, el OR impide un seek
-- eficiente, y la falta de indice en PriceBookId fuerza un full scan.

-- SOLUCION 2A: Crear indice
CREATE NONCLUSTERED INDEX IX_AditionalConcept_PriceBookId
ON dbo.AditionalConcept (PriceBookId)
INCLUDE (ServiceDirectTypeId, PeriodicityId, PeriodicityTypeId,
         ServiceConditionId, VehicleTypeId, AditionalConcepts,
         Formula, Description, Concept, IsOptional, DayOfTheMonth,
         StartDate, EndDate, RequiresProvision);

-- SOLUCION 2B: Corregir la query (parentesis + simplificar condicion)

-- QUERY RECOMENDADA:
/*
SELECT AC.Id, AC.AditionalConcepts, AC.Formula, AC.Description,
       AC.PriceBookId, AC.Concept, AC.IsOptional, AC.DayOfTheMonth,
       AC.StartDate, AC.EndDate, AC.PeriodicityId, AC.PeriodicityTypeId,
       AC.RequiresProvision,
       DW.Description AS AdditionalConceptPerDay,
       SDT.Id AS ServiceDirectTypeId,
       SDT.Description AS ServiceDirectDescription,
       SDT.Entity AS ServiceDirectEntity,
       SDT.Property AS ServiceDirectProperty,
       P.Description AS PeriodicityDescription,
       PT.Description AS PeriodicityTypeDescription,
       SC.Comparer AS ConditionComparer,
       SC.Value AS ConditionValue,
       SC.Attribute AS ConditionAttribute,
       SC.Property AS ConditionProperty,
       AC.VehicleTypeId
FROM AditionalConcept AS AC
LEFT JOIN AdditionalConceptPerDay AS ACPD ON ACPD.AditionalConceptId = AC.Id
LEFT JOIN ServiceDirectType AS SDT ON SDT.Id = AC.ServiceDirectTypeId
LEFT JOIN Periodicity AS P ON P.Id = AC.PeriodicityId
LEFT JOIN PeriodicityType AS PT ON PT.Id = AC.PeriodicityTypeId
LEFT JOIN DaysOfTheWeek DW ON ACPD.DaysOfTheWeekId = DW.Id
LEFT JOIN ServiceCondition SC ON SC.Id = AC.ServiceConditionId
WHERE (PT.IsDeleted IS NULL OR PT.IsDeleted = 0)
  AND AC.PriceBookId IN (@PriceBookIds1);
*/


-- ============================================================================
-- PLAN DE EJECUCION RECOMENDADO
-- ============================================================================
-- PASO 1 (inmediato, sin riesgo): Crear los indices en horario de baja carga
--         Los CREATE INDEX no bloquean lecturas si se usa ONLINE = ON.
--         Ejecutar los 3 CREATE INDEX de arriba.
--
-- PASO 2 (requiere deploy): Corregir las queries en el codigo de la aplicacion
--         - Settlement: reemplazar OR por UNION
--         - AditionalConcept: agregar parentesis y validar logica del filtro
--
-- PASO 3 (verificacion): Al dia siguiente a las 7am monitorear los DTU
--         para confirmar que el spike se redujo.
-- ============================================================================


-- ============================================================================
-- RESUMEN DE IMPACTO ESPERADO
-- ============================================================================
--
-- +-----+-----------------------+-------------+-----------+------------------+
-- | #   | Tabla                 | Filas antes | Fix       | Filas despues    |
-- +-----+-----------------------+-------------+-----------+------------------+
-- | 1   | Settlement            | 936,587     | UNION +IX | ~decenas (seek)  |
-- | 2a  | AditionalConcept (v1) | 1,669,200   | () + IX   | ~decenas (seek)  |
-- | 2b  | AditionalConcept (v2) | 1,619,050   | () + IX   | ~decenas (seek)  |
-- +-----+-----------------------+-------------+-----------+------------------+
-- | TOT | Filas escaneadas      | ~4,224,837  |           | < 1,000          |
-- +-----+-----------------------+-------------+-----------+------------------+
--
-- Reduccion estimada de IO: >99%
-- Impacto en DTU: deberia eliminar o reducir drasticamente el spike de las 7am
-- ============================================================================
