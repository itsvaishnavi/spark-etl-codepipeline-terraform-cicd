terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

############################
# VARIABLES
############################
variable "region" {
  type    = string
  default = "us-east-1"
}

# IMPORTANT: Use different env per stack, e.g. use1 vs euc1
# to avoid IAM name collisions (IAM is GLOBAL).
variable "env" {
  type    = string
  default = "use1"
}

variable "github_repo_id" {
  type        = string
  description = "GitHub repo in the form org/repo"
}

# CodePipeline artifact store bucket (S3 bucket names are GLOBAL)
variable "artifact_bucket_name" {
  type        = string
  description = "Globally unique S3 bucket for CodePipeline artifacts"
}

# Bucket where pipelines will deploy Glue scripts
variable "scripts_bucket_name" {
  type        = string
  description = "Globally unique S3 bucket for deployed Glue scripts"
}

# Data buckets used by Glue jobs (you can reuse existing buckets from any region,
# but best practice is same region as Glue. If you reuse EU buckets from USE1,
# expect latency/cost.)
variable "test_bucket" {
  type        = string
  description = "S3 bucket name holding test raw/curated data"
}

variable "main_bucket" {
  type        = string
  description = "S3 bucket name holding prod raw/curated data"
}

# Optional: create artifact/scripts buckets (set false if already exist)
variable "create_buckets" {
  type    = bool
  default = true
}

# Optional: create prod schedule trigger
variable "enable_prod_schedule_trigger" {
  type    = bool
  default = false
}

variable "prod_schedule_cron" {
  type    = string
  default = "cron(0 2 * * ? *)"
}

############################
# PROVIDER / DATA
############################
provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  project_prefix = "glue-etl-${var.env}"

  # Glue script locations deployed by pipelines
  test_script_s3 = "s3://${var.scripts_bucket_name}/glue-scripts/test/user_events_etl.py"
  prod_script_s3 = "s3://${var.scripts_bucket_name}/glue-scripts/main/user_events_etl.py"

  raw_prefix       = "raw/user_events/"
  curated_prefix   = "curated/user_events/"
  quarantine_prefix= "quarantine/user_events/"
}

