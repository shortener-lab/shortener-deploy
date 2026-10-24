# Fase 8: entrega contínua entre repos, promoção e canary na prática

**Entrega:**
- Merge na `main` do `shortener-api` ou do `shortener-web` → imagem nova → commit automático no `shortener-deploy` → staging atualizado sozinho, com canary (api) ou blue-green (web).
- Botão "Promote" no `shortener-deploy` + **sua aprovação** → **a mesma imagem** em produção, uma app por vez.
- Um canary com bug **abortando sozinho**, sem você encostar no cluster.
- Rollback pelo Git.

**Repos:** os 3. **Custo:** ~US$ 0,76 por hora com staging e prod de pé ao mesmo tempo (cada um na sua conta). Suba prod só para esta fase e para a Fase 9.

```
 shortener-api                         shortener-web
 PR ─▶ CI ─▶ merge na main             PR ─▶ CI ─▶ merge na main
            │                                     │
   Release: imagem                       Release: imagem
   ghcr.io/<org>/shortener-api:sha-aaa1111    ghcr.io/<org>/shortener-web:sha-bbb2222
            │  job deploy-staging                 │  job deploy-staging
            │  (token do GitHub App, ~1h)         │  (token do GitHub App, ~1h)
            ▼                                     ▼
 ┌──────────────────────────── shortener-deploy (main) ─────────────────────────────┐
 │ commit "deploy(staging): api sha-aaa1111"   commit "deploy(staging): web sha-bbb2222" │
 │   apps/api/overlays/staging                    apps/web/overlays/staging          │
 └───────────────┬──────────────────────────────────────────┬────────────────────────┘
                 ▼                                          ▼
   ArgoCD staging: Application shortener-api     ArgoCD staging: Application shortener-web
   Job setup (PreSync) → Rollout api (canary)    Rollout web (blue-green + web-smoke)
   10% → 2m → análise → 50% → 2m → análise → 100%  preview → smoke → troca do active
                 │
       você valida staging (navegador + k6)
                 │
 Actions do shortener-deploy ▸ "Promote to production" ▸ app=api|web ▸ (aprovação no environment "production")
                 │
   commit "deploy(prod): api sha-aaa1111"  ─▶ ArgoCD prod (conta shortener-prod) ─▶ mesmo Rollout, mesmos passos
```

**Por que o bot escreve no Git e não no cluster:** o GitHub nunca recebe credencial da AWS. O ArgoCD de cada conta **puxa** o estado desejado do `shortener-deploy`. O único segredo novo é a chave do GitHub App, que só sabe escrever em **um** repositório.

---

## Tarefa 8.1: GitHub App `<org>-deployer`

**Conceitos:**
- **Por que um GitHub App e não um PAT (Personal Access Token):**
  - **Token curto:** o `create-github-app-token` troca a chave privada por um *installation token* que expira em ~1h e é revogado no fim do job. Um PAT vive meses (fine-grained) ou para sempre (classic).
  - **Escopo por repositório e por permissão:** o App só está instalado no `shortener-deploy` e só tem `Contents`. Mesmo que vaze o token de um run, ele não lê nem escreve no `shortener-api`.
  - **Não está ligado a uma pessoa:** o commit aparece como `<org>-deployer[bot]`. Se você sair da "empresa", nada quebra; num PAT, o deploy morre junto com a sua conta.
  - **Dá para dar bypass só para ele** no ruleset (Tarefa 8.2).
- **Por que não uma deploy key:** ela também funciona (SSH, escrita em um repo, existe até `actor_type: DeployKey` no ruleset). Mas é uma credencial **de longa duração** que nunca expira, não fala com a API do GitHub (o `promote.yml` e o `gh api` precisariam de outra credencial) e não tem identidade: o commit fica no nome de quem você configurar no `git config`. Com o App, uma chave cobre os 3 repos de origem com tokens curtos.

- [x] **Passo 1: crie o App pela UI, na org.** `https://github.com/organizations/<org>/settings/apps` (Settings da org → **Developer settings** → **GitHub Apps**) → **New GitHub App**. Criado na org, o App pertence à "empresa", não ao seu usuário:
  - **GitHub App name:** `<org>-deployer` (o nome é global no GitHub; por isso o prefixo com a org).
  - **Homepage URL:** `https://github.com/<org>/shortener-deploy`.
  - **Webhook:** desmarque **Active**. O App não recebe eventos; ele só é usado para gerar tokens.
  - **Permissions** → **Repository permissions** → **Contents: Read and write**. **Metadata: Read-only** entra sozinho (é obrigatório). Nada mais.
  - **Where can this GitHub App be installed?** → **Only on this account** (a conta aqui é a org).
  - **Create GitHub App.**
- [x] **Passo 2: anote os IDs.** Na página do App (seção *About*): **App ID** (um número, ex.: `1234567`) e **Client ID** (começa com `Iv23...`).
- [x] **Passo 3: gere a chave privada.** Mesma página → **Private keys** → **Generate a private key**. O navegador baixa um `.pem`.
- [x] **Passo 4: instale o App só no `shortener-deploy`.** Menu lateral do App → **Install App** → `<org>` → **Only select repositories** → `shortener-deploy` → **Install**.
- [x] **Passo 5: guarde ID e chave uma vez, na org, liberados para os 3 repos**

```bash
APP_ID=<App ID>                 # número
CLIENT_ID=<Client ID>           # Iv23...
PEM=~/Downloads/<org>-deployer.<data>.private-key.pem
REPOS=shortener-api,shortener-web,shortener-deploy

gh variable set DEPLOYER_APP_ID      --org <org> --visibility selected --repos "$REPOS" --body "$APP_ID"
gh variable set DEPLOYER_CLIENT_ID   --org <org> --visibility selected --repos "$REPOS" --body "$CLIENT_ID"
gh secret   set DEPLOYER_PRIVATE_KEY --org <org> --visibility selected --repos "$REPOS" < "$PEM"

gh variable list --org <org>   # DEPLOYER_APP_ID e DEPLOYER_CLIENT_ID, visibilidade SELECTED
gh secret list   --org <org>   # DEPLOYER_PRIVATE_KEY (o valor nunca é mostrado)
gh api repos/<org>/shortener-api/actions/organization-secrets --jq '.secrets[].name'   # o repo enxerga a chave
```

Por que na org: a chave existe num lugar só. Para trocá-la (rotação ou vazamento), você atualiza um secret, não três. Os workflows leem `vars.DEPLOYER_CLIENT_ID` e `secrets.DEPLOYER_PRIVATE_KEY` do mesmo jeito, venham do repo ou da org.

