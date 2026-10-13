# Fase 9: operação, caos e desligamento

**Entrega:**
- Você viu o sistema falhar de propósito e se recuperar, inclusive com o Argo Rollouts no meio.
- Tem runbooks para o dia a dia com várias contas AWS.
- Termina com **custo zero comprovado** e, se quiser, com as contas fechadas.

**Repos:** os 3. Os experimentos locais rodam na pasta do `shortener-api`; os da AWS e os scripts rodam no `shortener-deploy`.

---

## Runbook: sessão de estudo

**Início** (no `shortener-deploy`):

```bash
aws sso login --sso-session shortener        # um login vale para shortener-mgmt, -shared, -staging e -prod (8h)
aws sts get-caller-identity --profile shortener-staging --query Account --output text   # <STAGING_ACCOUNT_ID>

export CLOUDFLARE_API_TOKEN='...'; export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"
export CLOUDFLARE_ZONE_ID='...'

scripts/up.sh staging            # ~40 min, conta shortener-staging. Prod só quando precisar: scripts/up.sh prod
kubectl config get-contexts      # shortener-staging (e shortener-prod, se subiu)
```

**Não exporte `AWS_PROFILE` à toa.** Os scripts e os providers do Terraform já escolhem o profile pelo ambiente (`shortener-<env>`), e o backend usa `shortener-shared`. Um `AWS_PROFILE` esquecido no shell só confunde os comandos `aws` avulsos. Quando precisar de um, passe `--profile` no próprio comando.

**Fim (sempre):**

```bash
scripts/down.sh prod             # se estiver de pé
scripts/down.sh staging
scripts/leftovers.sh staging     # roda dentro da conta shortener-staging
scripts/leftovers.sh prod        # roda dentro da conta shortener-prod
```

Como cada ambiente tem a sua conta, o `leftovers.sh` de um nunca enxerga recursos do outro: "sobra" é sobra mesmo.

**No dia seguinte:** na conta **management** (a única com a visão consolidada), Console → **Billing and Cost Management** → **Cost Explorer**:
- **Group by:** *Linked account*. Cada conta aparece numa linha: staging e prod com o custo das horas de pé, shared com centavos, management com ~0.
- Confira se bate com as horas de pé (~US$ 0,38 por hora por ambiente).

Pelo terminal (cada chamada da API do Cost Explorer custa US$ 0,01):

```bash
aws ce get-cost-and-usage --profile shortener-mgmt \
  --time-period Start=$(date -v-7d +%F),End=$(date +%F) --granularity DAILY \
  --metrics UnblendedCost --group-by Type=DIMENSION,Key=LINKED_ACCOUNT \
  --query 'ResultsByTime[].{dia:TimePeriod.Start,contas:Groups[].[Keys[0],Metrics.UnblendedCost.Amount]}'
```

## Tabela de custos (referência)

| Recurso (por ambiente, na conta do ambiente) | US$/hora |
|---|---|
| EKS (plano de controle) | 0,100 |
| MSK, 2× kafka.t3.small | 0,091 |
| 2× EC2 t4g.medium (api, worker, web, Argo Rollouts e controllers cabem aqui) | 0,067 |
| NAT Gateway | 0,045 |
| ALB (um só, compartilhado pelos 3 hosts via IngressGroup) | ~0,025 |
| RDS db.t4g.micro | 0,016 |
| ElastiCache cache.t4g.micro | ~0,016 |
| IPv4 públicos e EBS | ~0,020 |
| CloudWatch `GetMetricData` (análises do canary) | centavos por sessão |
| **Total** | **~0,38** |

Os dois ambientes juntos: **~US$ 0,76/h**.

| Permanente (sempre de pé) | Custo |
|---|---|
| Contas, Organizations, SCPs, IAM Identity Center | 0 |
| Cognito Lite (até 10 mil usuários ativos/mês), um user pool por conta | 0 |
| Certificados ACM públicos, um por conta | 0 |
| Bucket de state na conta shared | centavos |

---

## Experimentos de caos

**Antes de cada experimento, escreva a sua hipótese** ("acho que vai acontecer X"). Depois compare com o que aconteceu. É isso que transforma o experimento em aprendizado.

### Local (docker-compose, na pasta do `shortener-api`), sem custo

