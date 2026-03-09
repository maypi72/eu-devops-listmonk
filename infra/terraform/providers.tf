# Configure Terraform
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }

  # Backend remoto en LocalStack (bucket creado por create_tfstate_bucket.sh)
  backend "s3" {
    bucket = "terraform-tfstate"
    key    = "bootstrap/terraform.tfstate"
    region = "us-east-1"

    access_key = "test"
    secret_key = "test"

    endpoint = "http://localhost:31566"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    force_path_style            = true
  }
}
  

# Configure the AWS Provider
provider "aws" {
  region                      = var.aws_region
  access_key                  = var.aws_access_key_id
  secret_key                  = var.aws_secret_access_key
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  # Para facilitar el uso con LocalStack 
  s3_use_path_style           = true
  skip_region_validation      = true
  sts_region                  = var.aws_region


  endpoints {
    s3             = var.localstack_endpoint
    #ecr            = var.localstack_endpoint
    #secretsmanager = var.localstack_endpoint
  }

  
}