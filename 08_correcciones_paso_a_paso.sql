-- ============================================================================
-- CORRECCIONES PASO A PASO
-- ============================================================================
-- Ejecutar en orden. Cada paso es independiente.
-- Se puede aplicar uno, verificar resultados, y luego aplicar el siguiente.
-- ============================================================================


-- ============================================================================
-- PASO 1: INDICES (ejecutar en horario de baja carga)
-- ============================================================================
-- Estos indices se pueden crear sin modificar codigo de la aplicacion.
-- Con ONLINE = ON no bloquean lecturas ni la operatoria normal.
-- ============================================================================

-- 1.1 Indice para que Settlement busque por SettlementIdentifier sin escanear
--     toda la tabla. Hoy escanea 936,587 filas. Con el indice: seek directo.
CREATE NONCLUSTERED INDEX IX_Settlement_SettlementIdentifier
ON dbo.Settlement (SettlementIdentifier)
INCLUDE (TransmittedSettlementId)
WITH (ONLINE = ON);

-- 1.2 Indice para que TransmittedSettlement busque por SettlementIdentifier
--     sin escanear toda la tabla.
CREATE NONCLUSTERED INDEX IX_TransmittedSettlement_SettlementIdentifier
ON dbo.TransmittedSettlement (SettlementIdentifier)
INCLUDE (Id)
WITH (ONLINE = ON);

-- 1.3 Indice para que AditionalConcept filtre por PriceBookId sin escanear
--     toda la tabla. Hoy escanea 1,669,200 filas. Con el indice: seek directo.
CREATE NONCLUSTERED INDEX IX_AditionalConcept_PriceBookId
ON dbo.AditionalConcept (PriceBookId)
INCLUDE (ServiceDirectTypeId, PeriodicityId, PeriodicityTypeId,
         ServiceConditionId, VehicleTypeId, AditionalConcepts,
         Formula, Description, Concept, IsOptional, DayOfTheMonth,
         StartDate, EndDate, RequiresProvision)
WITH (ONLINE = ON);


-- ============================================================================
-- PASO 2: CORRECCION QUERY SETTLEMENT (requiere cambio en la aplicacion)
-- ============================================================================
-- PROBLEMA:
--   El OR entre S.SettlementIdentifier y TS.SettlementIdentifier impide
--   que el optimizador use cualquier indice. Resultado: Clustered Index Scan
--   de 936,587 filas cada vez que se ejecuta.
--
-- SOLUCION:
--   Reemplazar el OR por UNION. Cada rama hace un Index Seek independiente.
--
-- RESULTADO ESPERADO:
--   Antes:  Clustered Index Scan = 936,587 filas leidas | IO Cost = 42.14
--   Despues: 2 Index Seeks = ~decenas de filas leidas   | IO Cost < 0.01
-- ============================================================================

-- QUERY ORIGINAL (NO USAR):
-- SELECT top(20) sl.Id, al.Description as ActionDescription,
--        sl.CreatedAt, sl.CreatedBy, sl.SettlementId,
--        s.SettlementIdentifier,
--        TS.SettlementIdentifier as TransmittedSettlementIdentifier
-- FROM SettlementLog sl
-- INNER JOIN ActionLog al ON AL.id = sl.ActionLogId
-- INNER JOIN Settlement S ON S.ID = SL.SettlementId
-- LEFT JOIN TransmittedSettlement TS ON TS.Id = S.TransmittedSettlementId
-- WHERE S.SettlementIdentifier = @SettlementIdentifier
--    OR TS.SettlementIdentifier = @TransmittedSettlementIdentifier
-- ORDER BY sl.CreatedAt DESC

-- QUERY CORREGIDA:
SELECT TOP(20) *
FROM (
    -- Rama 1: busca por Settlement.SettlementIdentifier (usa IX_Settlement_SettlementIdentifier)
    SELECT sl.Id,
           al.Description                    AS ActionDescription,
           sl.CreatedAt,
           sl.CreatedBy,
           sl.SettlementId,
           S.SettlementIdentifier,
           TS.SettlementIdentifier           AS TransmittedSettlementIdentifier
    FROM SettlementLog sl
    INNER JOIN ActionLog al ON al.Id = sl.ActionLogId
    INNER JOIN Settlement S ON S.Id = sl.SettlementId
    LEFT JOIN TransmittedSettlement TS ON TS.Id = S.TransmittedSettlementId
    WHERE S.SettlementIdentifier = @SettlementIdentifier

    UNION

    -- Rama 2: busca por TransmittedSettlement.SettlementIdentifier (usa IX_TransmittedSettlement_SettlementIdentifier)
    SELECT sl.Id,
           al.Description                    AS ActionDescription,
           sl.CreatedAt,
           sl.CreatedBy,
           sl.SettlementId,
           S.SettlementIdentifier,
           TS.SettlementIdentifier           AS TransmittedSettlementIdentifier
    FROM SettlementLog sl
    INNER JOIN ActionLog al ON al.Id = sl.ActionLogId
    INNER JOIN Settlement S ON S.Id = sl.SettlementId
    LEFT JOIN TransmittedSettlement TS ON TS.Id = S.TransmittedSettlementId
    WHERE TS.SettlementIdentifier = @TransmittedSettlementIdentifier
) AS combined
ORDER BY CreatedAt DESC;


