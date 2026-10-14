# Design: frontend React, entrega progressiva (canary) e uma conta AWS por ambiente

**Data:** 2026-10-12
**Status:** aprovado na conversa de planejamento (seções 1 e 1-revisada); seções seguintes aprovadas por delegação ("pode seguir até finalizar toda a documentação").
**Escopo:** só documentação. Nada é implementado nesta etapa.

## 1. Objetivo

Evoluir o plano do encurtador (`docs/plano/`) para:

1. Ter uma **interface React** como aplicação separada, com build, imagem, deploy e ciclo de vida próprios.
2. Ter **login de usuário** (OIDC) e o conceito de "meus links", já que uma chave de API não pode ir para o navegador.
3. Fazer **entrega progressiva**: canary com análise automática na api e blue-green no frontend (Argo Rollouts).
4. Usar **uma conta AWS por ambiente** (AWS Organizations), como em empresa.

Continua valendo: o projeto é de estudo, então realismo importa mais do que atalhos, e os ambientes na AWS são efêmeros (sobe e derruba a cada sessão), com custo mensal perto de zero.

## 2. Decisões tomadas

| Tema | Decisão | Alternativas descartadas |
|---|---|---|
| Repositórios | 3 repos: `shortener-api`, `shortener-web` e `shortener-deploy` (GitOps + Terraform + scripts + plano) | 2 repos com `deploy/` próprio; monorepo |
| Hospedagem do frontend | Container nginx no EKS, implantado pelo ArgoCD | S3 + CloudFront; Next.js SSR |
| Autenticação | OIDC (Authorization Code + PKCE). Cognito na AWS, `mock-oauth2-server` em dev. `API_KEY` continua para máquina-a-máquina | Proxy injetando a chave; criação pública |
| Domínios | 3 hosts por ambiente num único ALB (IngressGroup) | 2 hosts com `/api` no mesmo host do painel |
| Entrega progressiva | api: canary com pesos no ALB e análise no CloudWatch. web: blue-green com análise de smoke. worker: rolling update | Rolling update em tudo |
| Contas AWS | Organizations com `management`, `shared`, `staging` e `prod`; SCPs; SSO com um profile por conta | Uma conta só |

## 3. Repositórios

Pastas irmãs no Mac. A pasta atual (`~/Documents/projects/teste`) **é** o `shortener-api`. Os outros dois são clonados ao lado: `~/Documents/projects/shortener-web` e `~/Documents/projects/shortener-deploy`. O usuário pode renomear `teste` para `shortener-api` quando quiser; o plano se refere a ela como "a pasta do `shortener-api`".

| Repo | Conteúdo | Artefato publicado |
|---|---|---|
| `shortener-api` | `src/` (api, worker, setup), `migrations/`, testes, `Dockerfile`, `docker-compose.yml` (infra local + IdP mock), `.github/workflows/{ci,release}.yml` | `ghcr.io/<org>/shortener-api:sha-<7>` |
| `shortener-web` | App Vite + React + TS, testes, `nginx/`, `Dockerfile`, `.github/workflows/{ci,release}.yml` | `ghcr.io/<org>/shortener-web:sha-<7>` |
| `shortener-deploy` | `apps/{api,web}/{base,overlays/{staging,prod}}` (Kustomize), `infra/` (Terraform), `scripts/`, `load/` (k6), `docs/plano/` e `docs/superpowers/`, `.github/workflows/{ci,promote}.yml` | estado desejado de cada ambiente |

`<org>` = organização do GitHub que é dona dos 3 repos (`shortener-lab`), em minúsculas. Os 3 repos são públicos (ArgoCD e cluster leem Git e imagens sem credencial; segredos nunca entram no Git).

O `package.json` do `shortener-api` passa de `name: shortener` para `name: shortener-api` (Fase 4).

## 4. Contas AWS

| Conta | Nome/alias | OU | Conteúdo |
|---|---|---|---|
| management | `shortener-mgmt` | raiz | Organizations, IAM Identity Center, billing consolidado, budget da organização, SCPs. **Nenhum workload.** |
| shared | `shortener-shared` | `Infrastructure` | Bucket de state do Terraform de todas as contas |
| staging | `shortener-staging` | `Workloads` | ACM, Cognito, VPC, EKS, RDS, ElastiCache, MSK de staging |
| prod | `shortener-prod` | `Workloads` | O mesmo, isolado |

