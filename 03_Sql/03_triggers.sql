
/* =====================================================================
   DataSalud Perú - CIIN1021P
   Archivo 03: Triggers de auditoría e integridad
   ===================================================================== */

USE DataSalud;
GO

/* ================================================================
   TRIGGER 1: AUDITORÍA
   Registra INSERT, UPDATE y DELETE en Neumonia_Validada.
   ================================================================ */

CREATE OR ALTER TRIGGER dbo.trg_Neumonia_Auditoria
ON dbo.Neumonia_Validada
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted)
       AND NOT EXISTS (SELECT 1 FROM deleted)
        RETURN;

    INSERT INTO dbo.log_Auditoria
    (
        Tabla,
        Operacion,
        IdRegistro,
        DatosAnteriores,
        DatosNuevos
    )
    SELECT
        N'Neumonia_Validada',
        CASE
            WHEN i.IdNeumonia IS NOT NULL
             AND d.IdNeumonia IS NOT NULL THEN 'UPDATE'
            WHEN i.IdNeumonia IS NOT NULL THEN 'INSERT'
            ELSE 'DELETE'
        END,
        COALESCE(i.IdNeumonia, d.IdNeumonia),

        CASE
            WHEN d.IdNeumonia IS NULL THEN NULL
            ELSE CONCAT(
                N'Est=', d.CodEstablecimiento,
                N'; Anio=', d.Anio,
                N'; Sem=', d.Semana,
                N'; Ubigeo=', d.Ubigeo,
                N'; Casos=', d.NEU_2_11M, N'/',
                d.NEU_1_4A, N'/',
                d.NEU_5_9A, N'/',
                d.NEU_10_19A, N'/',
                d.NEU_20_59A, N'/',
                d.NEU_60A
            )
        END,

        CASE
            WHEN i.IdNeumonia IS NULL THEN NULL
            ELSE CONCAT(
                N'Est=', i.CodEstablecimiento,
                N'; Anio=', i.Anio,
                N'; Sem=', i.Semana,
                N'; Ubigeo=', i.Ubigeo,
                N'; Casos=', i.NEU_2_11M, N'/',
                i.NEU_1_4A, N'/',
                i.NEU_5_9A, N'/',
                i.NEU_10_19A, N'/',
                i.NEU_20_59A, N'/',
                i.NEU_60A
            )
        END
    FROM inserted AS i
    FULL OUTER JOIN deleted AS d
        ON i.IdNeumonia = d.IdNeumonia;
END;
GO

/* ================================================================
   TRIGGER 2: INTEGRIDAD
   Impide registrar casos negativos, semanas inválidas, años
   incorrectos, códigos vacíos y UBIGEO inválidos.
   ================================================================ */

CREATE OR ALTER TRIGGER dbo.trg_Neumonia_Integridad
ON dbo.Neumonia_Validada
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM inserted)
        RETURN;

    DECLARE @v TABLE
    (
        IdNeumonia INT,
        Motivo NVARCHAR(200)
    );

    INSERT INTO @v (IdNeumonia, Motivo)
    SELECT
        i.IdNeumonia,
        CASE
            WHEN i.NEU_2_11M < 0
              OR i.NEU_1_4A < 0
              OR i.NEU_5_9A < 0
              OR i.NEU_10_19A < 0
              OR i.NEU_20_59A < 0
              OR i.NEU_60A < 0
                THEN N'Casos negativos'

            WHEN i.Semana NOT BETWEEN 1 AND 53
                THEN N'Semana fuera del rango 1-53'

            WHEN i.Anio NOT BETWEEN 2000 AND YEAR(GETDATE())
                THEN N'Año fuera del rango permitido'

            WHEN LEN(LTRIM(RTRIM(i.CodEstablecimiento))) = 0
                THEN N'Código de establecimiento vacío'

            WHEN LEN(LTRIM(RTRIM(i.Ubigeo))) <> 6
                THEN N'UBIGEO debe contener seis dígitos'

            WHEN i.Ubigeo LIKE N'%[^0-9]%'
                THEN N'UBIGEO con caracteres no numéricos'
        END
    FROM inserted AS i;

    DELETE FROM @v
    WHERE Motivo IS NULL;

    IF EXISTS (SELECT 1 FROM @v)
    BEGIN
        DECLARE @n INT =
            (SELECT COUNT(*) FROM @v);

        DECLARE @msg NVARCHAR(400) =
            CONCAT(
                N'Integridad violada en Neumonia_Validada: ',
                @n,
                N' fila(s) rechazada(s). Primer motivo: ',
                (
                    SELECT TOP (1) Motivo
                    FROM @v
                    ORDER BY IdNeumonia
                )
            );

        /* Deshace la operación que intentó insertar el dato inválido. */
        ROLLBACK TRANSACTION;

        /* Registra el intento rechazado después del rollback. */
        INSERT INTO dbo.log_Auditoria
        (
            Tabla,
            Operacion,
            IdRegistro,
            Detalle
        )
        SELECT
            N'Neumonia_Validada',
            'RECHAZO',
            v.IdNeumonia,
            v.Motivo
        FROM @v AS v;

        THROW 50020, @msg, 1;
    END
END;
GO
