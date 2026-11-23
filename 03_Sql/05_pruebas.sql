
/* =====================================================================
   DataSalud Perú - CIIN1021P
   Archivo 05: Pruebas de funcionamiento
   IMPORTANTE:
   - Ajustar las rutas de los CSV antes de ejecutar la prueba 1.
   - Ejecutar cada prueba por separado.
   - La prueba 6 reemplaza el contenido de stg_Neumonia.
   ===================================================================== */

USE DataSalud;
GO

/* =====================================================================
   PRUEBA 1: INGESTA DE ARCHIVOS CSV
   ===================================================================== */

DECLARE @id INT;

EXEC dbo.sp_Ingestar_CSV
    @Fuente = 'NEUMONIA',
    @RutaArchivo = N'C:\DataSalud\datos\DatasetNeumonia_actual_0.csv',
    @IdEjecucion = @id OUTPUT;

EXEC dbo.sp_Ingestar_CSV
    @Fuente = 'RENIPRESS',
    @RutaArchivo = N'C:\DataSalud\datos\RENIPRESS_30-10-2026.csv',
    @IdEjecucion = @id OUTPUT;

SELECT
    IdEjecucion,
    Proceso,
    Fuente,
    FilasLeidas,
    Estado,
    Mensaje
FROM dbo.log_EjecucionETL
ORDER BY IdEjecucion;
GO


/* =====================================================================
   PRUEBA 2: VALIDACIÓN Y CARGA DE DATOS REALES
   ===================================================================== */

DECLARE @id INT;

EXEC dbo.sp_Validar_Neumonia
    @IdEjecucion = @id OUTPUT;

EXEC dbo.sp_Validar_RENIPRESS
    @FechaCorte = '20261030',
    @IdEjecucion = @id OUTPUT;

/* Resultado de las ejecuciones. */

SELECT
    IdEjecucion,
    Proceso,
    FilasLeidas,
    FilasCargadas,
    FilasRechazadas,
    Estado,
    Mensaje
FROM dbo.log_EjecucionETL
WHERE Proceso LIKE N'sp_Validar%'
ORDER BY IdEjecucion;

/* Indicadores de calidad. */

SELECT
    IdEjecucion,
    Fuente,
    CodigoRegla,
    Descripcion,
    Cantidad
FROM dbo.log_CalidadDatos
ORDER BY IdCalidad;

/* Excepciones encontradas. */

SELECT
    Fuente,
    CodigoRegla,
    Accion,
    COUNT(*) AS Filas
FROM dbo.ExcepcionesDatos
GROUP BY
    Fuente,
    CodigoRegla,
    Accion
ORDER BY
    Fuente,
    CodigoRegla;
GO


/* =====================================================================
   PRUEBA 3: TRIGGER DE AUDITORÍA
   Comprueba INSERT, UPDATE y DELETE.
   ===================================================================== */

INSERT INTO dbo.Neumonia_Validada
(
    Departamento,
    Provincia,
    Distrito,
    Ubigeo,
    CodEstablecimiento,
    Establecimiento,
    Anio,
    Semana,
    Mes,
    NEU_2_11M
)
VALUES
(
    N'PIURA',
    N'PIURA',
    N'PIURA',
    '200101',
    'TEST000001',
    N'ESTABLECIMIENTO DE PRUEBA',
    2026,
    1,
    N'Enero',
    1
);

UPDATE dbo.Neumonia_Validada
SET NEU_2_11M = 5
WHERE CodEstablecimiento = 'TEST000001';

DELETE FROM dbo.Neumonia_Validada
WHERE CodEstablecimiento = 'TEST000001';

/* Verifica que se registraron las tres operaciones. */

SELECT TOP (3)
    IdAuditoria,
    Tabla,
    Operacion,
    IdRegistro,
    Usuario,
    Host,
    Fecha,
    DatosAnteriores,
    DatosNuevos
FROM dbo.log_Auditoria
WHERE Tabla = N'Neumonia_Validada'
ORDER BY IdAuditoria DESC;
GO


/* =====================================================================
   PRUEBA 4: TRIGGER DE INTEGRIDAD
   Intenta insertar una semana inválida y casos negativos.
   Resultado esperado: error 50020 y registro RECHAZO en auditoría.
   ===================================================================== */