- **IDs nos docs:** `<MGMT_ACCOUNT_ID>`, `<SHARED_ACCOUNT_ID>`, `<STAGING_ACCOUNT_ID>`, `<PROD_ACCOUNT_ID>`.
- **E-mails das contas-membro:** alias com `+`, por exemplo `<seu-email>+shortener-staging@gmail.com`. Nunca escrever o e-mail real nos docs.
- **Criação das contas:** Terraform em `infra/organization/` (rodado com o profile `shortener-mgmt`), com `aws_organizations_organizational_unit`, `aws_organizations_account`, `aws_organizations_policy` (SCP) e as atribuições do Identity Center (`aws_ssoadmin_account_assignment`). O state começa local e migra para o bucket da `shared` depois que ele existe ("ovo e galinha" de novo).
- **SCPs** (anexadas às OUs `Infrastructure` e `Workloads`):
  - `deny-other-regions`: nega ações fora de `us-east-1`, com `NotAction` para serviços globais (IAM, Organizations, STS, SSO, Route 53, CloudFront, Budgets, Cost Explorer, Support, Account, Health etc.). Usar o exemplo oficial da AWS como base.
  - `deny-leave-org`: nega `organizations:LeaveOrganization`.
  - `deny-root-user`: nega ações do usuário root nas contas-membro.
- **Root das contas-membro:** usar o "centralized root access management" do IAM (Organizations) para remover as credenciais root das contas-membro. Opcional, mas recomendado.
- **SSO:** uma `sso-session` chamada `shortener` no `~/.aws/config`, com os profiles `shortener-mgmt`, `shortener-shared`, `shortener-staging` e `shortener-prod` (permission set `AdministratorAccess`, sessão de 8h).
- **Terraform e contas:**
  - Backend S3 de **todas** as raízes: bucket `shortener-tfstate-<SHARED_ACCOUNT_ID>`, `region = "us-east-1"`, `use_lockfile = true`, `profile = "shortener-shared"`.
  - Provider `aws` de cada raiz: `profile = "shortener-<env>"` e `allowed_account_ids = ["<ENV_ACCOUNT_ID>"]` (trava de segurança contra aplicar na conta errada).
  - Chaves de state: `organization/terraform.tfstate`, `bootstrap/shared.tfstate`, `bootstrap/staging.tfstate`, `bootstrap/prod.tfstate`, `envs/<env>/aws.tfstate`, `envs/<env>/platform.tfstate`.
  - Em empresa, o CI assumiria papéis entre contas (OIDC do GitHub → role); aqui, o humano usa SSO. Fica nas extensões.
- **Billing e créditos:** budget de US$ 20 na management, cobrindo a organização. Créditos promocionais da management são compartilhados com as contas-membro por padrão ("credit sharing"); o plano manda conferir em Billing → Preferences.
- **Fechar contas-membro:** ficam 90 dias suspensas antes de sumir; a AWS limita quantas contas se fecha por período. Entra no encerramento final.
- **Benefício colateral:** `leftovers.sh` agora roda dentro da conta do ambiente, então os recursos de um ambiente nunca aparecem como "sobra" do outro.

## 5. Domínios e TLS

| | staging | prod |
|---|---|---|
| Links curtos (só redirect) | `shortener-staging.fabricioroglio.com` | `shortener.fabricioroglio.com` |
| API REST | `api.shortener-staging.fabricioroglio.com` | `api.shortener.fabricioroglio.com` |
| Painel React | `app.shortener-staging.fabricioroglio.com` | `app.shortener.fabricioroglio.com` |

