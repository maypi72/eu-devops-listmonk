resource "aws_s3_bucket" "docker_registry" {
	bucket        = var.docker_registry_bucket_name
	force_destroy = true

	tags = {
		Name        = "docker-registry"
		Environment = var.environment
		ManagedBy   = "terraform"
	}
}