Duas pegadinhas:
- **Sem `--visibility`, o `gh` cria com `private`**: o valor só fica visível para repos *privados*, e os 3 são públicos. O workflow receberia valores vazios e o passo do `create-github-app-token` falharia.
- **No plano Free, secrets e variables da org só chegam a repos públicos.** Num repo privado, seria preciso o plano Team ou guardar no próprio repo.

Por que duas variáveis:
- `DEPLOYER_CLIENT_ID` é o que o `actions/create-github-app-token@v3` usa. Desde a v3.1, o input `app-id` está *deprecated* em favor de `client-id`, mas continua aceito.
- `DEPLOYER_APP_ID` é o número que o ruleset precisa no bypass (Tarefa 8.2). Ele também identifica o App em logs e na API.

Os dois IDs não são segredo, por isso ficam como *variables*. Só a chave é *secret*.

- [x] **Passo 6: tire o `.pem` do disco.** Ou guarde-o no gerenciador de senhas e depois apague, ou apenas apague (se perder, gere outra chave na página do App e revogue a antiga):

```bash
rm -P "$PEM"        # -P sobrescreve antes de apagar (macOS)
```

- [x] **Passo 7: descubra o id do usuário-bot** (o commit precisa dele para aparecer com o avatar do App):

```bash
gh api "/users/<org>-deployer[bot]" --jq .id    # ex.: 987654321
```

O e-mail do bot é `<esse id>+<org>-deployer[bot]@users.noreply.github.com`. Os workflows calculam isso sozinhos; o passo é só para você entender de onde vem.

**Pronto quando:** o App existe, está instalado só no `shortener-deploy`, e a org tem `DEPLOYER_APP_ID`, `DEPLOYER_CLIENT_ID` e `DEPLOYER_PRIVATE_KEY`, liberados para os 3 repos.

---

## Tarefa 8.2: ruleset na `main` do `shortener-deploy`, com bypass para o App

**Conceitos:**
- **Humanos entram por PR**, com os checks `infra` e `manifests` (jobs do `ci.yml` do `shortener-deploy`, criados nas Fases 6 e 7) verdes.
- **O bot entra direto** (bypass). Os commits `deploy(staging): ...` e `deploy(prod): ...` são mecânicos (uma linha de tag) e já foram validados na origem. Exigir PR para cada um travaria o CD.
- **`bypass_mode: always`:** o App pode empurrar direto na `main`. Você, mesmo sendo admin do repo, **não** está na lista, então o seu `git push origin main` é recusado.
- **`strict_required_status_checks_policy: false`:** com `true`, todo PR precisaria estar atualizado com a `main` antes do merge. Como o bot commita na `main` o tempo todo, você viveria clicando em "Update branch".
- **`required_approving_review_count: 0`:** você é a única pessoa no projeto e o GitHub não deixa aprovar o próprio PR. O portão humano de prod é o environment `production` (Tarefa 8.4).

- [x] **Passo 1: crie o ruleset pela API**

```bash
APP_ID=$(gh variable get DEPLOYER_APP_ID --org <org>)

gh api --method POST /repos/<org>/shortener-deploy/rulesets --input - <<EOF
{
  "name": "main protegida (bypass: deployer)",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] }
  },
  "bypass_actors": [
    { "actor_id": $APP_ID, "actor_type": "Integration", "bypass_mode": "always" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [
          { "context": "infra" },
          { "context": "manifests" }
        ]
      }
    }
  ]
}
EOF
```

O `actor_id` de um `Integration` é o **App ID** (número), não o Client ID.

- [x] **Passo 2: confira**

```bash
gh api /repos/<org>/shortener-deploy/rulesets --jq '.[] | {id, name, enforcement}'
gh api /repos/<org>/shortener-deploy/rules/branches/main --jq '.[].type'
# deletion, non_fast_forward, pull_request, required_status_checks
```

Ou na UI: repo → **Settings** → **Rules** → **Rulesets**. Em *Bypass list* aparece o App.

- [x] **Passo 3: prove que você (humano) não passa**

```bash
cd ~/Documents/projects/shortener-deploy
git switch main && git pull
git commit --allow-empty -m "teste: push direto"
git push origin main          # remote: error: GH013: Repository rule violations found for refs/heads/main
git reset --hard origin/main  # desfaz o commit de teste
```

**Cuidado com `paths` no `ci.yml` do `shortener-deploy`:** se os jobs `infra` e `manifests` só rodassem quando certos caminhos mudam, um PR que só mexe em `docs/` nunca receberia esses checks e ficaria bloqueado para sempre. Eles precisam rodar em todo PR.

**Pronto quando:** o ruleset está ativo, o seu push direto é recusado com `GH013` e o App aparece na bypass list.

---

## Tarefa 8.3: job `deploy-staging` no `release.yml` do `shortener-api` e do `shortener-web`

**Arquivos:**
- `shortener-api`: alterar `.github/workflows/release.yml`.
- `shortener-web`: alterar `.github/workflows/release.yml`.

Os dois `release.yml` já têm (Fase 4) os jobs `ci` e `image`, e o job `image` expõe `outputs.tag` (`sha-<7>`). O job novo depende dele.

**Conceitos:**
- **`actions/create-github-app-token@v3`** troca `client-id` + `private-key` por um token de instalação. `owner` + `repositories: shortener-deploy` restringem o token a esse repo, mesmo que um dia o App seja instalado em outros.
- **Commits feitos com token de App disparam workflows** no repo de destino (diferente do `GITHUB_TOKEN`). No `shortener-deploy`, o `ci.yml` roda só em `pull_request`, então um push do bot na `main` não dispara nada nem gera loop.
- **Autor do commit = bot do App.** `user.name` é `<app-slug>[bot]` e `user.email` é `<id>+<app-slug>[bot]@users.noreply.github.com`. O id é o do **usuário-bot** (`gh api /users/<app-slug>[bot]`), que é diferente do App ID.
- **`concurrency` por app:** dois merges seguidos no `shortener-api` fazem fila (o GitHub mantém só o mais novo pendente); um deploy da api e um do web podem correr juntos porque mexem em arquivos diferentes. O `git pull --rebase` resolve a corrida entre eles.
- **`permissions: {}`:** o `GITHUB_TOKEN` desse job não precisa de nada; quem escreve é o token do App.

- [x] **Passo 1 (`shortener-api`): adicione o job** ao final de `.github/workflows/release.yml`

