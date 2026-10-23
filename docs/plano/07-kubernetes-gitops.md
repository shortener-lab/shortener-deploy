# Fase 7: manifests Kubernetes, Argo Rollouts e o primeiro deploy via GitOps

**Entrega:**
- `https://app.shortener-staging.fabricioroglio.com` (painel React), `https://api.shortener-staging.fabricioroglio.com` (API REST) e `https://shortener-staging.fabricioroglio.com` (links curtos) no ar, com HTTPS, num único ALB, servidos pelo EKS e implantados pelo ArgoCD a partir do repo `shortener-deploy`.
- A api roda como `Rollout` com estratégia **canary** (pesos no ALB + análise no CloudWatch); o web roda como `Rollout` **blue-green** (com smoke test antes da troca); o worker continua `Deployment` com rolling update.
- A consulta de métricas que vai decidir o canary está **testada** contra métricas reais, para a Fase 8 não ter surpresa.

**Custo:** ~US$ 0,38 por hora enquanto staging estiver de pé. Termine a sessão com `scripts/down.sh staging`.

**Repo desta fase:** tudo acontece no `shortener-deploy` (`~/Documents/projects/shortener-deploy`). Os comandos assumem que você está na raiz dele.

**Pré-requisitos:**
- Fase 5: certificado ACM (3 hosts) e Cognito da conta `staging` criados pelo bootstrap.
- Fase 6: `scripts/up.sh staging` funcionando; o Terraform cria o namespace `shortener`, o ConfigMap `shortener-infra`, o Secret `shortener-secrets`, o ConfigMap `shortener-oidc`, o Argo Rollouts (namespace `argo-rollouts`, com permissão de CloudWatch via Pod Identity) e as Applications `shortener-api` e `shortener-web`, que apontam para `apps/<app>/overlays/<env>` e até agora davam erro de path.
- Imagens publicadas pelo Release da Fase 4: `ghcr.io/<org>/shortener-api:sha-<7>` e `ghcr.io/<org>/shortener-web:sha-<7>`, com os pacotes públicos.
- Plugin do Argo Rollouts para o kubectl:

```bash
brew install argoproj/tap/kubectl-argo-rollouts
kubectl argo rollouts version
```

---

## Visão geral

### Como os manifests se organizam (Kustomize)

```
shortener-deploy/
└── apps/
    ├── api/
    │   ├── base/                          # igual em todo ambiente
    │   │   ├── kustomization.yaml
    │   │   ├── rollout-transform.yaml     # ensina o Kustomize a "ler" Rollout (ver Tarefa 7.1)
    │   │   ├── rollout.yaml               # Rollout "api" (canary)
    │   │   ├── services.yaml              # api-stable e api-canary
    │   │   ├── ingress.yaml               # 2 hosts: curto e api.
    │   │   ├── hpa.yaml  pdb.yaml
    │   │   ├── analysis-template.yaml     # api-error-rate (CloudWatch)
    │   │   ├── worker-deployment.yaml     # worker continua Deployment
    │   │   └── setup-job.yaml             # hook PreSync: migrations + tópicos
    │   └── overlays/{staging,prod}/kustomization.yaml   # hosts, certificado, config, TAG DA IMAGEM
    └── web/
        ├── base/
        │   ├── kustomization.yaml
        │   ├── rollout-transform.yaml
        │   ├── rollout.yaml               # Rollout "web" (blue-green)
        │   ├── services.yaml              # web-active e web-preview
        │   ├── ingress.yaml               # host app.
        │   ├── pdb.yaml
        │   └── analysis-template.yaml     # web-smoke (Job com curl)
        └── overlays/{staging,prod}/kustomization.yaml
```

Cada app tem a sua Application no ArgoCD (`shortener-api` e `shortener-web`), as duas no namespace `shortener`. Por isso a api e o web têm ciclos de deploy independentes: dá para promover um sem tocar no outro.

> **`rollout-transform.yaml` não estava na árvore da spec.** Ele é necessário: sem ele, o Kustomize não sabe que o `envFrom` de um `Rollout` aponta para um ConfigMap, e não troca `shortener-api-config` pelo nome com hash (`shortener-api-config-<hash>`). O pod falharia com "configmap not found". A alternativa sem arquivo novo é referenciar a URL remota em `configurations:`, mas aí todo render do ArgoCD depende de baixar um arquivo da internet. Preferimos a cópia versionada no Git.

### De onde vem cada configuração do pod

| Origem | Nome | Conteúdo | Quem escreve | Usado por |
|---|---|---|---|---|
| ConfigMap | `shortener-infra` | `KAFKA_BROKERS`, `KAFKA_SSL`, `KAFKA_REPLICATION_FACTOR`, `REDIS_URL`, `DATABASE_SSL`, `DATABASE_SSL_CA_FILE` | Terraform (Fase 6) | api, worker, setup |
| Secret | `shortener-secrets` | `DATABASE_URL`, `API_KEY` | Terraform (Fase 6) | api, worker, setup |
| ConfigMap | `shortener-oidc` | `OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URL`, `OIDC_AUTHORITY`, `OIDC_CLIENT_ID`, `OIDC_LOGOUT_URL` | Terraform (Fase 6, lendo o bootstrap da Fase 5) | api, web |
| ConfigMap | `shortener-api-config-<hash>` | `PUBLIC_BASE_URL`, `CORS_ALLOWED_ORIGINS`, `LOG_LEVEL`, `CACHE_TTL_SECONDS`, `RATE_LIMIT_PER_MINUTE` | Kustomize (overlay da api, no Git) | api, worker |
| ConfigMap | `shortener-web-config-<hash>` | `API_BASE_URL` | Kustomize (overlay do web, no Git) | web |

- O `shortener-oidc` entra inteiro por `envFrom` nos dois apps. A api lê só `OIDC_ISSUER`, `OIDC_AUDIENCE` e `OIDC_JWKS_URL` (o zod ignora o resto). O entrypoint do web lê só `OIDC_AUTHORITY`, `OIDC_CLIENT_ID` e `OIDC_LOGOUT_URL` (mais `API_BASE_URL`, do ConfigMap do Kustomize). Variáveis extras não fazem mal.
- O hash no nome dos ConfigMaps do Kustomize faz qualquer mudança de configuração disparar um rollout automático dos pods. Com Argo Rollouts, isso significa que **uma mudança de config também passa pelo canary** (api) ou pelo blue-green (web), como uma imagem nova. É o comportamento certo: config errada derruba produção tanto quanto código errado.

### Roteamento: um ALB, três hosts

```
                         Cloudflare DNS (external-dns, DNS-only)
     shortener-staging.…        api.shortener-staging.…        app.shortener-staging.…
              └──────────────────────────┬──────────────────────────────┘
                                         ▼
          ALB "k8s-shortener-…"  (IngressGroup "shortener", TLS com 1 certificado ACM de 3 hosts)
                    │                                                │
        Ingress "api" (2 regras: host curto e api.)        Ingress "web" (host app.)
        backend: api-stable / porta "use-annotation"       backend: web-active:80
                    │                                                │
     ação "api-stable" (forward ponderado, escrita          Service web-active ──▶ pods do RS ativo
     pelo Argo Rollouts na annotation do Ingress)                                  (blue ou green)
          ├── peso 100-N ─▶ TG api-stable ─▶ pods do RS estável
          └── peso N ────▶ TG api-canary ─▶ pods do RS canary      Service web-preview (só dentro do
                                                                   cluster) ──▶ pods do RS novo,
                                                                   testados pelo Job web-smoke
```

- **IngressGroup:** os dois Ingresses têm `alb.ingress.kubernetes.io/group.name: shortener`. O AWS Load Balancer Controller junta os dois num ALB só (economiza ~US$ 0,02/h por ALB evitado). Annotations "de ALB" (scheme, listen-ports, certificado) precisam ser **iguais** nos Ingresses do grupo; as "de target group" (healthcheck, target-type) são de cada Ingress.
- **Por que dois hosts no Ingress da api:** o host curto só serve redirects (`GET /:code`), e o `api.` serve a API REST para o navegador. É o mesmo processo; a separação é de URL (o `shortUrl` sai do host curto, e o CORS libera o `app.` para chamar o `api.`). Restringir rotas por host fica como extensão.

### Estratégia por app (e por quê)

