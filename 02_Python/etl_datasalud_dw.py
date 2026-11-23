"""
DataSalud Perú - ETL hacia SQL Server
Lee los CSV originales, transforma los datos y carga DataSalud_DW.

Estructura esperada:
DataSalud_Peru/
├── datasets/
│   ├── DatasetNeumonia_actual_0.csv
│   └── RENIPRESS_30-10-2026.csv
├── python/
│   └── etl_datasalud_dw.py
└── logs/
"""

from pathlib import Path
from datetime import datetime
import logging
import re
import unicodedata

import pandas as pd
from sqlalchemy import create_engine, text
from urllib.parse import quote_plus


# ------------------------------------------------------------
# 1. CONFIGURACIÓN
# ------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent
DATASETS = ROOT / "datasets"
LOGS = ROOT / "logs"
LOGS.mkdir(parents=True, exist_ok=True)

CSV_NEUMONIA = DATASETS / "DatasetNeumonia_actual_0.csv"
CSV_RENIPRESS = DATASETS / "RENIPRESS_30-10-2026.csv"

SERVIDOR = r"(localdb)\MSSQLLocalDB"
BASE_DATOS = "DataSalud_DW"
DRIVER = "ODBC Driver 18 for SQL Server"

# Fecha de corte que figura en el informe del proyecto.
FECHA_CORTE = pd.Timestamp("2026-10-30")

ARCHIVO_LOG = LOGS / "etl_datasalud_dw.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[
        logging.FileHandler(ARCHIVO_LOG, encoding="utf-8"),
        logging.StreamHandler()
    ],
)
logger = logging.getLogger("DataSalud_ETL")


def crear_engine():
    """Crea la conexión SQLAlchemy usando autenticación de Windows."""
    cadena = (
        f"DRIVER={{{DRIVER}}};"
        f"SERVER={SERVIDOR};"
        f"DATABASE={BASE_DATOS};"
        "Trusted_Connection=yes;"
        "TrustServerCertificate=yes;"
    )
    url = "mssql+pyodbc:///?odbc_connect=" + quote_plus(cadena)
    return create_engine(url, fast_executemany=True)


def normalizar_texto(valor):
    """Quita espacios extremos y devuelve texto en mayúsculas sin tildes."""
    if pd.isna(valor):
        return None
    texto = str(valor).strip()
    if not texto:
        return None
    texto = unicodedata.normalize("NFKD", texto)
    texto = "".join(c for c in texto if not unicodedata.combining(c))
    texto = re.sub(r"\s+", " ", texto)
    return texto.upper()


def limpiar_columnas(df):
    """Recorta espacios en todas las columnas de texto."""
    df.columns = [str(c).strip().replace("\ufeff", "") for c in df.columns]
    for col in df.columns:
        df[col] = df[col].astype("string").str.strip()
        df[col] = df[col].replace("", pd.NA)
    return df


def verificar_archivos():
    faltantes = [p for p in [CSV_NEUMONIA, CSV_RENIPRESS] if not p.exists()]
    if faltantes:
        detalle = "\n".join(str(p) for p in faltantes)
        raise FileNotFoundError(
            "No se encontraron estos archivos. Verifica que estén dentro "
            f"de la carpeta datasets:\n{detalle}"
        )


# ------------------------------------------------------------
# 2. EXTRACCIÓN
# ------------------------------------------------------------

def extraer_datos():
    logger.info("E01 - Leyendo archivo de neumonía")
    neumonia = pd.read_csv(
        CSV_NEUMONIA,
        sep=",",
        encoding="utf-8-sig",
        dtype="string",
        keep_default_na=False,
    )
    neumonia = limpiar_columnas(neumonia)

    logger.info("E02 - Leyendo archivo RENIPRESS")
    renipress = pd.read_csv(
        CSV_RENIPRESS,
        sep=";",
        encoding="utf-8-sig",
        dtype="string",
        keep_default_na=False,
    )
    renipress = limpiar_columnas(renipress)

    logger.info(
        "Filas leídas: neumonía=%s | RENIPRESS=%s",
        len(neumonia), len(renipress)
    )
    return neumonia, renipress


