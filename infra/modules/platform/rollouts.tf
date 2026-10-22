# Argo Rollouts: controller + CRDs (Rollout, AnalysisTemplate, AnalysisRun, Experiment).
# Os Rollouts em si vêm do Git (Fase 7).
resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = var.chart_versions.argo_rollouts
  namespace        = "argo-rollouts"
  create_namespace = true

  values = [yamlencode({
    installCRDs = true # instala e atualiza os CRDs junto com o chart
    keepCRDs    = true # padrão do chart: o uninstall não apaga CRDs (e os Rollouts) por acidente

    # Nome fixo, igual ao da Pod Identity (Tarefa 6.2). Sem isso o chart gera o nome
    # a partir do "fullname" do release, que hoje também daria "argo-rollouts", mas por acaso.
    serviceAccount = { create = true, name = "argo-rollouts" }

    controller = {
      replicas = 1 # produção real: 2 (leader election). Aqui economiza recurso nos nós.
      # O provider CloudWatch das análises exige a região no ambiente do controller;
      # a Pod Identity entrega só as credenciais.
      extraEnv = [{ name = "AWS_REGION", value = var.region }]
    }

    # Dashboard desligado no cluster: use o plugin local "kubectl argo rollouts dashboard",
    # que roda no seu Mac (localhost:3100) com as credenciais do seu kubeconfig. Nada exposto.
    dashboard = { enabled = false }
  })]
}