- **DNS:** zona `fabricioroglio.com` na Cloudflare, registros DNS-only (não proxied), criados pelo external-dns de cada cluster (`txtOwnerId = shortener-<env>`).
- **Certificado:** um certificado ACM por conta, com o host curto como `domain_name` e os outros dois como SANs. Fica no bootstrap da conta (permanente, grátis), validado via Cloudflare (3 CNAMEs).
- **ALB:** um por cluster. Os Ingresses `api` (2 hosts: curto e `api.`) e `web` (host `app.`) usam `alb.ingress.kubernetes.io/group.name: shortener` e o mesmo `certificate-arn`.
- **CORS:** a api aceita só as origens de `CORS_ALLOWED_ORIGINS`: em staging `https://app.shortener-staging.fabricioroglio.com`, em prod `https://app.shortener.fabricioroglio.com`, em dev `http://localhost:5173,http://localhost:8081`.
- `PUBLIC_BASE_URL` continua sendo o host curto (é dele que saem os `shortUrl`).

## 6. Identidade (OIDC)

### 6.1 Na AWS: Cognito, um por conta (bootstrap permanente)

- User pool `shortener-<env>`, login por e-mail, auto-cadastro habilitado com verificação de e-mail (o remetente padrão do Cognito tem limite diário baixo, o que basta para estudo).
- Domínio do Hosted UI com prefixo `shortener-<env>-<sufixo aleatório>` (precisa ser único na região). Usar o Hosted UI clássico (`managed_login_version = 1`) para não precisar de branding; o managed login v2 fica como extensão.
- App client `shortener-web`: público (sem secret), `allowed_oauth_flows = ["code"]`, scopes `openid email profile`, callback `https://app.<host>/callback`, logout `https://app.<host>/`, access token de 1h, refresh token de 1 dia.
- Saídas do bootstrap da conta: `certificate_arn`, `cognito_user_pool_id`, `oidc_authority` (= issuer), `oidc_issuer` (`https://cognito-idp.us-east-1.amazonaws.com/<pool_id>`), `oidc_jwks_url` (`<issuer>/.well-known/jwks.json`), `oidc_client_id`, `oidc_logout_url` (`https://<prefixo>.auth.us-east-1.amazoncognito.com/logout`).
- Usuários sobrevivem ao sobe-e-desce dos ambientes, porque o pool fica no bootstrap.

### 6.2 Em dev: `mock-oauth2-server` no compose do `shortener-api`

- Serviço `oidc` (imagem `ghcr.io/navikt/mock-oauth2-server`, versão fixada), porta `8090`, no compose **sem profile** (sobe junto com a infra local, porque o frontend em dev precisa dele).
- Issuer `http://localhost:8090/shortener`, JWKS `http://localhost:8090/shortener/jwks`. Config JSON com `interactiveLogin: true` e um token callback que põe `aud = shortener-web`.
- Dentro do compose, a api em container busca o JWKS em `http://oidc:8090/shortener/jwks`, mas valida `iss = http://localhost:8090/shortener`, porque o token é emitido para o navegador. É por isso que `OIDC_JWKS_URL` é configurável à parte do `OIDC_ISSUER`.

### 6.3 Validação na api

- Biblioteca `jose` (`createRemoteJWKSet` + `jwtVerify`), com algoritmo RS256.
- Variáveis novas (só na api): `OIDC_ISSUER`, `OIDC_AUDIENCE` (client id do web) e `OIDC_JWKS_URL`.
- Aceita o token se `iss` bate e **(`aud` contém `OIDC_AUDIENCE` OU `client_id == OIDC_AUDIENCE`)**. O access token do Cognito não tem `aud`; ele usa `client_id` e `token_use = access`. Se `token_use` existir, precisa ser `access`.
- O identificador do usuário é o `sub`.

## 7. Backend (`shortener-api`), mudanças da Fase 2

- **Migration `002_link_owner.sql`:** `ALTER TABLE links ADD COLUMN owner_id text;` + índice `(owner_id, created_at DESC, code DESC)`. É compatível com a versão anterior (expand).
- **Principal:** `type Principal = { kind: 'user'; sub: string } | { kind: 'service' }`, guardado em `res.locals.principal`.
- **Middleware `authenticate({ apiKey, verifyToken })`:** `Authorization: Bearer <jwt>` → user; `x-api-key` válida (comparação em tempo constante, como hoje) → service; senão 401. `requireUser` exige `kind === 'user'` (403 para service).
- **Repositório:**
  - `insert(code, url, ownerId: string | null)`
  - `findUrl(code)` (sem mudança)
  - `getOwner(code)` → `string | null | undefined` (undefined = link não existe)
  - `listByOwner(ownerId, { limit, cursor? })` → `{ items: { code, url, createdAt, totalClicks }[]; nextCursor: string | null }`, com paginação keyset por `(created_at, code)` e cursor opaco em base64url
  - `getStats(code)` (sem mudança)
