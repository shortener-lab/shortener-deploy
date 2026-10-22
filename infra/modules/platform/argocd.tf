resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_versions.argocd
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    dex           = { enabled = false } # sem SSO no ArgoCD: login admin via port-forward
    notifications = { enabled = false }
    configs       = { params = { "server.insecure" = true } } # TLS fica a cargo do port-forward local
  })]
}

locals {
  # Uma Application por app, cada uma com o seu overlay. Mesma política de sync para as duas.
  argocd_applications = {
    for app in ["api", "web"] : "shortener-${app}" => {
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"] # apagar a App apaga o que ela criou
      project    = "default"
      source = {
        repoURL        = var.git_repo_url
        targetRevision = var.git_revision
        path           = "apps/${app}/overlays/${var.environment}"
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "shortener" }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
        retry     = { limit = 5, backoff = { duration = "10s", factor = 2, maxDuration = "3m" } }
      }
    }
  }
}

resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.chart_versions.argocd_apps
  namespace  = "argocd"

  # Garante a ordem: tudo de que as apps dependem existe antes (inclusive os CRDs do Rollout
  # e o ConfigMap do OIDC); no destroy, as apps saem primeiro.
  depends_on = [
    helm_release.argocd,
    helm_release.argo_rollouts,
    helm_release.aws_lb_controller,
    helm_release.external_dns,
    helm_release.metrics_server,
    kubernetes_config_map_v1.infra,
    kubernetes_config_map_v1.oidc,
    kubernetes_secret_v1.app,
  ]

  values = [yamlencode({
    applications = local.argocd_applications
  })]
}
