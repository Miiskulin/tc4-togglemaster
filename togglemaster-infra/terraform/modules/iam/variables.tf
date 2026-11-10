variable "sqs_queue_arn" {
  description = "ARN da fila SQS de Analytics"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN da tabela DynamoDB de Analytics"
  type        = string
}

variable "auth_db_secret_arn" {
  description = "ARN do Secret Manager do Auth DB"
  type        = string
}

variable "flag_db_secret_arn" {
  description = "ARN do Secret Manager do Flag DB"
  type        = string
}

variable "targeting_db_secret_arn" {
  description = "ARN do Secret Manager do Targeting DB"
  type        = string
}

variable "github_repository" {
  description = "Repositorio monorepo no formato owner/repo autorizado a assumir a role via OIDC"
  type        = string
}

variable "github_branch" {
  description = "Branch autorizada a assumir a role via OIDC"
  type        = string
}