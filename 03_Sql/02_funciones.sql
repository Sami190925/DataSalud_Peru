
/* =====================================================================
   DataSalud Perú - CIIN1021P
   Archivo 02: Funciones reutilizables
   ===================================================================== */

USE DataSalud;
GO

CREATE OR ALTER FUNCTION dbo.fn_NormalizarUbigeo
(
    @Ubigeo NVARCHAR(50)
)
RETURNS CHAR(6)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @u NVARCHAR(50) = LTRIM(RTRIM(@Ubigeo));

    IF @u IS NULL OR @u = N''
        RETURN NULL;

    IF @u LIKE N'%[^0-9]%'
        RETURN NULL;

    IF LEN(@u) > 6
        RETURN NULL;

    RETURN RIGHT(N'000000' + @u, 6);
END;
GO

/* Calcula los casos por grupo etario dentro de un rango
   de semanas y un año determinado. */

CREATE OR ALTER FUNCTION dbo.fn_CasosPorGrupoEtario
(
    @Anio SMALLINT,
    @SemanaDesde SMALLINT,
    @SemanaHasta SMALLINT
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        g.Orden,
        g.GrupoEtario,
        SUM(CAST(g.Casos AS BIGINT)) AS TotalCasos
    FROM dbo.Neumonia_Validada AS n
    CROSS APPLY
    (
        VALUES
            (1, N'2 a 11 meses',  n.NEU_2_11M),
            (2, N'1 a 4 años',    n.NEU_1_4A),
            (3, N'5 a 9 años',    n.NEU_5_9A),
            (4, N'10 a 19 años',  n.NEU_10_19A),
            (5, N'20 a 59 años',  n.NEU_20_59A),
            (6, N'60 años a más', n.NEU_60A)
    ) AS g (Orden, GrupoEtario, Casos)
    WHERE n.Anio = @Anio
      AND n.Semana BETWEEN @SemanaDesde AND @SemanaHasta
    GROUP BY
        g.Orden,
        g.GrupoEtario
);
GO