| App | Estratégia | Como funciona | Por quê |
|---|---|---|---|
| api | **Canary** com `trafficRouting.alb` | O ALB manda 10% e depois 50% do tráfego real para a versão nova; entre os passos, uma análise lê a taxa de 5xx do target group do canary no CloudWatch. Se passar de 1%, o Rollout aborta sozinho e volta 100% para a versão estável | Requisições da api são independentes; dividir por peso é seguro e expõe a versão nova a pouca gente primeiro |
| web | **Blue-green** | A versão nova sobe inteira atrás do `web-preview`; um Job de smoke testa `/healthz`, `/`, um asset e `/runtime/config.js`; só então o `web-active` troca de uma vez para os pods novos | **Canary quebra SPA:** o `index.html` novo referencia `/assets/index-<hash-novo>.js`, que só existe nos pods novos. Com o tráfego dividido, o navegador baixa o `index.html` de um pod novo e pede o asset ao ALB, que manda 90% das vezes para um pod velho → **404** e tela branca. Com blue-green, todo usuário vê uma versão inteira ou a outra |
| worker | **Rolling update** (Deployment) | Troca os pods aos poucos | Consumidor Kafka não recebe tráfego HTTP: não há o que dividir por peso. A "entrega progressiva" dele é o próprio consumer group rebalanceando |

**Primeiro sync de um Rollout não tem canary nem blue-green.** Na primeira vez que um `Rollout` é criado, não existe versão estável para comparar: o Argo Rollouts pula os `steps` (a especificação diz "Skipped upon initial deploy of a rollout"), a primeira ReplicaSet vira a estável direto, e `api-stable` e `api-canary` apontam para ela. No web, `web-active` e `web-preview` apontam para os mesmos pods e a `prePromotionAnalysis` não roda. É por isso que nesta fase você **não** vê canary: ele aparece a partir da segunda versão, na Fase 8.

---

## Tarefa 7.1: base da api

**Arquivos:** criar tudo em `apps/api/base/`.

**Conceitos:**
- **`Rollout` (argoproj.io/v1alpha1)** é um substituto do `Deployment`: mesmo `selector` e mesmo `template` de pod, mais um bloco `strategy` com canary ou blue-green. O controller do Argo Rollouts (instalado na Fase 6) cria e escala as ReplicaSets.
- **Probes:** a readiness tira o pod do tráfego; a liveness reinicia o pod.
- **`preStop`:** dá tempo para o ALB parar de mandar tráfego antes do SIGTERM.
- **securityContext restritivo:** sem root, sem escalada de privilégio, filesystem somente leitura.
- **A api não tem `replicas` no manifesto:** quem manda é o HPA (que agora aponta para `kind: Rollout`). Se houvesse, o ArgoCD (selfHeal) e o HPA brigariam.
- **Canary com roteamento no ALB:** o Argo Rollouts escreve no Ingress a annotation `alb.ingress.kubernetes.io/actions.api-stable`, uma ação `forward` com dois target groups e pesos (ex.: 90/10). Para o AWS Load Balancer Controller usar essa ação, o backend do Ingress precisa ser o **Service estável** (`api-stable`, que é o `rootService` padrão quando você não define um) com a porta **pelo nome `use-annotation`**. Todas as regras do Ingress que apontam para `api-stable` + `use-annotation` usam a mesma ação, então os dois hosts recebem o mesmo peso.
- **Os Services `api-stable` e `api-canary` têm o mesmo selector.** O Argo Rollouts acrescenta `rollouts-pod-template-hash: <hash>` em cada um, apontando o estável para a ReplicaSet estável e o canary para a nova. Por isso o selector no Git é "genérico".
- **Não coloque a annotation `actions.api-stable` no Git.** Ela é do Argo Rollouts. Como ela não está no manifesto desejado, o ArgoCD não a considera diferença; se estivesse, o selfHeal desfaria os pesos no meio do canary. O mesmo vale para o hash que o Rollouts põe nos selectors dos Services.

- [x] **Passo 1: copie o `rollout-transform.yaml`** (config oficial do Argo Rollouts para Kustomize 5, que é o que vem no `kubectl` e no ArgoCD)

```bash
mkdir -p apps/api/base apps/web/base
curl -sSLo apps/api/base/rollout-transform.yaml \
  https://argoproj.github.io/argo-rollouts/features/kustomize/rollout-transform-kustomize-v5.yaml
cp apps/api/base/rollout-transform.yaml apps/web/base/rollout-transform.yaml
head -5 apps/api/base/rollout-transform.yaml    # começa com "nameReference:"
```

O arquivo ensina ao Kustomize onde, dentro de um `Rollout`, `AnalysisTemplate` e `HorizontalPodAutoscaler`, há referências a ConfigMaps, Secrets, Services e ao próprio Rollout. Sem ele, o `configMapGenerator` gera `shortener-api-config-abc123`, mas o Rollout continua pedindo `shortener-api-config`. Ele fica na `base` porque o Kustomize junta as `configurations` das bases com as do overlay, e é no overlay que o ConfigMap é gerado. A Tarefa 7.3 confere isso.

- [x] **Passo 2:** `apps/api/base/rollout.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: api
  labels: { app.kubernetes.io/name: shortener-api, app.kubernetes.io/component: api }
spec:
  # sem "replicas": o HPA controla
  revisionHistoryLimit: 5
  selector:
    matchLabels: { app.kubernetes.io/component: api }
  strategy:
    canary:
      stableService: api-stable          # recebe 100-N% do tráfego
      canaryService: api-canary          # recebe N%
      trafficRouting:
        alb:
          ingress: api                   # Ingress onde o Rollouts escreve a ação com pesos
          servicePort: 80                # porta dos Services api-stable/api-canary
          # rootService omitido = stableService. O backend do Ingress tem de ser "api-stable"
      maxSurge: "25%"
      maxUnavailable: 0                  # nunca perde capacidade durante a troca
      scaleDownDelaySeconds: 30          # depois de promover, a RS antiga vive 30s (o ALB termina de mover)
      abortScaleDownDelaySeconds: 30     # depois de abortar, o canary vive 30s (requisições em andamento terminam)
      # dynamicStableScale: false (padrão). Ver explicação abaixo.
      steps:
        - setWeight: 10
        - pause: { duration: 2m }
        - analysis:
            templates:
              - templateName: api-error-rate
        - setWeight: 50
        - pause: { duration: 2m }
        - analysis:
            templates:
              - templateName: api-error-rate
        # fim dos passos = promoção: 100% para a versão nova, que vira a estável
  template:
    metadata:
      labels: { app.kubernetes.io/name: shortener-api, app.kubernetes.io/component: api }
    spec:
      terminationGracePeriodSeconds: 45   # preStop (10s) + shutdown do app (até 25s) + folga
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000                   # usuário "node" da imagem
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app.kubernetes.io/component: api }
      containers:
        - name: api
          image: shortener-api            # nome lógico: o Kustomize troca por ghcr.io/<org>/shortener-api:sha-<7>
          command: ["node", "dist/api.js"]
          ports:
            - { name: http, containerPort: 3000 }
          envFrom:
            - configMapRef: { name: shortener-infra }
            - configMapRef: { name: shortener-api-config }   # vira shortener-api-config-<hash>
            - configMapRef: { name: shortener-oidc }
            - secretRef: { name: shortener-secrets }
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
            failureThreshold: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            failureThreshold: 3
          lifecycle:
            preStop:
              sleep: { seconds: 10 }
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
```

Decisões do bloco `canary`:

- **Quantos pods o canary tem?** Com `trafficRouting`, o Rollouts escala o canary para `ceil(réplicas × peso)`: com 1 réplica (staging) e peso 10%, o canary tem 1 pod e o estável continua com 1. O ALB entrega **exatamente** 10% das requisições ao canary, independentemente do número de pods. Sem `trafficRouting`, o "peso" seria aproximado pela proporção de pods (com 1 réplica, 10% viraria 0% ou 100%). Nesse modo, quem decide quantos pods o canary tem é o peso; `maxSurge`/`maxUnavailable` deixam de ser o fator principal. Ficam explícitos para ninguém precisar adivinhar o padrão (1/1).
- **`dynamicStableScale` desligado (padrão).** Com ele ligado, o estável encolheria conforme o canary cresce (a 50%, metade dos pods estáveis sairia), economizando pods durante o deploy. O custo aparece no abort: o tráfego só pode voltar ao estável depois que ele crescer de novo, e o abort deixa de ser instantâneo. No nosso cluster sobra espaço para alguns pods extras por alguns minutos, então preferimos abort imediato.
- **`abortScaleDownDelaySeconds: 30`** é o padrão, mas fica escrito porque vai importar na Fase 8: no abort, o ALB volta 100% para o estável primeiro, e o canary ainda vive 30s para terminar as requisições em andamento (alinhado com o `deregistration_delay` de 30s do target group). Com `0`, os pods do canary **não** seriam removidos, o que ajuda a investigar um canary com bug (`kubectl logs`), mas exige limpeza manual.
- **Análise como passo, não em background.** O `analysis` dentro de `steps` bloqueia o avanço até o AnalysisRun terminar: sucesso → próximo passo; falha → abort. A janela de 2 minutos de `pause` antes de cada análise garante que já existam métricas do canary no CloudWatch.

