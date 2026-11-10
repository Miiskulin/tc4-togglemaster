resource "aws_eks_cluster" "main" {
  name     = "togglemaster-eks"
  role_arn = var.cluster_role_arn

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"

    # Desligado de proposito: o acesso admin vem do aws_eks_access_entry.admin
    # abaixo. Com o bootstrap ligado, a AWS cria sozinha um access entry para o
    # criador do cluster e o recurso explicito falha com ResourceInUseException
    # quando o criador e o mesmo principal informado em admin_principal_arn.
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids = var.subnet_ids

    endpoint_private_access = true
    endpoint_public_access  = true
  }

  tags = {
    Name    = "togglemaster-eks"
    Projeto = "MBA DevOps"
  }
}

# ============================================================
# EKS ACCESS - ADMIN
# ============================================================

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_principal_arn
  type          = "STANDARD"

  depends_on = [
    aws_eks_cluster.main
  ]
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_principal_arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [
    aws_eks_access_entry.admin
  ]
}

# ============================================================
# EKS ACCESS - GITHUB ACTIONS (Self-Healing da Fase 4)
# Escopo limitado ao namespace togglemaster: o suficiente para
# `kubectl rollout restart`, sem acesso ao resto do cluster.
# ============================================================

resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.github_actions_role_arn
  type          = "STANDARD"

  depends_on = [
    aws_eks_cluster.main
  ]
}

resource "aws_eks_access_policy_association" "github_actions" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.github_actions_role_arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["togglemaster"]
  }

  depends_on = [
    aws_eks_access_entry.github_actions
  ]
}

# ============================================================
# EKS NODE GROUP
# ============================================================

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "togglemaster-node-group"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids

  capacity_type  = "ON_DEMAND"
  instance_types = ["t3.large"]

  scaling_config {
    desired_size = 2
    max_size     = 3

    # min_size = 0 permite escalar o node group para zero fora do horario de
    # trabalho, que e a maior economia possivel sem destruir a infraestrutura.
    min_size = 0
  }

  update_config {
    max_unavailable = 1
  }

  lifecycle {
    # Escalar manualmente (aws eks update-nodegroup-config) nao pode ser
    # revertido pelo proximo apply.
    ignore_changes = [
      scaling_config[0].desired_size
    ]
  }

  tags = {
    Name    = "togglemaster-node-group"
    Projeto = "MBA DevOps"
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}

# ============================================================
# EKS POD IDENTITY ASSOCIATIONS
# ============================================================

resource "aws_eks_pod_identity_association" "evaluation" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "togglemaster"
  service_account = "evaluation-service"
  role_arn        = var.evaluation_workload_role_arn

  depends_on = [
    aws_eks_cluster.main
  ]
}

resource "aws_eks_pod_identity_association" "analytics" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "togglemaster"
  service_account = "analytics-service"
  role_arn        = var.analytics_workload_role_arn

  depends_on = [
    aws_eks_cluster.main
  ]
}

resource "aws_eks_pod_identity_association" "db_init" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "togglemaster"
  service_account = "db-init"
  role_arn        = var.db_init_workload_role_arn

  depends_on = [
    aws_eks_cluster.main
  ]
}

# ============================================================
# EKS POD IDENTITY AGENT
# ============================================================

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"

  depends_on = [
    aws_eks_node_group.main
  ]
}