variable "use_aws_academy" {
  description = "Indica se o cluster esta sendo provisionado no AWS Academy (usando LabRole)"
  type        = bool
  default     = true
}

variable "cluster_role_arn" {
  description = "ARN da IAM Role do EKS Cluster"
  type        = string
}

variable "node_role_arn" {
  description = "ARN da IAM Role dos EKS Node Groups"
  type        = string
}

variable "subnet_ids" {
  description = "IDs das subnets privadas utilizadas pelo EKS"
  type        = list(string)
}

variable "evaluation_workload_role_arn" {
  description = "ARN da IAM Role do evaluation-service"
  type        = string
  default     = ""
}

variable "analytics_workload_role_arn" {
  description = "ARN da IAM Role do analytics-service"
  type        = string
  default     = ""
}

variable "db_init_workload_role_arn" {
  description = "ARN da IAM Role do Job de inicializacao dos bancos"
  type        = string
  default     = ""
}

variable "admin_principal_arn" {
  description = "ARN do principal IAM com acesso administrativo ao cluster EKS"
  type        = string
  default     = ""
}

variable "github_actions_role_arn" {
  description = "ARN da IAM Role do GitHub Actions, usada pelo workflow de self-healing"
  type        = string
  default     = ""
}
