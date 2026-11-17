resource "aws_eks_cluster" "main" {
  name     = "togglemaster-eks"
  role_arn = var.cluster_role_arn

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"

    # No AWS Academy (use_aws_academy = true), habilita a permissao automatica
    # de admin para o criador do cluster (voclabs/LabRole).
    # Fora do AWS Academy (use_aws_academy = false), desliga o bootstrap para
    # que o acesso admin venha do aws_eks_access_entry.admin sem conflito.
    bootstrap_cluster_creator_admin_permissions = var.use_aws_academy
  }

  vpc_config {
    subnet_ids = var.subnet_ids

    endpoint_private_access = true
    endpoint_public_access  = true
  }

  tags = {
    Name    = "togglemaster-eks"
    Projeto = "Pos DevOps"
  }
}

# ============================================================
# EKS ACCESS - ADMIN
# ============================================================

resource "aws_eks_access_entry" "admin" {
  count         = (!var.use_aws_academy && var.admin_principal_arn != "") ? 1 : 0
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_principal_arn
  type          = "STANDARD"

  depends_on = [
    aws_eks_cluster.main
  ]
}

resource "aws_eks_access_policy_association" "admin" {
  count         = (!var.use_aws_academy && var.admin_principal_arn != "") ? 1 : 0
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
  count         = (!var.use_aws_academy && var.github_actions_role_arn != "") ? 1 : 0
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.github_actions_role_arn
  type          = "STANDARD"

  depends_on = [
    aws_eks_cluster.main
  ]
}

resource "aws_eks_access_policy_association" "github_actions" {
  count         = (!var.use_aws_academy && var.github_actions_role_arn != "") ? 1 : 0
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
# LAUNCH TEMPLATE PARA WORKER NODES
# Hop Limit = 2 permite que os containers nos pods (db-init,
# evaluation-service e analytics-service) alcancem o IMDSv2 e
# herdem a LabRole do no no AWS Academy Learner Lab.
# ============================================================

resource "aws_launch_template" "eks_nodes" {
  name_prefix = "togglemaster-eks-node-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "togglemaster-eks-worker"
      Projeto = "Pos DevOps"
    }
  }
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

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

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
    Projeto = "Pos DevOps"
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}

# ============================================================
# EKS POD IDENTITY ASSOCIATIONS
# Desativado no AWS Academy, pois os nos e pods usam LabRole.
# ============================================================

resource "aws_eks_pod_identity_association" "evaluation" {
  count           = var.use_aws_academy ? 0 : 1
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "togglemaster"
  service_account = "evaluation-service"
  role_arn        = var.evaluation_workload_role_arn

  depends_on = [
    aws_eks_cluster.main
  ]
}

resource "aws_eks_pod_identity_association" "analytics" {
  count           = var.use_aws_academy ? 0 : 1
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "togglemaster"
  service_account = "analytics-service"
  role_arn        = var.analytics_workload_role_arn

  depends_on = [
    aws_eks_cluster.main
  ]
}

resource "aws_eks_pod_identity_association" "db_init" {
  count           = var.use_aws_academy ? 0 : 1
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
  count        = var.use_aws_academy ? 0 : 1
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"

  depends_on = [
    aws_eks_node_group.main
  ]
}
