resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "shortener"
    labels = {
      # O ALB só manda tráfego para o pod depois de registrá-lo no target group: zero downtime real.
      # Vale também para os pods canary/preview criados pelo Argo Rollouts.
      "elbv2.k8s.aws/pod-readiness-gate-inject" = "enabled"
    }
  }
}

resource "random_password" "api_key" {
  length  = 40
  special = false
}

# Endereços que mudam a cada "up": vêm do Terraform, não do Git. Usado por api, worker e setup.
resource "kubernetes_config_map_v1" "infra" {
  metadata {
    name      = "shortener-infra"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    KAFKA_BROKERS            = var.kafka_brokers
    KAFKA_SSL                = "true"
    KAFKA_REPLICATION_FACTOR = "2"
    REDIS_URL                = var.redis_url
    DATABASE_SSL             = "true"
    DATABASE_SSL_CA_FILE     = "/app/certs/rds-global-bundle.pem"
  }
}

resource "kubernetes_secret_v1" "app" {
  metadata {
    name      = "shortener-secrets"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    DATABASE_URL = var.database_url
    API_KEY      = random_password.api_key.result
  }
}

# Identidade (Cognito da conta). Nada aqui é segredo: o client é público (PKCE, sem secret).
# A api usa OIDC_ISSUER, OIDC_AUDIENCE e OIDC_JWKS_URL; o web usa OIDC_AUTHORITY,
# OIDC_CLIENT_ID e OIDC_LOGOUT_URL (viram /runtime/config.js no container nginx).
resource "kubernetes_config_map_v1" "oidc" {
  metadata {
    name      = "shortener-oidc"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    OIDC_ISSUER     = var.oidc_issuer
    OIDC_AUDIENCE   = var.oidc_client_id # a api aceita aud OU client_id igual a este valor
    OIDC_JWKS_URL   = var.oidc_jwks_url
    OIDC_AUTHORITY  = var.oidc_authority
    OIDC_CLIENT_ID  = var.oidc_client_id
    OIDC_LOGOUT_URL = var.oidc_logout_url
  }
}
