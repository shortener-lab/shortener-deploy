module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs

  # Quem roda o apply vira admin do cluster via Access Entry. Com o profile shortener-<env>,
  # esse "quem" é o papel SSO AWSReservedSSO_AdministratorAccess_... DA CONTA DO AMBIENTE.
  enable_cluster_creator_admin_permissions = true

  # Logs do control plane desligados: geram custo e sobram depois do destroy. Em produção real, ligue.
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }
}

# Permissão IAM para o AWS Load Balancer Controller criar ALBs (via EKS Pod Identity).
module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0" # confira a última no registry

  name                            = "${local.name}-aws-lbc"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

# Permissão IAM para o controller do Argo Rollouts ler métricas do CloudWatch
# (AnalysisTemplate api-error-rate, Fase 7). Política mínima: só leitura de métricas.
module "argo_rollouts_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                      = "${local.name}-argo-rollouts"
  attach_custom_policy      = true
  custom_policy_description = "Argo Rollouts: leitura de metricas do CloudWatch"

  policy_statements = [
    {
      sid       = "CloudWatchReadMetrics"
      actions   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics"]
      resources = ["*"] # estas ações não aceitam restrição por recurso
    }
  ]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "argo-rollouts"
      service_account = "argo-rollouts" # o mesmo nome fixado no chart (Tarefa 6.4, rollouts.tf)
    }
  }
}
