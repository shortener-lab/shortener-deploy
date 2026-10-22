terraform {
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
    random     = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

data "aws_region" "current" {}

# ---------- Certificado TLS (3 hosts) ----------
resource "aws_acm_certificate" "this" {
  domain_name               = var.hosts.short
  subject_alternative_names = [var.hosts.api, var.hosts.app]
  validation_method         = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_dns_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name    = dvo.resource_record_name
      type    = dvo.resource_record_type
      content = dvo.resource_record_value
    }
  }
  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(each.value.name, ".")
  type    = each.value.type
  content = trimsuffix(each.value.content, ".")
  ttl     = 60
  proxied = false
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn = aws_acm_certificate.this.arn
  depends_on      = [cloudflare_dns_record.acm_validation]
}

# ---------- Cognito ----------
resource "aws_cognito_user_pool" "this" {
  name                     = "shortener-${var.environment}"
  user_pool_tier           = "LITE"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "INACTIVE"

  admin_create_user_config {
    allow_admin_create_user_only = false # auto-cadastro pelo Hosted UI
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "random_string" "domain_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_cognito_user_pool_domain" "this" {
  domain                = "shortener-${var.environment}-${random_string.domain_suffix.result}" # único na região
  user_pool_id          = aws_cognito_user_pool.this.id
  managed_login_version = 1 # Hosted UI clássico
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "shortener-web"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = false # cliente público (SPA + PKCE)
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["https://${var.hosts.app}/callback"]
  logout_urls                          = ["https://${var.hosts.app}/"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 1
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
}

locals {
  oidc_issuer = "https://${aws_cognito_user_pool.this.endpoint}" # https://cognito-idp.us-east-1.amazonaws.com/<pool_id>
  hosted_ui   = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}
