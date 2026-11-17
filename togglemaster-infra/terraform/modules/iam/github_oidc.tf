resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  tags = {
    Name    = "github-actions-oidc"
    Projeto = "Pos DevOps"
  }
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"

      identifiers = [
        aws_iam_openid_connect_provider.github.arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }

    # O GitHub inclui IDs numericos imutaveis no claim sub:
    #   repo:<login>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/<branch>
    # Os IDs nao mudam se o repositorio ou a conta forem renomeados, o
    # que impede alguem que registre o nome antigo de assumir a role.
    # Os dois formatos ficam aceitos: com uma lista de values, o IAM
    # avalia como OU.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "repo:${var.github_repository}:ref:refs/heads/${var.github_branch}",
        "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo_name}@${var.github_repo_id}:ref:refs/heads/${var.github_branch}",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name = "togglemaster-github-actions-role"

  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

  tags = {
    Name    = "togglemaster-github-actions-role"
    Projeto = "Pos DevOps"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_policy" "github_actions_ecr" {
  name        = "togglemaster-github-actions-ecr-policy"
  description = "Permite que GitHub Actions publique imagens nos repositorios ECR do ToggleMaster"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "ecr:GetAuthorizationToken"
        ]

        Resource = "*"
      },
      {
        Effect = "Allow"

        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]

        Resource = [
          "arn:aws:ecr:us-east-1:${data.aws_caller_identity.current.account_id}:repository/togglemaster-auth",
          "arn:aws:ecr:us-east-1:${data.aws_caller_identity.current.account_id}:repository/togglemaster-flag",
          "arn:aws:ecr:us-east-1:${data.aws_caller_identity.current.account_id}:repository/togglemaster-targeting",
          "arn:aws:ecr:us-east-1:${data.aws_caller_identity.current.account_id}:repository/togglemaster-evaluation",
          "arn:aws:ecr:us-east-1:${data.aws_caller_identity.current.account_id}:repository/togglemaster-analytics"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_ecr" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_ecr.arn
}

# ============================================================
# POLICY - GITHUB ACTIONS / EKS (Self-Healing da Fase 4)
# Permite ao workflow de self-healing montar o kubeconfig
# (`aws eks update-kubeconfig`) antes do rollout restart.
# O acesso dentro do cluster e concedido por um EKS Access
# Entry no modulo eks, limitado ao namespace togglemaster.
# ============================================================

resource "aws_iam_policy" "github_actions_eks" {
  name        = "togglemaster-github-actions-eks-policy"
  description = "Permite que GitHub Actions descreva o cluster EKS para o self-healing"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "eks:DescribeCluster"
        ]

        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_eks" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_eks.arn
}
