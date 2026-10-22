# Plano: encurtador de URLs (shortener)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objetivo:** construir e operar um encurtador de URLs com analytics e painel web, em três ambientes (dev local, staging e produção na AWS). A ideia é praticar Kafka, Redis, OIDC, CI/CD, Kubernetes, entrega progressiva, Terraform e AWS multi-conta do jeito que se faz em empresa.

**Arquitetura:**
- **Três aplicações independentes**, cada uma no seu repositório:
  - `shortener-api`: uma imagem Node.js com três processos (`api` HTTP, `worker` consumidor Kafka, `setup` de migrations e tópicos).
  - `shortener-web`: painel React servido por nginx.
  - `shortener-deploy`: o estado desejado dos ambientes (manifests, Terraform e scripts).
- Login de usuário via **OIDC**: Cognito na AWS e um IdP mock em dev. A `API_KEY` fica só para uso máquina-a-máquina.
- **Uma conta AWS por ambiente** (AWS Organizations). Cada ambiente tem VPC, EKS, RDS Postgres, ElastiCache (Valkey) e MSK próprios, criados por Terraform e destruídos ao fim de cada sessão de estudo.
- **Deploy GitOps com entrega progressiva:**
  - O CI de cada app publica a imagem e grava a tag no `shortener-deploy`.
  - O ArgoCD aplica a mudança.
  - O Argo Rollouts faz canary na api (com análise automática no CloudWatch) e blue-green no web.

**Stack:**
- **api:** Node 24, Express 5, TypeScript, pg, ioredis, @confluentinc/kafka-javascript, zod, pino, jose, vitest
- **web:** Vite, React 19, React Router 7, TanStack Query 5, oidc-client-ts, zod, Oxlint, Vitest, Testing Library, MSW, Playwright, nginx
- **Infra:** Docker, Terraform, AWS Organizations, IAM Identity Center, EKS, Cognito, ArgoCD, Argo Rollouts, Kustomize, GitHub Actions (com GitHub App), Cloudflare DNS

**Spec:** [`docs/superpowers/specs/2026-10-12-frontend-canary-multiconta-design.md`](../superpowers/specs/2026-10-12-frontend-canary-multiconta-design.md). As decisões da arquitetura original estão nas seções "Ambientes" e "Decisões" deste README.

---

## Como usar este plano

1. Siga as fases em ordem. Cada fase é um arquivo, e cada tarefa termina com um critério **"Pronto quando"**.
2. Marque os checkboxes (`- [ ]` → `- [x]`) conforme avança.
3. **Para aprender de verdade:** leia o objetivo e os testes de cada tarefa, tente implementar sozinho e só depois compare com o código de referência. Os blocos de código são a resposta, não o enunciado.
4. **Regra de ouro de custo:** toda sessão na AWS termina com `scripts/down.sh <ambiente>` e com `scripts/leftovers.sh <ambiente>` retornando vazio.
5. **Onde o plano mora:** até a Fase 3, em `shortener-api/docs/plano`. Na Fase 4 ele muda para `shortener-deploy/docs/plano` e fica lá.

| Fase | Arquivo | Repo(s) | Entrega | Custo AWS | Tempo |
|---|---|---|---|---|---|
| 1 | [01-dev-local.md](01-dev-local.md) | api | App completo com testes, rodando no compose (**concluída**) | 0 | 5–6h |
| 2 | [02-api-auth.md](02-api-auth.md) | api | Login OIDC na api, dono do link, `/me/links`, CORS, IdP mock no compose (**concluída**) | 0 | 3–4h |
| 3 | [03-frontend.md](03-frontend.md) | web | Painel React com login, testes, e2e local e imagem nginx com config de runtime (**concluída**) | 0 | 5–6h |
| 4 | [04-ci.md](04-ci.md) | os 3 | Org e três repos no GitHub; CI em todo PR e imagem no GHCR a cada merge (api e web) (**concluída**) | 0 | 1,5–2h |
| 5 | [05-aws-organizacao-bootstrap.md](05-aws-organizacao-bootstrap.md) | deploy | Organização com 4 contas, SCPs, SSO, state remoto, certificados e Cognito por conta | ~0 | 2–3h |
| 6 | [06-terraform-ambientes.md](06-terraform-ambientes.md) | deploy | Staging sobe e desce com um comando, na sua própria conta, com Argo Rollouts | ~US$ 0,38/h | 3–4h |
| 7 | [07-kubernetes-gitops.md](07-kubernetes-gitops.md) | deploy | api (canary) e web (blue-green) no ar em staging via ArgoCD | ~US$ 0,38/h | 3h |
| 8 | [08-cd-promocao.md](08-cd-promocao.md) | os 3 | CD entre repos, promoção por app com aprovação, canary com bug abortando sozinho | ~US$ 0,76/h | 3h |
| 9 | [09-operacao.md](09-operacao.md) | os 3 | Caos, runbooks e desligamento verificado (incluindo fechar contas) | ~US$ 0,38–0,76/h | 1–2h |