**C1. Redis fora do ar**

```bash
docker compose stop valkey
curl -si localhost:3000/<code> | head -1          # 302: segue funcionando
docker compose logs api | grep -i "cache indisponível" | tail -2
docker compose start valkey
```

Pergunta: por que **não** tiramos a api do ar (readiness) quando o Redis cai?

**C2. Kafka fora do ar por pouco tempo**

```bash
docker compose stop kafka
for i in $(seq 1 10); do curl -s -o /dev/null localhost:3000/<code>; done   # todos 302
sleep 30 && docker compose start kafka
# espere ~1 min e consulte /stats: os 10 cliques aparecem
```

O cliente Kafka segurou as mensagens em memória e entregou quando o broker voltou. Se a queda passasse do `message.timeout.ms` (padrão: 5 min), elas se perderiam. A solução robusta é o *outbox pattern*, listado nas extensões do README.

**C3. Consumer group com mais réplicas que partições**

```bash
docker compose --profile app up -d --scale worker=4
docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group shortener-analytics
```

Esperado: 3 partições divididas entre 3 consumers; o 4º fica sem partição. Pare um worker com `docker stop <container>` e rode o comando de novo: houve rebalance.

**C4. Mensagem envenenada**

```bash
docker compose exec kafka bash -c 'echo "abcDEF1:isto não é json" | /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 --topic link.clicked --property parse.key=true --property key.separator=:'
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic link.clicked.dlq --from-beginning --max-messages 1 --property print.headers=true
```

Esperado: a mensagem foi para a DLQ com o header `error`, e o worker continua processando as outras.

**C5. IdP fora do ar**

Preparação: suba o compose com a api (`docker compose --profile app up -d`) e o web em dev (`npm run dev` no `shortener-web`). Faça login em `http://localhost:5173`, abra DevTools → **Application** → **Session Storage**, copie o `access_token` da chave `oidc.user:...` e crie um link pelo painel.

```bash
TOKEN='<access_token copiado>'
curl -s -o /dev/null -w '%{http_code}\n' localhost:3000/me/links -H "Authorization: Bearer $TOKEN"   # 200

docker compose stop oidc

curl -s -o /dev/null -w '%{http_code}\n' localhost:3000/me/links -H "Authorization: Bearer $TOKEN"   # 200 (ainda)
curl -si localhost:3000/<code> | head -1                                                           # 302
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:3000/links -H "x-api-key: $API_KEY" \
  -H 'content-type: application/json' -d '{"url":"https://example.com"}'                           # 201
```

No navegador: **Sair** e **Entrar** de novo → o redirect para `localhost:8090` falha (o IdP não responde).

Depois, reinicie só a api com o IdP ainda parado e repita a primeira chamada:

```bash
docker compose restart api
curl -s -o /dev/null -w '%{http_code}\n' localhost:3000/me/links -H "Authorization: Bearer $TOKEN"   # 401
docker compose start oidc
```

**Explicação:**
- **Login novo depende do IdP**; ele está fora, então ninguém entra.
- **Tokens já emitidos continuam válidos** até expirar: a api valida a assinatura **localmente** com a chave pública do JWKS, sem perguntar nada ao IdP a cada requisição.
- **O `jose` faz cache do JWKS** (`createRemoteJWKSet`): por padrão, ele busca de novo depois de `cacheMaxAge` = 10 minutos, ou quando chega um `kid` desconhecido (com intervalo mínimo de 30 s). Se a nova busca falha, **o cache velho não é usado** e a verificação falha. Por isso, depois de ~10 min sem IdP, ou logo após um restart da api (cache vazio), até tokens válidos passam a dar 401.
- **Redirects e a chave de API não dependem do IdP.** O caminho que mais importa para o produto (`GET /:code`) nem passa por autenticação.
- **A renovação silenciosa** (refresh token) do painel também falha. Quando o access token expira, o usuário cai no login, que está fora.

Perguntas:
- 401 é a resposta certa quando o **IdP** está fora, e não o token? Ou seria 503 (falha de infraestrutura, "tente de novo")? Como o cliente se comportaria em cada caso?
- A readiness da api deveria depender do IdP? (Compare com a resposta do C1.)

### Na AWS (staging; custo da sessão)