- **Endpoints:**

| Método e rota | Auth | Resposta |
|---|---|---|
| `GET /healthz`, `GET /readyz` | não | sem mudança |
| `POST /links` `{url}` | rate limit → user **ou** service | `201 {code, shortUrl, url, createdAt}`. Grava `owner_id = sub` (user) ou `null` (service) |
| `GET /me/links?limit&cursor` | user | `200 {items: [{code, shortUrl, url, createdAt, totalClicks}], nextCursor}`; `limit` padrão 20, máximo 100 |
| `GET /links/:code/stats` | user dono **ou** service | `200 LinkStats`. `404` se não existe **ou** se o user não é o dono (não vaza existência) |
| `GET /:code` | não | sem mudança |

- **CORS:** pacote `cors` com allowlist de `CORS_ALLOWED_ORIGINS`, `allowedHeaders: [Authorization, Content-Type]`, `exposedHeaders: [RateLimit-Limit, RateLimit-Remaining, Retry-After]`, `maxAge: 600`. Fica antes das rotas da API; não interfere no redirect.
- **Ordem no `POST /links`:** rate limit → authenticate → handler (o rate limit continua freando força bruta).
- **Config:** `OIDC_*` e `CORS_ALLOWED_ORIGINS` são obrigatórios em `apiSchema` (o worker e o setup não exigem).
- **Dependências novas:** `jose`, `cors`, `@types/cors`.

## 8. Frontend (`shortener-web`), Fase 3

- **Scaffold pela CLI:** `npm create vite@latest shortener-web -- --template react-ts` (preferência do usuário: nunca criar à mão os arquivos que a CLI gera). Ajustes via `npm pkg set`.
- **Stack:** React 19, React Router 7 (pacote `react-router`, modo declarativo), TanStack Query 5, `oidc-client-ts` + `react-oidc-context`, `zod`. Testes: Vitest, Testing Library, jsdom, MSW 2. E2E: Playwright, só local (contra o compose do `shortener-api`).
- **Config de runtime** (a mesma imagem vai para staging e prod):
  - `index.html` carrega `/runtime/config.js` **antes** do bundle. O arquivo define `window.__APP_CONFIG__ = { apiBaseUrl, oidcAuthority, oidcClientId, oidcLogoutUrl? }`.
  - `src/config.ts` valida com zod e falha com mensagem clara.
  - Em dev, `public/runtime/config.js` aponta para `http://localhost:3000` e para o mock.
  - No container, um script em `/docker-entrypoint.d/` gera o arquivo a partir de `API_BASE_URL`, `OIDC_AUTHORITY`, `OIDC_CLIENT_ID` e `OIDC_LOGOUT_URL` (opcional).
- **Rotas:**

| Rota | Acesso | Conteúdo |
|---|---|---|
| `/` | público | Landing com botão "Entrar"; logado, redireciona para `/links` |
| `/callback` | público | Conclui o login (PKCE) |
| `/links` | protegido | Formulário de criação + lista paginada de "meus links" (copiar URL curta, total de cliques) |
| `/links/:code` | protegido | Detalhe: total, gráfico de barras dos últimos 30 dias (SVG próprio, sem lib) e tabela de navegadores |
| `*` | público | 404 |

