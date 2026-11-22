FROM python:3.12-slim
RUN pip install --no-cache-dir "pyiceberg[pyarrow]==0.12.0" duckdb==2.0.1 boto3==1.44.9 requests==2.34.2 trino==0.340.0 numpy==2.3.5 \
 && python -c "import duckdb; c=duckdb.connect(); [c.execute(f'INSTALL {e}') for e in ('iceberg','httpfs','avro')]"
WORKDIR /lab
