# Conclusiones - DataSalud Perú

1. El proyecto permitió integrar herramientas con diferentes funciones: Python para el proceso ETL, SQL Server para el almacenamiento relacional, MongoDB para el trabajo documental, Spark para el procesamiento y Power BI para la visualización.

2. El uso de un Data Warehouse permitió organizar la información para su consulta y análisis. Durante la verificación se observó que la tabla `fact_casos_neumonia` contenía 73,020 registros.

3. MongoDB permitió trabajar con una estructura NoSQL mediante la base `DataSalud_NoSQL` y las colecciones `renipress` y `neumonia_piura`.

4. PySpark permitió realizar operaciones de agrupación utilizando DataFrames y RDD. Los tiempos medidos corresponden al entorno de prueba utilizado y no deben interpretarse como una conclusión universal sobre el rendimiento de ambas alternativas.

5. Power BI facilitó la presentación de la información mediante visualizaciones e indicadores que permiten explorar los datos.