- **Cliente da API:** `src/api/client.ts`, com `fetch`, Bearer obtido do `react-oidc-context`, respostas validadas com zod e `ApiError { status, code }`. Em 401, dispara novo login; em 429, mostra "muitas requisições, tente em N s" a partir de `Retry-After`.
- **Tokens:** `sessionStorage` (`WebStorageStateStore`) e renovação silenciosa via refresh token. O trade-off (XSS × conveniência) é explicado; BFF fica nas extensões.
- **Container:**
  - Multi-stage: `node:24-slim` (build) → `nginxinc/nginx-unprivileged` (alpine, versão fixada), porta `8080`, usuário 101.
  - `nginx.conf`: fallback de SPA para `index.html`; `/assets/*` com `Cache-Control: public, max-age=31536000, immutable`; `index.html` e `/runtime/config.js` com `no-store`; `/healthz` → 200; headers de segurança (`X-Content-Type-Options`, `Referrer-Policy`, `X-Frame-Options: DENY`). CSP fica nas extensões (depende de hosts de runtime).
  - Root filesystem somente leitura no K8s: `/usr/share/nginx/html/runtime` e `/tmp` são `emptyDir`.
- **Portas em dev:** Vite `5173`; container local `8081` (`docker run -p 8081:8080 ...`).

## 9. Kubernetes e GitOps (`shortener-deploy`)

```
apps/
├── api/
│   ├── base/        kustomization.yaml  rollout.yaml  services.yaml (api-stable, api-canary)
│   │                ingress.yaml  hpa.yaml  pdb.yaml  analysis-template.yaml
│   │                worker-deployment.yaml  setup-job.yaml  rollout-transform.yaml
│   └── overlays/{staging,prod}/kustomization.yaml
└── web/
    ├── base/        kustomization.yaml  rollout.yaml  services.yaml (web-active, web-preview)
    │                ingress.yaml  pdb.yaml  analysis-template.yaml  rollout-transform.yaml
    └── overlays/{staging,prod}/kustomization.yaml
```

- **`rollout-transform.yaml`:** config oficial do Argo Rollouts para o Kustomize, referenciada em `configurations:`. Sem ela, o Kustomize não troca o nome com hash dos ConfigMaps gerados dentro do `Rollout`.
- **Namespace:** `shortener`, compartilhado pelas duas apps.
- **Applications do ArgoCD:** `shortener-api` (path `apps/api/overlays/<env>`) e `shortener-web` (path `apps/web/overlays/<env>`), repo `https://github.com/<org>/shortener-deploy.git`, revisão `main`, `automated: {prune, selfHeal}`.
- **Imagens no Kustomize:** nome lógico `shortener-api` → `ghcr.io/<org>/shortener-api`; `shortener-web` → `ghcr.io/<org>/shortener-web`. O seletor do `yq` passa a ser `select(.name == "shortener-api")` ou `select(.name == "shortener-web")`.
- **Config dos pods:**

| Origem | Nome | Conteúdo | Quem escreve | Usado por |
|---|---|---|---|---|
| ConfigMap | `shortener-infra` | `KAFKA_BROKERS`, `KAFKA_SSL`, `KAFKA_REPLICATION_FACTOR`, `REDIS_URL`, `DATABASE_SSL`, `DATABASE_SSL_CA_FILE` | Terraform (platform) | api, worker, setup |
| Secret | `shortener-secrets` | `DATABASE_URL`, `API_KEY` | Terraform (platform) | api, worker, setup |
| ConfigMap | `shortener-oidc` | `OIDC_ISSUER`, `OIDC_AUDIENCE`, `OIDC_JWKS_URL`, `OIDC_AUTHORITY`, `OIDC_CLIENT_ID`, `OIDC_LOGOUT_URL` | Terraform (platform, lendo o bootstrap da conta) | api, web |
| ConfigMap | `shortener-api-config-<hash>` | `PUBLIC_BASE_URL`, `CORS_ALLOWED_ORIGINS`, `LOG_LEVEL`, `CACHE_TTL_SECONDS`, `RATE_LIMIT_PER_MINUTE` | Kustomize (overlay) | api, worker |
| ConfigMap | `shortener-web-config-<hash>` | `API_BASE_URL` | Kustomize (overlay) | web |

