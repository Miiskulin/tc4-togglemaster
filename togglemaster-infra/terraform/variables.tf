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
# ---------------------------------------------------------------
# Identificadores imutaveis do GitHub (claim sub do OIDC)
# ---------------------------------------------------------------

variable "github_owner" {
  description = "Login do dono do repositorio"
  type        = string
  default     = "Miiskulin"
}

variable "github_owner_id" {
  description = "ID numerico imutavel do dono"
  type        = string
  default     = "105600526"
}

variable "github_repo_name" {
  description = "Nome do repositorio, sem o dono"
  type        = string
  default     = "tc4-togglemaster"
}

variable "github_repo_id" {
  description = "ID numerico imutavel do repositorio"
  type        = string
  default     = "1449794415"
}