```yaml
  deploy-staging:
    needs: image
    runs-on: ubuntu-24.04
    permissions: {}
    concurrency:
      group: deploy-staging-api
      cancel-in-progress: false
    steps:
      - name: Gera token do GitHub App (só shortener-deploy, ~1h)
        id: app-token
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.DEPLOYER_CLIENT_ID }}
          private-key: ${{ secrets.DEPLOYER_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: shortener-deploy

      - name: Identidade do bot
        id: bot
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          SLUG: ${{ steps.app-token.outputs.app-slug }}
        run: |
          BOT_ID=$(gh api "/users/${SLUG}[bot]" --jq .id)
          echo "name=${SLUG}[bot]" >> "$GITHUB_OUTPUT"
          echo "email=${BOT_ID}+${SLUG}[bot]@users.noreply.github.com" >> "$GITHUB_OUTPUT"

      - name: Checkout do shortener-deploy
        uses: actions/checkout@v7
        with:
          repository: ${{ github.repository_owner }}/shortener-deploy
          ref: main
          token: ${{ steps.app-token.outputs.token }}

      - name: Atualiza a tag no overlay de staging
        env:
          TAG: ${{ needs.image.outputs.tag }}
        run: |
          [[ "$TAG" =~ ^sha-[0-9a-f]{7}$ ]] || { echo "tag inválida: $TAG"; exit 1; }
          yq -i '(.images[] | select(.name == "shortener-api")).newTag = strenv(TAG)' \
            apps/api/overlays/staging/kustomization.yaml
          git diff --stat

      - name: Commit e push (com retry)
        env:
          TAG: ${{ needs.image.outputs.tag }}
          BOT_NAME: ${{ steps.bot.outputs.name }}
          BOT_EMAIL: ${{ steps.bot.outputs.email }}
        run: |
          git config user.name "$BOT_NAME"
          git config user.email "$BOT_EMAIL"
          if git diff --quiet; then echo "staging já está em api $TAG"; exit 0; fi
          git commit -am "deploy(staging): api $TAG"
          for attempt in 1 2 3 4 5; do
            git push origin HEAD:main && exit 0
            echo "push recusado (tentativa $attempt): outro deploy chegou antes; rebase e tento de novo"
            sleep $((attempt * 3))
            git pull --rebase origin main
          done
          exit 1
```

- [x] **Passo 2 (`shortener-web`): adicione o job** ao final de `.github/workflows/release.yml`

```yaml
  deploy-staging:
    needs: image
    runs-on: ubuntu-24.04
    permissions: {}
    concurrency:
      group: deploy-staging-web
      cancel-in-progress: false
    steps:
      - name: Gera token do GitHub App (só shortener-deploy, ~1h)
        id: app-token
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.DEPLOYER_CLIENT_ID }}
          private-key: ${{ secrets.DEPLOYER_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: shortener-deploy

      - name: Identidade do bot
        id: bot
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          SLUG: ${{ steps.app-token.outputs.app-slug }}
        run: |
          BOT_ID=$(gh api "/users/${SLUG}[bot]" --jq .id)
          echo "name=${SLUG}[bot]" >> "$GITHUB_OUTPUT"
          echo "email=${BOT_ID}+${SLUG}[bot]@users.noreply.github.com" >> "$GITHUB_OUTPUT"

      - name: Checkout do shortener-deploy
        uses: actions/checkout@v7
        with:
          repository: ${{ github.repository_owner }}/shortener-deploy
          ref: main
          token: ${{ steps.app-token.outputs.token }}

      - name: Atualiza a tag no overlay de staging
        env:
          TAG: ${{ needs.image.outputs.tag }}
        run: |
          [[ "$TAG" =~ ^sha-[0-9a-f]{7}$ ]] || { echo "tag inválida: $TAG"; exit 1; }
          yq -i '(.images[] | select(.name == "shortener-web")).newTag = strenv(TAG)' \
            apps/web/overlays/staging/kustomization.yaml
          git diff --stat

      - name: Commit e push (com retry)
        env:
          TAG: ${{ needs.image.outputs.tag }}
          BOT_NAME: ${{ steps.bot.outputs.name }}
          BOT_EMAIL: ${{ steps.bot.outputs.email }}
        run: |
          git config user.name "$BOT_NAME"
          git config user.email "$BOT_EMAIL"
          if git diff --quiet; then echo "staging já está em web $TAG"; exit 0; fi
          git commit -am "deploy(staging): web $TAG"
          for attempt in 1 2 3 4 5; do
            git push origin HEAD:main && exit 0
            echo "push recusado (tentativa $attempt): outro deploy chegou antes; rebase e tento de novo"
            sleep $((attempt * 3))
            git pull --rebase origin main
          done
          exit 1
```

As únicas diferenças entre os dois jobs são o grupo de `concurrency`, o nome lógico da imagem no `yq`, o caminho do overlay e a mensagem do commit. Está repetido de propósito: cada repo é dono do seu pipeline.

- [x] **Passo 3: leve cada mudança por PR** (branch → PR → CI verde → merge), em cada um dos dois repos. O próprio merge dispara o Release, que já usa o job novo.

```bash
gh run watch --repo <org>/shortener-api       # ci → image → deploy-staging
gh run watch --repo <org>/shortener-web
```

- [x] **Passo 4: confira os commits no `shortener-deploy`**

```bash
cd ~/Documents/projects/shortener-deploy && git switch main && git pull
git log --format='%h %an <%ae> %s' -4
# a1b2c3d <org>-deployer[bot] <987654321+<org>-deployer[bot]@users.noreply.github.com> deploy(staging): web sha-bbb2222
# d4e5f6a <org>-deployer[bot] <...> deploy(staging): api sha-aaa1111
```

No GitHub, o commit aparece com o avatar do App. Se aparecer um usuário genérico sem avatar, o e-mail está errado (provavelmente você usou o App ID no lugar do id do usuário-bot).

- [x] **Passo 5: com staging de pé, veja o ArgoCD aplicar**

```bash
kubectl --context shortener-staging -n argocd get applications     # shortener-api e shortener-web Synced/Healthy
curl -s https://api.shortener-staging.fabricioroglio.com/healthz   # {"status":"ok","version":"sha-aaa1111"}
```

**Pronto quando:** um merge em cada repo de app gera sozinho o commit `deploy(staging): <app> sha-<7>` no `shortener-deploy`, assinado pelo bot.

---

## Tarefa 8.4: `promote.yml` no `shortener-deploy`, com aprovação manual

**Arquivos:** criar `.github/workflows/promote.yml` no `shortener-deploy`.

**Conceitos:**
- **GitHub Environment com *required reviewers*:** é o portão humano antes de prod. O job que usa `environment: production` fica "Waiting" até alguém aprovar.
- **Validar antes de pedir aprovação:** o workflow tem dois jobs. `validate` (sem environment) checa as entradas, a imagem e se a tag passou por staging. Só depois o `promote` pede a sua aprovação. Assim você não aprova algo que vai falhar.
- **Entradas via `env`, nunca `${{ inputs.x }}` dentro do `run:`.** Uma tag como `x"; curl evil | sh; "` seria executada pelo shell. Por `env`, ela é só texto, e a regex barra.
- **Promoção por app:** prod pode ter api `sha-aaa1111` e web `sha-bbb2222`. O contrato entre eles é a API REST, que precisa ser compatível com a versão anterior.
- **"Só promove o que passou por staging":** o `validate` procura no histórico o commit `deploy(staging): <app> <tag>`. Isso vale também para rollback com uma tag antiga, porque ela passou por staging no passado.
- **O token do App também aqui:** o `GITHUB_TOKEN` não está na bypass list do ruleset, então o push dele na `main` seria recusado.