- [x] **Passo 3:** `apps/api/base/services.yaml`

```yaml
# Os dois Services têm o mesmo selector. O Argo Rollouts acrescenta
# "rollouts-pod-template-hash" em cada um, em tempo de execução:
#   api-stable → ReplicaSet estável;  api-canary → ReplicaSet nova (durante o canary).
# Fora de um canary, os dois apontam para os mesmos pods.
apiVersion: v1
kind: Service
metadata:
  name: api-stable
  labels: { app.kubernetes.io/name: shortener-api, app.kubernetes.io/component: api }
spec:
  selector: { app.kubernetes.io/component: api }
  ports:
    - { name: http, port: 80, targetPort: http }
---
apiVersion: v1
kind: Service
metadata:
  name: api-canary
  labels: { app.kubernetes.io/name: shortener-api, app.kubernetes.io/component: api }
spec:
  selector: { app.kubernetes.io/component: api }
  ports:
    - { name: http, port: 80, targetPort: http }
```

- [x] **Passo 4:** `apps/api/base/ingress.yaml` (os hosts e o certificado vêm do overlay)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api
  annotations:
    alb.ingress.kubernetes.io/group.name: shortener          # mesmo ALB do Ingress "web"
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip                # ALB fala direto com o IP do pod
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/healthcheck-path: /readyz
    alb.ingress.kubernetes.io/target-group-attributes: deregistration_delay.timeout_seconds=30
    # certificate-arn: adicionado pelo overlay (o mesmo nos dois Ingresses do grupo)
    # actions.api-stable: escrita pelo Argo Rollouts. NÃO declare aqui.
spec:
  ingressClassName: alb
  rules:
    - host: short.placeholder.invalid            # overlay: host curto (só redirect)
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-stable                 # = stableService (rootService padrão)
                port: { name: use-annotation }   # "leia a ação com pesos da annotation"
    - host: api.placeholder.invalid              # overlay: api.<host>
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-stable
                port: { name: use-annotation }
```

O AWS Load Balancer Controller cria um target group por Service referenciado na ação. O nome segue o padrão `k8s-<namespace>-<service>-<hash>`, com namespace e service **sem caracteres não alfanuméricos e cortados em 8 caracteres**: `k8s-shortene-apistabl-<10 hex>` e `k8s-shortene-apicanar-<10 hex>`. A análise do canary (Passo 7) depende desse padrão, e a Tarefa 7.5 confere os nomes reais.

- [x] **Passo 5:** `apps/api/base/hpa.yaml`

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
spec:
  scaleTargetRef:
    apiVersion: argoproj.io/v1alpha1     # o HPA escala o Rollout, não um Deployment
    kind: Rollout
    name: api
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
```

O `Rollout` expõe o subresource `scale`, então o HPA funciona como com um Deployment. Durante um canary, o HPA muda `spec.replicas` e o Rollouts recalcula as duas ReplicaSets.

- [x] **Passo 6:** `apps/api/base/pdb.yaml`

```yaml
# Durante manutenção de nó (drain), no máximo 1 pod da api sai por vez.
# Usamos maxUnavailable e não minAvailable: 1. Com 1 réplica só (staging), minAvailable: 1 bloquearia o drain para sempre.
# O selector pega pods estáveis e canary (todos têm component=api).
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api
spec:
  maxUnavailable: 1
  selector:
    matchLabels: { app.kubernetes.io/component: api }
```

- [x] **Passo 7:** `apps/api/base/analysis-template.yaml`

**Conceitos da análise:**
- O provider `cloudWatch` do Argo Rollouts chama `GetMetricData` com as `metricDataQueries` que você escreve, olhando para trás `interval` (aqui, 2 minutos). O resultado chega na expressão como `result`: uma lista com um item por query de `returnData: true`, e cada item tem `.Values` (lista de números, um por período de 60s).
- **Qual target group?** O nome do target group do canary tem um hash que só existe depois que o Load Balancer Controller o cria, então não dá para escrever o nome exato no Git. A função `SEARCH` do CloudWatch resolve isso: ela quebra os valores das dimensões em *tokens* (separando em caracteres não alfanuméricos) e aceita casamento parcial por token. `targetgroup/k8s-shortene-apicanar-0a1b2c3d4e/…` gera, entre outros, o token `apicanar`. Então `TargetGroup=apicanar` encontra o target group do canary, e só ele (o estável gera `apistabl`).
- **Métricas:** `HTTPCode_Target_5XX_Count` (5xx **gerados pelos pods**) e `RequestCount`, ambas na dimensão `{LoadBalancer, TargetGroup}` do namespace `AWS/ApplicationELB`. A razão `errors / requests` por minuto precisa ficar abaixo de 1%.
- **Sem tráfego = sucesso.** Se ninguém chamou o canary, não há pontos e `.Values` vem vazio. `all([], …)` é verdadeiro, e `len(result) == 0` cobre o caso de não vir resultado nenhum. Isso é deliberado (staging sem carga não deve travar deploy), e por isso a demonstração da Fase 8 usa o k6 gerando carga. O lado ruim: se o `SEARCH` não casar com nada por erro de nome, a análise **passa** sem olhar nada. A Tarefa 7.5 existe para eliminar esse risco.
- **Divisão por zero:** em metric math, um ponto que divide por zero é descartado (não vira NaN). E a métrica de 5xx só existe nos minutos em que houve 5xx; nos outros, o valor ausente conta como 0 na aritmética. A Tarefa 7.5 confere esse comportamento na prática.
- **`count: 3`, `interval: 1m`, `failureLimit: 1`:** três medições, uma por minuto; a análise falha na segunda medição ruim (tolera um pico isolado). **`consecutiveErrorLimit: 2`:** se a chamada ao CloudWatch der erro (permissão, região) duas vezes seguidas, o AnalysisRun termina em `Error`, e o Rollout aborta, que é o lado seguro.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: api-error-rate
spec:
  metrics:
    - name: error-rate
      interval: 1m
      count: 3
      failureLimit: 1
      consecutiveErrorLimit: 2
      # Sem dados (canary sem tráfego) conta como sucesso.
      successCondition: "len(result) == 0 || all(result[0].Values, {# < 0.01})"
      provider:
        cloudWatch:
          interval: 2m            # janela olhada a cada medição (StartTime = agora - 2m)
          metricDataQueries:
            - id: errors
              expression: >-
                SUM(SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} MetricName="HTTPCode_Target_5XX_Count" TargetGroup=apicanar', 'Sum', 60))
              returnData: false
            - id: requests
              expression: >-
                SUM(SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} MetricName="RequestCount" TargetGroup=apicanar', 'Sum', 60))
              returnData: false
            - id: ratio
              label: canary-5xx-ratio
              expression: errors / requests
              returnData: true    # só esta volta em "result"
```

Detalhes que valem saber:
- As métricas do ALB chegam ao CloudWatch com cerca de 1 minuto de atraso. Com janela de 2 minutos, cada medição vê 1 ou 2 pontos. Se na Tarefa 7.5 a consulta vier vazia mesmo com tráfego, aumente `cloudWatch.interval` para `3m`.
- O target group do canary é **reaproveitado** entre deploys (é sempre o Service `api-canary`). Se você abortar um canary e disparar outro em menos de 2 minutos, os 5xx do anterior ainda estão na janela. Espere 2 minutos entre tentativas.
- `HTTPCode_Target_5XX_Count` não conta 502/503/504 gerados pelo **próprio ALB** (pod que não responde). Para o nosso caso (bug que faz a api responder 500), é a métrica certa. Somar `HTTPCode_ELB_5XX_Count` fica como extensão: essa métrica é do load balancer inteiro, não do target group.

- [x] **Passo 8:** `apps/api/base/worker-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: worker
  labels: { app.kubernetes.io/name: shortener-api, app.kubernetes.io/component: worker }