Para os experimentos que mudam o cluster manualmente, **pause o auto-sync da Application envolvida**. Senão o selfHeal desfaz tudo em segundos. Agora são duas Applications; pause só a que for mexer:

```bash
kubectl --context shortener-staging -n argocd patch application shortener-api --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
# ao terminar, reative:
kubectl --context shortener-staging -n argocd patch application shortener-api --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

(Para o web, troque `shortener-api` por `shortener-web`.)

**A1. Lag do consumer no MSK** (auto-sync de `shortener-api` pausado: o worker faz parte dela)

```bash
K="kubectl --context shortener-staging -n shortener"
$K scale deploy/worker --replicas=0
for i in $(seq 1 200); do curl -s -o /dev/null https://shortener-staging.fabricioroglio.com/<code>; done

# Pod temporário com as ferramentas do Kafka, conectando via TLS:
$K run kafka-cli --rm -it --restart=Never --image=apache/kafka:3.9.1 \
  --env="BROKERS=$($K get cm shortener-infra -o jsonpath='{.data.KAFKA_BROKERS}')" -- bash -c '
  echo "security.protocol=SSL" > /tmp/ssl.properties
  /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server "$BROKERS" \
    --command-config /tmp/ssl.properties --describe --group shortener-analytics'
# coluna LAG ≈ 200, somando as partições

$K scale deploy/worker --replicas=1                 # rode o kafka-cli de novo: LAG volta para 0
```

**A2. Autoscaling (HPA → Rollout)**

```bash
k6 run -e BASE_URL=https://shortener-staging.fabricioroglio.com -e CODE=<code> -e DURATION=5m \
  -e RATE=300 load/redirect.js &
kubectl --context shortener-staging -n shortener get hpa api -w     # REFERENCE = Rollout/api; TARGETS sobe e REPLICAS vai de 1 para 2 ou 3
kubectl argo rollouts --context shortener-staging -n shortener get rollout api   # mais pods no ReplicaSet estável
```

O HPA não sabe nada de canary: ele mexe em `spec.replicas` do Rollout, e o Rollout distribui as réplicas entre os ReplicaSets. Depois da carga, o HPA leva cerca de 5 minutos para reduzir (janela de estabilização, que evita oscilar).

Pergunta: por que o `spec.replicas` do Rollout não está no Git? (Mesma resposta de quando era Deployment: o HPA e o selfHeal brigariam.)

**A3. Manutenção de nó (drain) sem derrubar o serviço**

```bash
NODE=$(kubectl --context shortener-staging get nodes -o name | head -1)
k6 run -e BASE_URL=https://shortener-staging.fabricioroglio.com -e CODE=<code> -e DURATION=4m load/redirect.js &
kubectl --context shortener-staging drain "$NODE" --ignore-daemonsets --delete-emptydir-data
kubectl --context shortener-staging uncordon "$NODE"
```

Esperado: o k6 termina sem erros. Com 1 réplica da api e 1 do web (staging), pode haver um blip curto; explique por quê e como prod (api com 2+ réplicas, web com 2, PDBs) evita isso.

**A4. Deploy quebrado na readiness** (sem pausar o ArgoCD; o fluxo é pelo Git)
1. Num PR no `shortener-deploy`, faça a readiness falhar de propósito: em `apps/api/base/rollout.yaml`, mude o `readinessProbe.httpGet.path` para `/nao-existe`. Os checks `infra` e `manifests` passam (o YAML é válido).
2. Com o k6 rodando, faça o merge e observe com `kubectl argo rollouts --context shortener-staging -n shortener get rollout api --watch`:
   - O ReplicaSet do canary sobe, mas o pod nunca fica `Ready`.
   - **O Rollout não progride.** O controller só muda o peso no ALB quando o canary está disponível, então o tráfego segue 100% no estável e o k6 continua sem erros.
   - Depois de `progressDeadlineSeconds` (600 s por padrão), o Rollout fica `Degraded` (`ProgressDeadlineExceeded`) e o ArgoCD mostra `Degraded`. Ele **não** aborta sozinho, a menos que `progressDeadlineAbort: true`.
3. Corrija com `git revert` do merge, por PR no `shortener-deploy`.

**Compare com a Tarefa 8.7:**

| | Readiness quebrada (A4) | Bug em runtime (8.7) |
|---|---|---|
| Quem pega | Kubernetes (probe), antes de qualquer tráfego | Análise no CloudWatch, com 10% do tráfego |
| Erros para o usuário | Zero | Poucos, só na janela de 10% |
| Estado final | `Degraded` por prazo, sem abort | `Degraded` por abort, 100% no estável |
| Lição | Probes boas barram o óbvio de graça | Métrica de negócio barra o que a probe não vê |

**A5. Matar pods aleatoriamente**

```bash
kubectl --context shortener-staging -n shortener delete pod -l app.kubernetes.io/component=worker
```

O ReplicaSet recria o pod, o consumer group rebalanceia e nenhum clique se perde. Confira as stats. Repita com um pod da api e um do web, com o k6 rodando: o PDB e as outras réplicas seguram (em staging, com 1 réplica, explique o blip).

**A6. Abortar um canary manualmente e retomar**

Dispare um canary inofensivo: num PR no `shortener-deploy`, mude `LOG_LEVEL` no `configMapGenerator` de `apps/api/overlays/staging/kustomization.yaml` (de `debug` para `info`). O hash do ConfigMap muda, o template do pod muda e o Rollout começa um canary. Com o k6 rodando e o Rollout em `Paused` a 10%:

```bash
R="kubectl argo rollouts --context shortener-staging -n shortener"
$R abort api
$R get rollout api                     # ✖ Degraded, RolloutAborted; peso 0/100; canary vai a zero após ~30 s
kubectl --context shortener-staging -n argocd get application shortener-api   # Synced + Degraded