- [x] **Passo 1: crie o environment.** `shortener-deploy` → **Settings** → **Environments** → **New environment** → `production`:
  - **Required reviewers:** você. Deixe *Prevent self-review* desmarcado (você é o único revisor).
  - **Deployment branches and tags:** *Selected branches and tags* → `main`.
  - (Opcional, mais rígido) tire o `shortener-deploy` da lista do secret da org (`gh secret set DEPLOYER_PRIVATE_KEY --org <org> --visibility selected --repos shortener-api,shortener-web < "$PEM"`) e crie a chave como *Environment secret* de `production`. Assim, só jobs aprovados conseguem gerar token neste repo.

- [x] **Passo 2: crie** `.github/workflows/promote.yml`

```yaml
name: Promote to production

on:
  workflow_dispatch:
    inputs:
      app:
        description: "App a promover"
        type: choice
        options: [api, web]
        required: true
      tag:
        description: "Tag a promover (vazio = a que está em staging agora)"
        type: string
        required: false

permissions:
  contents: read

concurrency:
  group: promote-${{ inputs.app }}
  cancel-in-progress: false

jobs:
  validate:
    runs-on: ubuntu-24.04
    outputs:
      tag: ${{ steps.tag.outputs.tag }}
    steps:
      - uses: actions/checkout@v7
        with:
          ref: main
          fetch-depth: 0               # histórico inteiro, para achar o deploy(staging)

      - name: Valida as entradas e define a tag
        id: tag
        env:
          APP: ${{ inputs.app }}
          INPUT_TAG: ${{ inputs.tag }}
        run: |
          [[ "$APP" =~ ^(api|web)$ ]] || { echo "app inválida: $APP"; exit 1; }
          export IMAGE="shortener-$APP"
          TAG="${INPUT_TAG:-$(yq '.images[] | select(.name == strenv(IMAGE)) | .newTag' "apps/$APP/overlays/staging/kustomization.yaml")}"
          [[ "$TAG" =~ ^sha-[0-9a-f]{7}$ ]] || { echo "tag inválida: $TAG"; exit 1; }
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
          echo "### Promover $APP $TAG para prod" >> "$GITHUB_STEP_SUMMARY"

      - name: Confere que a imagem existe no GHCR
        env:
          APP: ${{ inputs.app }}
          TAG: ${{ steps.tag.outputs.tag }}
        run: docker manifest inspect "ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/shortener-$APP:$TAG" > /dev/null

      - name: Confere que a tag passou por staging
        env:
          APP: ${{ inputs.app }}
          TAG: ${{ steps.tag.outputs.tag }}
        run: |
          git log --format=%s origin/main -- "apps/$APP/overlays/staging" \
            | grep -Fxq "deploy(staging): $APP $TAG" \
            || { echo "$APP $TAG nunca foi para staging"; exit 1; }

  promote:
    needs: validate
    runs-on: ubuntu-24.04
    environment: production          # pausa aqui até você aprovar
    permissions: {}
    steps:
      - name: Gera token do GitHub App (só shortener-deploy, ~1h)
        id: app-token
        uses: actions/create-github-app-token@v3
        with:
          client-id: ${{ vars.DEPLOYER_CLIENT_ID }}
          private-key: ${{ secrets.DEPLOYER_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}
          repositories: shortener-deploy

      - name: Identidade do bot
        id: bot
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          SLUG: ${{ steps.app-token.outputs.app-slug }}
        run: |
          BOT_ID=$(gh api "/users/${SLUG}[bot]" --jq .id)
          echo "name=${SLUG}[bot]" >> "$GITHUB_OUTPUT"
          echo "email=${BOT_ID}+${SLUG}[bot]@users.noreply.github.com" >> "$GITHUB_OUTPUT"

      - uses: actions/checkout@v7
        with:
          ref: main
          token: ${{ steps.app-token.outputs.token }}

      - name: Atualiza o overlay de prod, commit e push
        env:
          APP: ${{ inputs.app }}
          TAG: ${{ needs.validate.outputs.tag }}
          BOT_NAME: ${{ steps.bot.outputs.name }}
          BOT_EMAIL: ${{ steps.bot.outputs.email }}
        run: |
          [[ "$APP" =~ ^(api|web)$ && "$TAG" =~ ^sha-[0-9a-f]{7}$ ]] || exit 1
          export IMAGE="shortener-$APP"
          yq -i '(.images[] | select(.name == strenv(IMAGE))).newTag = strenv(TAG)' \
            "apps/$APP/overlays/prod/kustomization.yaml"
          git config user.name "$BOT_NAME"
          git config user.email "$BOT_EMAIL"
          if git diff --quiet; then echo "prod já está em $APP $TAG"; exit 0; fi
          git commit -am "deploy(prod): $APP $TAG"
          for attempt in 1 2 3 4 5; do
            git push origin HEAD:main && exit 0
            sleep $((attempt * 3))
            git pull --rebase origin main
          done
          exit 1
```

- [x] **Passo 3: leve o workflow por PR** no `shortener-deploy` (o ruleset exige) e faça o merge.

- [x] **Passo 4: promova api e web uma vez cada, antes de subir prod.** Prod ainda está desligado, então só o Git muda. Assim, o primeiro sync de prod já usa tags que existem.

```bash
R=<org>/shortener-deploy
gh workflow run promote.yml --repo $R -f app=api
gh run watch --repo $R        # validate ✓ → promote "Waiting" → aprove em Actions ▸ run ▸ "Review deployments" ▸ production ▸ Approve
gh workflow run promote.yml --repo $R -f app=web
gh run watch --repo $R

git pull && git log --oneline -4
# deploy(prod): web sha-bbb2222
# deploy(prod): api sha-aaa1111
```

- [x] **Passo 5: teste as validações** (cada um deve falhar no `validate`, **sem** pedir aprovação):

```bash
gh workflow run promote.yml --repo $R -f app=api -f tag='sha-zzzzzzz'      # regex
gh workflow run promote.yml --repo $R -f app=api -f tag='sha-0000000'      # imagem não existe
gh workflow run promote.yml --repo $R -f app=web -f tag='x"; id; "'        # injection: vira texto e a regex barra
```

**Pronto quando:** a promoção valida antes, exige a sua aprovação e gera `deploy(prod): <app> sha-<7>` em `apps/<app>/overlays/prod`.