# ------------------------------------------------------------
# 3. LIMPIEZA Y VALIDACIÓN DE NEUMONÍA
# ------------------------------------------------------------

COLUMNAS_CASOS = [
    "NEU_2_11M",
    "NEU_1_4A",
    "NEU_5_9A",
    "NEU_10_19A",
    "NEU_20_59A",
    "NEU_60A",
]

MAPA_GRUPOS = {
    "NEU_2_11M": (1, "2 a 11 meses", "Menores de 5"),
    "NEU_1_4A": (2, "1 a 4 años", "Menores de 5"),
    "NEU_5_9A": (3, "5 a 9 años", "Escolares"),
    "NEU_10_19A": (4, "10 a 19 años", "Escolares"),
    "NEU_20_59A": (5, "20 a 59 años", "Adultos"),
    "NEU_60A": (6, "60 años a más", "Adultos mayores"),
}


def transformar_neumonia(df):
    requeridas = [
        "UBIGEO", "E_SALUD", "ESTABLECIMIENTO", "DEPARTAMENTEO",
        "PROVINCIA", "DISTRITO", "ANO", "SEMANA", "MES",
        *COLUMNAS_CASOS
    ]
    faltan = [c for c in requeridas if c not in df.columns]
    if faltan:
        raise ValueError(f"Faltan columnas en el CSV de neumonía: {faltan}")

    filas_leidas = len(df)

    # Identificador de la línea del CSV (la primera fila de datos es la 2).
    df = df.copy()
    df["IdFilaOrigen"] = range(2, filas_leidas + 2)

    # PC-01: descartar filas completamente vacías.
    vacia = df.drop(columns=["IdFilaOrigen"]).isna().all(axis=1)
    descartadas_vacias = int(vacia.sum())
    df = df.loc[~vacia].copy()

    # Normalización de códigos y campos.
    for c in ["UBIGEO", "E_SALUD"]:
        df[c] = df[c].astype("string").str.strip()

    # PC-04: completar UBIGEO de cinco dígitos con cero inicial.
    df["UBIGEO"] = df["UBIGEO"].str.replace(r"\.0$", "", regex=True)
    df["UBIGEO"] = df["UBIGEO"].str.zfill(6)

    # Validar campos obligatorios y UBIGEO.
    ubigeo_ok = df["UBIGEO"].str.fullmatch(r"\d{6}").fillna(False)
    codigo_ok = df["E_SALUD"].str.fullmatch(r"\d{6}[A-Za-z]\d{3}").fillna(False)
    anio = pd.to_numeric(df["ANO"], errors="coerce")
    semana = pd.to_numeric(df["SEMANA"], errors="coerce")

    casos = df[COLUMNAS_CASOS].apply(pd.to_numeric, errors="coerce")
    casos_ok = casos.notna().all(axis=1) & casos.ge(0).all(axis=1)

    valida = (
        ubigeo_ok
        & codigo_ok
        & anio.between(1900, 2100)
        & semana.between(1, 53)
        & casos_ok
    )

    rechazadas = int((~valida).sum())
    df = df.loc[valida].copy()
    casos = casos.loc[valida].copy()

    df["ANO"] = pd.to_numeric(df["ANO"]).astype(int)
    df["SEMANA"] = pd.to_numeric(df["SEMANA"]).astype(int)
    for c in COLUMNAS_CASOS:
        df[c] = pd.to_numeric(df[c]).astype("int64")

    # El grano de origen es establecimiento x semana x UBIGEO.
    clave_origen = ["E_SALUD", "ANO", "SEMANA", "UBIGEO"]
    if df.duplicated(clave_origen).any():
        duplicados = int(df.duplicated(clave_origen).sum())
        raise ValueError(
            f"Se encontraron {duplicados} claves duplicadas en neumonía. "
            "No se cargarán hechos hasta revisar el grano."
        )

    logger.info(
        "Neumonía: leídas=%s | vacías descartadas=%s | "
        "rechazadas por validación=%s | válidas=%s",
        filas_leidas, descartadas_vacias, rechazadas, len(df)
    )
    return df, descartadas_vacias, rechazadas


