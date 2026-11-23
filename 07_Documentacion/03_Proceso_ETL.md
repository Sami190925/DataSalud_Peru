# Proceso ETL - DataSalud Perú

## 1. Objetivo
Describir el proceso de extracción, transformación y carga de información realizado mediante el script `Python/etl_datasalud_dw.py`.

## 2. Ubicación de los archivos
- Script ETL: `Python/etl_datasalud_dw.py`
- Archivos de entrada: carpeta `01_datasets`
- Destino del Data Warehouse: base de datos `DataSalud_DW`

## 3. Etapas del proceso

### 3.1 Extracción
El proceso obtiene la información desde los archivos CSV disponibles en la carpeta `datasets`, relacionados con neumonía y RENIPRESS.

### 3.2 Transformación
El script aplica las operaciones de preparación y transformación definidas en el código, con el propósito de adecuar los datos para su almacenamiento.

### 3.3 Carga
La información preparada se carga en SQL Server, dentro del entorno del Data Warehouse.

### 3.4 Verificación
Se revisa que la carga se haya realizado y se comprueba la cantidad de registros almacenados. Durante el desarrollo se verificó que `fact_casos_neumonia` contenía 73,020 registros.

## 4. Ejecución
Desde una terminal, ubicarse en la carpeta del proyecto y ejecutar el script con Python, utilizando el entorno y las dependencias configuradas:

```bash
python Python/etl_datasalud_dw.py
```

La ejecución exacta puede variar según la configuración local de Python y SQL Server.

## 5. Observaciones
Registrar aquí cualquier incidencia real encontrada durante la ejecución, por ejemplo, problemas de conexión, formato de CSV o permisos de carga. No incluir errores que no hayan ocurrido.