---

## Tarefa 8.5: subir produção

Prod vive na conta `shortener-prod`. Ela tem VPC, EKS, RDS, ElastiCache, MSK, ACM e **Cognito próprios**.

- [x] **Passo 1: suba os dois ambientes** (no `shortener-deploy`)

```bash
aws sso login --sso-session shortener          # um login vale para todos os profiles shortener-*
export CLOUDFLARE_API_TOKEN='...'; export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"
export CLOUDFLARE_ZONE_ID='...'
scripts/up.sh staging      # se não estiver de pé
scripts/up.sh prod         # ~40 min; dá para rodar em outro terminal ao mesmo tempo
```

- [x] **Passo 2: smoke test de prod pelo terminal**

```bash
k() { kubectl --context shortener-prod -n shortener "$@"; }   # função, não variável: funciona no zsh e no bash
kubectl --context shortener-prod -n argocd get applications     # shortener-api e shortener-web Synced/Healthy
kubectl argo rollouts --context shortener-prod -n shortener list rollouts   # api e web Healthy
k get pods,hpa                                                   # api 2 réplicas (HPA), worker 2, web 2

export API=https://api.shortener.fabricioroglio.com
export SHORT=https://shortener.fabricioroglio.com
export KEY=$(terraform -chdir=infra/envs/prod/platform output -raw api_key)
curl -s $API/healthz                                  # {"status":"ok","version":"sha-aaa1111"} = mesma tag de staging
CODE=$(curl -s -X POST $API/links -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -d '{"url":"https://github.com"}' | jq -r .code); echo $CODE
curl -sI $SHORT/$CODE | head -3                       # HTTP/2 302 + location: https://github.com/
curl -sI https://app.shortener.fabricioroglio.com/ | grep -i cache-control   # no-store (index.html)
curl -s https://app.shortener.fabricioroglio.com/runtime/config.js           # apiBaseUrl = https://api.shortener...
```

- [x] **Passo 3: smoke test de prod pelo navegador**
  1. Abra `https://app.shortener.fabricioroglio.com` → **Entrar**.
  2. O seu usuário de staging **não existe aqui**. Use **Sign up** no Hosted UI de prod, confirme o código que chega por e-mail e entre.
  3. Crie um link, abra a URL curta em outra aba e veja o clique nas stats.

**Por que o usuário de staging não serve em prod:** cada conta tem o seu user pool (`shortener-staging` e `shortener-prod`), com emissores (`iss`) e chaves diferentes. Mesmo que você copiasse um access token de staging (DevTools → Application → Session Storage) e mandasse para a api de prod, ela responderia 401: o `iss` não bate com o `OIDC_ISSUER` de prod e a assinatura não confere com o JWKS de prod. É o mesmo isolamento de dados da empresa: ninguém de staging encosta em prod, nem por engano.

```bash
STAGING_TOKEN='<cole o access_token de staging>'
curl -s -o /dev/null -w '%{http_code}\n' $API/me/links -H "Authorization: Bearer $STAGING_TOKEN"   # 401
```

**Pronto quando:** os 3 hosts de prod respondem, `/healthz` mostra a mesma versão de staging e você fez login com um usuário criado em prod.

---

## Tarefa 8.6: canary na prática, com zero erros

**Repos:** `shortener-deploy` (teste de carga) e `shortener-api` (mudança visível).

**Conceitos:**
- **O ALB divide o tráfego:** o Argo Rollouts escreve na annotation de ação do Ingress `api` os pesos entre os target groups de `api-stable` e `api-canary`. O AWS Load Balancer Controller traduz isso para uma regra *forward* com pesos no listener 443.
- **A análise precisa de tráfego:** a métrica é `HTTPCode_Target_5XX_Count / RequestCount` do target group do canary. Sem requisições, a conta não tem o que medir e passa como sucesso. Por isso o k6 fica ligado o tempo todo.
- **Passos do Rollout `api`:** `setWeight 10` → `pause 2m` → análise `api-error-rate` → `setWeight 50` → `pause 2m` → análise → 100%. São ~6 a 8 minutos depois que o ArgoCD aplica.

- [x] **Passo 1: crie o teste de carga** `load/redirect.js` no `shortener-deploy`

```js
import http from 'k6/http';
import { check } from 'k6';

// Uso: k6 run -e BASE_URL=... -e CODE=... [-e RATE=20] [-e DURATION=5m] [-e MAX_FAIL_RATE=0] load/redirect.js
export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 20), // requisições por segundo
      timeUnit: '1s',
      duration: __ENV.DURATION || '5m',
      preAllocatedVUs: 50,
      maxVUs: 400,
    },
  },
  // Padrão: qualquer erro reprova. A Tarefa 8.7 relaxa isso de propósito.
  thresholds: { http_req_failed: [`rate<=${Number(__ENV.MAX_FAIL_RATE || 0)}`] },
};

export default function () {
  const res = http.get(`${__ENV.BASE_URL}/${__ENV.CODE}`, { redirects: 0 });
  check(res, { '302': (r) => r.status === 302 });
}
```

Commit por PR no `shortener-deploy`. O k6 roda do seu Mac, não do CI.

- [x] **Passo 2: crie um link em staging para a carga**

```bash
export API=https://api.shortener-staging.fabricioroglio.com
export SHORT=https://shortener-staging.fabricioroglio.com
export KEY=$(terraform -chdir=infra/envs/staging/platform output -raw api_key)
CODE=$(curl -s -X POST $API/links -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -d '{"url":"https://github.com"}' | jq -r .code); echo $CODE
```

- [x] **Passo 3: faça uma mudança visível no `shortener-api`, seguindo o TDD**
  - Branch `feat/version-header`.
  - **Primeiro o teste** em `test/integration/app.test.ts`, dentro do `describe` de `/healthz`:

    ```ts
    it('expõe a versão no header X-Shortener-Version', async () => {
      const res = await request(app).get('/healthz');
      expect(res.headers['x-shortener-version']).toBe('test');
    });
    ```

  - `npm test` → **falha** (header ausente).
  - **Depois o código** em `src/http/app.ts`, em `createApp`, logo após `app.disable('x-powered-by')` e antes de qualquer rota:

    ```ts
    app.use((_req, res, next) => {
      res.set('X-Shortener-Version', deps.version);
      next();
    });
    ```

  - `npm test` → verde. Commit, push, `gh pr create --fill`, CI verde. **Ainda não faça o merge.**

- [x] **Passo 4: ligue a carga e faça o merge**

