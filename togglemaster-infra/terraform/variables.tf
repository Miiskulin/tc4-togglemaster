variable "auth_db_password" {
  description = "Senha do banco Auth"
  type        = string
  sensitive   = true
}

variable "flag_db_password" {
  description = "Senha do banco Flag"
  type        = string
  sensitive   = true
}

variable "targeting_db_password" {
  description = "Senha do banco Targeting"
  type        = string
  sensitive   = true
}

variable "eks_admin_principal_arn" {
  description = "ARN do principal IAM administrador do cluster EKS"
  type        = string
}

variable "github_repository" {
  description = "Monorepo no formato owner/repo autorizado a assumir a role via OIDC"
  type        = string
  default     = "Miiskulin/tc4-togglemaster"
}

variable "github_branch" {
  description = "Branch autorizada a assumir a role via OIDC"
  type        = string
  default     = "main"
}