Buracos e defeitos encontrados durante a implementação, com status: [achados.md](achados.md).

**Total:** ~27–33h, ou seja, 4 a 5 dias de estudo. O gasto na AWS deve ficar entre US$ 10 e 20, provavelmente coberto pelos créditos de conta nova.

---

## Arquitetura

```
                        AWS Organization (conta management: SSO, billing, SCPs)
             ┌──────────────────────────┬──────────────────────────┬──────────────────────────┐
     OU Infrastructure             OU Workloads                OU Workloads
     conta shared                  conta staging               conta prod
     └─ S3: state Terraform        (mesma estrutura de prod)   │
                                                               │
          Cloudflare DNS (registros criados pelo external-dns de cada cluster)
                                                               │
        shortener.fabricioroglio.com      api.shortener.fabricioroglio.com      app.shortener.fabricioroglio.com
                     │  (links curtos)               │  (API REST)                         │  (painel)
                     └───────────────────────────────┼─────────────────────────────────────┘
                                                     ▼
 ┌── conta prod · VPC 10.20.0.0/16 ─────────────────────────────────────────────────────────────┐
 │ públicas: 1 ALB compartilhado (IngressGroup, TLS via ACM) · NAT GW                            │
 │ privadas: EKS (nós t4g ARM)                                                                   │
 │   ├─ api     (Argo Rollout canary + HPA) ◀── hosts curto e api.                               │
 │   ├─ web     (Argo Rollout blue-green, nginx) ◀── host app.                                   │
 │   ├─ worker  (Deployment)                                                                     │
 │   ├─ setup   (Job PreSync: migra DB + cria tópicos)                                           │
 │   └─ ArgoCD · Argo Rollouts · AWS LB Controller · external-dns · metrics-server               │
 │   RDS Postgres 17 · ElastiCache Valkey 8 · MSK Kafka 3.9 (2 brokers)                          │
 │ permanente (bootstrap da conta): certificado ACM (3 hosts) · Cognito user pool                │
 └───────────────────────────────────────────────────────────────────────────────────────────────┘
```

Staging é igual, na conta staging, com a VPC `10.10.0.0/16` e hosts com o sufixo `-staging` (`shortener-staging.`, `api.shortener-staging.` e `app.shortener-staging.fabricioroglio.com`).

**Fluxo de uma requisição:**
- **Painel:**
  1. O navegador carrega o React de `app.*`.
  2. O login é feito no Cognito (Authorization Code + PKCE).
  3. O painel chama `api.*` com `Authorization: Bearer <access token>`, via CORS.
  4. A api valida o JWT pela JWKS do Cognito.
- **`GET /:code` no host curto:**
  1. Lê o Valkey (cache).
  2. Se não achar, lê o Postgres e grava o resultado no cache.
  3. Publica `link.clicked` no Kafka **sem esperar a confirmação**.
  4. Responde 302.
- **`worker`:** consome `link.clicked` e, em uma transação, deduplica pelo `eventId` e incrementa os agregados por dia e por navegador. Depois de 3 falhas, a mensagem vai para `link.clicked.dlq`.

**Fluxo de entrega:**

```
shortener-api ou shortener-web
PR ──▶ CI (lint, tipos, testes, build) ──▶ merge na main
                                              │
                Release: ghcr.io/<org>/shortener-<app>:sha-abc1234
                                              │
         GitHub App: commit "deploy(staging): <app> sha-abc1234" no shortener-deploy
                                              │
                ArgoCD staging aplica ──▶ Argo Rollouts: canary (api) ou blue-green (web)
                                              │
      shortener-deploy ▸ "Promote to production" (app + aprovação sua)
                                              │
         commit "deploy(prod): <app> sha-abc1234" ──▶ ArgoCD prod ──▶ Argo Rollouts
```

Cada app é promovido de forma independente. Prod pode ter a api na versão X e o web na versão Y; o contrato entre eles é a API REST, que precisa ser compatível com a versão anterior.

## Ambientes