############################
# S3 BUCKETS (optional)
############################
resource "aws_s3_bucket" "artifacts" {
  count  = var.create_buckets ? 1 : 0
  bucket = var.artifact_bucket_name
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  count                   = var.create_buckets ? 1 : 0
  bucket                  = aws_s3_bucket.artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "scripts" {
  count  = var.create_buckets ? 1 : 0
  bucket = var.scripts_bucket_name
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  count                   = var.create_buckets ? 1 : 0
  bucket                  = aws_s3_bucket.scripts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

############################
# CODESTAR CONNECTION (GitHub)
############################
resource "aws_codestarconnections_connection" "github" {
  name          = "github-connection-${var.env}"
  provider_type = "GitHub"
}

############################
# IAM: GLUE ROLE + POLICY
############################
data "aws_iam_policy_document" "glue_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "glue_role" {
  name               = "glue-etl-role-${var.env}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

data "aws_iam_policy_document" "glue_policy_doc" {
  # Allow listing the relevant buckets
  statement {
    effect = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.test_bucket}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.main_bucket}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.scripts_bucket_name}"
    ]
  }

  # Allow object R/W on those buckets
  statement {
    effect = "Allow"
    actions = ["s3:GetObject","s3:PutObject","s3:DeleteObject"]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.test_bucket}/*",
      "arn:${data.aws_partition.current.partition}:s3:::${var.main_bucket}/*",
      "arn:${data.aws_partition.current.partition}:s3:::${var.scripts_bucket_name}/*"
    ]
  }

  # CloudWatch logs
  statement {
    effect = "Allow"
    actions = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogStreams"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "glue_policy" {
  name   = "glue-etl-policy-${var.env}"
  policy = data.aws_iam_policy_document.glue_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "glue_policy_attach" {
  role       = aws_iam_role.glue_role.name
  policy_arn = aws_iam_policy.glue_policy.arn
}

resource "aws_iam_role_policy_attachment" "glue_service_attach" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

############################
# GLUE JOBS (test + prod)
############################
resource "aws_glue_job" "test" {
  name         = "user-events-etl-test-${var.env}"
  role_arn     = aws_iam_role.glue_role.arn
  glue_version = "4.0"

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = local.test_script_s3
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"

    "--bucket"            = var.test_bucket
    "--raw_prefix"        = local.raw_prefix
    "--curated_prefix"    = local.curated_prefix
    "--quarantine_prefix" = local.quarantine_prefix
  }

  worker_type       = "G.1X"
  number_of_workers = 2
}

resource "aws_glue_job" "prod" {
  name         = "user-events-etl-prod-${var.env}"
  role_arn     = aws_iam_role.glue_role.arn
  glue_version = "4.0"

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = local.prod_script_s3
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-metrics"                   = "true"

    "--bucket"            = var.main_bucket
    "--raw_prefix"        = local.raw_prefix
    "--curated_prefix"    = local.curated_prefix
    "--quarantine_prefix" = local.quarantine_prefix
  }

  worker_type       = "G.1X"
  number_of_workers = 2
}

############################
# OPTIONAL: PROD SCHEDULE TRIGGER
############################
resource "aws_glue_trigger" "prod_schedule" {
  count    = var.enable_prod_schedule_trigger ? 1 : 0
  name     = "user-events-etl-prod-schedule-${var.env}"
  type     = "SCHEDULED"
  schedule = var.prod_schedule_cron

  actions {
    job_name = aws_glue_job.prod.name
  }

  start_on_creation = true
}

############################
# IAM: CODEPIPELINE ROLE
############################
data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codepipeline_role" {
  name               = "codepipeline-glue-etl-role-${var.env}"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume.json
}

data "aws_iam_policy_document" "codepipeline_policy_doc" {
  statement {
    effect = "Allow"
    actions = ["codestar-connections:UseConnection"]
    resources = [aws_codestarconnections_connection.github.arn]
  }

  # Artifact bucket access (if you reuse an existing bucket, still needs these permissions)
  statement {
    effect = "Allow"
    actions = ["s3:GetObject","s3:GetObjectVersion","s3:PutObject","s3:GetBucketVersioning"]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.artifact_bucket_name}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.artifact_bucket_name}/*"
    ]
  }

  # Start CodeBuild builds
  statement {
    effect = "Allow"
    actions = ["codebuild:StartBuild","codebuild:BatchGetBuilds"]
    resources = [
      aws_codebuild_project.deploy_test.arn,
      aws_codebuild_project.deploy_prod.arn
    ]
  }
}

resource "aws_iam_policy" "codepipeline_policy" {
  name   = "codepipeline-glue-etl-policy-${var.env}"
  policy = data.aws_iam_policy_document.codepipeline_policy_doc.json

  # Ensure projects exist before policy resolution (helps ordering)
  depends_on = [
    aws_codebuild_project.deploy_test,
    aws_codebuild_project.deploy_prod
  ]
}

resource "aws_iam_role_policy_attachment" "codepipeline_attach" {
  role       = aws_iam_role.codepipeline_role.name
  policy_arn = aws_iam_policy.codepipeline_policy.arn
}

############################
# IAM: CODEBUILD ROLE
############################
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codebuild_role" {
  name               = "codebuild-glue-etl-role-${var.env}"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
}

data "aws_iam_policy_document" "codebuild_policy_doc" {
  # Read pipeline artifact + write scripts to scripts bucket
  statement {
    effect = "Allow"
    actions = ["s3:GetObject","s3:GetObjectVersion","s3:PutObject"]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.artifact_bucket_name}/*",
      "arn:${data.aws_partition.current.partition}:s3:::${var.scripts_bucket_name}/*"
    ]
  }

  # CloudWatch logs for CodeBuild
  statement {
    effect = "Allow"
    actions = ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"]
    resources = ["*"]
  }

  # Allow starting Glue jobs (test pipeline runs test job once)
  statement {
    effect = "Allow"
    actions = ["glue:StartJobRun"]
    resources = [aws_glue_job.test.arn, aws_glue_job.prod.arn]
  }
}

resource "aws_iam_policy" "codebuild_policy" {
  name   = "codebuild-glue-etl-policy-${var.env}"
  policy = data.aws_iam_policy_document.codebuild_policy_doc.json
}

resource "aws_iam_role_policy_attachment" "codebuild_attach" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = aws_iam_policy.codebuild_policy.arn
}

############################
# CODEBUILD PROJECTS (test/prod)
############################
resource "aws_codebuild_project" "deploy_test" {
  name          = "deploy-glue-script-test-${var.env}"
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 15

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "SCRIPTS_BUCKET"
      value = var.scripts_bucket_name
    }
    environment_variable {
      name  = "GLUE_JOB_NAME"
      value = aws_glue_job.test.name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-test.yml"
  }
}

resource "aws_codebuild_project" "deploy_prod" {
  name          = "deploy-glue-script-prod-${var.env}"
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = 15

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "SCRIPTS_BUCKET"
      value = var.scripts_bucket_name
    }
    environment_variable {
      name  = "GLUE_JOB_NAME"
      value = aws_glue_job.prod.name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-prod.yml"
  }
}

############################
# CODEPIPELINES (test/main)
############################
resource "aws_codepipeline" "test" {
  name     = "glue-etl-test-pipeline-${var.env}"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = var.artifact_bucket_name
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "SourceFromGitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repo_id
        BranchName       = "test"
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "DeployAndRun"
    action {
      name            = "DeployScriptAndRunJob"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy_test.name
      }
    }
  }
}

resource "aws_codepipeline" "prod" {
  name     = "glue-etl-prod-pipeline-${var.env}"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = var.artifact_bucket_name
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "SourceFromGitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repo_id
        BranchName       = "main"
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = "DeployScript"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = aws_codebuild_project.deploy_prod.name
      }
    }
  }
}

############################
# OUTPUTS
############################
output "region" {
  value = var.region
}

output "codestar_connection_arn" {
  value = aws_codestarconnections_connection.github.arn
}

output "test_pipeline_name" {
  value = aws_codepipeline.test.name
}

output "prod_pipeline_name" {
  value = aws_codepipeline.prod.name
}

output "codebuild_test_project" {
  value = aws_codebuild_project.deploy_test.name
}

output "codebuild_prod_project" {
  value = aws_codebuild_project.deploy_prod.name
}

output "glue_test_job" {
  value = aws_glue_job.test.name
}

output "glue_prod_job" {
  value = aws_glue_job.prod.name
}
