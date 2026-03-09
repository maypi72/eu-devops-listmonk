variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_access_key_id" {
  description = "AWS access key ID for LocalStack"
  type        = string
  default     = "test"
}

variable "aws_secret_access_key" {
  description = "AWS secret access key for LocalStack"
  type        = string
  default     = "test"
}

variable "localstack_endpoint" {
  description = "LocalStack endpoint URL"
  type        = string
  default     = "http://localhost:31566"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "docker_registry_bucket_name" {
  description = "Dedicated S3 bucket name for Docker Registry storage"
  type        = string
  default     = "docker-registry-data"
}