- **api (Argo Rollouts, canary):**
  - `Rollout` `api` (substitui o Deployment); o HPA aponta para `kind: Rollout`.
  - `trafficRouting.alb` no Ingress `api`, com `stableService: api-stable` e `canaryService: api-canary`.
  - Passos: `setWeight 10` → `pause 2m` → `analysis api-error-rate` → `setWeight 50` → `pause 2m` → `analysis api-error-rate` → 100%.
  - `AnalysisTemplate api-error-rate`: provider **CloudWatch**, consulta `HTTPCode_Target_5XX_Count / RequestCount` do target group do **canary** (via expressão `SEARCH` no nome do target group, que o LB controller cria com o nome do service), janela de 2 min e sucesso se < 1%. Sem tráfego, conta como sucesso: a demonstração usa k6 gerando carga.
  - O controller do Argo Rollouts precisa de `cloudwatch:GetMetricData`/`ListMetrics` via EKS Pod Identity (camada aws).
- **web (Argo Rollouts, blue-green):** `Rollout` `web` com `activeService: web-active`, `previewService: web-preview`, `autoPromotionEnabled: true`, `prePromotionAnalysis` com o template `web-smoke` (provider `job`: um pod `curl` checa `/healthz`, `/` e `/runtime/config.js` no `web-preview`) e `scaleDownDelaySeconds: 30`. Réplicas: staging 1, prod 2; sem HPA.
- **worker:** continua `Deployment` com rolling update.
- **setup:** continua `Job` PreSync, dentro da app `shortener-api`.
- **Por que essas estratégias:** canary em SPA quebra, porque o `index.html` novo pede assets com hash que só existem nos pods novos; com tráfego dividido, esses pedidos caem nos pods velhos e dão 404. Consumidor Kafka não tem tráfego HTTP para dividir.

## 10. Infra (Terraform em `shortener-deploy/infra`)

```
infra/
├── organization/                    # conta management: OUs, contas, SCPs, Identity Center
├── bootstrap/
│   ├── shared/                      # conta shared: bucket de state
│   ├── modules/account-baseline/    # ACM (3 hosts) + Cognito (user pool, domínio, app client)
│   ├── staging/                     # usa account-baseline na conta staging
│   └── prod/
├── modules/
│   ├── aws-environment/             # camada 1: VPC, EKS, RDS, ElastiCache, MSK, Pod Identities (LBC e Argo Rollouts)
│   └── platform/                    # camada 2: LBC, external-dns, metrics-server, ArgoCD, Argo Rollouts, config da app
└── envs/{staging,prod}/{aws,platform}/
```

- A camada `platform` lê `envs/<env>/aws.tfstate` **e** `bootstrap/<env>.tfstate` (para o `shortener-oidc`).
- `argocd-apps` cria 2 Applications.
- Helm release `argo-rollouts` (chart `argo/argo-rollouts`, namespace `argo-rollouts`, versão fixada em `chart_versions`).
- Scripts (`scripts/up.sh`, `down.sh` e `leftovers.sh`) recebem o ambiente, usam `AWS_PROFILE=shortener-<env>`, esperam as 2 Applications `Healthy` e, no `down`, apagam as 2 Applications antes do destroy (o ALB compartilhado só some quando os 2 Ingresses somem).
- kubeconfig: `aws eks update-kubeconfig --profile shortener-<env> --alias shortener-<env>`; o `exec` dos providers kubernetes/helm passa `--profile`.

## 11. CI/CD

- **`shortener-api` e `shortener-web`:**
  - `ci.yml` em PR (lint, typecheck, testes e build da imagem ARM64).
  - `release.yml` no push da `main`: CI → imagem `sha-<7>` no GHCR → job `deploy-staging`, que gera um token do GitHub App, faz checkout do `shortener-deploy`, roda `yq` no overlay de staging da app, commita `deploy(staging): <app> sha-<7>` e faz push com retry.