# ------------------------------------------------------------
# 4. LIMPIEZA Y VALIDACIÓN DE RENIPRESS
# ------------------------------------------------------------

def transformar_renipress(df):
    requeridas = [
        "COD_IPRESS", "NOMBRE", "DEPARTAMENTO", "PROVINCIA",
        "DISTRITO", "UBIGEO", "ESTADO", "NORTE", "ESTE",
        "INICIO_ACTIVIDAD"
    ]
    faltan = [c for c in requeridas if c not in df.columns]
    if faltan:
        raise ValueError(f"Faltan columnas en RENIPRESS: {faltan}")

    filas_leidas = len(df)
    df = df.copy()

    df["COD_IPRESS"] = df["COD_IPRESS"].astype("string").str.strip()
    df["UBIGEO"] = df["UBIGEO"].astype("string").str.strip().str.zfill(6)

    # PC-10: los registros sin nombre no ingresan a dim_ipress.
    sin_nombre = df["NOMBRE"].isna() | df["NOMBRE"].astype("string").str.strip().eq("")
    rechazadas_nombre = int(sin_nombre.sum())
    df = df.loc[~sin_nombre].copy()

    codigo_ok = df["COD_IPRESS"].str.fullmatch(r"\d{8}").fillna(False)
    ubigeo_ok = df["UBIGEO"].str.fullmatch(r"\d{6}").fillna(False)
    codigo_unico = ~df["COD_IPRESS"].duplicated(keep=False)
    valida = codigo_ok & ubigeo_ok & codigo_unico

    rechazadas_codigo = int((~valida).sum())
    df = df.loc[valida].copy()

    # PC-09 y PC-14: coordenadas ausentes o fuera de Perú quedan NULL.
    lat = pd.to_numeric(df["NORTE"], errors="coerce")
    lon = pd.to_numeric(df["ESTE"], errors="coerce")

    coordenadas_completas = lat.notna() & lon.notna()
    dentro_peru = (
        lat.between(-18.5, 0)
        & lon.between(-82, -68)
    )
    coordenadas_validas = coordenadas_completas & dentro_peru

    coordenadas_invalidas = int((coordenadas_completas & ~dentro_peru).sum())
    df["Latitud"] = lat.where(coordenadas_validas, pd.NA)
    df["Longitud"] = lon.where(coordenadas_validas, pd.NA)

    # PC-11: se identifican fechas inválidas; la tabla dim_ipress no tiene
    # columna de fecha de inicio, por lo que no se cargan al modelo físico.
    fecha_inicio = pd.to_datetime(df["INICIO_ACTIVIDAD"], errors="coerce")
    fecha_invalida = (
        fecha_inicio.isna()
        | (fecha_inicio < pd.Timestamp("1900-01-01"))
        | (fecha_inicio > FECHA_CORTE)
    )
    fechas_invalidadas = int(fecha_invalida.sum())

    logger.info(
        "RENIPRESS: leídas=%s | sin nombre rechazadas=%s | "
        "otros códigos/UBIGEO rechazados=%s | válidas=%s | "
        "coordenadas fuera de rango anuladas=%s | fechas inválidas identificadas=%s",
        filas_leidas, rechazadas_nombre, rechazadas_codigo, len(df),
        coordenadas_invalidas, fechas_invalidadas
    )
    return df, rechazadas_nombre + rechazadas_codigo, coordenadas_invalidas, fechas_invalidadas


# ------------------------------------------------------------
# 5. CONSTRUCCIÓN DE DIMENSIONES Y HECHOS
# ------------------------------------------------------------