| | dev | staging | prod |
|---|---|---|---|
| **Onde** | Seu Mac (docker-compose) | Conta AWS `shortener-staging`, VPC `10.10.0.0/16` | Conta AWS `shortener-prod`, VPC `10.20.0.0/16` |
| **Links** | `http://localhost:3000` | `https://shortener-staging.fabricioroglio.com` | `https://shortener.fabricioroglio.com` |
| **API** | `http://localhost:3000` | `https://api.shortener-staging.fabricioroglio.com` | `https://api.shortener.fabricioroglio.com` |
| **Painel** | `http://localhost:5173` (Vite) | `https://app.shortener-staging.fabricioroglio.com` | `https://app.shortener.fabricioroglio.com` |
| **Login (OIDC)** | `mock-oauth2-server` no compose | Cognito da conta staging | Cognito da conta prod |
| **Deploy** | Manual (`npm run dev:*`) | Automático a cada merge (por app) | Manual, com aprovação (workflow "Promote", por app) |
| **Estratégia** | — | api canary · web blue-green · worker rolling | Igual |
| **Postgres** | Container `postgres:17` | RDS `db.t4g.micro` | RDS `db.t4g.micro` (flag para Multi-AZ) |
| **Redis** | Container `valkey/valkey:8` | ElastiCache Valkey `cache.t4g.micro` | Igual |
| **Kafka** | Container `apache/kafka:3.9.1` | MSK 3.9, 2× `kafka.t3.small` | Igual |
| **Réplicas api** | 1 | HPA 1–3 | HPA 2–6 |
| **Réplicas web** | 1 | 1 | 2 |
| **Réplicas worker** | 1 | 1 | 2 |
| **Vida útil** | Sempre | Efêmera | Efêmera |

## Decisões (e porquês)

| Decisão | Por quê | Como seria em produção de verdade |
|---|---|---|
| Três repos: api, web e deploy (GitOps) | Ciclos de release independentes; mudanças de config separadas do código; é o padrão recomendado pelo ArgoCD | Igual. Muitas empresas ainda separam um repo só de infra |
| Frontend em container nginx no EKS | Reaproveita o mesmo fluxo GitOps e de promoção da api | Muito comum servir o SPA por CDN (CloudFront/S3) com WAF; está nas extensões |
| Config de runtime no frontend (`/runtime/config.js`) | A mesma imagem vai de staging para prod. Config em build-time exigiria um build por ambiente | Igual |
| OIDC com PKCE e JWT validado na api | Uma chave de API no navegador é pública; o login dá identidade e o conceito de "meus links" | Igual, às vezes com BFF guardando os tokens no servidor |
| Cognito em produção, IdP mock em dev | O código só fala OIDC padrão; troca de provedor por configuração | Igual (Cognito, Auth0, Okta, Entra ID...) |
| 3 hosts por ambiente, 1 ALB | Modelo do bit.ly (links, API e painel separados) sem pagar um ALB por app | Igual, às vezes com CDN na frente |
| Canary na api com análise automática | Uma versão ruim recebe só 10% do tráfego e volta sozinha se o erro subir | Igual; a análise costuma usar Prometheus/Datadog |
| Blue-green no web | Canary em SPA quebra assets com hash; a troca precisa ser atômica | Igual, ou deploy atômico em CDN |
| Uma conta AWS por ambiente (Organizations + SCPs) | Isolamento real de segurança, cotas e custos; um erro em staging não alcança prod | Igual, com Control Tower/Account Factory e contas de log e segurança |
| Dados em serviços gerenciados (RDS, ElastiCache, MSK) | É o padrão de produção na AWS | Igual, mas com Multi-AZ, 3 brokers e backups |
| Ambientes efêmeros | Custo mensal zero | Ambientes fixos. As versões efêmeras viram "preview environments" |
| Terraform em camadas (`organization` → `bootstrap` → `aws` → `platform`) | Ciclos de vida diferentes, e os providers de Kubernetes/Helm precisam de um cluster que já exista | Igual |
| GitOps pull com ArgoCD e GitHub App para escrever no repo de deploy | O CI não precisa de credencial da AWS; o token do App é curto e limitado a um repo | Igual |
| Imagens no GHCR | Grátis e independente do ciclo de vida da AWS | ECR com pull via IAM |
| MSK com TLS e sem autenticação (rede restrita por security group) | Simplicidade no primeiro contato | IAM auth (extensão listada abaixo) |
| Valkey no lugar de Redis | Mais barato no ElastiCache e compatível com o protocolo Redis | Igual |
| Imagens só ARM64 | Os nós são Graviton (t4g), mais baratos, e o seu Mac também é ARM | Multi-arch, se houver nós x86 |

## Restrições globais

Valem para todas as tarefas.

