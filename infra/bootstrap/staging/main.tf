terraform {
  required_version = ">= 1.10"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
    random     = { source = "hashicorp/random", version = "~> 3.0" }
  }

  backend "s3" {
    bucket       = "shortener-tfstate-<SHARED_ACCOUNT_ID>"
    key          = "bootstrap/staging.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    profile      = "shortener-shared"
  }
}

provider "aws" {
  region              = "us-east-1"
  profile             = "shortener-staging"
  allowed_account_ids = ["<STAGING_ACCOUNT_ID>"]
  default_tags {
    tags = { Project = "shortener", Environment = "staging", ManagedBy = "terraform" }
  }
}

provider "cloudflare" {} # lê o token de CLOUDFLARE_API_TOKEN

variable "cloudflare_zone_id" {
  type = string
}

module "baseline" {
  source             = "../modules/account-baseline"
  environment        = "staging"
  cloudflare_zone_id = var.cloudflare_zone_id
  hosts = {
    short = "shortener-staging.fabricioroglio.com"
    api   = "api.shortener-staging.fabricioroglio.com"
    app   = "app.shortener-staging.fabricioroglio.com"
  }
}

output "certificate_arn" {
  value = module.baseline.certificate_arn
}
output "oidc_issuer" {
  value = module.baseline.oidc_issuer
}
output "oidc_jwks_url" {
  value = module.baseline.oidc_jwks_url
}
output "oidc_authority" {
  value = module.baseline.oidc_authority
}
output "oidc_client_id" {
  value = module.baseline.oidc_client_id
}
output "oidc_logout_url" {
  value = module.baseline.oidc_logout_url
}
output "cognito_user_pool_id" {
  value = module.baseline.cognito_user_pool_id
}
output "hosts" {
  value = module.baseline.hosts
}
