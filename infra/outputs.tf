output "ingest_url" {
  description = "Public base URL for the ingest API"
  value       = "http://${aws_lb.main.dns_name}"
}

output "health_url" {
  description = "Health endpoint, useful for a first smoke test"
  value       = "http://${aws_lb.main.dns_name}/health"
}

output "ecr_repository_url" {
  description = "Push target for container images"
  value       = aws_ecr_repository.ingest.repository_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.ingest.name
}

output "db_endpoint" {
  description = "RDS endpoint (reachable only from inside the VPC)"
  value       = aws_db_instance.main.address
}
