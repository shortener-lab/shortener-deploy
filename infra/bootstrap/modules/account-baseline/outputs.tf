output "certificate_arn" {
  value = aws_acm_certificate_validation.this.certificate_arn
}

output "oidc_issuer" {
  value = local.oidc_issuer
}

output "oidc_jwks_url" {
  value = "${local.oidc_issuer}/.well-known/jwks.json"
}

output "oidc_authority" {
  value = local.oidc_issuer # o oidc-client-ts descobre os endpoints em <authority>/.well-known/openid-configuration
}

output "oidc_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "oidc_logout_url" {
  value = "${local.hosted_ui}/logout"
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "hosts" {
  value = var.hosts
}
