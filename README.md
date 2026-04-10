# Diagnostico DTU Spike - Azure SQL Database

## Problema
Todos los dias a las ~7:00 AM UTC los DTU se disparan al 100% durante ~10 minutos.

## Scripts

### Flujo recomendado (con persistencia)

| Orden | Script | Cuando | Que hace |
|-------|--------|--------|----------|
| 1 | `01_crear_tablas_diagnostico.sql` | Una sola vez, antes del spike | Crea las tablas donde se guardan los datos |
| 2 | `02_captura_persistente.sql` | Cada 1-2 min durante el spike | Inserta snapshots en las tablas |
| 3 | `03_analisis_resultados.sql` | Despues del spike | Resume y agrega los datos para encontrar culpables |
| 4 | `04_cleanup.sql` | Cuando ya no se necesiten | Elimina las tablas de diagnostico |

### Scripts originales (solo visualizacion en pantalla)

| Script | Uso |
|--------|-----|
| `diagnostico_dtu_spike.sql` | Diagnostico completo de 10 secciones, resultados en pantalla |
| `captura_rapida.sql` | Version compacta para ejecucion rapida repetida |

## Como usar

1. Conectar a la DB afectada con SSMS o Azure Data Studio
2. Ejecutar `01_crear_tablas_diagnostico.sql` (una sola vez)
3. A las ~6:55 AM ejecutar `02_captura_persistente.sql` como baseline
4. A las ~7:00 AM cuando suban los DTU, ejecutar `02_captura_persistente.sql` cada 1-2 min
5. Repetir paso 4 durante los ~10 min del spike
6. Ejecutar `03_analisis_resultados.sql` para ver el resumen
7. Compartir resultados de secciones E, F y H para optimizacion

## Que buscar en los resultados del analisis

- **Seccion E**: Top queries por CPU total del Query Store (la fuente mas confiable)
- **Seccion H**: Texto completo + plan de ejecucion XML de las top 5 queries
- **Seccion F**: Que tipo de waits crecieron durante el spike (CPU, IO, locks)
- **Seccion B**: Usuarios, IPs y programas que estuvieron conectados
- **Seccion D**: Queries agrupadas por patron (misma query ejecutada muchas veces)
- **Seccion G**: Bloqueos detectados

## Limpieza

Ejecutar `04_cleanup.sql` para eliminar las tablas de diagnostico cuando ya no se necesiten.