def construir_modelo(neu, ren):
    # DIMENSIÓN TIEMPO: 35 combinaciones año-semana del archivo.
    tiempo = neu[["ANO", "SEMANA", "MES"]].drop_duplicates().copy()
    tiempo["TiempoKey"] = tiempo["ANO"] * 100 + tiempo["SEMANA"]

    meses = {
        "enero": 1, "febrero": 2, "marzo": 3, "abril": 4,
        "mayo": 5, "junio": 6, "julio": 7, "agosto": 8,
        "setiembre": 9, "septiembre": 9, "octubre": 10,
        "noviembre": 11, "diciembre": 12,
    }
    numero_mes = tiempo["MES"].astype("string").str.lower().map(meses)
    if numero_mes.isna().any():
        desconocidos = tiempo.loc[numero_mes.isna(), "MES"].unique().tolist()
        raise ValueError(f"Meses no reconocidos en neumonía: {desconocidos}")

    tiempo["Trimestre"] = ((numero_mes.astype(int) - 1) // 3 + 1).astype(int)
    tiempo["EsPeriodoParcial"] = tiempo["SEMANA"].eq(35)
    dim_tiempo = tiempo[
        ["TiempoKey", "ANO", "SEMANA", "MES", "Trimestre", "EsPeriodoParcial"]
    ].rename(columns={"ANO": "Anio", "SEMANA": "Semana"})

    # DIMENSIÓN GEOGRAFÍA: RENIPRESS es la referencia por UBIGEO.
    geo = ren[["UBIGEO", "DEPARTAMENTO", "PROVINCIA", "DISTRITO"]].copy()
    geo = geo.drop_duplicates(subset=["UBIGEO"], keep="first")
    dim_geografia = geo.rename(columns={
        "UBIGEO": "GeografiaKey",
        "DEPARTAMENTO": "Departamento",
        "PROVINCIA": "Provincia",
        "DISTRITO": "Distrito",
    })
    dim_geografia["EsPiura"] = (
        dim_geografia["Departamento"].astype("string").str.upper().eq("PIURA")
    )

    # Verificar que todos los UBIGEO de neumonía existan en la referencia.
    ubigeos_ref = set(dim_geografia["GeografiaKey"].astype(str))
    ubigeos_neu = set(neu["UBIGEO"].astype(str))
    faltantes_geo = sorted(ubigeos_neu - ubigeos_ref)
    if faltantes_geo:
        raise ValueError(
            "Hay UBIGEO de neumonía sin correspondencia en RENIPRESS: "
            f"{faltantes_geo[:10]}"
        )

    # DIMENSIÓN GRUPO ETARIO.
    dim_grupo = pd.DataFrame([
        {
            "GrupoEtarioKey": key,
            "GrupoEtario": nombre,
            "GrupoAmplio": amplio,
        }
        for key, nombre, amplio in MAPA_GRUPOS.values()
    ])

    # DIMENSIÓN ESTABLECIMIENTO: no se fuerza unión con COD_IPRESS.
    estab = neu[["E_SALUD", "ESTABLECIMIENTO"]].drop_duplicates(
        subset=["E_SALUD"], keep="first"
    ).copy()
    dim_establecimiento = estab.rename(columns={
        "E_SALUD": "EstablecimientoKey",
        "ESTABLECIMIENTO": "Nombre",
    })
    dim_establecimiento["NombreNormalizado"] = (
        dim_establecimiento["Nombre"].map(normalizar_texto)
    )
    dim_establecimiento["IpressKey"] = None

    # DIMENSIÓN IPRESS: solo registros RENIPRESS con nombre.
    dim_ipress = ren[[
        "COD_IPRESS", "NOMBRE", "DEPARTAMENTO", "PROVINCIA",
        "DISTRITO", "UBIGEO", "ESTADO", "Latitud", "Longitud"
    ]].copy()
    dim_ipress = dim_ipress.rename(columns={
        "COD_IPRESS": "IpressKey",
        "NOMBRE": "Nombre",
        "DEPARTAMENTO": "Departamento",
        "PROVINCIA": "Provincia",
        "DISTRITO": "Distrito",
        "UBIGEO": "Ubigeo",
    })

    # HECHOS: transformar las seis columnas de edades a filas.
    identificadores = [
        "E_SALUD", "ANO", "SEMANA", "UBIGEO", "IdFilaOrigen"
    ]
    hechos = neu[identificadores + COLUMNAS_CASOS].melt(
        id_vars=identificadores,
        value_vars=COLUMNAS_CASOS,
        var_name="ColumnaGrupo",
        value_name="Casos",
    )

    hechos["GrupoEtarioKey"] = hechos["ColumnaGrupo"].map(
        {col: datos[0] for col, datos in MAPA_GRUPOS.items()}
    )
    hechos["TiempoKey"] = hechos["ANO"] * 100 + hechos["SEMANA"]

    hechos = hechos.rename(columns={
        "E_SALUD": "EstablecimientoKey",
        "UBIGEO": "GeografiaKey",
    })

    hechos["Casos"] = pd.to_numeric(hechos["Casos"], errors="raise").astype("int64")
    hechos["GrupoEtarioKey"] = hechos["GrupoEtarioKey"].astype("int64")
    hechos["TiempoKey"] = hechos["TiempoKey"].astype("int64")
    hechos["IdFilaOrigen"] = hechos["IdFilaOrigen"].astype("int64")

    dim_hechos = hechos[[
        "EstablecimientoKey", "TiempoKey", "GeografiaKey",
        "GrupoEtarioKey", "Casos", "IdFilaOrigen"
    ]].copy()

    # Verificaciones antes de tocar SQL Server.
    if len(dim_tiempo) != 35:
        logger.warning("Se esperaban 35 semanas; se encontraron %s", len(dim_tiempo))
    if len(dim_geografia) != 1891:
        logger.warning("Se esperaban 1,891 geografías; se encontraron %s", len(dim_geografia))
    if len(dim_establecimiento) != 447:
        logger.warning("Se esperaban 447 establecimientos; se encontraron %s", len(dim_establecimiento))
    if len(dim_ipress) != 36226:
        logger.warning("Se esperaban 36,226 IPRESS; se encontraron %s", len(dim_ipress))

    clave_hecho = [
        "EstablecimientoKey", "TiempoKey", "GeografiaKey", "GrupoEtarioKey"
    ]
    if dim_hechos.duplicated(clave_hecho).any():
        raise ValueError("La tabla de hechos contiene claves duplicadas.")

    total_casos = int(dim_hechos["Casos"].sum())
    logger.info(
        "Modelo preparado: tiempo=%s | geografía=%s | grupos=%s | "
        "establecimientos=%s | IPRESS=%s | hechos=%s | casos=%s",
        len(dim_tiempo), len(dim_geografia), len(dim_grupo),
        len(dim_establecimiento), len(dim_ipress),
        len(dim_hechos), total_casos
    )

    if len(dim_hechos) != len(neu) * 6:
        raise ValueError("La cantidad de hechos no coincide con filas de neumonía x 6.")
    if total_casos != 6230:
        logger.warning(
            "El total de casos (%s) difiere de las 6,230 registradas en el informe.",
            total_casos
        )

    return {
        "dim_tiempo": dim_tiempo,
        "dim_geografia": dim_geografia,
        "dim_grupo_etario": dim_grupo,
        "dim_establecimiento": dim_establecimiento,
        "dim_ipress": dim_ipress,
        "fact_casos_neumonia": dim_hechos,
    }


# ------------------------------------------------------------
# 6. CARGA TRANSACCIONAL Y AUDITORÍA
# ------------------------------------------------------------

def ejecutar_carga(engine, tablas, filas_leidas, filas_cargadas, filas_rechazadas,
                   mensaje):
    # Se crea el registro inicial fuera de la transacción de carga.
    with engine.begin() as conn:
        id_log = conn.execute(
            text("""
                INSERT INTO dbo.log_ETL_DW
                    (Proceso, FechaInicio, Estado, Mensaje)
                OUTPUT INSERTED.IdLog
                VALUES
                    (:proceso, SYSDATETIME(), 'EN_PROCESO', :mensaje)
            """),
            {
                "proceso": "ETL_DataSalud_Python",
                "mensaje": "Inicio de carga desde CSV a SQL Server."
            }
        ).scalar_one()

    try:
        # Si cualquier inserción falla, se revierte toda la carga.
        with engine.begin() as conn:
            # Eliminar primero hechos y luego dimensiones.
            orden_borrado = [
                "fact_casos_neumonia",
                "dim_establecimiento",
                "dim_tiempo",
                "dim_geografia",
                "dim_grupo_etario",
                "dim_ipress",
            ]
            for tabla in orden_borrado:
                conn.execute(text(f"DELETE FROM dbo.{tabla}"))
                logger.info("Tabla preparada para recarga: %s", tabla)

            # Cargar dimensiones antes de la tabla de hechos.
            orden_carga = [
                "dim_tiempo",
                "dim_geografia",
                "dim_grupo_etario",
                "dim_establecimiento",
                "dim_ipress",
                "fact_casos_neumonia",
            ]

            for tabla in orden_carga:
                df = tablas[tabla]
                df.to_sql(
                    name=tabla,
                    con=conn,
                    schema="dbo",
                    if_exists="append",
                    index=False,
                    chunksize=1000,
                    method=None,
                )
                logger.info("Cargada %s: %s filas", tabla, len(df))

            # Reconciliación en SQL Server.
            resultado = conn.execute(text("""
                SELECT
                    (SELECT COUNT(*) FROM dbo.dim_tiempo) AS Tiempo,
                    (SELECT COUNT(*) FROM dbo.dim_geografia) AS Geografia,
                    (SELECT COUNT(*) FROM dbo.dim_grupo_etario) AS GrupoEtario,
                    (SELECT COUNT(*) FROM dbo.dim_establecimiento) AS Establecimiento,
                    (SELECT COUNT(*) FROM dbo.dim_ipress) AS Ipress,
                    (SELECT COUNT(*) FROM dbo.fact_casos_neumonia) AS Hechos,
                    (SELECT COALESCE(SUM(Casos), 0)
                     FROM dbo.fact_casos_neumonia) AS TotalCasos
            """)).mappings().one()

            logger.info("Reconciliación SQL Server: %s", dict(resultado))

            # Actualizar el log dentro de la misma transacción de carga.
            conn.execute(
                text("""
                    UPDATE dbo.log_ETL_DW
                    SET FechaFin = SYSDATETIME(),
                        FilasLeidas = :leidas,
                        FilasCargadas = :cargadas,
                        FilasRechazadas = :rechazadas,
                        Estado = 'OK',
                        Mensaje = :mensaje
                    WHERE IdLog = :id
                """),
                {
                    "leidas": filas_leidas,
                    "cargadas": filas_cargadas,
                    "rechazadas": filas_rechazadas,
                    "mensaje": mensaje,
                    "id": id_log,
                }
            )

        logger.info("ETL finalizado correctamente. IdLog=%s", id_log)

    except Exception as exc:
        # La carga se revierte; se registra el error en una transacción aparte.
        logger.exception("Error durante la carga ETL")
        try:
            with engine.begin() as conn:
                conn.execute(
                    text("""
                        UPDATE dbo.log_ETL_DW
                        SET FechaFin = SYSDATETIME(),
                            FilasLeidas = :leidas,
                            FilasCargadas = 0,
                            FilasRechazadas = :rechazadas,
                            Estado = 'ERROR',
                            Mensaje = :mensaje
                        WHERE IdLog = :id
                    """),
                    {
                        "leidas": filas_leidas,
                        "rechazadas": filas_rechazadas,
                        "mensaje": str(exc)[:1900],
                        "id": id_log,
                    }
                )
        except Exception:
            logger.exception("No se pudo actualizar el registro de error en el log.")
        raise


# ------------------------------------------------------------
# 7. PROGRAMA PRINCIPAL
# ------------------------------------------------------------

def main():
    inicio = datetime.now()
    logger.info("=" * 65)
    logger.info("INICIO ETL DATASALUD PERÚ")
    logger.info("Carpeta del proyecto: %s", ROOT)

    verificar_archivos()
    engine = crear_engine()

    # Comprobar conexión y base de datos.
    with engine.connect() as conn:
        base = conn.execute(text("SELECT DB_NAME()")).scalar_one()
        logger.info("Conectado correctamente a SQL Server: %s", base)

    neu_raw, ren_raw = extraer_datos()

    neu, neu_vacias, neu_rechazadas = transformar_neumonia(neu_raw)
    ren, ren_rechazadas, coords_invalidas, fechas_invalidas = transformar_renipress(ren_raw)

    tablas = construir_modelo(neu, ren)

    filas_leidas = len(neu_raw) + len(ren_raw)
    filas_rechazadas = neu_vacias + neu_rechazadas + ren_rechazadas
    filas_cargadas = len(neu) + len(ren)

    mensaje = (
        f"Neumonía válidas: {len(neu)}; filas vacías descartadas: {neu_vacias}; "
        f"neumonía rechazadas: {neu_rechazadas}. "
        f"RENIPRESS válidas: {len(ren)}; rechazadas: {ren_rechazadas}. "
        f"Coordenadas fuera de rango anuladas: {coords_invalidas}; "
        f"fechas inválidas identificadas: {fechas_invalidas}. "
        f"Hechos generados: {len(tablas['fact_casos_neumonia'])}; "
        f"total de casos: {int(tablas['fact_casos_neumonia']['Casos'].sum())}. "
        "FilasCargadas del log representa registros fuente aceptados "
        "(neumonía + RENIPRESS); el número de hechos transformados se detalla aquí."
    )

    ejecutar_carga(
        engine,
        tablas,
        filas_leidas,
        filas_cargadas,
        filas_rechazadas,
        mensaje,
    )

    with engine.connect() as conn:
        print("\nRESUMEN FINAL EN SQL SERVER")
        resumen = conn.execute(text("""
            SELECT 'dim_tiempo' AS Tabla, COUNT(*) AS Registros
            FROM dbo.dim_tiempo
            UNION ALL SELECT 'dim_geografia', COUNT(*) FROM dbo.dim_geografia
            UNION ALL SELECT 'dim_grupo_etario', COUNT(*) FROM dbo.dim_grupo_etario
            UNION ALL SELECT 'dim_establecimiento', COUNT(*) FROM dbo.dim_establecimiento
            UNION ALL SELECT 'dim_ipress', COUNT(*) FROM dbo.dim_ipress
            UNION ALL SELECT 'fact_casos_neumonia', COUNT(*) FROM dbo.fact_casos_neumonia
        """)).all()

        for tabla, cantidad in resumen:
            print(f"{tabla}: {cantidad:,}")

        total = conn.execute(
            text("SELECT COALESCE(SUM(Casos), 0) FROM dbo.fact_casos_neumonia")
        ).scalar_one()
        print(f"Total de casos: {total:,}")

        log = conn.execute(text("""
            SELECT TOP 1 IdLog, Estado, FilasLeidas, FilasCargadas,
                         FilasRechazadas, Mensaje
            FROM dbo.log_ETL_DW
            ORDER BY IdLog DESC
        """)).mappings().one()
        print("\nÚltimo registro ETL:")
        print(dict(log))

    logger.info("Duración total: %s", datetime.now() - inicio)
    logger.info("ETL COMPLETADO")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("\nEL ETL NO SE COMPLETÓ.")
        print("Revisa el mensaje de error y el archivo logs/etl_datasalud_dw.log")
        print(error)
        raise
