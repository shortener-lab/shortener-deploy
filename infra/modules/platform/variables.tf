variable "environment" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "database_url" {
  type      = string
  sensitive = true
}

variable "redis_url" {
  type = string
}

variable "kafka_brokers" {
  type = string
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "domain_filter" {
  type    = string
  default = "fabricioroglio.com"
}

variable "git_repo_url" {
  type        = string
  description = "Repo GitOps lido pelo ArgoCD (https://github.com/<org>/shortener-deploy.git)"
}

variable "git_revision" {
  type    = string
  default = "main"
}

# ---------- OIDC (vem do bootstrap da conta, Fase 5) ----------
variable "oidc_issuer" {
  type        = string
  description = "https://cognito-idp.us-east-1.amazonaws.com/<pool_id>"
}

variable "oidc_jwks_url" {
  type        = string
  description = "<issuer>/.well-known/jwks.json"
}

variable "oidc_authority" {
  type        = string
  description = "Authority que o oidc-client-ts usa no navegador (no Cognito, igual ao issuer)"
}

variable "oidc_client_id" {
  type        = string
  description = "Client id do app client shortener-web (público, sem secret)"
}

variable "oidc_logout_url" {
  type        = string
  description = "https://<prefixo>.auth.us-east-1.amazoncognito.com/logout"
}

# Um lugar só para as versões: staging e prod usam sempre as mesmas.
variable "chart_versions" {
  type = object({
    aws_lb_controller = string
    external_dns      = string
    metrics_server    = string
    argocd            = string
    argocd_apps       = string
    argo_rollouts     = string
  })
  default = {
    aws_lb_controller = "3.6.1"
    external_dns      = "1.23.0"
    metrics_server    = "3.14.0"
    argocd            = "10.10.5"
    argocd_apps       = "2.0.7"
    argo_rollouts     = "2.43.8"
  }
}
