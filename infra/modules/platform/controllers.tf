resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_versions.aws_lb_controller
  namespace  = "kube-system"

  values = [yamlencode({
    clusterName    = var.cluster_name
    region         = var.region
    vpcId          = var.vpc_id
    serviceAccount = { name = "aws-load-balancer-controller" }                # o mesmo nome da Pod Identity (Tarefa 6.2)
    defaultTags    = { Project = "shortener", Environment = var.environment } # para achar sobras depois
  })]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.chart_versions.metrics_server
  namespace  = "kube-system"
}

resource "kubernetes_namespace_v1" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_secret_v1" "cloudflare" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace_v1.external_dns.metadata[0].name
  }
  data = { token = var.cloudflare_api_token }
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.chart_versions.external_dns
  namespace  = kubernetes_namespace_v1.external_dns.metadata[0].name

  values = [yamlencode({
    provider = { name = "cloudflare" }
    env = [{
      name      = "CF_API_TOKEN"
      valueFrom = { secretKeyRef = { name = "cloudflare-api-token", key = "token" } }
    }]
    sources       = ["ingress"]
    domainFilters = [var.domain_filter]
    policy        = "sync"                         # apaga o registro quando o Ingress some
    txtOwnerId    = "shortener-${var.environment}" # staging e prod não apagam os registros um do outro
  })]
}