$R retry rollout api                   # recomeça do passo 0 (10%)
$R get rollout api --watch
$R promote api                         # pula a pausa atual e vai para o próximo passo
# $R promote api --full                # pularia TODOS os passos e análises (evite: é desligar a rede de proteção)
```

Hipótese a conferir: o ArgoCD não reage ao `abort` nem ao `retry`, porque eles só mexem no **status** do Rollout; o spec continua igual ao Git. Já o `promote --full` também é status, mas tira o sentido da análise: use só quando você **sabe** que a versão é boa e a análise está errada.

**A7. `web-smoke` falhando: o active fica na versão antiga**

1. Num PR no `shortener-deploy`, deixe `API_BASE_URL` vazio no `configMapGenerator` de `apps/web/overlays/staging/kustomization.yaml` (`- API_BASE_URL=`).
2. Merge e observe:

```bash
kubectl argo rollouts --context shortener-staging -n shortener get rollout web --watch
kubectl --context shortener-staging -n shortener get pods -l app.kubernetes.io/component=web
kubectl --context shortener-staging -n shortener logs <pod-novo-do-web>     # o script do /docker-entrypoint.d/ falha: API_BASE_URL obrigatório
```

   - O pod do preview entra em `CrashLoopBackOff`; o preview nunca fica pronto, a `web-smoke` nem chega a rodar e **não há troca**.
   - `web-active` continua apontando para os pods antigos: `https://app.shortener-staging.fabricioroglio.com` segue funcionando.
   - Depois do `progressDeadlineSeconds`, o Rollout e a Application ficam `Degraded`.
3. Corrija com `git revert` do merge, por PR.

Variante para pensar: se o seu entrypoint **não** validasse a variável e gerasse `apiBaseUrl: ""`, o pod ficaria pronto e a `web-smoke` passaria (ela só checa HTTP 200 em `/runtime/config.js`), e a config quebrada iria para o active. O que você mudaria no `web-smoke` para pegar isso? (Por exemplo, um `grep 'apiBaseUrl: *"https://'` no conteúdo.)

---

## Encerramento final (quando tiver aprendido tudo)

A ordem importa: o state de **todas** as raízes do Terraform mora no bucket da conta shared. Se você destruir o bucket antes, perde o state de quem ainda existe.

- [ ] **1. Derrube os ambientes e confira as sobras, em cada conta**

```bash
scripts/down.sh prod && scripts/down.sh staging
scripts/leftovers.sh staging && scripts/leftovers.sh prod      # "OK: nenhuma sobra encontrada" nos dois
```

