import sys
from awsglue.utils import getResolvedOptions
from pyspark.sql import SparkSession
from pyspark.sql.types import StructType, StructField, StringType
from pyspark.sql.functions import col, to_timestamp, to_date, lit, when

def get_optional_arg(argv, name, default=None):
    flag = f"--{name}"
    if flag in argv:
        i = argv.index(flag)
        if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
            return argv[i + 1]
    return default

spark = SparkSession.builder.getOrCreate()

# Required args only
required = ["bucket", "raw_prefix", "curated_prefix", "quarantine_prefix"]
args = getResolvedOptions(sys.argv, required)

bucket = args["bucket"]
raw_prefix = args["raw_prefix"]
curated_prefix = args["curated_prefix"]
quarantine_prefix = args["quarantine_prefix"]

# Optional args
ingest_date = get_optional_arg(sys.argv, "ingest_date", default=None)

RAW_BASE = f"s3://{bucket}/{raw_prefix}"
CURATED_BASE = f"s3://{bucket}/{curated_prefix}"
QUAR_BASE = f"s3://{bucket}/{quarantine_prefix}"

raw_path = RAW_BASE if not ingest_date else f"{RAW_BASE}ingest_date={ingest_date}/"
quarantine_path = QUAR_BASE if not ingest_date else f"{QUAR_BASE}ingest_date={ingest_date}/"

print(f"[CONFIG] raw_path={raw_path}")
print(f"[CONFIG] curated_out={CURATED_BASE}")
print(f"[CONFIG] quarantine_out={quarantine_path}")

# Schema enforcement
schema = StructType([
    StructField("event_id", StringType(), True),
    StructField("user_id", StringType(), True),
    StructField("event_type", StringType(), True),
    StructField("event_ts", StringType(), True),
    StructField("page", StringType(), True),
    StructField("device", StringType(), True),
])

raw_df = spark.read.schema(schema).json(raw_path)

# Parse timestamps; invalid -> null
df = raw_df.withColumn("event_ts_parsed", to_timestamp(col("event_ts")))
df = df.withColumn("event_date", to_date(col("event_ts_parsed")))

# Required fields
is_valid = (
    col("event_id").isNotNull() &
    col("user_id").isNotNull() &
    col("event_ts_parsed").isNotNull()
)

df_valid = df.where(is_valid)
df_invalid = df.where(~is_valid)

# Null handling
df_valid = df_valid.withColumn(
    "event_type",
    when(col("event_type").isNull(), lit("unknown")).otherwise(col("event_type"))
)

# Deduplication (simple): one row per event_id
df_dedup = df_valid.dropDuplicates(["event_id"])

final_df = df_dedup.select(
    "event_id",
    "user_id",
    "event_type",
    col("event_ts_parsed").alias("event_ts"),
    "page",
    "device",
    "event_date"
)

print("[INFO] Writing curated Parquet partitioned by event_date...")
(final_df
 .write
 .mode("append")
 .partitionBy("event_date")
 .parquet(CURATED_BASE)
)

print("[INFO] Writing quarantine JSON (invalid records)...")
(df_invalid
 .write
 .mode("overwrite")
 .json(quarantine_path)
)

print("[DONE] ETL completed.")
