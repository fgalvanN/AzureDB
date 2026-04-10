# Diagnostico DTU Spike - Azure SQL Database

## Problema
Todos los dias a las ~7:00 AM UTC los DTU se disparan al 100% durante ~10 minutos.

## Scripts

### `diagnostico_dtu_spike.sql`
Script completo con 10 secciones de diagnostico. Ejecutar al menos **una vez** durante el spike.

**Captura:**
1. Consumo actual de DTU/CPU/IO/Log
2. Sesiones activas (login, IP origen, programa, host)
3. Queries en ejecucion con texto SQL completo + plan de ejecucion XML
4. Top queries por CPU del Query Store (ultima hora)
5. Wait stats (donde espera el servidor)
6. Cadena de bloqueos activos
7. Indices faltantes sugeridos
8. Estadisticas de IO por tabla
9. Uso de tempdb por sesion (detectar spills)
10. Queries costosas completadas recientemente (ultimos 15 min)

### `captura_rapida.sql`
Version compacta para ejecutar cada 1-2 minutos. Captura recursos + queries activas + IP/usuario + plan.

## Como usar

1. Conectar a la DB afectada con SSMS o Azure Data Studio
2. A las ~6:55 AM ejecutar `diagnostico_dtu_spike.sql` como baseline
3. A las ~7:00 AM cuando suban los DTU, ejecutar `captura_rapida.sql` cada 1-2 min
4. A las ~7:05 AM ejecutar `diagnostico_dtu_spike.sql` completo nuevamente
5. Guardar todos los resultados para analisis

## Que buscar en los resultados

- **Seccion 3**: La query con mas `cpu_time` y `logical_reads` es la sospechosa principal
- **`ip_origen`**: Identifica desde donde se conecta
- **`login_name`**: Quien ejecuta la query
- **`program_name`**: Que aplicacion/servicio la lanza
- **`plan_xml`**: Click en el XML para ver el plan grafico en SSMS
- **Seccion 6**: Si hay bloqueos, el problema puede ser una transaccion abierta que bloquea a las demas
- **Seccion 7**: Si hay missing indexes con alto `improvement_measure`, pueden estar causando scans costosos
