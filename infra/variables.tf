variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-1"
}

variable "project" {
  description = "Name prefix for all resources"
  type        = string
  default     = "telemetry"
}

variable "db_password" {
  description = "Postgres password. Supply via TF_VAR_db_password, never in a .tfvars committed to git."
  type        = string
  sensitive   = true
}

variable "ingest_cpu" {
  description = "Fargate CPU units (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "ingest_memory" {
  description = "Fargate memory in MiB"
  type        = number
  default     = 512
}

variable "log_retention_days" {
  description = "CloudWatch log retention. 7 days keeps this inside the free tier."
  type        = number
  default     = 7
}

variable "alarm_email" {
  description = "Address to receive CloudWatch alarms. Leave empty to skip SNS entirely."
  type        = string
  default     = ""
}