- **GitHub App `<org>-deployer`** (registrado na org): permissão `Contents: Read and write`, instalada **só** no `shortener-deploy`. `DEPLOYER_CLIENT_ID` e `DEPLOYER_APP_ID` (variables; o client id gera o token e o app id numérico entra no bypass do ruleset) e `DEPLOYER_PRIVATE_KEY` (secret) definidos na org, com visibilidade `selected` para os 3 repos. Token via `actions/create-github-app-token@v3` com `client-id`.
- **`shortener-deploy`:**
  - `ci.yml` em PR: `terraform fmt -check` e `validate` em todas as raízes; `kustomize build` + `kubeconform` (com schemas de CRD do Argo Rollouts via catálogo de CRDs).
  - `promote.yml` (`workflow_dispatch`, inputs `app` ∈ {`api`, `web`} e `tag` opcional): environment `production` com required reviewer, valida a tag (`^sha-[0-9a-f]{7}$`), confere se a imagem existe, commita `deploy(prod): <app> sha-<7>` usando o token do App.
- **Proteção de branch:** ruleset na `main` do `shortener-deploy` exigindo PR, com bypass para o GitHub App. Na `main` do `shortener-api` e do `shortener-web`, exige PR e check de CI verde.
- **Promoção independente:** prod pode ter api `sha-aaa` e web `sha-bbb`. O contrato entre eles é a API REST, que precisa ser compatível com a versão anterior (expand/contract também na API).

## 12. Nova numeração das fases

| Fase | Arquivo | Repo(s) | Entrega |
|---|---|---|---|
| 1 | `01-dev-local.md` | api | (concluída) app completo no compose |
| 2 | `02-api-auth.md` | api | OIDC na api, dono do link, `/me/links`, CORS, IdP mock no compose |
| 3 | `03-frontend.md` | web | Painel React com login, testes e imagem nginx com config de runtime |
| 4 | `04-ci.md` | os 3 | Repos no GitHub, CI e Release de api e web, esqueleto do deploy |
| 5 | `05-aws-organizacao-bootstrap.md` | deploy | Organizations, contas, SCPs, SSO, state na shared, ACM + Cognito por conta |
| 6 | `06-terraform-ambientes.md` | deploy | Staging sobe e desce com um comando na sua própria conta, com Argo Rollouts |
| 7 | `07-kubernetes-gitops.md` | deploy | api (canary) e web (blue-green) no ar em staging via ArgoCD |
| 8 | `08-cd-promocao.md` | os 3 | CD entre repos (GitHub App), promoção por app, canary abortando sozinho |
| 9 | `09-operacao.md` | os 3 | Caos, runbooks e desligamento (incluindo fechar contas) |

Os arquivos antigos 02–07 são renomeados com `git mv` para os novos números e reescritos.

## 13. Custos

- Contas, Organizations, SCPs, Identity Center e Cognito Lite (até 10 mil MAU): US$ 0.
- Por ambiente de pé: continua ~US$ 0,38/h. Argo Rollouts e os pods do web cabem nos nós existentes. CloudWatch `GetMetricData` custa centavos durante as análises.
- Os dois ambientes juntos: ~US$ 0,76/h. Cada conta aparece separada no Cost Explorer da management, o que é um bônus didático.

## 14. Fora de escopo (vai para as extensões do README)

Contrato OpenAPI com client gerado; supply chain (Trivy, SBOM, cosign); observabilidade (OpenTelemetry, Prometheus/Grafana); CloudFront + WAF na frente do web; CSP; BFF para tokens; managed login v2 do Cognito; GitHub OIDC → AWS para `terraform plan` em PR; Control Tower/Account Factory; preview environments por PR; External Secrets; IAM auth no MSK; outbox pattern; limpeza de `processed_events`.

## 15. Testes (o que cada fase prova)

- **Fase 2:** unit para o verificador de JWT (chaves geradas no teste, `aud` × `client_id`, emissor errado, expirado, `token_use` errado); integração HTTP para auth (user/service/nenhum), dono × não-dono nas stats, paginação de `/me/links`, CORS permitido × negado e migration 002.
- **Fase 3:** unit para config e client da API (MSW); componentes (formulário valida URL; lista; detalhe; 401 → login; 429 → mensagem); rota protegida; e2e Playwright local (login no mock → criar → abrir link curto → ver clique nas stats).
- **Fases 7 e 8:** smoke em staging pelo navegador (cadastro no Cognito → criar link → stats); canary progredindo com k6 sem erro; canary com bug abortando sozinho; blue-green do web sem 404 de assets.