spec:
  replicas: 1   # o overlay define; nunca mais que o número de partições (3): réplicas extras ficam ociosas
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }
  selector:
    matchLabels: { app.kubernetes.io/component: worker }
  template:
    metadata:
      labels: { app.kubernetes.io/name: shortener-api, app.kubernetes.io/component: worker }
    spec:
      terminationGracePeriodSeconds: 45
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: worker
          image: shortener-api            # mesma imagem da api, outro entrypoint
          command: ["node", "dist/worker.js"]
          ports:
            - { name: health, containerPort: 3001 }
          envFrom:
            - configMapRef: { name: shortener-infra }
            - configMapRef: { name: shortener-api-config }   # o worker não usa OIDC nem CORS (o zod ignora)
            - secretRef: { name: shortener-secrets }
          livenessProbe:
            httpGet: { path: /, port: health }
            periodSeconds: 15
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
```

O worker sobe a mesma imagem da api. Quando o canary da api começa, o worker já foi trocado por rolling update na mesma sincronização. Como ele só consome eventos com formato estável (`link.clicked`), versões diferentes de api e worker convivendo por alguns minutos não são problema. Se um dia o evento mudar de formato, a mudança também precisa ser compatível com a versão anterior.

- [x] **Passo 9:** `apps/api/base/setup-job.yaml`

```yaml
# Hook PreSync: o ArgoCD roda este Job ANTES de aplicar o Rollout e o worker, a cada sync da app shortener-api.
# Se ele falhar (migration quebrada), o deploy para e a versão antiga continua no ar.
apiVersion: batch/v1
kind: Job
metadata:
  name: setup
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 3
  activeDeadlineSeconds: 300
  template:
    metadata:
      labels: { app.kubernetes.io/name: shortener-api, app.kubernetes.io/component: setup }
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: setup
          image: shortener-api
          command: ["node", "dist/setup.js"]
          envFrom:
            # NÃO usa shortener-api-config: no PreSync o ConfigMap com hash novo ainda não existe
            # (ele é criado na fase Sync, depois do hook). E o setup não precisa de OIDC.
            - configMapRef: { name: shortener-infra }
            - secretRef: { name: shortener-secrets }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
```

- [x] **Passo 10:** `apps/api/base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configurations:
  - rollout-transform.yaml   # Kustomize entende Rollout/AnalysisTemplate (nomes com hash, HPA → Rollout)
resources:
  - rollout.yaml
  - services.yaml
  - ingress.yaml
  - hpa.yaml
  - pdb.yaml
  - analysis-template.yaml
  - worker-deployment.yaml
  - setup-job.yaml
```

**Sobre migrations e canary:** durante o canary, a versão estável e a nova convivem por vários minutos com o **schema novo** (o setup roda antes de tudo). Por isso migrations precisam ser compatíveis com a versão anterior do código:
- Adicionar coluna nullable (como a `owner_id` da Fase 2): pode.
- Renomear ou apagar coluna: só em duas etapas (padrão "expand/contract").
- Se o canary abortar, a migration **não** é desfeita. A versão estável precisa funcionar com o schema novo, e é exatamente o que "compatível com a versão anterior" garante.

**Pronto quando:** os 10 arquivos existem em `apps/api/base/`.

---

## Tarefa 7.2: base do web

**Arquivos:** criar tudo em `apps/web/base/` (o `rollout-transform.yaml` já foi copiado na Tarefa 7.1).

**Conceitos:**
- **Blue-green no Argo Rollouts:** a ReplicaSet nova sobe inteira e o `previewService` passa a apontar para ela. A `prePromotionAnalysis` roda contra o preview; com sucesso e `autoPromotionEnabled: true`, o Rollouts troca o selector do `activeService` (a "virada"). A ReplicaSet antiga vive mais `scaleDownDelaySeconds` (30s), tempo para o ALB desregistrar os IPs antigos e registrar os novos sem derrubar requisições.
- **Config de runtime:** a mesma imagem vai para staging e prod. No start, um script em `/docker-entrypoint.d/` gera `/usr/share/nginx/html/runtime/config.js` a partir de `API_BASE_URL`, `OIDC_AUTHORITY`, `OIDC_CLIENT_ID` e `OIDC_LOGOUT_URL` (Fase 3).
- **Root filesystem somente leitura:** o nginx precisa escrever em `/tmp` (pid e arquivos temporários da imagem `nginx-unprivileged`), e o entrypoint precisa escrever o `config.js`. Os dois diretórios viram `emptyDir`; o resto da imagem fica imutável.
- **Sem HPA:** o web serve arquivos estáticos e gasta quase nada de CPU. As réplicas são fixas por ambiente (staging 1, prod 2), definidas por patch no overlay.

- [x] **Passo 1:** `apps/web/base/rollout.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: web
  labels: { app.kubernetes.io/name: shortener-web, app.kubernetes.io/component: web }