BEGIN TRY

    INSERT INTO dbo.Neumonia_Validada
    (
        Departamento,
        Provincia,
        Distrito,
        Ubigeo,
        CodEstablecimiento,
        Establecimiento,
        Anio,
        Semana,
        Mes,
        NEU_2_11M
    )
    VALUES
    (
        N'PIURA',
        N'PIURA',
        N'PIURA',
        '200101',
        'TEST000002',
        N'ESTABLECIMIENTO DE PRUEBA',
        2026,
        99,
        N'Enero',
        -5
    );

END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS NumeroError,
        ERROR_MESSAGE() AS MensajeError;

END CATCH;

/* Comprueba que el registro inválido no se guardó. */

SELECT
    COUNT(*) AS FilasTEST000002
FROM dbo.Neumonia_Validada
WHERE CodEstablecimiento = 'TEST000002';

/* Comprueba que el intento quedó registrado. */

SELECT TOP (3)
    IdAuditoria,
    Tabla,
    Operacion,
    IdRegistro,
    Usuario,
    Fecha,
    Detalle
FROM dbo.log_Auditoria
WHERE Operacion = 'RECHAZO'
ORDER BY IdAuditoria DESC;
GO


/* =====================================================================
   PRUEBA 5: FUNCIONES
   ===================================================================== */

/* Función de normalización de UBIGEO. */

SELECT
    dbo.fn_NormalizarUbigeo(N'30101') AS Ubigeo5Digitos,
    dbo.fn_NormalizarUbigeo(N'200101') AS Ubigeo6Digitos,
    dbo.fn_NormalizarUbigeo(N'20A101') AS ConLetras,
    dbo.fn_NormalizarUbigeo(NULL) AS Nulo;

/* Función de casos por grupo etario. */

SELECT *
FROM dbo.fn_CasosPorGrupoEtario(2026, 1, 35)
ORDER BY Orden;
GO


/* =====================================================================
   PRUEBA 6: VALIDACIÓN CON DATOS SINTÉTICOS Y SAVEPOINT
   IMPORTANTE:
   Esta prueba reemplaza el contenido de stg_Neumonia.
   Después de terminar, se deben volver a cargar los datos reales
   si se necesitan para otras pruebas.
   ===================================================================== */

/* Se reemplazan temporalmente los datos de staging. */

TRUNCATE TABLE dbo.stg_Neumonia;

INSERT INTO dbo.stg_Neumonia
(
    FECHA_CORTE,
    DEPARTAMENTEO,
    PROVINCIA,
    DISTRITO,
    UBIGEO,
    E_SALUD,
    ESTABLECIMIENTO,
    ANO,
    SEMANA,
    MES,
    NEU_2_11M,
    NEU_1_4A,
    NEU_5_9A,
    NEU_10_19A,
    NEU_20_59A,
    NEU_60A
)
VALUES
/* Fila 1: válida. */
(
    N'20261007', N'PIURA', N'PIURA', N'PIURA',
    N'200101', N'TESTSP0001', N'ESTAB PRUEBA 1',
    N'2025', N'10', N'Marzo',
    N'1', N'0', N'0', N'0', N'2', N'3'
),

/* Fila 2: UBIGEO de cinco dígitos. */
(
    N'20261007', N'PIURA', N'PIURA', N'PIURA',
    N'30101', N'TESTSP0002', N'ESTAB PRUEBA 2',
    N'2025', N'10', N'Marzo',
    N'0', N'1', N'0', N'0', N'0', N'0'
),

/* Fila 3: provincia fuera de Piura y todos los casos en cero. */
(
    N'20261007', N'PIURA', N'LIMA', N'LIMA',
    N'150101', N'TESTSP0003', N'ESTAB PRUEBA 3',
    N'2025', N'10', N'Marzo',
    N'0', N'0', N'0', N'0', N'0', N'0'
),

/* Fila 4: completamente vacía. */
(
    NULL, NULL, NULL, NULL,
    NULL, NULL, NULL,
    NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL
),

/* Fila 5: casos negativos. */
(
    N'20261007', N'PIURA', N'PIURA', N'PIURA',
    N'200101', N'TESTSP0004', N'ESTAB PRUEBA 4',
    N'2025', N'10', N'Marzo',
    N'-5', N'0', N'0', N'0', N'0', N'0'
),

/* Fila 6: semana inválida. */
(
    N'20261007', N'PIURA', N'PIURA', N'PIURA',
    N'200101', N'TESTSP0005', N'ESTAB PRUEBA 5',
    N'2025', N'99', N'Marzo',
    N'1', N'0', N'0', N'0', N'0', N'0'
),

