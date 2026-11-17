data "aws_iam_role" "lab_role" {
  count = var.use_aws_academy ? 1 : 0
  name  = "LabRole"
}

module "networking" {
  source = "./modules/networking"

  vpc_cidr             = "10.0.0.0/16"
  availability_zones   = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
}

module "iam" {
  count  = var.use_aws_academy ? 0 : 1
  source = "./modules/iam"

  sqs_queue_arn      = module.data_services.sqs_queue_arn
  dynamodb_table_arn = module.data_services.dynamodb_table_arn

  auth_db_secret_arn      = module.data_services.auth_db_secret_arn
  flag_db_secret_arn      = module.data_services.flag_db_secret_arn
  targeting_db_secret_arn = module.data_services.targeting_db_secret_arn

  github_repository = var.github_repository
  github_branch     = var.github_branch

  github_owner     = var.github_owner
  github_owner_id  = var.github_owner_id
  github_repo_name = var.github_repo_name
  github_repo_id   = var.github_repo_id
}

locals {
  eks_cluster_role_arn         = var.use_aws_academy ? data.aws_iam_role.lab_role[0].arn : module.iam[0].eks_cluster_role_arn
  eks_node_role_arn            = var.use_aws_academy ? data.aws_iam_role.lab_role[0].arn : module.iam[0].eks_node_role_arn
  evaluation_workload_role_arn = var.use_aws_academy ? data.aws_iam_role.lab_role[0].arn : module.iam[0].evaluation_workload_role_arn
  analytics_workload_role_arn  = var.use_aws_academy ? data.aws_iam_role.lab_role[0].arn : module.iam[0].analytics_workload_role_arn
  db_init_workload_role_arn    = var.use_aws_academy ? data.aws_iam_role.lab_role[0].arn : module.iam[0].db_init_workload_role_arn
  github_actions_role_arn      = var.use_aws_academy ? data.aws_iam_role.lab_role[0].arn : module.iam[0].github_actions_role_arn
}

module "eks" {
  source = "./modules/eks"

  use_aws_academy  = var.use_aws_academy
  cluster_role_arn = local.eks_cluster_role_arn
  node_role_arn    = local.eks_node_role_arn
  subnet_ids       = module.networking.private_subnet_ids

  evaluation_workload_role_arn = local.evaluation_workload_role_arn
  analytics_workload_role_arn  = local.analytics_workload_role_arn
  db_init_workload_role_arn    = local.db_init_workload_role_arn

  admin_principal_arn     = var.eks_admin_principal_arn
  github_actions_role_arn = local.github_actions_role_arn
}

module "data_services" {
  source = "./modules/data_services"

  vpc_id             = module.networking.vpc_id
  vpc_cidr           = "10.0.0.0/16"
  private_subnet_ids = module.networking.private_subnet_ids

  auth_db_password      = var.auth_db_password
  flag_db_password      = var.flag_db_password
  targeting_db_password = var.targeting_db_password
}
