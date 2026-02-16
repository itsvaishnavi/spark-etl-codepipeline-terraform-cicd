import os
import json
import re
import boto3

glue = boto3.client("glue")
JOB_NAME = os.environ["GLUE_JOB_NAME"]

def handler(event, context):
    for record in event.get("Records", []):
        key = record["s3"]["object"]["key"]

        # Extract ingest_date=YYYY-MM-DD if present
        m = re.search(r"ingest_date=(\d{4}-\d{2}-\d{2})", key)
        args = {}
        if m:
            args["--ingest_date"] = m.group(1)

        resp = glue.start_job_run(JobName=JOB_NAME, Arguments=args)
        print(json.dumps({
            "started": True,
            "jobRunId": resp["JobRunId"],
            "key": key,
            "args": args
        }))