- **Runtime:**
  - **api:** Node.js 24, projeto ESM (`"type": "module"`), TypeScript `strict`, `module: NodeNext`. **Imports relativos levam `.js`** (`import { x } from './y.js'`).
  - **web:** o que o template `react-ts` do Vite gerar (TypeScript `strict`, `verbatimModuleSyntax`).
- **Projetos novos nascem pela CLI** (`npm init`, `npm create vite@latest`, `tsc --init`, `npm pkg set`). Não se escreve à mão o que a ferramenta gera.
- **Versões iguais em dev e na AWS:** Postgres 17, Valkey 8, Kafka 3.9.
- **Região:** `us-east-1`, AZs `us-east-1a` e `us-east-1b`. Uma SCP bloqueia as demais regiões.
- **Contas e profiles AWS:** `shortener-mgmt`, `shortener-shared`, `shortener-staging` e `shortener-prod`, todos pela sso-session `shortener`. Todo provider `aws` declara `allowed_account_ids`.
- **Imagens:** `ghcr.io/<org>/shortener-api:sha-<7 chars>` e `ghcr.io/<org>/shortener-web:sha-<7 chars>`, apenas `linux/arm64`.
- **Tags obrigatórias** em todo recurso AWS: `Project=shortener`, `Environment=<staging|prod|shared|management>`, `ManagedBy=terraform`.
- **Nomes:**
  - Clusters e contexts do kubectl: `shortener-staging` e `shortener-prod`
  - Namespace das apps: `shortener`
  - Applications do ArgoCD: `shortener-api` e `shortener-web`
  - Rollouts: `api` (canary) e `web` (blue-green)
  - Tópicos: `link.clicked` (3 partições) e `link.clicked.dlq` (1 partição)
  - Consumer group: `shortener-analytics`
  - Client OIDC: `shortener-web`
- **Nenhum segredo no Git.** Tokens entram por variável de ambiente; senhas são geradas pelo Terraform e entregues ao cluster como Secret; a chave privada do GitHub App fica só nos secrets do GitHub.
- **Códigos curtos:** exatamente 7 caracteres `[0-9A-Za-z]`.
- **URLs aceitas:** só `http:` e `https:`, com até 2048 caracteres.

## Foco de revisão

Estas são as falhas mais prováveis de morder quem usa o sistema. Cada uma tem um teste na tarefa dona do código.

1. **URL maliciosa** (`javascript:`, `data:`, gigante) tem que dar 400, nunca virar redirect. Testes na Tarefa 1.5 e na 1.8; a validação client-side da Fase 3 só melhora a UX, não substitui a do servidor.
2. **Redis fora do ar:** redirect e criação de link continuam funcionando, mais lentos e sem travar. Testes na Tarefa 1.6 e na 1.8.
3. **Kafka lento ou fora do ar:** o redirect não espera o Kafka. Testes na Tarefa 1.7 e na 1.8.
4. **Evento entregue duas vezes** (o Kafka garante "pelo menos uma vez") tem que ser contado uma vez só. Teste na Tarefa 1.10.
5. **Rate limit atrás do ALB** precisa usar o IP real do cliente. Teste na Tarefa 1.8.
6. **Token de outro emissor, expirado ou de outro client** tem que dar 401. O access token do Cognito não tem `aud`, só `client_id`. Testes na Fase 2.
7. **Usuário vendo stats do link de outro** tem que receber 404, sem vazar que o link existe. Teste na Fase 2.
8. **Origem não autorizada** (CORS) não pode receber `Access-Control-Allow-Origin`. Teste na Fase 2.
9. **Versão ruim em produção** tem que ficar restrita a 10% do tráfego e voltar sozinha. Demonstração na Fase 8.

Mais um: **rotas fixas versus códigos.** `healthz` tem 7 caracteres alfanuméricos e seria um código válido. A ordem das rotas importa; o teste fica na Tarefa 1.8.

## Estrutura final dos repositórios