/* Fila 7: clave duplicada de la fila 1. */
(
    N'20261007', N'PIURA', N'PIURA', N'PIURA',
    N'200101', N'TESTSP0001', N'ESTAB PRUEBA 1',
    N'2025', N'10', N'Marzo',
    N'4', N'4', N'4', N'4', N'4', N'4'
);
GO


/* -------------------- PRUEBA 6A --------------------
   Se simula un error en la fase de carga.
   Se espera:
   - Estado ERROR_CARGA.
   - Filas cargadas: 0.
   - Filas rechazadas por validación: 4.
   - Se conserva el diagnóstico de calidad.
   - No quedan registros TESTSP% cargados.
   --------------------------------------------------- */

DECLARE @id INT;

EXEC dbo.sp_Validar_Neumonia
    @SimularFalloCarga = 1,
    @IdEjecucion = @id OUTPUT;

SELECT
    IdEjecucion,
    FilasLeidas,
    FilasCargadas,
    FilasRechazadas,
    Estado,
    Mensaje
FROM dbo.log_EjecucionETL
WHERE IdEjecucion = @id;

SELECT
    CodigoRegla,
    Descripcion,
    Cantidad
FROM dbo.log_CalidadDatos
WHERE IdEjecucion = @id
ORDER BY IdCalidad;

SELECT
    CodigoRegla,
    Accion,
    Detalle
FROM dbo.ExcepcionesDatos
WHERE IdEjecucion = @id
ORDER BY IdExcepcion;

SELECT
    COUNT(*) AS FilasTESTSPCargadas
FROM dbo.Neumonia_Validada
WHERE CodEstablecimiento LIKE 'TESTSP%';
GO


/* -------------------- PRUEBA 6B --------------------
   Se ejecuta nuevamente sin fallo simulado.
   Se espera:
   - Estado OK.
   - 7 filas leídas.
   - 3 filas cargadas.
   - 4 filas rechazadas.
   - El UBIGEO 30101 se normaliza a 030101.
   --------------------------------------------------- */

DECLARE @id INT;

EXEC dbo.sp_Validar_Neumonia
    @IdEjecucion = @id OUTPUT;

SELECT
    IdEjecucion,
    FilasLeidas,
    FilasCargadas,
    FilasRechazadas,
    Estado,
    Mensaje
FROM dbo.log_EjecucionETL
WHERE IdEjecucion = @id;

SELECT
    CodigoRegla,
    Accion,
    Detalle
FROM dbo.ExcepcionesDatos
WHERE IdEjecucion = @id
ORDER BY IdExcepcion;

SELECT
    CodEstablecimiento,
    Ubigeo,
    Provincia
FROM dbo.Neumonia_Validada
WHERE CodEstablecimiento LIKE 'TESTSP%'
ORDER BY CodEstablecimiento;
GO


/* =====================================================================
   PRUEBA 7: CONTROL DE ERRORES DE INGESTA
   Intenta cargar un archivo que no existe.
   Se espera error y registro ERROR en el log.
   ===================================================================== */

DECLARE @id INT;

BEGIN TRY

    EXEC dbo.sp_Ingestar_CSV
        @Fuente = 'NEUMONIA',
        @RutaArchivo = N'C:\DataSalud\datos\NO_EXISTE.csv',
        @IdEjecucion = @id OUTPUT;

END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS NumeroError,
        ERROR_MESSAGE() AS MensajeError;

END CATCH;

/* Verifica el registro de error. */

SELECT TOP (1)
    IdEjecucion,
    Proceso,
    Archivo,
    Estado,
    Mensaje
FROM dbo.log_EjecucionETL
ORDER BY IdEjecucion DESC;

/* La tabla de staging debe conservar sus siete filas. */

SELECT
    COUNT(*) AS FilasEnStgNeumonia
FROM dbo.stg_Neumonia;
GO


/* -------------------- PRUEBA 7B --------------------
   Comprueba el control de un parámetro inválido.
   Se espera el error 50010.
   --------------------------------------------------- */

BEGIN TRY

    EXEC dbo.sp_Ingestar_CSV
        @Fuente = 'OTRA',
        @RutaArchivo = N'C:\x.csv';

END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS NumeroError,
        ERROR_MESSAGE() AS MensajeError;

END CATCH;
GO