```bash
# terminal 1 (no shortener-deploy): ~20 min cobre CI + Release + canary
k6 run -e BASE_URL=$SHORT -e CODE=$CODE -e DURATION=20m load/redirect.js

# terminal 2 (no shortener-api)
gh pr merge --squash --delete-branch
gh run watch                                   # ci → image → deploy-staging

# terminal 3: o Rollout ao vivo
kubectl argo rollouts --context shortener-staging -n shortener get rollout api --watch
```

O que observar no `--watch`:
1. `Status: ◌ Progressing`, `Step: 1/6`, `SetWeight: 10`, `ActualWeight: 10`. Aparece um ReplicaSet novo (`canary`) ao lado do `stable`.
2. `Status: ॥ Paused` (`CanaryPauseStep`) por 2 minutos.
3. Uma linha `AnalysisRun` com `◌ Running` e depois `✔ Successful`.
4. `SetWeight: 50`, pausa, segunda análise.
5. `Status: ✔ Healthy`. O ReplicaSet antigo fica `ScaledDown` depois do `scaleDownDelaySeconds`.

- [x] **Passo 5: veja os pesos no ALB e as análises** (enquanto o canary está em 10% ou 50%)

```bash
export AWS_PROFILE=shortener-staging
LB=$(aws elbv2 describe-load-balancers --query 'LoadBalancers[0].LoadBalancerArn' --output text)   # a conta só tem este ALB
L443=$(aws elbv2 describe-listeners --load-balancer-arn "$LB" \
  --query 'Listeners[?Port==`443`].ListenerArn' --output text)
aws elbv2 describe-rules --listener-arn "$L443" \
  --query 'Rules[].Actions[?Type==`forward`].ForwardConfig.TargetGroups[]' --output table
# dois target groups (nomes com "apistabl..." e "apicanar...") com Weight 90/10, depois 50/50

kubectl --context shortener-staging -n shortener get analysisrun
kubectl --context shortener-staging -n shortener describe analysisrun <nome> | sed -n '/Metric Results/,$p'
# Value: [0] ou um número < 0.01 → Phase: Successful

# quantas respostas vêm da versão nova (em 10%, ~5 de 50)
for i in $(seq 1 50); do curl -sI $SHORT/healthz | grep -i '^x-shortener-version' || echo "(sem header: versão antiga)"; done | sort | uniq -c
```

No console: EC2 → **Load Balancers** → o ALB → **Listeners and rules** → HTTPS:443 mostra os pesos. O fato de a conta ter **um** ALB só (o do ambiente) é o isolamento por conta trabalhando a seu favor.

Esperado ao fim:
- O k6 termina com `http_req_failed: 0.00%` e o threshold verde.
- `curl -sI $SHORT/healthz | grep -i x-shortener` mostra a tag nova em 100% das respostas.

Se o k6 acusar erros:
- 502 → keep-alive do Node menor que o do ALB (Problemas comuns da Fase 7).
- 503 → target group do canary vazio quando o peso subiu, preStop ou `deregistration_delay`.

- [x] **Passo 6: promova para prod, com carga em prod**

```bash
PROD_CODE=<code criado em prod na Tarefa 8.5>
k6 run -e BASE_URL=https://shortener.fabricioroglio.com -e CODE=$PROD_CODE -e DURATION=15m load/redirect.js &
gh workflow run promote.yml --repo <org>/shortener-deploy -f app=api     # aprove na UI
kubectl argo rollouts --context shortener-prod -n shortener get rollout api --watch
```

Esperado: os mesmos passos (10% → 50% → 100%), análises `Successful`, zero erros no k6 e prod com a mesma tag de staging.

**Pronto quando:** a mesma mudança passou por canary em staging e em prod sem nenhuma requisição com falha, e você viu os pesos no ALB.

---

## Tarefa 8.7: canary com bug, abortando sozinho

**Objetivo:** provar que a análise automática protege prod (e staging) de um bug que **passou no CI**.

**Por que o bug foge do TDD, de propósito:** o experimento só ensina algo se o bug chegar ao cluster, ou seja, se o CI passar. Um `Math.random()` puro faria os testes de `GET /:code` falharem ~30% das vezes (e o CI barraria, o que é ótimo na vida real, mas estraga o experimento). Então o bug depende de algo que **só existe dentro de um pod**: a variável `KUBERNETES_SERVICE_HOST`, que o kubelet injeta em todo container. No Vitest e no runner do GitHub ela não existe, então os testes nunca exercitam o caminho com defeito. É o clássico "só quebra em produção" (config, rede, permissão), simulado de forma controlada. O código fica marcado com um comentário e nunca vai para prod.

- [x] **Passo 1: o PR do bug, no `shortener-api`**

```bash
cd ~/Documents/projects/shortener-api
git switch main && git pull && git switch -c experimento/canary-bug
```

Em `src/http/app.ts`, no início do handler de `GET /:code`:

```ts
  app.get('/:code', async (req, res) => {
    // BUG PROPOSITAL (Tarefa 8.7 do plano): só ativa dentro de um pod (o kubelet injeta
    // KUBERNETES_SERVICE_HOST), por isso os testes e o CI não o pegam. Será revertido.
    if (process.env.KUBERNETES_SERVICE_HOST && Math.random() < 0.3) {
      res.status(500).json({ error: 'internal' });
      return;
    }
    const { code } = req.params as { code: string };
    // ... resto igual
```

```bash
npm test                     # verde: o caminho do bug nunca roda aqui
git commit -am "experimento: bug proposital no redirect (Tarefa 8.7, será revertido)"
git push -u origin HEAD && gh pr create --fill
gh pr checks --watch         # CI verde
```

- [x] **Passo 2: carga com threshold relaxado, e merge**

**Por que relaxar o threshold:** o bug vai receber 10% do tráfego por ~3 minutos (pausa de 2 min + análise) até o abort. Com 30% de falha nesse pedaço, ~3% das requisições falham durante a janela, e ~0,5–1% no total da execução. Com `rate<=0`, o k6 reprovaria, mas o que queremos medir aqui é outra coisa: que o estrago fica **limitado e curto**. `MAX_FAIL_RATE=0.05` aceita esse blip e ainda reprovaria se o bug chegasse a 50% ou 100%.

```bash
# terminal 1 (shortener-deploy)
k6 run -e BASE_URL=$SHORT -e CODE=$CODE -e DURATION=20m -e MAX_FAIL_RATE=0.05 load/redirect.js

# terminal 2 (shortener-api)
gh pr merge --squash --delete-branch

# terminal 3
kubectl argo rollouts --context shortener-staging -n shortener get rollout api --watch
```

