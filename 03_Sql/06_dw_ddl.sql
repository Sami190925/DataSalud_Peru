
/* =========================================================
   DATASALUD PERÚ - PASO 5
   Base de datos: DataSalud_DW
   ========================================================= */

IF DB_ID('DataSalud_DW') IS NULL
    CREATE DATABASE DataSalud_DW;
GO

USE DataSalud_DW;
GO

/* 1. DIMENSIÓN TIEMPO */
CREATE TABLE dbo.dim_tiempo (
    TiempoKey INT NOT NULL PRIMARY KEY,
    Anio SMALLINT NOT NULL,
    Semana TINYINT NOT NULL,
    Mes NVARCHAR(20) NULL,
    Trimestre TINYINT NULL,
    EsPeriodoParcial BIT NOT NULL DEFAULT 0,
    CONSTRAINT UQ_dim_tiempo UNIQUE (Anio, Semana)
);
GO

/* 2. DIMENSIÓN GEOGRAFÍA */
CREATE TABLE dbo.dim_geografia (
    GeografiaKey CHAR(6) NOT NULL PRIMARY KEY,
    Departamento NVARCHAR(60) NULL,
    Provincia NVARCHAR(60) NULL,
    Distrito NVARCHAR(100) NULL,
    EsPiura BIT NOT NULL DEFAULT 0
);
GO

/* 3. DIMENSIÓN GRUPO ETARIO */
CREATE TABLE dbo.dim_grupo_etario (
    GrupoEtarioKey TINYINT NOT NULL PRIMARY KEY,
    GrupoEtario NVARCHAR(50) NOT NULL,
    GrupoAmplio NVARCHAR(50) NULL
);
GO

/* 4. DIMENSIÓN ESTABLECIMIENTO */
CREATE TABLE dbo.dim_establecimiento (
    EstablecimientoKey VARCHAR(10) NOT NULL PRIMARY KEY,
    Nombre NVARCHAR(200) NULL,
    NombreNormalizado NVARCHAR(200) NULL,
    IpressKey VARCHAR(8) NULL
);
GO

/* 5. DIMENSIÓN IPRESS */
CREATE TABLE dbo.dim_ipress (
    IpressKey VARCHAR(8) NOT NULL PRIMARY KEY,
    Nombre NVARCHAR(200) NOT NULL,
    Departamento NVARCHAR(60) NULL,
    Provincia NVARCHAR(60) NULL,
    Distrito NVARCHAR(100) NULL,
    Ubigeo CHAR(6) NULL,
    Estado NVARCHAR(60) NULL,
    Latitud DECIMAL(12,8) NULL,
    Longitud DECIMAL(12,8) NULL
);
GO

/* 6. TABLA DE HECHOS */
CREATE TABLE dbo.fact_casos_neumonia (
    EstablecimientoKey VARCHAR(10) NOT NULL,
    TiempoKey INT NOT NULL,
    GeografiaKey CHAR(6) NOT NULL,
    GrupoEtarioKey TINYINT NOT NULL,
    Casos BIGINT NOT NULL DEFAULT 0,
    IdFilaOrigen INT NULL,

    CONSTRAINT PK_fact_casos_neumonia
        PRIMARY KEY (
            EstablecimientoKey,
            TiempoKey,
            GeografiaKey,
            GrupoEtarioKey
        ),

    CONSTRAINT FK_fact_establecimiento
        FOREIGN KEY (EstablecimientoKey)
        REFERENCES dbo.dim_establecimiento(EstablecimientoKey),

    CONSTRAINT FK_fact_tiempo
        FOREIGN KEY (TiempoKey)
        REFERENCES dbo.dim_tiempo(TiempoKey),

    CONSTRAINT FK_fact_geografia
        FOREIGN KEY (GeografiaKey)
        REFERENCES dbo.dim_geografia(GeografiaKey),

    CONSTRAINT FK_fact_grupo
        FOREIGN KEY (GrupoEtarioKey)
        REFERENCES dbo.dim_grupo_etario(GrupoEtarioKey),

    CONSTRAINT CK_fact_casos
        CHECK (Casos >= 0)
);
GO

/* 7. TABLA DE REGISTRO ETL */
CREATE TABLE dbo.log_ETL_DW (
    IdLog INT IDENTITY(1,1) PRIMARY KEY,
    Proceso NVARCHAR(100) NOT NULL,
    FechaInicio DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    FechaFin DATETIME2 NULL,
    FilasLeidas INT NULL,
    FilasCargadas INT NULL,
    FilasRechazadas INT NULL,
    Estado VARCHAR(20) NOT NULL,
    Mensaje NVARCHAR(2000) NULL
);
GO

/* 8. ÍNDICES DE APOYO */
CREATE INDEX IX_fact_tiempo
ON dbo.fact_casos_neumonia(TiempoKey);

CREATE INDEX IX_fact_geografia
ON dbo.fact_casos_neumonia(GeografiaKey);

CREATE INDEX IX_fact_grupo
ON dbo.fact_casos_neumonia(GrupoEtarioKey);

CREATE INDEX IX_fact_establecimiento
ON dbo.fact_casos_neumonia(EstablecimientoKey);
GO

/* 9. VERIFICACIÓN DE CREACIÓN */
SELECT
    TABLE_NAME AS Tabla_Creada
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE'
ORDER BY TABLE_NAME;
GO

USE DataSalud_DW;
GO

SELECT COUNT(*) AS TotalTablas
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE = 'BASE TABLE';

SELECT * FROM dbo.log_ETL_DW;
