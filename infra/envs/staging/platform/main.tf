terraform {
  required_version = ">= 1.10"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }

  backend "s3" {
    bucket       = "shortener-tfstate-319679463324"
    key          = "envs/staging/platform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    profile      = "shortener-shared"
  }
}

provider "aws" {
  region              = "us-east-1"
  profile             = "shortener-staging"
  allowed_account_ids = ["785072247212"]

  default_tags {
    tags = { Project = "shortener", Environment = "staging", ManagedBy = "terraform" }
  }
}

# Saídas da camada aws deste ambiente (state na conta shared).
data "terraform_remote_state" "aws" {
  backend = "s3"
  config = {
    bucket  = "shortener-tfstate-319679463324"
    key     = "envs/staging/aws.tfstate"
    region  = "us-east-1"
    profile = "shortener-shared"
  }
}

# Saídas do bootstrap PERMANENTE da conta de staging (Fase 5): Cognito e certificado.
data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket  = "shortener-tfstate-319679463324"
    key     = "bootstrap/staging.tfstate"
    region  = "us-east-1"
    profile = "shortener-shared"
  }
}

data "aws_eks_cluster" "this" {
  name = data.terraform_remote_state.aws.outputs.cluster_name
}

locals {
  bootstrap = data.terraform_remote_state.bootstrap.outputs

  # O token do cluster é pedido com o profile da conta do ambiente, explicitamente.
  k8s_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", data.aws_eks_cluster.this.name,
      "--region", "us-east-1",
      "--profile", "shortener-staging",
    ]
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = local.k8s_exec.api_version
    command     = local.k8s_exec.command
    args        = local.k8s_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec                   = local.k8s_exec
  }
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

module "platform" {
  source = "../../../modules/platform"

  environment          = "staging"
  cluster_name         = data.aws_eks_cluster.this.name
  vpc_id               = data.terraform_remote_state.aws.outputs.vpc_id
  database_url         = data.terraform_remote_state.aws.outputs.database_url
  redis_url            = data.terraform_remote_state.aws.outputs.redis_url
  kafka_brokers        = data.terraform_remote_state.aws.outputs.kafka_brokers
  cloudflare_api_token = var.cloudflare_api_token
  git_repo_url         = "https://github.com/shortener-lab/shortener-deploy.git"

  oidc_issuer     = local.bootstrap.oidc_issuer
  oidc_jwks_url   = local.bootstrap.oidc_jwks_url
  oidc_authority  = local.bootstrap.oidc_authority
  oidc_client_id  = local.bootstrap.oidc_client_id
  oidc_logout_url = local.bootstrap.oidc_logout_url
}

output "api_key" {
  value     = module.platform.api_key
  sensitive = true
}