- [ ] **2. (Opcional) Destrua os bootstraps das contas de ambiente** (ACM e Cognito)
  - **Os usuários do Cognito somem**, e não há como recuperá-los.
  - Se você ligou `deletion_protection` no user pool, desligue (`INACTIVE`) e rode `apply` antes.
  - Com o token da Cloudflare exportado, os CNAMEs de validação do ACM também saem.

```bash
terraform -chdir=infra/bootstrap/staging destroy
terraform -chdir=infra/bootstrap/prod destroy
```

- [ ] **3. (Opcional, para zerar até os centavos) Tire o state do bucket e destrua o bucket**
  1. **Organização → state local.** Em `infra/organization`, comente o bloco `backend "s3"` e rode `terraform -chdir=infra/organization init -migrate-state` (responda `yes`). O `terraform.tfstate` passa a ficar na pasta. Ele **não** vai para o Git (`.gitignore`); guarde uma cópia no gerenciador de senhas ou num disco, porque ele descreve as suas contas.
  2. **Bootstrap da shared → state local.** Mesmo procedimento em `infra/bootstrap/shared`.
  3. **Libere a destruição do bucket.** Em `infra/bootstrap/shared`, remova o `lifecycle { prevent_destroy = true }` e acrescente `force_destroy = true` no `aws_s3_bucket` (apaga também todas as versões dos objetos). Rode `terraform -chdir=infra/bootstrap/shared apply`.
  4. `terraform -chdir=infra/bootstrap/shared destroy`.
  5. Confira: `aws s3 ls --profile shortener-shared` não lista mais `shortener-tfstate-<SHARED_ACCOUNT_ID>`.

- [ ] **4. (Opcional) Feche as contas-membro** (shared, staging e prod), com o profile da management:

```bash
for id in <STAGING_ACCOUNT_ID> <PROD_ACCOUNT_ID> <SHARED_ACCOUNT_ID>; do
  aws organizations close-account --account-id "$id" --profile shortener-mgmt
done
aws organizations list-accounts --profile shortener-mgmt \
  --query 'Accounts[].{nome:Name,id:Id,status:Status}' --output table     # PENDING_CLOSURE → SUSPENDED
```

  - **90 dias suspensas:** a conta fica `SUSPENDED` e pode ser reaberta pelo Support nesse prazo. Depois, some de vez. Nada é cobrado enquanto ela está suspensa (recursos que sobraram param de funcionar).
  - **Limite de fechamentos:** a AWS deixa fechar só **10% das contas-membro numa janela móvel de 30 dias, com mínimo de 10** (e máximo de 1000). É um limite fixo. Com 3 contas, você está bem abaixo do mínimo; se estourar, o erro é `CLOSE_ACCOUNT_QUOTA_EXCEEDED`.
  - **Pelo Terraform (alternativa):** com `close_on_deletion = true` nos `aws_organizations_account` de `infra/organization` (`apply` primeiro), um `terraform destroy -target='aws_organizations_account.<nome>'` fecha a conta. Sem essa flag, o Terraform tentaria *remover* a conta da organização, o que exige que ela vire uma conta avulsa com cartão próprio, e falha.
  - Depois de fechar, remova os profiles `shortener-shared`, `shortener-staging` e `shortener-prod` do `~/.aws/config`, e os contexts do kubeconfig (`kubectl config delete-context shortener-staging` e `shortener-prod`).

- [ ] **5. (Opcional, por último) Feche a management**
  - Antes: baixe as faturas e o que quiser do Cost Explorer (os dados de custo somem junto).
  - Só funciona quando não há contas-membro **ativas** (as suspensas aparecem como *Closed* em Organizations).
  - Não dá pelo console do Organizations: entre com o **usuário root** da management → **Account** → **Close account**. Isso também apaga a organização, as SCPs e o Identity Center no fim do período pós-fechamento.

- [ ] **6. Depois de alguns dias, confira Billing → Bills** (na management, enquanto ela existir): o mês corrente deve parar de crescer em todas as contas.

## Troubleshooting geral