- [x] **Passo 3: observe** (escreva antes a sua hipótese)
  1. `SetWeight: 10`, `॥ Paused`. No k6, os `✗ 302` começam a aparecer (~2 por segundo a 20 rps).
  2. A `AnalysisRun` roda e termina **`✖ Failed`**: o valor medido fica perto de `0.3`, bem acima de `0.01`.
  3. O Rollout vira **`✖ Degraded`**, com a mensagem `RolloutAborted: Rollout aborted update to revision N: Metric "<métrica do api-error-rate>" assessed Failed ...`.
  4. O peso volta para **0/100** sozinho: 100% no estável. Depois do `abortScaleDownDelaySeconds` (30 s por padrão), o ReplicaSet do canary vai a zero.
  5. Os erros param no k6. No fim: `http_req_failed` em torno de 0,5–1%, todos concentrados na janela de 10%.

```bash
kubectl --context shortener-staging -n shortener get analysisrun                  # a última com PHASE Failed
kubectl --context shortener-staging -n shortener describe analysisrun <nome> | sed -n '/Metric Results/,$p'
kubectl --context shortener-staging -n argocd get application shortener-api       # Synced + Degraded
```

**Por que o ArgoCD mostra `Degraded` e não volta sozinho a `Healthy`:** o Git (`apps/api/overlays/staging`) **ainda aponta para a tag com bug**. O ArgoCD está `Synced` (o spec aplicado é o do Git), mas o Rollout diz "abortei essa revisão". Ele fica assim até o Git mudar. O abort protege o tráfego; consertar o estado desejado é com você.

- [x] **Passo 4: corrija com roll-forward, no `shortener-api`**

```bash
cd ~/Documents/projects/shortener-api
git switch main && git pull
git switch -c revert/canary-bug
git revert --no-edit <hash-do-squash-do-bug>
git push -u origin HEAD && gh pr create --fill && gh pr checks --watch
gh pr merge --squash --delete-branch
```

O Release gera uma imagem nova (`sha-<novo>`, com o mesmo código do estável), o bot commita `deploy(staging): api sha-<novo>`, e o Rollout começa um canary **novo** a partir do estável. Desta vez as análises passam e o status vai para `✔ Healthy`.

**Por que não reverter só no `shortener-deploy`?** Até pode: um PR com `git revert` do commit `deploy(staging): api sha-<bug>` faz o spec voltar à tag estável. Como o template bate com o ReplicaSet estável, o Rollout volta a `Healthy` na hora, sem passar pelos passos. Só que o bug **continua na `main` do `shortener-api`**, e o próximo merge de qualquer feature o leva junto para staging de novo. Em empresa, você faria as duas coisas se o abort não existisse (reverter o deploy para estancar e consertar a origem). Com o abort automático, o sangramento já parou, então basta o roll-forward na origem.

**Pronto quando:** você viu `AnalysisRun Failed` → `Rollout Degraded` → 100% no estável sem intervenção, o k6 mostrou erros só na janela de 10%, e o roll-forward deixou tudo `Healthy`.

---

## Tarefa 8.8: blue-green do web, sem 404 de assets

**Repo:** `shortener-web`.

**Conceitos:**
- **Rollout `web` (blueGreen):** a versão nova sobe atrás do `web-preview`; a `AnalysisTemplate web-smoke` (um Job com `curl`) checa `/healthz`, `/` e `/runtime/config.js` no preview; se passar, com `autoPromotionEnabled: true`, o controller troca o seletor do `web-active` para os pods novos de uma vez. Os pods antigos continuam de pé por `scaleDownDelaySeconds: 30`.
- **Por que blue-green e não canary no SPA:** com tráfego dividido, o `index.html` novo (servido por um pod novo) pede `/assets/index-NOVOHASH.js`, e esse pedido pode cair num pod antigo, que só tem `index-VELHOHASH.js` → 404. No blue-green, cada requisição nova vai para **uma** versão inteira.
- **Por que a mudança é texto estático e não "versão no rodapé":** a mesma imagem vai para staging e prod e a config de runtime não sabe a tag. Algo como `import.meta.env` é resolvido no build, e não é o objetivo aqui. Basta uma mudança visível no código.

- [x] **Passo 1: mudança visível, com TDD**
  - Branch `feat/titulo`.
  - Primeiro o teste do componente da landing (`/`): espere o título novo, por exemplo `screen.getByRole('heading', { name: 'Encurtador de links' })`. `npm test` → falha.
  - Depois o código: troque o texto do título na landing e o `<title>` do `index.html` para `Encurtador de links`. `npm test` → verde.
  - Push, PR, CI verde. Não faça o merge ainda.

- [x] **Passo 2: abra o painel ANTES da troca**
  1. Abra `https://app.shortener-staging.fabricioroglio.com`, faça login e vá para `/links`.
  2. DevTools → **Network** → marque **Preserve log** e filtre por `assets`.
  3. Anote o hash do `index-XXXX.js` carregado.

- [x] **Passo 3: merge e observe**

```bash
gh pr merge --squash --delete-branch
kubectl argo rollouts --context shortener-staging -n shortener get rollout web --watch
```

Sequência esperada:
1. Um ReplicaSet novo marcado `preview` sobe; o antigo segue `stable, active`.
2. `AnalysisRun` (`web-smoke`) → um Job `curl` roda contra `web-preview` → `✔ Successful`.
3. Troca atômica: o novo vira `stable, active`; o antigo fica com `delay:30s` e depois `ScaledDown`.
4. `Status: ✔ Healthy`.

```bash
kubectl --context shortener-staging -n shortener get svc web-active -o jsonpath='{.spec.selector}'; echo
# rollouts-pod-template-hash mudou para o hash do ReplicaSet novo
```

- [x] **Passo 4: navegue depois da troca, sem recarregar**
  - Clique num link da lista (`/links/<code>`) e volte. A navegação é client-side (React Router): o bundle já está na memória da aba e nenhum `/assets/...` novo é pedido. **Nenhum 404** no Network.
  - Agora dê **F5**: aparece o título novo, o `index-YYYY.js` tem outro hash e todos os assets vêm 200.

**O que protege o usuário nessa troca:**
- **Atomicidade:** depois da troca, todo pedido novo (inclusive o `index.html` do F5) vai para a versão nova inteira, e os assets que ele pede existem nos mesmos pods.
- **`no-store` no `index.html`:** sem ele, o navegador poderia reaproveitar um `index.html` antigo do cache e pedir `index-VELHOHASH.js` para pods que não têm mais esse arquivo → 404 (a menos que o asset também estivesse no cache). Com `no-store`, o F5 sempre busca o `index.html` atual. Os assets com hash podem ser `immutable` porque o nome muda a cada build.
- **`scaleDownDelaySeconds: 30`:** os pods antigos não somem no instante da troca. Os pedidos que já estavam em voo, ou que chegam enquanto a mudança de seletor e de targets do ALB se propaga, ainda encontram quem responda (com os assets antigos). Depois disso, nenhum pedido novo vai para eles.
- **Limite honesto:** se o app usasse *code splitting* (`React.lazy`), uma aba aberta antes da troca pediria um chunk antigo **depois** da troca, e ele daria 404. As saídas usuais são manter os assets das duas últimas versões na imagem ou recarregar a página ao detectar erro de chunk. Fica como extensão.

