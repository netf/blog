#!/usr/bin/env bash
# spark-submit with the pinned Iceberg 1.12.0 jars (Spark 4.1 runtime + AWS bundle).
exec /opt/spark/bin/spark-submit \
  --jars /opt/lakegate-jars/iceberg-spark-runtime-4.1_2.13-1.12.0.jar,/opt/lakegate-jars/iceberg-aws-bundle-1.12.0.jar \
  --driver-memory 1g --conf spark.ui.enabled=false "$@"
