
/* =====================================================================
   DataSalud Perú - CIIN1021P
   Archivo 04: Procedimientos almacenados
   Requisito: SQL Server 2017 o superior
   ===================================================================== */

USE DataSalud;
GO

/* =====================================================================
   PROCEDIMIENTO 1: sp_Ingestar_CSV
   Carga los archivos CSV a las tablas de preparación.
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.sp_Ingestar_CSV
    @Fuente VARCHAR(20),
    @RutaArchivo NVARCHAR(260),
    @FinLinea NVARCHAR(10) = NULL,
    @IdEjecucion INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @Leidas INT,
        @Sql NVARCHAR(MAX),
        @Vista NVARCHAR(128),
        @Tabla NVARCHAR(128),
        @Sep NCHAR(1);

    IF @@TRANCOUNT > 0
        THROW 50001,
            N'Ejecute el procedimiento fuera de una transacción abierta.',
            1;

    IF @Fuente IS NULL
       OR @Fuente NOT IN ('NEUMONIA', 'RENIPRESS')
        THROW 50010,
            N'@Fuente debe ser NEUMONIA o RENIPRESS.',
            1;

    IF @RutaArchivo IS NULL
       OR LTRIM(RTRIM(@RutaArchivo)) = N''
        THROW 50011,
            N'@RutaArchivo es obligatoria.',
            1;

    SELECT
        @Tabla =
            CASE @Fuente
                WHEN 'NEUMONIA' THEN N'dbo.stg_Neumonia'
                ELSE N'dbo.stg_RENIPRESS'
            END,
        @Vista =
            CASE @Fuente
                WHEN 'NEUMONIA' THEN N'dbo.vw_Carga_Neumonia'
                ELSE N'dbo.vw_Carga_RENIPRESS'
            END,
        @Sep =
            CASE @Fuente
                WHEN 'NEUMONIA' THEN N','
                ELSE N';'
            END;

    INSERT INTO dbo.log_EjecucionETL
    (
        Proceso,
        Fuente,
        Archivo,
        Estado
    )
    VALUES
    (
        N'sp_Ingestar_CSV',
        @Fuente,
        @RutaArchivo,
        'EN_CURSO'
    );

    SET @IdEjecucion = CONVERT(INT, SCOPE_IDENTITY());

    BEGIN TRY
        BEGIN TRANSACTION;

        /* Limpia la tabla de preparación antes de cargar el nuevo archivo. */
        SET @Sql = N'TRUNCATE TABLE ' + @Tabla + N';';

        EXEC sys.sp_executesql @Sql;

        /* Carga el CSV mediante la vista que excluye la columna identidad. */
        SET @Sql =
            N'BULK INSERT ' + @Vista
            + N' FROM '''
            + REPLACE(@RutaArchivo, N'''', N'''''')
            + N''''
            + N' WITH (FORMAT = ''CSV'', FIRSTROW = 2,'
            + N' FIELDTERMINATOR = '''
            + @Sep
            + N''', FIELDQUOTE = ''"'', CODEPAGE = ''65001'', TABLOCK'
            + CASE
                WHEN @FinLinea IS NULL THEN N''
                ELSE
                    N', ROWTERMINATOR = '''
                    + REPLACE(@FinLinea, N'''', N'''''')
                    + N''''
              END
            + N');';

        EXEC sys.sp_executesql @Sql;

        SET @Sql =
            N'SELECT @n = COUNT(*) FROM ' + @Tabla + N';';

        EXEC sys.sp_executesql
            @Sql,
            N'@n INT OUTPUT',
            @n = @Leidas OUTPUT;

        COMMIT TRANSACTION;

        UPDATE dbo.log_EjecucionETL
        SET
            FechaFin = SYSDATETIME(),
            FilasLeidas = @Leidas,
            Estado = 'OK',
            Mensaje = N'Carga a la zona de preparación completada.'
        WHERE IdEjecucion = @IdEjecucion;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        UPDATE dbo.log_EjecucionETL
        SET
            FechaFin = SYSDATETIME(),
            Estado = 'ERROR',
            Mensaje = LEFT(ERROR_MESSAGE(), 4000)
        WHERE IdEjecucion = @IdEjecucion;

        THROW;
    END CATCH
END;
GO


/* =====================================================================
   PROCEDIMIENTO 2: sp_Validar_Neumonia
   Valida los datos de neumonía y los carga a Neumonia_Validada.
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.sp_Validar_Neumonia
    @SimularFalloCarga BIT = 0,
    @IdEjecucion INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @Leidas INT,
        @Vacias INT,
        @Cargadas INT = 0,
        @Rechazadas INT,
        @Pc03 INT,
        @Pc04 INT,
        @Pc05 INT,
        @Pc06 INT,
        @Pc08 INT,
        @ErrorCarga NVARCHAR(4000) = NULL,
        @Estado VARCHAR(20);

    IF @@TRANCOUNT > 0
        THROW 50001,
            N'Ejecute el procedimiento fuera de una transacción abierta.',
            1;

    IF NOT EXISTS (SELECT 1 FROM dbo.stg_Neumonia)
        THROW 50002,
            N'stg_Neumonia está vacía. Ejecute sp_Ingestar_CSV primero.',
            1;

    INSERT INTO dbo.log_EjecucionETL
    (
        Proceso,
        Fuente,
        Archivo,
        Estado
    )
    VALUES
    (
        N'sp_Validar_Neumonia',
        'NEUMONIA',
        N'stg_Neumonia',
        'EN_CURSO'
    );

    SET @IdEjecucion = CONVERT(INT, SCOPE_IDENTITY());

    BEGIN TRY

        IF OBJECT_ID('tempdb..#T') IS NOT NULL
            DROP TABLE #T;

        IF OBJECT_ID('tempdb..#N') IS NOT NULL
            DROP TABLE #N;

        /* 1. Limpieza de espacios y conversión de vacíos a NULL. */

        SELECT
            IdFila,
            NULLIF(LTRIM(RTRIM(FECHA_CORTE)), N'') AS FECHA_CORTE,
            NULLIF(LTRIM(RTRIM(DEPARTAMENTEO)), N'') AS DEPARTAMENTEO,
            NULLIF(LTRIM(RTRIM(PROVINCIA)), N'') AS PROVINCIA,
            NULLIF(LTRIM(RTRIM(DISTRITO)), N'') AS DISTRITO,
            NULLIF(LTRIM(RTRIM(UBIGEO)), N'') AS UBIGEO,
            NULLIF(LTRIM(RTRIM(E_SALUD)), N'') AS E_SALUD,
            NULLIF(LTRIM(RTRIM(ESTABLECIMIENTO)), N'') AS ESTABLECIMIENTO,
            NULLIF(LTRIM(RTRIM(ANO)), N'') AS ANO,
            NULLIF(LTRIM(RTRIM(SEMANA)), N'') AS SEMANA,
            NULLIF(LTRIM(RTRIM(MES)), N'') AS MES,
            NULLIF(LTRIM(RTRIM(NEU_2_11M)), N'') AS NEU_2_11M,
            NULLIF(LTRIM(RTRIM(NEU_1_4A)), N'') AS NEU_1_4A,
            NULLIF(LTRIM(RTRIM(NEU_5_9A)), N'') AS NEU_5_9A,
            NULLIF(LTRIM(RTRIM(NEU_10_19A)), N'') AS NEU_10_19A,
            NULLIF(LTRIM(RTRIM(NEU_20_59A)), N'') AS NEU_20_59A,
            NULLIF(LTRIM(RTRIM(NEU_60A)), N'') AS NEU_60A
        INTO #T
        FROM dbo.stg_Neumonia;

        /* 2. Conversión de tipos de datos. */

        SELECT
            t.IdFila,

            CASE
                WHEN COALESCE(
                    t.FECHA_CORTE,
                    t.DEPARTAMENTEO,
                    t.PROVINCIA,
                    t.DISTRITO,
                    t.UBIGEO,
                    t.E_SALUD,
                    t.ESTABLECIMIENTO,
                    t.ANO,
                    t.SEMANA,
                    t.MES,
                    t.NEU_2_11M,
                    t.NEU_1_4A,
                    t.NEU_5_9A,
                    t.NEU_10_19A,
                    t.NEU_20_59A,
                    t.NEU_60A
                ) IS NULL THEN 1
                ELSE 0
            END AS EsVacia,

            TRY_CONVERT(DATE, t.FECHA_CORTE, 112) AS FechaCorte,
            t.DEPARTAMENTEO AS Departamento,
            t.PROVINCIA AS Provincia,
            t.DISTRITO AS Distrito,
            t.UBIGEO AS UbigeoOriginal,
            dbo.fn_NormalizarUbigeo(t.UBIGEO) AS Ubigeo,
            t.E_SALUD AS CodEstablecimiento,
            t.ESTABLECIMIENTO AS Establecimiento,
            TRY_CONVERT(SMALLINT, t.ANO) AS Anio,
            TRY_CONVERT(SMALLINT, t.SEMANA) AS Semana,
            t.MES AS Mes,
            TRY_CONVERT(INT, t.NEU_2_11M) AS C1,
            TRY_CONVERT(INT, t.NEU_1_4A) AS C2,
            TRY_CONVERT(INT, t.NEU_5_9A) AS C3,
            TRY_CONVERT(INT, t.NEU_10_19A) AS C4,
            TRY_CONVERT(INT, t.NEU_20_59A) AS C5,
            TRY_CONVERT(INT, t.NEU_60A) AS C6,
            CAST(NULL AS VARCHAR(10)) AS Rechazo
        INTO #N
        FROM #T AS t;

        /* 3. Validaciones y clasificación de errores. */

        UPDATE #N
        SET Rechazo =
            CASE
                WHEN EsVacia = 1 THEN 'N00'
                WHEN CodEstablecimiento IS NULL THEN 'N01'
                WHEN Ubigeo IS NULL THEN 'N02'
                WHEN Anio IS NULL
                  OR Semana IS NULL
                  OR Semana NOT BETWEEN 1 AND 53
                  OR Anio NOT BETWEEN 2000 AND YEAR(GETDATE())
                    THEN 'N03'
                WHEN C1 IS NULL OR C2 IS NULL OR C3 IS NULL
                  OR C4 IS NULL OR C5 IS NULL OR C6 IS NULL
                  OR C1 < 0 OR C2 < 0 OR C3 < 0
                  OR C4 < 0 OR C5 < 0 OR C6 < 0
                    THEN 'N04'
                WHEN FechaCorte IS NULL THEN 'N05'
                ELSE NULL
            END;

        /* 4. Duplicados dentro del archivo: se conserva la primera fila. */

        UPDATE n
        SET n.Rechazo = 'N06'
        FROM #N AS n
        INNER JOIN
        (
            SELECT
                IdFila,
                ROW_NUMBER() OVER
                (
                    PARTITION BY
                        CodEstablecimiento,
                        Anio,
                        Semana,
                        Ubigeo
                    ORDER BY IdFila
                ) AS rn
            FROM #N
            WHERE Rechazo IS NULL
        ) AS d
            ON d.IdFila = n.IdFila
        WHERE d.rn > 1;

        /* 5. Registros que ya existen en la tabla validada. */

        UPDATE n
        SET n.Rechazo = 'N07'
        FROM #N AS n
        WHERE n.Rechazo IS NULL
          AND EXISTS
          (
              SELECT 1
              FROM dbo.Neumonia_Validada AS v
              WHERE v.CodEstablecimiento = n.CodEstablecimiento
                AND v.Anio = n.Anio
                AND v.Semana = n.Semana
                AND v.Ubigeo = n.Ubigeo
          );

        /* 6. Indicadores de calidad. */

        SELECT
            @Leidas = COUNT(*),
            @Vacias = COALESCE(SUM(EsVacia), 0)
        FROM #N;

        SELECT @Pc03 = COUNT(*)
        FROM #N
        WHERE Rechazo IS NULL
          AND Departamento = N'PIURA'
          AND Provincia NOT IN
          (
              N'PIURA', N'SULLANA', N'AYABACA',
              N'HUANCABAMBA', N'MORROPON',
              N'PAITA', N'SECHURA', N'TALARA'
          );

        SELECT @Pc04 = COUNT(*)
        FROM #N
        WHERE Rechazo IS NULL
          AND LEN(UbigeoOriginal) = 5;

        SELECT @Pc05 = COUNT(*)
        FROM #N
        WHERE Rechazo IS NULL
          AND C1 = 0 AND C2 = 0 AND C3 = 0
          AND C4 = 0 AND C5 = 0 AND C6 = 0;

        SELECT @Pc06 = COUNT(*)
        FROM
        (
            SELECT
                COUNT(*) OVER
                (
                    PARTITION BY CodEstablecimiento, Anio, Semana
                ) AS c
            FROM #N
            WHERE Rechazo IS NULL
        ) AS x
        WHERE x.c > 1;

        SELECT @Pc08 = COUNT(*)
        FROM
        (
            SELECT Establecimiento
            FROM #N
            WHERE Rechazo IS NULL
            GROUP BY Establecimiento
            HAVING COUNT(DISTINCT CodEstablecimiento) > 1
        ) AS x;

        BEGIN TRANSACTION;

        /* FASE A: registro de calidad y excepciones. */

        INSERT INTO dbo.log_CalidadDatos
        (
            IdEjecucion,
            CodigoRegla,
            Descripcion,
            Fuente,
            Cantidad
        )
        SELECT
            @IdEjecucion,
            v.Codigo,
            v.Descripcion,
            'NEUMONIA',
            v.Cantidad
        FROM
        (
            VALUES
                ('PC-01', N'Filas completamente vacías', @Vacias),
                ('PC-02', N'Filas vacías adicionales', CASE WHEN @Vacias > 1 THEN @Vacias - 1 ELSE 0 END),
                ('PC-03', N'Departamento Piura con provincia de otra región', @Pc03),
                ('PC-04', N'UBIGEO de 5 caracteres corregido con cero a la izquierda', @Pc04),
                ('PC-05', N'Filas con los 6 grupos etarios en cero', @Pc05),
                ('PC-06', N'Filas con igual establecimiento y semana y distinto UBIGEO', @Pc06),
                ('PC-08', N'Nombres de establecimiento con más de un código', @Pc08)
        ) AS v (Codigo, Descripcion, Cantidad);

        INSERT INTO dbo.ExcepcionesDatos
        (
            IdEjecucion,
            Fuente,
            IdFilaStg,
            ClaveOrigen,
            CodigoRegla,
            Detalle,
            Accion
        )
        SELECT
            @IdEjecucion,
            'NEUMONIA',
            n.IdFila,
            LEFT(
                CONCAT(
                    n.CodEstablecimiento, N'|',
                    n.Anio, N'|',
                    n.Semana, N'|',
                    n.UbigeoOriginal
                ),
                100
            ),
            n.Rechazo,
            CASE n.Rechazo
                WHEN 'N01' THEN N'Sin código de establecimiento (E_SALUD)'
                WHEN 'N02' THEN N'UBIGEO vacío o con caracteres no numéricos'
                WHEN 'N03' THEN N'Año o semana fuera de rango'
                WHEN 'N04' THEN N'Casos no numéricos o negativos'
                WHEN 'N05' THEN N'Fecha de corte inválida'
                WHEN 'N06' THEN N'Clave duplicada dentro del archivo'
                WHEN 'N07' THEN N'Registro ya cargado anteriormente'
            END,
            'RECHAZADO'
        FROM #N AS n
        WHERE n.Rechazo IS NOT NULL
          AND n.Rechazo <> 'N00'

        UNION ALL

        SELECT
            @IdEjecucion,
            'NEUMONIA',
            n.IdFila,
            LEFT(
                CONCAT(
                    n.CodEstablecimiento, N'|',
                    n.Anio, N'|',
                    n.Semana, N'|',
                    n.UbigeoOriginal
                ),
                100
            ),
            'PC-03',
            N'Departamento Piura con provincia fuera de Piura; revisar contra la fuente',
            'REVISAR'
        FROM #N AS n
        WHERE n.Rechazo IS NULL
          AND n.Departamento = N'PIURA'
          AND n.Provincia NOT IN
          (
              N'PIURA', N'SULLANA', N'AYABACA',
              N'HUANCABAMBA', N'MORROPON',
              N'PAITA', N'SECHURA', N'TALARA'
          );

        /* Guarda el diagnóstico antes de intentar la carga. */
        SAVE TRANSACTION sv_FaseA;

        /* FASE B: carga de registros válidos. */

        BEGIN TRY

            INSERT INTO dbo.Neumonia_Validada
            (
                IdEjecucion,
                IdFilaStg,
                FechaCorte,
                Departamento,
                Provincia,
                Distrito,
                Ubigeo,
                CodEstablecimiento,
                Establecimiento,
                Anio,
                Semana,
                Mes,
                NEU_2_11M,
                NEU_1_4A,
                NEU_5_9A,
                NEU_10_19A,
                NEU_20_59A,
                NEU_60A
            )
            SELECT
                @IdEjecucion,
                n.IdFila,
                n.FechaCorte,
                n.Departamento,
                n.Provincia,
                n.Distrito,
                n.Ubigeo,
                n.CodEstablecimiento,
                n.Establecimiento,
                n.Anio,
                n.Semana,
                n.Mes,
                n.C1,
                n.C2,
                n.C3,
                n.C4,
                n.C5,
                n.C6
            FROM #N AS n
            WHERE n.Rechazo IS NULL;

            IF @SimularFalloCarga = 1
                THROW 50099,
                    N'Fallo simulado en la fase de carga (prueba de SAVEPOINT).',
                    1;

            SELECT @Cargadas = COUNT(*)
            FROM dbo.Neumonia_Validada
            WHERE IdEjecucion = @IdEjecucion;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() = 1
            BEGIN
                ROLLBACK TRANSACTION sv_FaseA;

                SET @ErrorCarga = LEFT(ERROR_MESSAGE(), 4000);
                SET @Cargadas = 0;
            END
            ELSE
            BEGIN
                THROW;
            END

        END CATCH;

        COMMIT TRANSACTION;

        /* Se cuentan únicamente las filas que realmente fueron rechazadas
           por las reglas de validación, no las válidas afectadas por un
           fallo simulado de carga. */

        SELECT @Rechazadas = COUNT(*)
        FROM #N
        WHERE Rechazo IS NOT NULL;

        SET @Estado =
            CASE
                WHEN @ErrorCarga IS NULL THEN 'OK'
                ELSE 'ERROR_CARGA'
            END;

        UPDATE dbo.log_EjecucionETL
        SET
            FechaFin = SYSDATETIME(),
            FilasLeidas = @Leidas,
            FilasCargadas = @Cargadas,
            FilasRechazadas = @Rechazadas,
            Estado = @Estado,
            Mensaje = COALESCE(
                @ErrorCarga,
                N'Validación y carga completadas.'
            )
        WHERE IdEjecucion = @IdEjecucion;

    END TRY
    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        UPDATE dbo.log_EjecucionETL
        SET
            FechaFin = SYSDATETIME(),
            Estado = 'ERROR',
            Mensaje = LEFT(ERROR_MESSAGE(), 4000)
        WHERE IdEjecucion = @IdEjecucion;

        THROW;
    END CATCH
END;
GO


/* =====================================================================
   PROCEDIMIENTO 3: sp_Validar_RENIPRESS
   Valida los datos de establecimientos de salud.
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.sp_Validar_RENIPRESS
    @FechaCorte DATE = NULL,
    @SimularFalloCarga BIT = 0,
    @IdEjecucion INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE
        @Leidas INT,
        @Vacias INT,
        @Cargadas INT = 0,
        @Rechazadas INT,
        @Pc09 INT,
        @Pc10 INT,
        @Pc11 INT,
        @Pc12 INT,
        @Pc14 INT,
        @ErrorCarga NVARCHAR(4000) = NULL,
        @Estado VARCHAR(20);

    IF @@TRANCOUNT > 0
        THROW 50001,
            N'Ejecute el procedimiento fuera de una transacción abierta.',
            1;

    IF NOT EXISTS (SELECT 1 FROM dbo.stg_RENIPRESS)
        THROW 50002,
            N'stg_RENIPRESS está vacía. Ejecute sp_Ingestar_CSV primero.',
            1;

    SET @FechaCorte =
        COALESCE(@FechaCorte, CAST(GETDATE() AS DATE));

    INSERT INTO dbo.log_EjecucionETL
    (
        Proceso,
        Fuente,
        Archivo,
        Estado
    )
    VALUES
    (
        N'sp_Validar_RENIPRESS',
        'RENIPRESS',
        N'stg_RENIPRESS',
        'EN_CURSO'
    );

    SET @IdEjecucion = CONVERT(INT, SCOPE_IDENTITY());

    BEGIN TRY

        IF OBJECT_ID('tempdb..#T') IS NOT NULL
            DROP TABLE #T;

        IF OBJECT_ID('tempdb..#R') IS NOT NULL
            DROP TABLE #R;

        /* 1. Limpieza de espacios. */

        SELECT
            IdFila,
            NULLIF(LTRIM(RTRIM(INSTITUCION)), N'') AS INSTITUCION,
            NULLIF(LTRIM(RTRIM(COD_IPRESS)), N'') AS COD_IPRESS,
            NULLIF(LTRIM(RTRIM(NOMBRE)), N'') AS NOMBRE,
            NULLIF(LTRIM(RTRIM(CLASIFICACION)), N'') AS CLASIFICACION,
            NULLIF(LTRIM(RTRIM(TIPO_ESTABLECIMIENTO)), N'') AS TIPO_ESTABLECIMIENTO,
            NULLIF(LTRIM(RTRIM(DEPARTAMENTO)), N'') AS DEPARTAMENTO,
            NULLIF(LTRIM(RTRIM(PROVINCIA)), N'') AS PROVINCIA,
            NULLIF(LTRIM(RTRIM(DISTRITO)), N'') AS DISTRITO,
            NULLIF(LTRIM(RTRIM(UBIGEO)), N'') AS UBIGEO,
            NULLIF(LTRIM(RTRIM(DIRECCION)), N'') AS DIRECCION,
            NULLIF(LTRIM(RTRIM(CO_DISA)), N'') AS CO_DISA,
            NULLIF(LTRIM(RTRIM(COD_RED)), N'') AS COD_RED,
            NULLIF(LTRIM(RTRIM(COD_MICRORRED)), N'') AS COD_MICRORRED,
            NULLIF(LTRIM(RTRIM(DISA)), N'') AS DISA,
            NULLIF(LTRIM(RTRIM(RED)), N'') AS RED,
            NULLIF(LTRIM(RTRIM(MICRORED)), N'') AS MICRORED,
            NULLIF(LTRIM(RTRIM(COD_UE)), N'') AS COD_UE,
            NULLIF(LTRIM(RTRIM(UNIDAD_EJECUTORA)), N'') AS UNIDAD_EJECUTORA,
            NULLIF(LTRIM(RTRIM(CATEGORIA)), N'') AS CATEGORIA,
            NULLIF(LTRIM(RTRIM(TELEFONO)), N'') AS TELEFONO,
            NULLIF(LTRIM(RTRIM(HORARIO)), N'') AS HORARIO,
            NULLIF(LTRIM(RTRIM(INICIO_ACTIVIDAD)), N'') AS INICIO_ACTIVIDAD,
            NULLIF(LTRIM(RTRIM(ESTADO)), N'') AS ESTADO,
            NULLIF(LTRIM(RTRIM(NORTE)), N'') AS NORTE,
            NULLIF(LTRIM(RTRIM(ESTE)), N'') AS ESTE,
            NULLIF(LTRIM(RTRIM(IMAGEN_1)), N'') AS IMAGEN_1,
            NULLIF(LTRIM(RTRIM(FE_ACT_IMAGEN_1)), N'') AS FE_ACT_IMAGEN_1,
            NULLIF(LTRIM(RTRIM(IMAGEN_2)), N'') AS IMAGEN_2,
            NULLIF(LTRIM(RTRIM(FE_ACT_IMAGEN_2)), N'') AS FE_ACT_IMAGEN_2,
            NULLIF(LTRIM(RTRIM(IMAGEN_3)), N'') AS IMAGEN_3,
            NULLIF(LTRIM(RTRIM(FE_ACT_IMAGEN_3)), N'') AS FE_ACT_IMAGEN_3
        INTO #T
        FROM dbo.stg_RENIPRESS;

        /* 2. Conversión y preparación de campos. */

        SELECT
            x.*,

            CASE
                WHEN x.InicioTxt IS NOT NULL
                 AND
                 (
                     x.InicioDate IS NULL
                     OR x.InicioDate < '19000101'
                     OR x.InicioDate > @FechaCorte
                 )
                THEN 1
                ELSE 0
            END AS FechaInvalida,

            CASE
                WHEN x.Latitud IS NULL OR x.Longitud IS NULL
                    THEN 0
                WHEN x.Latitud BETWEEN -18.5 AND -0.01
                 AND x.Longitud BETWEEN -81.5 AND -68.5
                    THEN 0
                ELSE 1
            END AS CoordFuera

        INTO #R
        FROM
        (
            SELECT
                t.IdFila,

                CASE
                    WHEN COALESCE(
                        t.INSTITUCION,
                        t.COD_IPRESS,
                        t.NOMBRE,
                        t.CLASIFICACION,
                        t.TIPO_ESTABLECIMIENTO,
                        t.DEPARTAMENTO,
                        t.PROVINCIA,
                        t.DISTRITO,
                        t.UBIGEO,
                        t.DIRECCION,
                        t.CO_DISA,
                        t.COD_RED,
                        t.COD_MICRORRED,
                        t.DISA,
                        t.RED,
                        t.MICRORED,
                        t.COD_UE,
                        t.UNIDAD_EJECUTORA,
                        t.CATEGORIA,
                        t.TELEFONO,
                        t.HORARIO,
                        t.INICIO_ACTIVIDAD,
                        t.ESTADO,
                        t.NORTE,
                        t.ESTE,
                        t.IMAGEN_1,
                        t.FE_ACT_IMAGEN_1,
                        t.IMAGEN_2,
                        t.FE_ACT_IMAGEN_2,
                        t.IMAGEN_3,
                        t.FE_ACT_IMAGEN_3
                    ) IS NULL THEN 1
                    ELSE 0
                END AS EsVacia,

                t.COD_IPRESS AS CodIpress,
                t.INSTITUCION AS Institucion,
                t.NOMBRE AS Nombre,
                t.CLASIFICACION AS Clasificacion,
                t.TIPO_ESTABLECIMIENTO AS TipoEstablecimiento,
                t.DEPARTAMENTO AS Departamento,
                t.PROVINCIA AS Provincia,
                t.DISTRITO AS Distrito,
                dbo.fn_NormalizarUbigeo(t.UBIGEO) AS Ubigeo,
                t.DIRECCION AS Direccion,
                t.DISA AS Disa,
                t.RED AS Red,
                t.MICRORED AS Microred,
                t.CATEGORIA AS Categoria,
                t.INICIO_ACTIVIDAD AS InicioTxt,

                TRY_CONVERT(
                    DATE,
                    LEFT(t.INICIO_ACTIVIDAD, 10),
                    23
                ) AS InicioDate,

                t.ESTADO AS Estado,

                TRY_CONVERT(
                    DECIMAL(12,8),
                    t.NORTE
                ) AS Latitud,

                TRY_CONVERT(
                    DECIMAL(12,8),
                    t.ESTE
                ) AS Longitud,

                CAST(NULL AS VARCHAR(10)) AS Rechazo

            FROM #T AS t
        ) AS x;

        /* 3. Reglas de rechazo.
           R03 se rechaza porque Nombre es obligatorio en la tabla destino. */

        UPDATE #R
        SET Rechazo =
            CASE
                WHEN EsVacia = 1 THEN 'R00'
                WHEN CodIpress IS NULL
                  OR CodIpress LIKE '%[^0-9]%'
                  OR LEN(CodIpress) <> 8
                    THEN 'R01'
                WHEN Nombre IS NULL THEN 'R03'
                WHEN Ubigeo IS NULL THEN 'R04'
                ELSE NULL
            END;

        /* 4. Duplicados dentro del archivo. */

        UPDATE r
        SET r.Rechazo = 'R02'
        FROM #R AS r
        INNER JOIN
        (
            SELECT
                IdFila,
                ROW_NUMBER() OVER
                (
                    PARTITION BY CodIpress
                    ORDER BY IdFila
                ) AS rn
            FROM #R
            WHERE Rechazo IS NULL
        ) AS d
            ON d.IdFila = r.IdFila
        WHERE d.rn > 1;

        /* 5. Registros que ya existen. */

        UPDATE r
        SET r.Rechazo = 'R05'
        FROM #R AS r
        WHERE r.Rechazo IS NULL
          AND EXISTS
          (
              SELECT 1
              FROM dbo.RENIPRESS_Validada AS v
              WHERE v.CodIpress = r.CodIpress
          );

        /* 6. Indicadores de calidad. */

        SELECT
            @Leidas = COUNT(*),
            @Vacias = COALESCE(SUM(EsVacia), 0)
        FROM #R;

        /* Se considera sin coordenadas si falta cualquiera de las dos. */
        SELECT @Pc09 = COUNT(*)
        FROM #R
        WHERE Rechazo IS NULL
          AND (Latitud IS NULL OR Longitud IS NULL);

        SELECT @Pc10 = COUNT(*)
        FROM #R
        WHERE Rechazo = 'R03';

        SELECT @Pc11 = COUNT(*)
        FROM #R
        WHERE Rechazo IS NULL
          AND FechaInvalida = 1;

        SELECT @Pc12 = COUNT(*)
        FROM #R
        WHERE Rechazo IS NULL
          AND Estado IS NOT NULL
          AND UPPER(Estado) <> N'ACTIVO';

        SELECT @Pc14 = COUNT(*)
        FROM #R
        WHERE Rechazo IS NULL
          AND CoordFuera = 1;

        BEGIN TRANSACTION;

        /* FASE A: registro de calidad y excepciones. */

        INSERT INTO dbo.log_CalidadDatos
        (
            IdEjecucion,
            CodigoRegla,
            Descripcion,
            Fuente,
            Cantidad
        )
        SELECT
            @IdEjecucion,
            v.Codigo,
            v.Descripcion,
            'RENIPRESS',
            v.Cantidad
        FROM
        (
            VALUES
                ('PC-01', N'Filas completamente vacías', @Vacias),
                ('PC-09', N'Establecimientos sin coordenadas completas', @Pc09),
                ('PC-10', N'Establecimientos sin nombre, rechazados', @Pc10),
                ('PC-11', N'Fecha de inicio de actividad inválida', @Pc11),
                ('PC-12', N'Establecimientos que no están en estado ACTIVO', @Pc12),
                ('PC-14', N'Coordenadas fuera del territorio de Perú', @Pc14)
        ) AS v (Codigo, Descripcion, Cantidad);

        INSERT INTO dbo.ExcepcionesDatos
        (
            IdEjecucion,
            Fuente,
            IdFilaStg,
            ClaveOrigen,
            CodigoRegla,
            Detalle,
            Accion
        )
        SELECT
            @IdEjecucion,
            'RENIPRESS',
            r.IdFila,
            LEFT(r.CodIpress, 100),
            CASE
                WHEN r.Rechazo = 'R03' THEN 'PC-10'
                ELSE r.Rechazo
            END,
            CASE r.Rechazo
                WHEN 'R01' THEN N'COD_IPRESS vacío o sin 8 dígitos'
                WHEN 'R02' THEN N'COD_IPRESS duplicado dentro del archivo'
                WHEN 'R03' THEN N'Establecimiento sin NOMBRE; registro rechazado'
                WHEN 'R04' THEN N'UBIGEO vacío o inválido'
                WHEN 'R05' THEN N'Registro ya cargado anteriormente'
            END,
            'RECHAZADO'
        FROM #R AS r
        WHERE r.Rechazo IS NOT NULL
          AND r.Rechazo <> 'R00'

        UNION ALL

        SELECT
            @IdEjecucion,
            'RENIPRESS',
            r.IdFila,
            LEFT(r.CodIpress, 100),
            'PC-11',
            N'INICIO_ACTIVIDAD inválida; se guardó en NULL: '
                + COALESCE(r.InicioTxt, N''),
            'REVISAR'
        FROM #R AS r
        WHERE r.Rechazo IS NULL
          AND r.FechaInvalida = 1

        UNION ALL

        SELECT
            @IdEjecucion,
            'RENIPRESS',
            r.IdFila,
            LEFT(r.CodIpress, 100),
            'PC-14',
            N'Coordenadas fuera de Perú; se guardaron en NULL',
            'REVISAR'
        FROM #R AS r
        WHERE r.Rechazo IS NULL
          AND r.CoordFuera = 1;

        SAVE TRANSACTION sv_FaseA;

        /* FASE B: carga de registros válidos. */

        BEGIN TRY

            INSERT INTO dbo.RENIPRESS_Validada
            (
                CodIpress,
                IdEjecucion,
                Institucion,
                Nombre,
                Clasificacion,
                TipoEstablecimiento,
                Departamento,
                Provincia,
                Distrito,
                Ubigeo,
                Direccion,
                Disa,
                Red,
                Microred,
                Categoria,
                InicioActividad,
                Estado,
                Latitud,
                Longitud
            )
            SELECT
                r.CodIpress,
                @IdEjecucion,
                r.Institucion,
                r.Nombre,
                r.Clasificacion,
                r.TipoEstablecimiento,
                r.Departamento,
                r.Provincia,
                r.Distrito,
                r.Ubigeo,
                r.Direccion,
                r.Disa,
                r.Red,
                r.Microred,
                r.Categoria,

                CASE
                    WHEN r.FechaInvalida = 1 THEN NULL
                    ELSE r.InicioDate
                END,

                r.Estado,

                CASE
                    WHEN r.CoordFuera = 1 THEN NULL
                    ELSE r.Latitud
                END,

                CASE
                    WHEN r.CoordFuera = 1 THEN NULL
                    ELSE r.Longitud
                END

            FROM #R AS r
            WHERE r.Rechazo IS NULL;

            IF @SimularFalloCarga = 1
                THROW 50099,
                    N'Fallo simulado en la fase de carga (prueba de SAVEPOINT).',
                    1;

            SELECT @Cargadas = COUNT(*)
            FROM dbo.RENIPRESS_Validada
            WHERE IdEjecucion = @IdEjecucion;

        END TRY
        BEGIN CATCH

            IF XACT_STATE() = 1
            BEGIN
                ROLLBACK TRANSACTION sv_FaseA;

                SET @ErrorCarga = LEFT(ERROR_MESSAGE(), 4000);
                SET @Cargadas = 0;
            END
            ELSE
            BEGIN
                THROW;
            END

        END CATCH;

        COMMIT TRANSACTION;

        SELECT @Rechazadas = COUNT(*)
        FROM #R
        WHERE Rechazo IS NOT NULL;

        SET @Estado =
            CASE
                WHEN @ErrorCarga IS NULL THEN 'OK'
                ELSE 'ERROR_CARGA'
            END;

        UPDATE dbo.log_EjecucionETL
        SET
            FechaFin = SYSDATETIME(),
            FilasLeidas = @Leidas,
            FilasCargadas = @Cargadas,
            FilasRechazadas = @Rechazadas,
            Estado = @Estado,
            Mensaje = COALESCE(
                @ErrorCarga,
                N'Validación y carga completadas.'
            )
        WHERE IdEjecucion = @IdEjecucion;

    END TRY
    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        UPDATE dbo.log_EjecucionETL
        SET
            FechaFin = SYSDATETIME(),
            Estado = 'ERROR',
            Mensaje = LEFT(ERROR_MESSAGE(), 4000)
        WHERE IdEjecucion = @IdEjecucion;

        THROW;
    END CATCH
END;
GO