-- ============================================================================
-- PASO 3: CORRECCION QUERY ADITIONALCONCEPT (requiere cambio en la aplicacion)
-- ============================================================================
-- PROBLEMA:
--   El WHERE tiene un OR sin parentesis, lo que causa un error de logica:
--
--     WHERE PT.IsDeleted IS NULL OR PT.IsDeleted = 0
--       AND AC.PriceBookId IN (@PriceBookIds1)
--
--   SQL lo interpreta como:
--     WHERE PT.IsDeleted IS NULL
--        OR (PT.IsDeleted = 0 AND AC.PriceBookId IN (@PriceBookIds1))
--
--   Esto significa que cuando PT.IsDeleted es NULL (lo cual ocurre siempre
--   que el LEFT JOIN a PeriodicityType no matchea), se devuelven TODOS esos
--   registros SIN filtrar por PriceBookId. Resultado: Clustered Index Scan
--   de 1,669,200 filas.
--
-- SOLUCION:
--   Agregar parentesis para que el AND aplique a ambas ramas del OR.
--
-- RESULTADO ESPERADO:
--   Antes:  Clustered Index Scan = 1,669,200 filas | IO Cost = 93.82
--   Despues: Index Seek por PriceBookId = ~decenas  | IO Cost < 0.1
-- ============================================================================

-- QUERY ORIGINAL (NO USAR):
-- SELECT AC.Id, AC.AditionalConcepts, ...
-- FROM AditionalConcept AS AC
-- LEFT JOIN AdditionalConceptPerDay AS ACPD ON ACPD.AditionalConceptId = AC.ID
-- LEFT JOIN ServiceDirectType AS SDT ON SDT.Id = AC.ServiceDirectTypeId
-- LEFT JOIN Periodicity AS P ON P.Id = AC.PeriodicityId
-- LEFT JOIN PeriodicityType AS PT ON PT.Id = AC.PeriodicityTypeId
-- LEFT JOIN DaysOfTheWeek DW ON ACPD.DaysOfTheWeekId = DW.Id
-- LEFT JOIN ServiceCondition SC ON SC.Id = AC.ServiceConditionId
-- WHERE PT.IsDeleted IS NULL OR PT.IsDeleted = 0
--   AND AC.PriceBookId IN (@PriceBookIds1)

-- QUERY CORREGIDA:
SELECT AC.Id,
       AC.AditionalConcepts,
       AC.Formula,
       AC.Description,
       AC.PriceBookId,
       AC.Concept,
       AC.IsOptional,
       AC.DayOfTheMonth,
       AC.StartDate,
       AC.EndDate,
       AC.PeriodicityId,
       AC.PeriodicityTypeId,
       AC.RequiresProvision,
       DW.Description                       AS AdditionalConceptPerDay,
       SDT.Id                               AS ServiceDirectTypeId,
       SDT.Description                      AS ServiceDirectDescription,
       SDT.Entity                           AS ServiceDirectEntity,
       SDT.Property                         AS ServiceDirectProperty,
       P.Description                        AS PeriodicityDescription,
       PT.Description                       AS PeriodicityTypeDescription,
       SC.Comparer                          AS ConditionComparer,
       SC.Value                             AS ConditionValue,
       SC.Attribute                         AS ConditionAttribute,
       SC.Property                          AS ConditionProperty,
       AC.VehicleTypeId
FROM AditionalConcept AS AC
LEFT JOIN AdditionalConceptPerDay AS ACPD ON ACPD.AditionalConceptId = AC.Id
LEFT JOIN ServiceDirectType AS SDT ON SDT.Id = AC.ServiceDirectTypeId
LEFT JOIN Periodicity AS P ON P.Id = AC.PeriodicityId
LEFT JOIN PeriodicityType AS PT ON PT.Id = AC.PeriodicityTypeId
LEFT JOIN DaysOfTheWeek DW ON ACPD.DaysOfTheWeekId = DW.Id
LEFT JOIN ServiceCondition SC ON SC.Id = AC.ServiceConditionId
WHERE (PT.IsDeleted IS NULL OR PT.IsDeleted = 0)   -- <== parentesis agregados
  AND AC.PriceBookId IN (@PriceBookIds1);


-- ============================================================================
-- RESUMEN
-- ============================================================================
--
-- +------+------------------------+-------------------+--------------------+
-- | Paso | Que se corrige         | Antes             | Despues            |
-- +------+------------------------+-------------------+--------------------+
-- |  1   | Crear 3 indices        | Sin indices       | Seek habilitado    |
-- |      | (sin cambio de codigo) | en las 3 columnas | para las 3 queries |
-- +------+------------------------+-------------------+--------------------+
-- |  2   | Query Settlement       | Scan 936K filas   | Seek ~decenas      |
-- |      | OR -> UNION            | IO Cost: 42.14    | IO Cost: < 0.01    |
-- +------+------------------------+-------------------+--------------------+
-- |  3   | Query AditionalConcept | Scan 1.6M filas   | Seek ~decenas      |
-- |      | Agregar parentesis     | IO Cost: 93.82    | IO Cost: < 0.1     |
-- |      |                        | + posible bug:    | + filtro correcto  |
-- |      |                        | devuelve datos    | por PriceBookId    |
-- |      |                        | sin filtrar       |                    |
-- +------+------------------------+-------------------+--------------------+
--
-- El Paso 1 (indices) se puede aplicar de forma inmediata sin deploy.
-- Por si solo puede mejorar la situacion, pero el beneficio completo
-- se obtiene combinandolo con los Pasos 2 y 3 (cambio de queries).
-- ============================================================================
