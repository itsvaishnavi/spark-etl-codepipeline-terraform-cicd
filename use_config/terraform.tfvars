region = "us-east-1"
env    = "use1"

github_repo_id = "itsvaishnavi/spark-etl-codepipeline-terraform-cicd"

artifact_bucket_name = "your-unique-artifact-bucket-use1-123456"
scripts_bucket_name  = "your-unique-scripts-bucket-use1-123456"

test_bucket = "your-test-data-bucket-use1"
main_bucket = "your-prod-data-bucket-use1"

create_buckets = true

enable_prod_schedule_trigger = false