spec:
  replicas: 1                     # o overlay troca (staging 1, prod 2)
  revisionHistoryLimit: 5
  selector:
    matchLabels: { app.kubernetes.io/component: web }
  strategy:
    blueGreen:
      activeService: web-active     # o que o Ingress (e os usuários) usam
      previewService: web-preview   # só dentro do cluster: alvo do smoke test
      autoPromotionEnabled: true    # análise passou → vira sozinho
      prePromotionAnalysis:
        templates:
          - templateName: web-smoke
        args:
          - name: base-url
            value: http://web-preview   # o Job roda no mesmo namespace (shortener)
      scaleDownDelaySeconds: 30     # a versão antiga vive 30s depois da virada
  template:
    metadata:
      labels: { app.kubernetes.io/name: shortener-web, app.kubernetes.io/component: web }
    spec:
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        runAsUser: 101                  # usuário "nginx" da imagem nginx-unprivileged
        runAsGroup: 101
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels: { app.kubernetes.io/component: web }
      containers:
        - name: web
          image: shortener-web          # nome lógico: o Kustomize troca por ghcr.io/<org>/shortener-web:sha-<7>
          ports:
            - { name: http, containerPort: 8080 }
          envFrom:
            - configMapRef: { name: shortener-oidc }        # usa OIDC_AUTHORITY, OIDC_CLIENT_ID, OIDC_LOGOUT_URL
            - configMapRef: { name: shortener-web-config }  # API_BASE_URL; vira shortener-web-config-<hash>
          readinessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 5
            failureThreshold: 2
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            failureThreshold: 3
          lifecycle:
            preStop:
              sleep: { seconds: 5 }
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { memory: 64Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
          volumeMounts:
            - { name: runtime, mountPath: /usr/share/nginx/html/runtime }   # config.js gerado no start
            - { name: tmp, mountPath: /tmp }                                 # pid e temporários do nginx
      volumes:
        - name: runtime
          emptyDir: { sizeLimit: 1Mi }
        - name: tmp
          emptyDir: { sizeLimit: 64Mi }
```

- [x] **Passo 2:** `apps/web/base/services.yaml`

```yaml
# Mesmo selector nos dois. O Argo Rollouts acrescenta "rollouts-pod-template-hash":
#   web-active  → ReplicaSet que os usuários veem
#   web-preview → ReplicaSet nova, antes da virada (depois da virada, as duas apontam para a mesma)
apiVersion: v1
kind: Service
metadata:
  name: web-active
  labels: { app.kubernetes.io/name: shortener-web, app.kubernetes.io/component: web }
spec:
  selector: { app.kubernetes.io/component: web }
  ports:
    - { name: http, port: 80, targetPort: http }
---
apiVersion: v1
kind: Service
metadata:
  name: web-preview
  labels: { app.kubernetes.io/name: shortener-web, app.kubernetes.io/component: web }
spec:
  selector: { app.kubernetes.io/component: web }
  ports:
    - { name: http, port: 80, targetPort: http }
```

- [x] **Passo 3:** `apps/web/base/ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
  annotations:
    alb.ingress.kubernetes.io/group.name: shortener          # mesmo ALB do Ingress "api"
    alb.ingress.kubernetes.io/scheme: internet-facing         # tem que ser igual ao do Ingress "api"
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/healthcheck-path: /healthz
    alb.ingress.kubernetes.io/target-group-attributes: deregistration_delay.timeout_seconds=30
    # certificate-arn: adicionado pelo overlay (o mesmo do Ingress "api")
spec:
  ingressClassName: alb
  rules:
    - host: app.placeholder.invalid           # overlay: app.<host>
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-active
                port: { name: http }
```

O web não usa `trafficRouting`: no blue-green, quem troca a versão é o selector do `web-active`, e o ALB só segue os endpoints desse Service. O `web-preview` não aparece em Ingress nenhum, então não fica exposto na internet.

- [x] **Passo 4:** `apps/web/base/pdb.yaml`

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web
spec:
  maxUnavailable: 1
  selector:
    matchLabels: { app.kubernetes.io/component: web }
```

- [x] **Passo 5:** `apps/web/base/analysis-template.yaml`

**Conceitos:**
- O provider **`job`** cria um `Job` do Kubernetes. Se ele terminar com código 0, a medição é sucesso; senão, falha. Com `count: 1` e `failureLimit: 0` (padrão), uma falha basta para o Rollout **não** virar o tráfego. O `web-active` continua na versão antiga, e o Rollout fica `Degraded` até você corrigir no Git.
- O smoke confere o que um usuário precisa para a tela carregar: o nginx responde (`/healthz`), o `index.html` é o da SPA (`<div id="root">`), **o primeiro asset JS que o `index.html` referencia existe no mesmo pod** (pega build quebrado e o 404 de assets), e o `config.js` foi gerado (`__APP_CONFIG__`). Se o entrypoint falhar em gerar o `config.js`, a SPA abre em branco; o smoke pega isso antes dos usuários.
- `{{args.base-url}}` é substituído pelo valor que o Rollout passa (`http://web-preview`).
- `ttlSecondsAfterFinished` apaga o Job 10 minutos depois, o que dá tempo de ler o log se algo falhar.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: web-smoke
spec:
  args:
    - name: base-url
  metrics:
    - name: smoke
      count: 1
      provider:
        job:
          metadata:
            labels: { app.kubernetes.io/name: shortener-web, app.kubernetes.io/component: web-smoke }
          spec:
            backoffLimit: 1
            activeDeadlineSeconds: 120
            ttlSecondsAfterFinished: 600
            template:
              metadata:
                labels: { app.kubernetes.io/name: shortener-web, app.kubernetes.io/component: web-smoke }
              spec:
                restartPolicy: Never
                securityContext:
                  runAsNonRoot: true
                  runAsUser: 100                 # usuário "curl_user" da imagem
                  seccompProfile: { type: RuntimeDefault }
                containers:
                  - name: smoke
                    image: curlimages/curl:8.22.0   # versão fixada; atualize de propósito, não por acidente
                    command:
                      - sh
                      - -c
                      - |
                        set -eu
                        U="{{args.base-url}}"
                        echo "1/4 healthz";   curl -fsS --max-time 5 "$U/healthz" > /dev/null
                        echo "2/4 index";     INDEX=$(curl -fsS --max-time 5 "$U/")
                        echo "$INDEX" | grep -q '<div id="root">'
                        echo "3/4 asset";     ASSET=$(echo "$INDEX" | grep -o '/assets/[^"]*\.js' | head -n 1)
                        test -n "$ASSET"
                        curl -fsS --max-time 5 -o /dev/null "$U$ASSET"
                        echo "4/4 config.js"; curl -fsS --max-time 5 "$U/runtime/config.js" | grep -q '__APP_CONFIG__'
                        echo "smoke ok ($ASSET)"
                    resources:
                      requests: { cpu: 10m, memory: 16Mi }
                      limits: { memory: 32Mi }
                    securityContext:
                      allowPrivilegeEscalation: false
                      readOnlyRootFilesystem: true
                      capabilities: { drop: ["ALL"] }
```

- [x] **Passo 6:** `apps/web/base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
configurations:
  - rollout-transform.yaml
resources:
  - rollout.yaml
  - services.yaml
  - ingress.yaml
  - pdb.yaml
  - analysis-template.yaml
```

**Pronto quando:** os 7 arquivos existem em `apps/web/base/`.

---

## Tarefa 7.3: overlays de staging e prod, validação e CI

**Arquivos:**
- Criar `apps/api/overlays/staging/kustomization.yaml`, `apps/api/overlays/prod/kustomization.yaml`, `apps/web/overlays/staging/kustomization.yaml` e `apps/web/overlays/prod/kustomization.yaml`.
- Alterar `.github/workflows/ci.yml` (criado na Fase 6 com o job `infra`).

**Conceitos:**
- **O overlay é "o ambiente".** Ele diz qual imagem roda (a linha `newTag`, que o CD da Fase 8 vai reescrever), com qual configuração e em quais hosts.
- **No JSON Patch, `~1` representa `/`** dentro do nome de uma annotation (`alb.ingress.kubernetes.io~1certificate-arn`).
- **Réplicas do web por patch:** o campo `replicas:` do Kustomize também funcionaria (o `rollout-transform.yaml` ensina isso), mas um patch explícito em `/spec/replicas` deixa claro o que está acontecendo. O worker (Deployment) usa `replicas:` normalmente.
- **Os dois Ingresses usam o mesmo certificado:** ele cobre os 3 hosts da conta (host curto + SANs `api.` e `app.`).

- [x] **Passo 1: pegue os valores**

```bash
aws sso login --sso-session shortener        # o state fica na conta shared; o comando abaixo lê de lá
terraform -chdir=infra/bootstrap/staging output -raw certificate_arn; echo   # <ARN do certificado de staging>
terraform -chdir=infra/bootstrap/prod output -raw certificate_arn; echo      # <ARN do certificado de prod>

gh run list --repo <org>/shortener-api --workflow Release --limit 1
gh run list --repo <org>/shortener-web --workflow Release --limit 1
# a tag é "sha-" + os 7 primeiros caracteres do commit; confira em GitHub → Packages
```

Se o `output` reclamar de backend não inicializado, rode `terraform -chdir=infra/bootstrap/<env> init` antes (o backend usa o profile `shortener-shared`, como na Fase 5).

- [x] **Passo 2:** `apps/api/overlays/staging/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shortener
resources:
  - ../../base

images:
  - name: shortener-api
    newName: ghcr.io/<org>/shortener-api
    newTag: sha-<7>            # o CD atualiza esta linha automaticamente (Fase 8)

configMapGenerator:
  - name: shortener-api-config
    literals:
      - PUBLIC_BASE_URL=https://shortener-staging.fabricioroglio.com
      - CORS_ALLOWED_ORIGINS=https://app.shortener-staging.fabricioroglio.com
      - LOG_LEVEL=debug
      - CACHE_TTL_SECONDS=3600
      - RATE_LIMIT_PER_MINUTE=30

replicas:
  - name: worker
    count: 1

patches:
  - target: { kind: Ingress, name: api }
    patch: |-
      - op: replace
        path: /spec/rules/0/host
        value: shortener-staging.fabricioroglio.com
      - op: replace
        path: /spec/rules/1/host
        value: api.shortener-staging.fabricioroglio.com
      - op: add
        path: /metadata/annotations/alb.ingress.kubernetes.io~1certificate-arn
        value: <ARN do certificado de staging>
  - target: { kind: HorizontalPodAutoscaler, name: api }
    patch: |-
      - op: replace
        path: /spec/minReplicas
        value: 1
      - op: replace
        path: /spec/maxReplicas
        value: 3
```

`CORS_ALLOWED_ORIGINS` é comparado **byte a byte** com o header `Origin` do navegador: `https://`, sem barra no final, sem porta.

- [x] **Passo 3:** `apps/api/overlays/prod/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shortener
resources:
  - ../../base

images:
  - name: shortener-api
    newName: ghcr.io/<org>/shortener-api
    newTag: sha-<7>            # só muda pelo workflow "Promote" (Fase 8)

configMapGenerator:
  - name: shortener-api-config
    literals:
      - PUBLIC_BASE_URL=https://shortener.fabricioroglio.com
      - CORS_ALLOWED_ORIGINS=https://app.shortener.fabricioroglio.com
      - LOG_LEVEL=info
      - CACHE_TTL_SECONDS=86400
      - RATE_LIMIT_PER_MINUTE=10

replicas:
  - name: worker
    count: 2

patches:
  - target: { kind: Ingress, name: api }
    patch: |-
      - op: replace
        path: /spec/rules/0/host
        value: shortener.fabricioroglio.com
      - op: replace
        path: /spec/rules/1/host
        value: api.shortener.fabricioroglio.com
      - op: add
        path: /metadata/annotations/alb.ingress.kubernetes.io~1certificate-arn
        value: <ARN do certificado de prod>
```

Prod usa o HPA da base (2 a 6 réplicas), sem patch.

- [x] **Passo 4:** `apps/web/overlays/staging/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shortener
resources:
  - ../../base

images:
  - name: shortener-web
    newName: ghcr.io/<org>/shortener-web
    newTag: sha-<7>            # o CD atualiza esta linha automaticamente (Fase 8)

configMapGenerator:
  - name: shortener-web-config
    literals:
      - API_BASE_URL=https://api.shortener-staging.fabricioroglio.com

patches:
  - target: { kind: Ingress, name: web }
    patch: |-
      - op: replace
        path: /spec/rules/0/host
        value: app.shortener-staging.fabricioroglio.com
      - op: add
        path: /metadata/annotations/alb.ingress.kubernetes.io~1certificate-arn
        value: <ARN do certificado de staging>
  - target: { group: argoproj.io, kind: Rollout, name: web }
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 1
```

- [x] **Passo 5:** `apps/web/overlays/prod/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shortener
resources:
  - ../../base

images:
  - name: shortener-web
    newName: ghcr.io/<org>/shortener-web
    newTag: sha-<7>            # só muda pelo workflow "Promote" (Fase 8)

configMapGenerator:
  - name: shortener-web-config
    literals:
      - API_BASE_URL=https://api.shortener.fabricioroglio.com

patches:
  - target: { kind: Ingress, name: web }
    patch: |-
      - op: replace
        path: /spec/rules/0/host
        value: app.shortener.fabricioroglio.com
      - op: add
        path: /metadata/annotations/alb.ingress.kubernetes.io~1certificate-arn
        value: <ARN do certificado de prod>
  - target: { group: argoproj.io, kind: Rollout, name: web }
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 2
```

- [x] **Passo 6: leia o YAML final** (é exatamente isso que o ArgoCD aplica)

```bash
kubectl kustomize apps/api/overlays/staging | less
kubectl kustomize apps/web/overlays/staging | less
```

Confira três coisas que costumam dar errado:

```bash
# 1) o Rollout aponta para o ConfigMap COM hash (prova de que o rollout-transform.yaml funcionou)
kubectl kustomize apps/api/overlays/staging | yq 'select(.kind == "Rollout") | .spec.template.spec.containers[0].envFrom'
kubectl kustomize apps/web/overlays/staging | yq 'select(.kind == "Rollout") | .spec.template.spec.containers[0].envFrom'
#    esperado: shortener-api-config-<hash> / shortener-web-config-<hash> (os outros sem hash)

# 2) a imagem foi trocada no Rollout, no worker e no Job
kubectl kustomize apps/api/overlays/staging | grep 'image:'
#    esperado: 3× ghcr.io/<org>/shortener-api:sha-<7>

# 3) os dois Ingresses têm o mesmo group.name e o mesmo certificate-arn
for app in api web; do kubectl kustomize apps/$app/overlays/staging | yq 'select(.kind == "Ingress") | .metadata.annotations'; done
```

- [x] **Passo 7: valide contra os schemas** (incluindo os CRDs do Argo Rollouts, que vêm do catálogo `datreeio/CRDs-catalog`: `argoproj.io/rollout_v1alpha1.json` e `argoproj.io/analysistemplate_v1alpha1.json`)

```bash
CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
for app in api web; do
  for env in staging prod; do
    echo "== $app/$env"
    kubectl kustomize apps/$app/overlays/$env \
      | kubeconform -strict -summary -schema-location default -schema-location "$CRDS" -
  done
done
```

Esperado: `Summary: N resources found ... - Valid: N, Invalid: 0, Errors: 0, Skipped: 0`. Se aparecer `Skipped` ou "could not find schema for Rollout", o template de URL está errado. O kubeconform põe o `kind` em minúsculas em `{{.ResourceKind}}`, e é assim que os arquivos do catálogo se chamam.

- [x] **Passo 8: adicione o job `manifests` ao CI** (`.github/workflows/ci.yml`, ao lado do job `infra`)

```yaml
  manifests:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - name: Instala kubeconform
        run: |
          curl -sSL https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz \
            | sudo tar xz -C /usr/local/bin kubeconform
          kubeconform -v
      - name: Valida manifests (kustomize + kubeconform com CRDs do Argo Rollouts)
        shell: bash
        run: |
          set -euo pipefail
          CRDS='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
          for app in api web; do
            for env in staging prod; do
              echo "::group::$app/$env"
              kubectl kustomize "apps/$app/overlays/$env" \
                | kubeconform -strict -summary -schema-location default -schema-location "$CRDS" -
              echo "::endgroup::"
            done
          done
```

- O `kubectl` já vem instalado no runner `ubuntu-24.04`, e o Kustomize embutido nele é o mesmo que roda no ArgoCD (v5).
- `{{.Group}}` sem `$` na frente não é expressão do GitHub Actions; só `${{ }}` é. Por isso a linha passa intacta para o kubeconform.
- O `pipefail` faz um erro do `kubectl kustomize` (YAML quebrado) falhar o passo, em vez de o kubeconform validar uma entrada vazia.
- Se a `main` do `shortener-deploy` tem ruleset exigindo checks, inclua `manifests` na lista de checks obrigatórios.

- [x] **Passo 9: commit e merge** (via PR, por causa do ruleset)

```bash
git switch -c fase-7-manifests
git add apps .github/workflows/ci.yml
git commit -m "apps: api (canary) e web (blue-green) com Argo Rollouts"
git push -u origin fase-7-manifests
gh pr create --fill
gh pr checks --watch        # infra e manifests verdes
gh pr merge --squash --delete-branch
```

Agora as duas Applications do ArgoCD têm o que aplicar.

**Pronto quando:** o kubeconform passa local e no CI (job `manifests` verde) e o merge está na `main`.

---

## Tarefa 7.4: primeiro deploy em staging

- [x] **Passo 1: suba staging**

```bash
aws sso login --sso-session shortener
scripts/up.sh staging        # termina quando shortener-api e shortener-web estão Healthy
```

Se staging já estava de pé (por exemplo, desde a Fase 6), o ArgoCD pega o merge sozinho em até 3 minutos. Para não esperar, rode `kubectl --context shortener-staging -n argocd annotate application shortener-api shortener-web argocd.argoproj.io/refresh=normal --overwrite`.

- [x] **Passo 2: acompanhe pelo ArgoCD**

```bash
kubectl --context shortener-staging -n argocd port-forward svc/argocd-server 8080:80 &
kubectl --context shortener-staging -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
open http://localhost:8080     # usuário admin + a senha acima
```

Na UI, abra `shortener-api` e observe a ordem: o Job `setup` (PreSync) roda; depois aparecem o `Rollout` `api` (com a ReplicaSet e os pods embaixo), o `Deployment` `worker`, os Services, o HPA e o Ingress. O ArgoCD entende a saúde de um `Rollout`: `Healthy` quando está totalmente promovido, `Progressing` durante um canary e `Suspended` quando está pausado num passo. Abra também `shortener-web`.

- [x] **Passo 3: acompanhe pelo plugin do Argo Rollouts**

```bash
kubectl argo rollouts get rollout api -n shortener --context shortener-staging --watch
# Ctrl+C para sair; depois:
kubectl argo rollouts get rollout web -n shortener --context shortener-staging
```

No primeiro deploy, o `api` aparece com `Strategy: Canary`, `Status: ✔ Healthy`, uma única revisão marcada como `stable`, e peso 100% para ela. Nenhum `setWeight` ou análise roda, porque **não existe versão anterior** (os passos são pulados no deploy inicial). O `web` aparece com `Strategy: BlueGreen` e uma revisão `stable,active`. O canary e o blue-green de verdade são a Fase 8.

Opcional, para quem gosta de ver em tela: `kubectl argo rollouts dashboard --context shortener-staging` e abra `http://localhost:3100`.

- [x] **Passo 4: confira cada peça pelo terminal**

```bash
k() { kubectl --context shortener-staging -n shortener "$@"; }   # função, não variável: funciona no zsh e no bash
k logs job/setup                          # migrations ok / tópicos ok
k get rollout,deploy,pods                 # api, worker e web Running/Ready
k get svc -o wide                         # SELECTOR de api-stable/api-canary/web-* com rollouts-pod-template-hash
k get ingress                             # api e web com o MESMO ADDRESS (k8s-shortener-xxxx.us-east-1.elb.amazonaws.com)
k get ingress api -o yaml | yq '.metadata.annotations' | grep -A3 actions.api-stable   # escrita pelo Rollouts: 100% api-stable
k get hpa api                             # TARGETS cpu: x%/70%, REFERENCE Rollout/api
kubectl --context shortener-staging -n external-dns logs deploy/external-dns | tail   # 3 hosts "CREATE"
for h in shortener-staging api.shortener-staging app.shortener-staging; do
  echo "$h → $(dig +short $h.fabricioroglio.com | head -1)"    # os 3 apontam para o mesmo ALB (1–3 min)
done
```

- [x] **Passo 5: smoke test da api** (máquina a máquina, com a API key)

```bash
export SHORT=https://shortener-staging.fabricioroglio.com
export API=https://api.shortener-staging.fabricioroglio.com
export APP=https://app.shortener-staging.fabricioroglio.com
export KEY=$(terraform -chdir=infra/envs/staging/platform output -raw api_key)

curl -s $API/healthz                                     # {"status":"ok","version":"sha-..."}
curl -s -X POST $API/links -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -d '{"url":"https://github.com"}' | tee /tmp/link.json | jq
#   shortUrl começa com https://shortener-staging.fabricioroglio.com/  (PUBLIC_BASE_URL)
CODE=$(jq -r .code /tmp/link.json); echo $CODE
curl -sI $SHORT/$CODE | head -3                          # HTTP/2 302 + location: https://github.com/
for i in $(seq 1 5); do curl -s -o /dev/null $SHORT/$CODE; done
sleep 5 && curl -s $API/links/$CODE/stats -H "x-api-key: $KEY" | jq    # totalClicks: 6
curl -s -o /dev/null -w '%{http_code}\n' $API/links/$CODE/stats       # 401 sem credencial
curl -sI http://shortener-staging.fabricioroglio.com/healthz | head -3  # 301 → https
```

- [x] **Passo 6: smoke test do web e do CORS**

```bash
curl -s $APP/healthz; echo                               # ok
curl -s $APP/runtime/config.js                           # window.__APP_CONFIG__ = { apiBaseUrl: "https://api.shortener-staging…", oidcAuthority: "https://cognito-idp…", … }
curl -s -o /dev/null -w '%{http_code}\n' $APP/links/qualquer   # 200: fallback da SPA para index.html
ASSET=$(curl -s $APP/ | grep -o '/assets/[^"]*\.js' | head -1)
curl -sI $APP$ASSET | grep -i cache-control              # public, max-age=31536000, immutable
curl -sI $APP/ | grep -i cache-control                   # no-store

# preflight do navegador: origem permitida
curl -si -X OPTIONS $API/links \
  -H "Origin: $APP" \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: authorization,content-type' | grep -i -E '^HTTP|access-control'
#   HTTP/2 204 + access-control-allow-origin: https://app.shortener-staging.fabricioroglio.com

# origem NÃO permitida: sem access-control-allow-origin (o navegador bloquearia)
curl -si -X OPTIONS $API/links -H 'Origin: https://evil.example' \
  -H 'Access-Control-Request-Method: POST' | grep -i access-control-allow-origin || echo "bloqueado: ok"
```

- [x] **Passo 7: o teste de verdade, no navegador**

1. Abra `https://app.shortener-staging.fabricioroglio.com` e clique em **Entrar**. Você vai para o Hosted UI do Cognito (`shortener-staging-<sufixo>.auth.us-east-1.amazoncognito.com`).
2. Clique em **Sign up**, cadastre um e-mail seu (pode ser um alias com `+`) e uma senha, e confirme com o **código que chega por e-mail**. O remetente padrão do Cognito tem limite diário baixo; se o código não chegar, olhe o spam e espere alguns minutos.
3. Depois do login, o Cognito volta para `https://app.shortener-staging.fabricioroglio.com/callback`, e o app leva você para `/links`.
4. Crie um link. Ele aparece em **meus links**, com a URL curta no host `shortener-staging.fabricioroglio.com`.
5. Abra a URL curta numa aba anônima (redirect) e volte ao painel: depois de alguns segundos, o detalhe do link mostra o clique (gráfico e navegador).
6. Com o DevTools aberto (aba Network): as chamadas vão para `api.shortener-staging…` com `Authorization: Bearer …`, sem erros de CORS no console e sem nenhum 404 em `/assets/`.
7. O usuário fica no user pool do bootstrap da conta (Fase 5), então continua existindo depois do `down.sh`.

- [x] **Passo 8: veja o GitOps em ação (selfHeal)**

```bash
kubectl --context shortener-staging -n shortener scale deploy/worker --replicas=0
kubectl --context shortener-staging -n shortener get deploy worker -w   # em segundos o ArgoCD volta para 1
```

**Lição:** no GitOps, mudança manual no cluster não sobrevive. Para mudar algo, mude o Git. A exceção são os campos que o Git não declara e que outros controllers gerenciam: `spec.replicas` da api (HPA), a annotation de pesos do Ingress e o hash nos selectors (Argo Rollouts). O ArgoCD não considera esses campos diferença, e é por isso que eles não aparecem no Git.

**Pronto quando:**
- Os smoke tests dos passos 5 e 6 passam com HTTPS nos 3 hosts.
- O fluxo do navegador (cadastro → criar → abrir → ver clique) funciona.
- O teste do passo 8 mostra o ArgoCD desfazendo a mudança manual.

---

## Tarefa 7.5: verificar a análise do canary (antes de precisar dela)

**Por quê:** a análise `api-error-rate` trata "sem dados" como sucesso. Se o `SEARCH` não encontrar o target group (nome diferente do esperado) ou se o controller não conseguir falar com o CloudWatch, você só descobriria na Fase 8, com um canary com bug passando ou abortando por motivo errado. Aqui você testa a mesma consulta contra o target group **estável**, que já recebe tráfego real.

- [x] **Passo 1: confira os nomes dos target groups**

```bash
export AWS_PROFILE=shortener-staging
aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName' --output table
#   k8s-shortene-apistabl-xxxxxxxxxx
#   k8s-shortene-apicanar-xxxxxxxxxx
#   k8s-shortene-webactiv-xxxxxxxxxx
```

Se o nome não tiver `apicanar`, ajuste o termo `TargetGroup=apicanar` do `analysis-template.yaml` para um token que apareça só no nome do canary.

- [x] **Passo 2: gere tráfego por 3 minutos e consulte o CloudWatch como o Rollouts faz**

```bash
end=$((SECONDS+180)); while [ $SECONDS -lt $end ]; do curl -s -o /dev/null $SHORT/$CODE; sleep 0.5; done &

cat > /tmp/cw-queries.json <<'EOF'
[
  {"Id": "errors", "ReturnData": false,
   "Expression": "SUM(SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} MetricName=\"HTTPCode_Target_5XX_Count\" TargetGroup=apistabl', 'Sum', 60))"},
  {"Id": "requests", "ReturnData": false,
   "Expression": "SUM(SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} MetricName=\"RequestCount\" TargetGroup=apistabl', 'Sum', 60))"},
  {"Id": "ratio", "Label": "stable-5xx-ratio", "ReturnData": true, "Expression": "errors / requests"},
  {"Id": "reqdebug", "Label": "stable-requests", "ReturnData": true, "Expression": "requests"}
]
EOF
sleep 180
aws cloudwatch get-metric-data --metric-data-queries file:///tmp/cw-queries.json \
  --start-time $(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ) --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --query 'MetricDataResults[].[Label,StatusCode,Values]'
```

Esperado: `stable-requests` com valores entre 40 e 120 por minuto (cada `curl` leva cerca de 1 s, então o laço não chega a 2 por segundo; medido em 23/10/2026: 40 a 44) e `stable-5xx-ratio` com valores `0.0`. Esse é o caso "sem nenhum 5xx": a métrica de 5xx nem existe, e a razão precisa dar 0, não vazio nem erro.

Troque `apistabl` por `apicanar` e rode de novo: `Values` vazio (o canary não recebe tráfego fora de um deploy). É o caso "sem dados = sucesso".

> **Se `stable-5xx-ratio` vier vazio (mas `stable-requests` tiver valores):** a soma de uma busca sem resultados não está virando zero. Troque, no template e no teste, a query `errors` por `SUM([SEARCH('…HTTPCode_Target_5XX_Count… TargetGroup=apicanar', 'Sum', 60), requests * 0])` (o `requests * 0` garante uma série com zeros nos minutos com tráfego) e repita. **Se vier erro na `Messages`:** leia a mensagem; o mais comum é aspas mal escapadas.

- [x] **Passo 3: rode a análise de dentro do cluster** (prova a permissão do controller via Pod Identity e a região)

Crie um AnalysisRun avulso, com as mesmas queries do template, apontado para o target group **estável**. Ele fica fora do Git e do ArgoCD, e você apaga no fim.

```bash
kubectl --context shortener-staging -n shortener create -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AnalysisRun
metadata:
  name: teste-error-rate-stable
spec:
  metrics:
    - name: error-rate
      count: 1
      successCondition: "len(result) == 0 || all(result[0].Values, {# < 0.01})"
      provider:
        cloudWatch:
          interval: 5m
          metricDataQueries:
            - id: errors
              expression: >-
                SUM(SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} MetricName="HTTPCode_Target_5XX_Count" TargetGroup=apistabl', 'Sum', 60))
              returnData: false
            - id: requests
              expression: >-
                SUM(SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} MetricName="RequestCount" TargetGroup=apistabl', 'Sum', 60))
              returnData: false
            - id: ratio
              label: stable-5xx-ratio
              expression: errors / requests
              returnData: true
EOF
sleep 15
kubectl --context shortener-staging -n shortener get analysisrun teste-error-rate-stable \
  -o yaml | yq '.status'
```

Esperado: `phase: Successful` e, em `metricResults[0].measurements[0].value`, algo como `[[0 0 0]]` (uma lista de valores por query). Se der `phase: Error`, a mensagem diz o motivo. Veja a linha "AnalysisRun Error" em Problemas comuns.

```bash
kubectl --context shortener-staging -n shortener delete analysisrun teste-error-rate-stable
```

- [x] **Passo 4 (só se os passos 2 ou 3 não ficarem verdes): plano B documentado** (não foi preciso: CloudWatch e AnalysisRun ok em 23/10/2026)

Se a consulta ao CloudWatch não ficar confiável, troque a análise da api por um teste ativo contra o Service `api-canary`, com o provider `job`, como no web. É mais fraco, porque não olha o tráfego real dos usuários, só o que o Job manda. Mas é determinístico e não depende de métricas. Crie `apps/api/base/analysis-template-smoke.yaml`, adicione-o aos `resources` da base e troque `templateName: api-error-rate` por `api-canary-smoke` nos dois passos `analysis` do `rollout.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: api-canary-smoke
spec:
  metrics:
    - name: smoke
      count: 1
      provider:
        job:
          spec:
            backoffLimit: 0
            activeDeadlineSeconds: 120
            ttlSecondsAfterFinished: 600
            template:
              spec:
                restartPolicy: Never
                securityContext:
                  runAsNonRoot: true
                  runAsUser: 100
                  seccompProfile: { type: RuntimeDefault }
                containers:
                  - name: smoke
                    image: curlimages/curl:8.22.0
                    command:
                      - sh
                      - -c
                      - |
                        set -eu
                        U=http://api-canary            # só os pods da versão nova
                        curl -fsS --max-time 5 "$U/readyz" > /dev/null
                        FAIL=0
                        for i in $(seq 1 30); do
                          # código inexistente de 7 caracteres: o esperado é 404; 5xx é falha
                          S=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$U/zzzzzz$((i % 10))")
                          case "$S" in 5*|000) FAIL=$((FAIL+1)); echo "falha: $S";; esac
                        done
                        echo "5xx: $FAIL/30"
                        test "$FAIL" -eq 0
                    resources:
                      requests: { cpu: 10m, memory: 16Mi }
                      limits: { memory: 32Mi }
                    securityContext:
                      allowPrivilegeEscalation: false
                      readOnlyRootFilesystem: true
                      capabilities: { drop: ["ALL"] }
```

Anote no PR qual análise ficou ativa. A Fase 8 funciona com qualquer uma das duas; muda só o que "canary com bug" precisa quebrar para ser pego.

- [x] **Passo 5: encerre a sessão** com `scripts/down.sh staging`, a menos que vá direto para a Fase 8. O `down.sh` apaga as duas Applications antes do destroy. O ALB compartilhado só some quando **os dois** Ingresses somem, e só então o external-dns remove os 3 registros.

**Pronto quando:**
- A consulta do CloudWatch devolve razão `0` para o target group estável com tráfego e vazio para o canary sem tráfego, **ou** o plano B está no lugar.
- O AnalysisRun de teste terminou `Successful`.
- O `down.sh` termina sem sobras.

---

## Problemas comuns nesta fase

| Sintoma | Causa provável | Como investigar |
|---|---|---|
| `ImagePullBackOff` | Pacote do GHCR privado, ou tag errada | `kubectl describe pod`. Deixe os pacotes `shortener-api` e `shortener-web` públicos e confira a tag no overlay |
| `CreateContainerConfigError: configmap "shortener-api-config" not found` (sem hash) | O Kustomize não trocou o nome dentro do Rollout: falta `configurations: [rollout-transform.yaml]` na base | Tarefa 7.3, Passo 6 (item 1) |
| Ingress sem ADDRESS | Controller sem permissão, subnets sem tag, ou annotations conflitantes no IngressGroup (ex.: `scheme` ou `certificate-arn` diferentes entre `api` e `web`) | `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| LB controller reclama de `actions.api-stable` ausente | O Ingress `api` foi aplicado antes de o Argo Rollouts escrever a ação. Normalmente é transitório (segundos) | Se persistir: `kubectl -n argo-rollouts logs deploy/argo-rollouts` e confira `trafficRouting.alb.ingress: api` e `servicePort: 80` |
| DNS não aparece | Token sem `Zone:Read`, ou `domainFilters` errado | `kubectl -n external-dns logs deploy/external-dns` |
| Job `setup` falha com TLS no Postgres | Imagem sem a CA do RDS, ou `sslmode` na URL | `kubectl logs job/setup`. Confira o Dockerfile e a `DATABASE_URL` |
| Job `setup` não conecta no Kafka | Porta 9094 bloqueada, ou `KAFKA_SSL` falso | Teste de rede da Fase 6 (netshoot) |
| 502 intermitente no ALB | Keep-alive do Node menor que o do ALB | Confira `keepAliveTimeout` em `src/api.ts` (`shortener-api`) |
| App `OutOfSync` eterno por causa de `replicas` | `replicas` no Rollout da api briga com o HPA | Tire `replicas` do `apps/api/base/rollout.yaml`. O web pode ter (não tem HPA) |
| Pod do web em `CrashLoopBackOff` com "Read-only file system" | Falta `emptyDir` em `/tmp` ou em `/usr/share/nginx/html/runtime` | `kubectl logs <pod> -c web`. Os avisos dos scripts de IPv6/templates do entrypoint do nginx são inofensivos |
| App abre em branco; console: `__APP_CONFIG__` inválido | `config.js` gerado sem alguma variável (`OIDC_*` ou `API_BASE_URL`) | `curl $APP/runtime/config.js`; `kubectl get cm shortener-oidc -o yaml`; confira o `envFrom` do Rollout `web` |
| **CORS bloqueado** no console do navegador | `CORS_ALLOWED_ORIGINS` diferente do `Origin` real (http × https, barra no final, host errado), ou a api ainda roda com config antiga | Preflight da Tarefa 7.4, Passo 6; `kubectl -n shortener get cm \| grep shortener-api-config` e leia (`-o yaml`) o que tem o hash citado no `envFrom` do Rollout `api` |
| **`redirect_uri_mismatch`** (ou "An error was encountered with the requested page") no Cognito | O callback do app client não é exatamente `https://app.<host>/callback`, ou o `config.js` aponta para outro client/pool | Confira o app client no bootstrap (Fase 5) e `OIDC_CLIENT_ID`/`OIDC_AUTHORITY` no `shortener-oidc` e no `config.js` |
| Login funciona, mas a api responde 401 | `OIDC_ISSUER`/`OIDC_AUDIENCE` da api não batem com o token (pool ou client errados) | `kubectl logs` da api (motivo da rejeição do JWT); compare com o `iss`/`client_id` do token em jwt.io |
| **Rollout preso em `Paused`** | Passo `pause` sem duração, AnalysisRun `Inconclusive`, ou `kubectl argo rollouts pause` esquecido | `kubectl argo rollouts get rollout api -n shortener`; decida com `kubectl argo rollouts promote api` ou `abort api` |
| Rollout `Degraded` depois de um abort | É o esperado: a versão do Git falhou na análise; o tráfego já voltou para a estável | Corrija pelo Git (reverter a tag); o Rollouts volta ao estável na hora. Detalhes na Fase 8 |
| **AnalysisRun `Error`** com `AccessDenied`/`no EC2 IMDS role found`/`MissingRegion` | Pod Identity do controller sem `cloudwatch:GetMetricData`/`ListMetrics`, associação criada **depois** do pod (credenciais só entram em pods novos), ou falta `AWS_REGION` no Deployment do controller | `kubectl -n argo-rollouts get deploy argo-rollouts -o yaml \| grep -A1 AWS_REGION`; `aws eks list-pod-identity-associations --cluster-name shortener-staging`; `kubectl -n argo-rollouts rollout restart deploy/argo-rollouts` |
| AnalysisRun `Successful` sempre, mesmo com erro | `SEARCH` não casa com o target group (sem dados = sucesso) | Tarefa 7.5, Passos 1 e 2 |
| **Assets 404** (`/assets/index-*.js`) depois de um deploy do web | Estratégia que mistura versões (canary/rolling no web), ou `index.html` em cache (faltando `no-store`) | `curl -sI $APP/ \| grep -i cache-control`; o web precisa ser blue-green; o `web-smoke` testa um asset antes da virada |
| `web-smoke` falha | Preview sem pods prontos, imagem sem `config.js`, ou grep não encontra `<div id="root">` (index.html mudou) | `kubectl -n shortener logs job/<nome do job do AnalysisRun>`; `kubectl argo rollouts get rollout web` |
| kubeconform `could not find schema for Rollout` | Template de URL do catálogo errado | Tarefa 7.3, Passo 7 |

## Checkpoint da Fase 7

- [x] Os 3 hosts de staging respondem em HTTPS, todos pelo mesmo ALB
- [x] Você se cadastrou no Cognito, criou um link pelo painel, abriu o link curto e viu o clique nas stats
- [ ] `kubectl argo rollouts get rollout api` e `... web` mostram `Healthy`, e você sabe explicar por que o primeiro deploy não teve canary nem blue-green
- [ ] Você sabe explicar por que a api é canary, o web é blue-green e o worker é rolling update (e o que é o problema dos assets com hash)
- [ ] Você sabe explicar o caminho de uma requisição: DNS (Cloudflare) → ALB (TLS, regra por host, ação com pesos) → target group estável ou canary → pod (IP direto) → Valkey/RDS → Kafka → worker
- [x] A análise do canary foi testada contra métricas reais (Tarefa 7.5)
- [x] **O ambiente está derrubado** (`scripts/down.sh staging`) se você não for continuar agora