- [x] **Passo 5: promova o web para prod**

```bash
gh workflow run promote.yml --repo <org>/shortener-deploy -f app=web     # aprove na UI
kubectl argo rollouts --context shortener-prod -n shortener get rollout web --watch
```

Prod tem 2 réplicas do web: o preview sobe com 2 pods antes da troca.

**Pronto quando:** você viu preview → smoke → troca do active, navegou sem 404 de assets e sabe explicar o papel de cada proteção.

---

## Tarefa 8.9: rollback do jeito GitOps

**Conceitos:**
- **`kubectl argo rollouts undo` muda o spec** (copia o template da revisão anterior para o Rollout). O spec é o que o ArgoCD compara com o Git, então o selfHeal desfaz o `undo` e você ganha dois deploys brigando.
- **`kubectl argo rollouts abort` não muda o spec**, só o status (`status.abort`). O ArgoCD não briga com ele. É o **botão de emergência legítimo**: durante um canary ruim, manda 100% para o estável na hora. O Rollout fica `Degraded` até o Git mudar (revert) ou alguém rodar `retry`. Em resumo: abort estanca, Git resolve.
- **O rollback certo é uma mudança no Git:** um PR com `git revert` do commit `deploy(prod): ...` no `shortener-deploy`, ou o próprio "Promote" com a tag antiga.
- **O rollback também passa pelos passos do canary** (é uma revisão nova para o Rollout), então leva ~6 minutos. Se quiser rollback instantâneo para revisões recentes, o Argo Rollouts tem `spec.rollbackWindow` (extensão).

- [x] **Passo 1: tente o rollback "errado"** (prod, com o header novo no ar)

```bash
kubectl argo rollouts --context shortener-prod -n shortener undo api
kubectl argo rollouts --context shortener-prod -n shortener get rollout api --watch
kubectl --context shortener-prod -n argocd get application shortener-api -w   # OutOfSync → Synced (selfHeal reaplicou o Git)
curl -sI https://shortener.fabricioroglio.com/healthz | grep -i x-shortener  # continua a versão nova
```

Observe: o `undo` começa um canary para a versão antiga, o ArgoCD detecta a divergência e reaplica o template do Git, e o Rollout volta para a versão nova. No GitOps, `undo` manual não vale.

- [x] **Passo 2: faça o rollback certo, por PR no `shortener-deploy`**

```bash
cd ~/Documents/projects/shortener-deploy
git switch main && git pull
git log --oneline -- apps/api/overlays/prod | head -3    # ache "deploy(prod): api sha-NOVA"
git switch -c rollback/api-prod
git revert --no-edit <hash-do-deploy-prod>
git push -u origin HEAD
gh pr create --fill && gh pr checks --watch              # infra + manifests verdes
gh pr merge --squash --delete-branch
```

Para não esperar o polling de ~3 minutos do ArgoCD:

```bash
kubectl --context shortener-prod -n argocd port-forward svc/argocd-server 8080:80 &
argocd login localhost:8080 --username admin --insecure \
  --password "$(kubectl --context shortener-prod -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd app sync shortener-api
# sem CLI: kubectl --context shortener-prod -n argocd annotate application shortener-api argocd.argoproj.io/refresh=normal --overwrite
# ou: botão Refresh na UI
kubectl argo rollouts --context shortener-prod -n shortener get rollout api --watch   # canary até a versão antiga
```

O header some quando chega a 100%.

**Alternativa sem PR:** `gh workflow run promote.yml --repo <org>/shortener-deploy -f app=api -f tag=sha-ANTIGA`. Ela passa pelo `validate` (a tag antiga passou por staging) e pela sua aprovação, e o bot commita com bypass. Em incidente, é o caminho mais rápido com trilha de auditoria.

- [ ] **Passo 3: botão de emergência (opcional, em staging)** (não feito: o abort automático da 8.7 mostrou o mesmo estado `Synced` + `Degraded`)
  - Dispare um canary qualquer (por exemplo, um merge trivial no `shortener-api`) e, com o Rollout em `Paused` a 10%, rode:

```bash
kubectl argo rollouts --context shortener-staging -n shortener abort api
kubectl argo rollouts --context shortener-staging -n shortener get rollout api   # Degraded, 100% no estável
kubectl --context shortener-staging -n argocd get application shortener-api      # Synced (o spec não mudou) + Degraded
kubectl argo rollouts --context shortener-staging -n shortener retry rollout api # recomeça o canary do passo 0
```

  - A Fase 9 (A6) explora isso com mais calma.

- [x] **Passo 4: volte para a versão nova** promovendo de novo pelo workflow (`-f app=api`, sem tag).

**Pronto quando:** você fez rollback e roll-forward pelo Git e sabe dizer por que o `undo` foi desfeito e o `abort` não.

---

## O que resolvemos (antes era "extensão")

Na versão anterior do plano, proteger a `main` bloqueava o bot de deploy e ficava para depois. Agora:
1. **Repositório separado de GitOps** (`shortener-deploy`): o histórico de deploys é só dele, e as apps não recebem commits de bot.
2. **GitHub App com bypass no ruleset:** humanos entram por PR com checks; o bot entra direto, com token de ~1h e acesso a um repo só.
3. **Prod com portão humano** (environment `production`) e validação antes da aprovação.

O que segue como extensão: o CI assumir papéis na AWS via OIDC (para `terraform plan` em PR) e assinatura de imagens (cosign) verificada antes do deploy.

## Checkpoint da Fase 8

- [x] GitHub App instalado só no `shortener-deploy`; nenhum PAT nos repos
- [x] Merge no `shortener-api` ou no `shortener-web` leva a staging sem intervenção, com commit assinado pelo bot
- [x] A `main` do `shortener-deploy` recusa o seu push direto e aceita o do bot
- [x] Prod só muda com a sua aprovação, uma app por vez, e sempre com uma tag que já passou por staging
- [ ] Canary da api com zero erros no k6, em staging e em prod; pesos vistos no ALB (staging: 0 em 24.001; prod: 30 × 503 do ALB numa das promoções, ver A20; pesos vistos pela annotation e pela contagem do header, não pelo listener)
- [x] **Canary com bug abortou sozinho**, e o roll-forward deixou tudo `Healthy`
- [x] Blue-green do web sem 404 de assets
- [ ] Rollback via Git; você sabe a diferença entre `undo` e `abort`
- [ ] **Derrube os ambientes** (`scripts/down.sh prod && scripts/down.sh staging`) se não for para a Fase 9 agora