| Sintoma | Onde olhar |
|---|---|
| `terraform destroy` travado em VPC, subnet ou security group | Sobrou ALB ou ENI criado pelo LB Controller. O ALB só some quando os Ingresses `api` **e** `web` somem; o `down.sh` apaga as 2 Applications antes. Rode `aws elbv2 describe-load-balancers --profile shortener-<env>`, apague o ALB e rode o destroy de novo |
| `Error: AWS account ID not allowed: <id>` no `plan`/`apply` | O `allowed_account_ids` do provider barrou a conta errada (é a trava funcionando). Confira `aws sts get-caller-identity --profile shortener-<env>` e se não há `AWS_ACCESS_KEY_ID`/`AWS_SESSION_TOKEN` exportados no shell (`unset` neles) |
| `Token has expired and refresh failed` / `The SSO session associated with this profile has expired` | A sessão SSO (8h) expirou. `aws sso login --sso-session shortener` renova todos os profiles de uma vez |
| `Error: Kubernetes cluster unreachable` na camada platform | O seu IP mudou: rode `apply` na camada aws (atualiza `admin_cidrs`). Ou a sessão SSO expirou (linha acima). Ou o kubeconfig aponta para o cluster de outro ambiente: `kubectl config current-context` |
| `AccessDenied ... with an explicit deny in a service control policy` | Uma SCP barrou. Quase sempre é região (provider, CLI ou console fora de `us-east-1`) ou um serviço global que faltou no `NotAction` da `deny-other-regions`. Corrija em `infra/organization` com o profile `shortener-mgmt`. SCP não se aplica à management |
| Rollout `api` parado em `Paused` | É uma pausa de 2 min dos passos. Se passou muito disso, veja se a `AnalysisRun` está `Running` (esperando dados) ou `Error`. `kubectl argo rollouts get rollout api` |
| Rollout `Progressing` sem sair do passo 1 | O canary não fica `Ready`: `kubectl describe pod` no pod novo (probe, imagem, config). Veja o A4 |
| Rollout `Degraded` com `RolloutAborted` | Uma análise falhou ou alguém rodou `abort`. Corrija o Git (roll-forward ou revert) ou, se foi engano, `kubectl argo rollouts retry rollout api` |
| `AnalysisRun` em `Error` com `AccessDenied` / `cloudwatch:GetMetricData` | O controller do Argo Rollouts não tem a permissão via Pod Identity. `aws eks list-pod-identity-associations --cluster-name shortener-<env> --profile shortener-<env>` deve listar o service account `argo-rollouts` no namespace `argo-rollouts`. Se a associação foi criada depois do pod, `kubectl -n argo-rollouts rollout restart deploy argo-rollouts`. Erros seguidos acima do limite também abortam o Rollout |
| `AnalysisRun` sempre `Successful` mesmo com bug | Sem tráfego no canary, a métrica não tem dados. Ligue o k6 antes do merge. Confira também se a expressão `SEARCH` acha o target group do **canary** |
| Push do bot recusado com `GH013: Repository rule violations` | O App não está na bypass list do ruleset, o `actor_id` é o Client ID em vez do App ID, ou o workflow usou o `GITHUB_TOKEN` em vez do token do App |
| `create-github-app-token` falha com `Not Found` | O App não está instalado no `shortener-deploy`, ou `owner`/`repositories` estão errados |
| `promote.yml` falha em "tag passou por staging" | A tag nunca teve um commit `deploy(staging): <app> <tag>`. Ela não passou por staging: promova pelo fluxo normal |
| 404 em `/assets/...` depois de deploy do web | `index.html` cacheado: confira `Cache-Control: no-store` com `curl -sI https://app.<host>/`. Se o app usa `React.lazy`, é chunk antigo pedido depois da troca (Tarefa 8.8) |
| Login de prod recusa o seu usuário | Os user pools são por conta; o usuário de staging não existe em prod. Faça *Sign up* em prod |
| ArgoCD em *Unknown* ou com erro de repo | `shortener-deploy` privado, ou `repoURL` errado no módulo `platform` |
| Pods em `Pending` | `kubectl describe pod`: falta CPU/memória (`kubectl top nodes`). Lembre que durante canary/blue-green há pods das duas versões ao mesmo tempo. Suba `node_desired_size` |
| Custo do dia maior que o esperado | Cost Explorer na management → *Group by: Linked account* para achar a conta, depois filtre por ela e agrupe por *Service*. Os suspeitos de sempre são NAT, MSK e EKS esquecidos ligados |
| Certificado não funciona no ALB | O ARN no overlay é de outra conta (certificado ACM não atravessa contas), ou o certificado não está `Issued` |