```
shortener-api/
├── src/
│   ├── api.ts  worker.ts  setup.ts        # entrypoints
│   ├── config.ts  logger.ts  shutdown.ts
│   ├── auth/          jwt.ts                          # Fase 2
│   ├── db/            pool.ts  migrate.ts
│   ├── links/         code.ts  url.ts  repository.ts  service.ts
│   ├── cache/         redis.ts  linkCache.ts  jsonCache.ts
│   ├── events/        clickEvent.ts  kafka.ts  clickPublisher.ts
│   ├── analytics/     browser.ts  processClick.ts
│   ├── worker/        handleMessage.ts
│   └── http/          app.ts  auth.ts  rateLimit.ts
├── migrations/        001_init.sql  002_link_owner.sql
├── test/unit/  test/integration/
├── docker/            postgres-init.sql  (+ config do IdP mock)
├── Dockerfile  .dockerignore  docker-compose.yml
└── .github/workflows/ ci.yml  release.yml

shortener-web/
├── src/               config.ts  api/  auth/  pages/  components/  main.tsx  App.tsx
├── public/runtime/config.js        # config de dev (no container é gerado no start)
├── e2e/                            # Playwright (local)
├── nginx/             default.conf  40-runtime-config.sh
├── Dockerfile  .dockerignore
└── .github/workflows/ ci.yml  release.yml

shortener-deploy/
├── apps/
│   ├── api/{base,overlays/{staging,prod}}/   # Rollout canary, worker, setup, Ingress, HPA, AnalysisTemplate
│   └── web/{base,overlays/{staging,prod}}/   # Rollout blue-green, Ingress, AnalysisTemplate
├── infra/
│   ├── organization/              # conta management: OUs, contas, SCPs, Identity Center
│   ├── bootstrap/shared/          # bucket de state
│   ├── bootstrap/modules/account-baseline/   # ACM (3 hosts) + Cognito
│   ├── bootstrap/{staging,prod}/
│   ├── modules/aws-environment/   # camada 1: VPC, EKS, RDS, ElastiCache, MSK, Pod Identities
│   ├── modules/platform/          # camada 2: controllers, ArgoCD, Argo Rollouts, config da app
│   └── envs/{staging,prod}/{aws,platform}/
├── scripts/           up.sh  down.sh  leftovers.sh
├── load/redirect.js               # teste de carga (k6)
├── docs/plano/  docs/superpowers/ # este plano e a spec
└── .github/workflows/ ci.yml  promote.yml
```

## Pré-requisitos

```bash
# Node 24 (via fnm; nvm também serve)
brew install fnm && fnm install 24 && fnm default 24

# Containers: Docker Desktop ou OrbStack, com ≥ 6 GB de RAM para o compose
brew install --cask orbstack   # ou docker

# Ferramentas
brew install git gh jq yq awscli kubectl helm kubeconform argocd k6
brew install argoproj/tap/kubectl-argo-rollouts                 # a partir da Fase 7
brew tap hashicorp/tap && brew install hashicorp/tap/terraform   # Terraform >= 1.10
npx playwright install chromium                                  # na Fase 3, dentro do shortener-web
```

Para conferir: `node -v` (v24.x), `terraform -version` (≥ 1.10), `aws --version` (v2) e `kubectl argo rollouts version`.

## Extensões (depois que tudo estiver 100%)

- **Contrato OpenAPI** na api e client TypeScript gerado no web, com o CI quebrando quando o contrato muda.
- **Supply chain:** scan de imagem (Trivy), SBOM e assinatura (cosign), verificada no cluster.
- **Observabilidade:** OpenTelemetry (traces web → api → Kafka → worker), Prometheus/Grafana, SLOs e alertas. Com Prometheus, a análise do canary migra do CloudWatch para métricas da própria app.
- **CloudFront + WAF** na frente do painel e da api, e **CSP** no nginx.
- **BFF** para que os tokens OIDC não fiquem no navegador.
- **Managed login v2** do Cognito, com branding.
- **GitHub OIDC → AWS** com roles por conta: `terraform plan` automático nos PRs do `shortener-deploy`.
- **Control Tower / Account Factory**, com contas de log-archive e audit.
- **Preview environments** por PR (ApplicationSet do ArgoCD).
- **External Secrets Operator + Secrets Manager:** tira as senhas do state do Terraform.
- **Autenticação IAM no MSK**, no lugar de TLS sem autenticação.
- **Karpenter** no lugar do node group fixo.
- **NetworkPolicies** (precisa ligar o suporte no VPC CNI).
- **Outbox pattern:** garante que nenhum clique se perca se o Kafka cair por mais de 5 minutos.
- **Limpeza periódica** da tabela `processed_events`.
- **`rollbackWindow` no Rollout da api:** rollback rápido (sem novo canary) para versões recentes.
- **Retenção de chunks antigos do web** (ex.: assets servidos de um bucket que acumula versões), para o painel poder usar `React.lazy` sem 404 depois de um blue-green.
- **Smoke e2e pós-deploy:** o Playwright da Fase 3 rodando contra staging depois de cada sync.
- **"Dia de HA":** ligar `rds_multi_az`, 3 brokers e um NAT por AZ, e medir quanto custa.
