terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }

  # O state vive na conta SHARED. Blocos de backend não aceitam variáveis: tudo literal.
  backend "s3" {
    bucket       = "shortener-tfstate-319679463324"
    key          = "envs/staging/aws.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    profile      = "shortener-shared"
  }
}

# Os recursos vivem na conta de STAGING.
provider "aws" {
  region              = "us-east-1"
  profile             = "shortener-staging"
  allowed_account_ids = ["785072247212"] # trava: falha se as credenciais forem de outra conta

  default_tags {
    tags = { Project = "shortener", Environment = "staging", ManagedBy = "terraform" }
  }
}

variable "admin_cidrs" {
  type = list(string)
}

variable "kubernetes_version" {
  type = string
}

module "env" {
  source = "../../../modules/aws-environment"

  environment        = "staging"
  vpc_cidr           = "10.10.0.0/16"
  kubernetes_version = var.kubernetes_version
  admin_cidrs        = var.admin_cidrs

  node_min_size     = 1
  node_max_size     = 3
  node_desired_size = 2
}

output "cluster_name" {
  value = module.env.cluster_name
}

output "vpc_id" {
  value = module.env.vpc_id
}

output "database_url" {
  value     = module.env.database_url
  sensitive = true
}

output "redis_url" {
  value = module.env.redis_url
}

output "kafka_brokers" {
  value = module.env.kafka_brokers
}
