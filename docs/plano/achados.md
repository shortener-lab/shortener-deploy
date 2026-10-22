# Achados: buracos encontrados durante a implementação

Registro dos problemas que apareceram ao executar o plano: nas revisões de código ao fim de cada fase, nos testes e no uso real. Cada item diz **onde está**, **como quebra** (entrada concreta → resultado errado) e **o que fazer**.

Severidade:
- **Importante:** o usuário sente o efeito, ou ele vira problema de segurança ou de operação em produção.
- **Menor:** caso de borda, atrito de dev ou endurecimento que vale fazer.

Os itens A1–A8 vieram da Fase 2; os A9–A16, da Fase 3 (revisão do `shortener-web` e Tarefa 3.11). Os A17–A18 e o C7 vieram da leitura guiada do código do Kafka.

Atualize o status aqui quando corrigir. Uma correção entra com teste: escreva o teste que reproduz o problema, veja-o falhar, corrija e veja-o passar.

---

## Em aberto

### A1. ID token do mock é aceito como access token. *Menor (endurecimento)*
- **Onde:** `shortener-api/src/auth/jwt.ts` (verificação de `aud` e `token_use`).
- **Como quebra:** peça um token ao mock com `grant_type=password` e mande o **`id_token`** (não o `access_token`) como `Authorization: Bearer`. `GET /me/links` responde 200.
- **Por que passa:** a regra recusa `token_use = id`, mas o ID token do mock não tem `token_use`. Ele tem `aud = shortener-web`, que a api aceita.
- **Risco real:** o Cognito marca `token_use = id` e é recusado; em produção, hoje, não há buraco. Mas, com outro provedor (Keycloak, Auth0), o ID token passaria como credencial de API.
- **Correção sugerida:** exigir `token_use = access` **ou** recusar o header `typ` de ID token. Outra opção é exigir um `scope` que só o access token carrega.

### A2. `exp` não é obrigatório no token. *Menor (endurecimento)*
- **Onde:** `shortener-api/src/auth/jwt.ts`, chamada a `jwtVerify`.
- **Como quebra:** um token **sem** a claim `exp` (IdP mal configurado) é aceito para sempre. O `jwtVerify` só confere `exp` quando ela existe.
- **Correção sugerida:** `jwtVerify(token, jwks, { ..., requiredClaims: ['exp', 'sub'] })`. Corrija também o comentário que diz que o `jwtVerify` "confere exp".

### A3. IdP fora do ar vira 401 para todo mundo. *Menor (operação)*
- **Onde:** `shortener-api/src/http/auth.ts`, no `catch` do `verifyToken`.
- **Como quebra:** o IdP (ou o JWKS) cai, e todo usuário recebe 401, como se o token fosse ruim. O painel manda logar de novo, e o login também falha. O log fica só em `debug`, então ninguém vê.
- **Correção sugerida:** separar erro de rede do `jose` (`JWKSTimeout`, falha de `fetch`) de erro de token. Erro de rede vira **503** com log em `warn`. O plano da Fase 2 já cita isso em "Para pensar".

### A4. Recriar o container `oidc` causa até 10 minutos de 401. *Menor (atrito de dev)*
- **Onde:** a interação entre o `mock-oauth2-server` e o `createRemoteJWKSet` do `jose`.
- **Como quebra:** `docker compose up -d --force-recreate oidc` → o mock gera uma chave nova com o **mesmo `kid`** (`shortener`) → a api continua com a chave antiga em cache (o `jose` só rebusca quando aparece um `kid` desconhecido) → tokens novos falham na assinatura até o cache expirar.
- **Contorno:** `docker compose restart api`. A Fase 2 (Tarefa 2.7) já avisa.

### A5. `Bearer` seguido de dois espaços dá 401. *Menor*
- **Onde:** `shortener-api/src/http/auth.ts`, regex `/^Bearer (\S+)$/i`.
- **Como quebra:** `Authorization: Bearer  <token>` (dois espaços) recebe 401. A RFC 7235 permite um ou mais espaços.
- **Correção sugerida:** `/^Bearer +(\S+)$/i`.

### A6. `CORS_ALLOWED_ORIGINS` não é validado. *Menor (operação)*
- **Onde:** `shortener-api/src/config.ts`, helper `csv`.
- **Como quebra:** `CORS_ALLOWED_ORIGINS=http://localhost:5173/` (com barra no fim) nunca casa com a `Origin` do navegador, que não tem barra. Todo `fetch` do painel é bloqueado, e a api sobe sem reclamar.
- **Correção sugerida:** no zod, recusar a entrada que não for exatamente uma origem: `new URL(v).origin === v`.

### A7. O `client_credentials` do mock vira "usuário". *Menor (só dev)*
- **Onde:** `shortener-api/docker/oidc-config.json`, primeira regra do `tokenCallbacks`.
- **Como quebra:** `grant_type=client_credentials&client_id=alice` gera um token que a api aceita como a usuária `alice`.
- **Risco real:** nenhum em dev, porque o fluxo `password` já deixa logar como qualquer um. Mas confunde a regra do projeto: máquina usa API key, pessoa usa Bearer.
- **Correção sugerida:** casar também o `client_id` na regra, ou emitir um `aud` diferente para `client_credentials`.

### A8. Os dois composes usam o mesmo projeto e o mesmo volume. *Menor (armadilha local)*
- **Onde:** `teste/docker-compose.yml` e `shortener-api/docker-compose.yml`, ambos com `name: shortener`.
- **Como quebra:** um `docker compose down -v` rodado **dentro de `teste`** apaga o volume `shortener_pgdata`, que é o banco do `shortener-api`. Um `up` lá derruba o stack de cá.
- **Correção sugerida:** não use mais o compose da pasta `teste`, ou apague esse arquivo de lá.

### A9. O painel não tem Content-Security-Policy. *Menor (endurecimento)*
- **Onde:** `shortener-web/nginx/security-headers.conf`.
- **Como quebra:** os tokens ficam no `sessionStorage`, então qualquer XSS os rouba. Sem CSP, nada limita de onde vêm os scripts nem para onde os dados podem ser enviados (`connect-src`).
- **Correção sugerida:** o `40-runtime-config.sh` já tem as origens validadas da api e do IdP e pode gerar também um snippet de CSP incluído pelo `default.conf`, por exemplo: `default-src 'self'; connect-src 'self' <api> <idp>; frame-ancestors 'none'`.

### A10. O nginx vaza a porta 8080 em redirects, e o gzip sai sem `Vary`. *Menor (operação)*
- **Onde:** `shortener-web/nginx/default.conf`.
- **Como quebra:**
  - `GET /runtime` (diretório sem barra) responde `301 Location: http://<host>:8080/runtime/`. Atrás do ALB, na 443, esse endereço não existe.
  - Os assets com cache de 1 ano saem com `Content-Encoding: gzip` e sem `Vary: Accept-Encoding`. Um cache compartilhado pode entregar gzip a quem não pediu.
- **Correção sugerida:** `absolute_redirect off;` e `gzip_vary on;`.

### A11. `Retry-After` com lixo vira "tente em 0 s". *Menor*
- **Onde:** `shortener-web/src/api/client.ts`, `parseRetryAfter`.
- **Como quebra:**
  - `"-5"` e `"1.5"` passam pelo `Date.parse` como datas no passado e viram 0 s.
  - `"99999999999999999999"` vira um número de 21 dígitos na mensagem.
- **Correção sugerida:** só tratar o valor como data se ele estiver no formato HTTP-date (IMF-fixdate). Limitar o resultado a uma faixa razoável e usar o padrão (60 s) fora dela. É o mesmo princípio do C1: validar pelo formato exato.

### A12. O schema da resposta aceita URL com qualquer esquema. *Menor (defesa em profundidade)*
- **Onde:** `shortener-web/src/api/client.ts`, onde o `z.url()` aceita `javascript:alert(1)` e `data:text/html,...`.
- **Como quebra:** hoje, nada: a api só grava http(s), e o React 19 bloqueia `href` com `javascript:`. Mas o valor vira `href` em três componentes.
- **Correção sugerida:** `z.url({ protocol: /^https?$/ })`, como o `config.ts` já faz.

### A13. "Copiar" falha calado, e há detalhes de acessibilidade. *Menor (UX/a11y)*
- **Onde:** `CopyButton.tsx`, `LinkList.tsx` e `CreateLinkForm.tsx` (todos em `shortener-web/src/components/`).
- **Como quebra:**
  - **Falha calada:** fora de `localhost` e sem https, ou sem permissão, o clique não faz nada visível.
  - **Leitor de tela:** o "Copiado!" não é anunciado.
  - **Botões iguais:** todos os botões da lista se chamam "Copiar".
  - **Região de status:** o `role="status"` nasce junto com o texto, e leitores de tela costumam ignorar regiões que não existiam antes.
- **Correção sugerida:** mostrar "Não foi possível copiar"; usar ``aria-label={`Copiar ${shortUrl}`}``; deixar a região de status sempre renderizada, vazia quando não há mensagem.

### A14. "Entrar" não faz nada se o IdP estiver fora do ar. *Menor (UX)*
- **Onde:** `shortener-web/src/pages/Landing.tsx`.
- **Como quebra:** o `signinRedirect` falha ao ler a *discovery*, e o erro é engolido (`void`). O botão parece morto.
- **Correção sugerida:** capturar o erro e mostrar "Não foi possível falar com o provedor de login".

### A15. `returnToFrom` não recusa caracteres de controle. *Menor (hoje inalcançável)*
- **Onde:** `shortener-web/src/auth/oidc.ts`.
- **Como quebra:** `"/\t/evil.com"` passa na checagem, e o navegador descarta o tab e lê `//evil.com`. Hoje não dá para explorar: o `returnTo` vem do `location.pathname` (já codificado), e o `oidc-client-ts` guarda o `state` no `sessionStorage`, de modo que só o id aleatório vai e volta do IdP. Por isso o comentário "o state volta do IdP" é impreciso.
- **Correção sugerida:** recusar também `[\x00-\x1f]` e ajustar o comentário.

### A16. Debandada no cache das stats (*cache stampede*). *Menor (escala)*
- **Onde:** `shortener-api/src/http/app.ts`, rota `GET /links/:code/stats`.
- **Como quebra:** num link viral, quando o `stats:<code>` expira, **todas** as requisições daquele instante dão *miss* juntas e calculam as stats no Postgres ao mesmo tempo. O *jitter* do painel (Tarefa 3.11) espalha os pedidos das telas abertas, mas não protege contra outros clientes.
- **Correção sugerida:**
  - *single-flight*: uma requisição recalcula, e as outras esperam por ela. Pode ser um lock curto no Valkey com `SET NX PX`.
  - Ou *stale-while-revalidate*: entregar o valor um pouco velho enquanto um único processo recalcula.

### A17. A tabela `processed_events` cresce para sempre. *Menor (operação)*
- **Onde:** `shortener-api/migrations/001_init.sql` e `src/analytics/processClick.ts`.
- **Como quebra:** cada clique grava uma linha (UUID de 16 bytes, timestamp e índice da chave primária: algo como 50–60 bytes por linha). Nada apaga essas linhas. Com 1 milhão de cliques por dia, isso dá dezenas de GB por ano, e o índice fica maior que a memória do banco.
- **Correção sugerida:** um job diário (CronJob no Kubernetes ou `pg_cron`) que faz `DELETE FROM processed_events WHERE processed_at < now() - interval '14 days'`. A janela só precisa ser maior que o tempo máximo em que uma mensagem pode ser reentregue: a retenção do tópico (7 dias) mais uma folga. Num volume grande, particionar a tabela por dia e apagar partições inteiras.

### A18. Nenhum teste garante que uma falha no envio para a DLQ segura o offset. *Menor (cobertura de teste)*
- **Onde:** `shortener-api/test/unit/handleMessage.test.ts`, que cobre o envio para a DLQ só com uma DLQ que sempre aceita.
- **Como quebra:** hoje o `await dlq.send(...)` faz o `handleMessage` lançar quando a DLQ recusa. O `eachMessage` falha, e a mensagem não é dada como lida. O comportamento está certo, mas nada o protege. Se alguém trocar o `await` por `.catch(log)`, para "não travar o worker", a mensagem envenenada passa a sumir em silêncio: o offset anda sem a mensagem estar em lugar nenhum. E os testes continuam verdes.
- **Correção sugerida:** um teste "DLQ recusa → `handleMessage` rejeita" com uma `dlq` cujo `send` lança erro.

---

## Corrigidos

### C1. Cursor com data que o Postgres recusa dava 500. *Importante (Fase 2)*
- **Onde:** `shortener-api/src/links/repository.ts`, `decodeCursor`.
- **Como quebrava:** `GET /me/links?cursor=<base64 de {"t":"1","c":"abcdefg"}>` → **500** `internal_error`. O `Date.parse("1")` do JS aceita, mas o `$2::timestamptz` do Postgres recusa. O mesmo valia para o ano 275760 e para 30 de fevereiro.
- **Correção:** o cursor só passa se `t` tiver o formato exato que o `to_char` gera (`YYYY-MM-DDTHH:MM:SS.ffffffZ`) e for uma data que existe. Commit `3594020` no `shortener-api`, com teste.

### C2. O teste e2e clicava num link ambíguo. *Defeito do plano (Fase 3)*
- **Onde:** `shortener-web/e2e/fluxo.spec.ts`, passo 5.
- **Como quebrava:** `getByRole('link', { name: '/abc1234' })` casava **dois** links: o do detalhe e o da URL curta `http://localhost:3000/abc1234`. O motivo é que o `name` do Playwright casa por *substring*.
- **Correção:** `{ name: ..., exact: true }`.

### C3. O container não explicava por que não subia com root FS somente leitura. *Defeito do plano (Fase 3)*
- **Onde:** `shortener-web/nginx/40-runtime-config.sh`.
- **Como quebrava:** com `--read-only` e sem o `tmpfs` de `/usr/share/nginx/html/runtime`, o container saía com erro (certo), mas sem a mensagem `não existe ou não é gravável`. Havia duas causas:
  1. O `[ -w dir ]` do BusyBox só olha os bits de permissão e não percebe um filesystem montado como somente leitura.
  2. A primeira correção tentada (`: > arquivo`) também falhava calada. O `:` é um *builtin especial* do POSIX: quando um redirecionamento dele falha, o script inteiro morre na hora, antes de chegar ao `fail`.
- **Correção:** testar a escrita de verdade, dentro de um subshell: `! (: > "$tmp") 2>/dev/null`. No K8s, a falta do `emptyDir` agora aparece com uma mensagem clara no log do CrashLoopBackOff.

### C4. `.DS_Store` entrava nos commits. *Atrito (Fase 2)*
- **Onde:** `shortener-api/.gitignore`. O template Node do GitHub não cobre arquivos do macOS.
- **Correção:** a linha `.DS_Store` foi adicionada. O `shortener-web` já vem com ela pelo template do Vite.

### C5. Um 401 logo depois do login criava um loop infinito com o IdP. *Importante (Fase 3)*
- **Onde:** `shortener-web/src/api/hooks.ts` (`useLoginOnUnauthorized`).
- **Como quebrava:** a api recusa o token recém-emitido (por exemplo, o A4: chave velha em cache) → 401 → o painel manda ao IdP → o IdP tem sessão e devolve na hora → 401 → … para sempre. Com o Cognito, isso é um loop de página inteira sem ação do usuário.
- **Correção:** o `onSigninCallback` (`completeSignin`) grava a hora do login no `sessionStorage`. Um 401 nos 30 s seguintes mostra o erro em vez de redirecionar. Commit `4437f11`, com teste.

### C6. Uma falha na renovação silenciosa trancava o painel. *Importante (Fase 3)*
- **Onde:** `shortener-web/src/auth/RequireAuth.tsx`.
- **Como quebrava:** o notebook acorda sem rede, o refresh do token falha uma vez, e o `react-oidc-context` marca `error`, mas mantém o usuário logado. O `RequireAuth` trocava o app inteiro por "Falha no login", sem "Sair", sem botão e sem redirect, até um F5 manual.
- **Correção:** com usuário ainda logado, o conteúdo continua; se o token vencer de fato, o 401 da api leva ao login. Sem usuário, o erro ganha o botão "Entrar de novo". Commit `1c6324f`, com teste.

### C7. A api não subia se o Kafka estivesse fora na hora da partida. *Importante (disponibilidade)*
- **Onde:** `shortener-api/src/api.ts` (o `await producer.connect()` antes do `app.listen`).
- **Como quebrava:** com o broker inacessível, o `connect()` ficava pendurado e rejeitava depois de **82 s** (medido: `broker transport failure`), derrubando o processo. Um pod novo durante uma pane do Kafka (scale-up, troca de nó, restart) entrava em CrashLoop, e o redirect caía por causa das estatísticas.
- **Correção:** o producer conecta em segundo plano (`connectInBackground` em `src/events/kafka.ts`), e a api abre a porta na hora. A cada falha, tenta de novo com um producer **novo**: medimos que um producer cujo `connect()` falhou recusa outro ("*Connect has already been called elsewhere*"). Enquanto não conecta, o `send()` é recusado e o publisher só loga: esses cliques se perdem, mas o redirect funciona. Commit `db05b3f`, com teste unitário e um teste de integração que sobe o `src/api.ts` com `KAFKA_BROKERS=localhost:1` e confere o 302.

### C8. A cota de contas só aparecia depois que o apply quebrava. *Defeito do plano (Fase 5)*
- **Onde:** `docs/plano/05-aws-organizacao-bootstrap.md`, Tarefa 5.3, Passo 8.
- **Como quebrava:** a organização nova nasceu com a cota "Maximum number of accounts" em **2** (default 10). O `terraform apply` criou a `shortener-prod` e falhou nas outras duas com `ConstraintViolationException: You have exceeded the allowed number of AWS accounts`. O plano citava outro código de erro (`ACCOUNT_NUMBER_LIMIT_EXCEEDED`) e mandava pedir aumento só depois da falha. Pedir 5 pela API também falha: ela só aceita valores acima do default ("*greater than the default quota value of 10.0*").
- **Correção:** novo Passo 8 na Tarefa 5.2 confere a cota e pede 11 antes de qualquer `apply`. O texto da Tarefa 5.3 traz a mensagem real.

### C9. O teste da SCP esperava o código de erro errado. *Defeito do plano (Fase 5)*
- **Onde:** `docs/plano/05-aws-organizacao-bootstrap.md`, Tarefa 5.4, Passo 3.
- **Como quebrava:** o plano dizia que o `ec2 describe-vpcs` em `us-west-2` daria `AccessDenied`. O EC2 responde `UnauthorizedOperation` (medido em 22/10/2026). A frase que importa, "*with an explicit deny in a service control policy*", vem igual. Quem procurasse a palavra exata acharia que a SCP não funcionou.
- **Correção:** o passo mostra o código real e explica que o nome do erro varia por serviço.

### C10. Flags numa variável quebravam no zsh. *Defeito do plano (Fase 6)*
- **Onde:** `docs/plano/06-terraform-ambientes.md`, Tarefa 6.1, Passo 1.
- **Como quebrava:** o passo fazia `P="--profile shortener-staging --region us-east-1"` e depois `aws eks ... $P`. No bash, o `$P` vira 4 argumentos. No zsh (o shell padrão do macOS), vira **um**, e a AWS CLI responde `Unknown options: --profile shortener-staging --region us-east-1`.
- **Correção:** o passo exporta `AWS_PROFILE` e `AWS_REGION`, que valem para qualquer shell. A rotina de início de sessão também passou a ler o token da Cloudflare do Keychain, como na Fase 5.

### C11. `K="kubectl ..."` e `exec ... env` não funcionavam. *Defeito do plano (Fases 6 a 9)*
- **Onde:** Tarefa 6.4 (Passo 10), Tarefa 7.4, Tarefa 8.5 e os experimentos A1 e A6 da Fase 9.
- **Como quebrava:**
  - O mesmo problema do C10, com comandos inteiros: `K="kubectl --context shortener-staging"` e depois `$K get ...`. No zsh, o shell procura um programa chamado `kubectl --context shortener-staging` e responde `command not found`.
  - A conferência da Pod Identity rodava `kubectl exec deploy/argo-rollouts -- env`. A imagem do controller é *distroless* (sem shell e sem o binário `env`), e o exec falha com `executable file not found in $PATH`.
- **Correção:**
  - Os atalhos viraram funções (`k() { kubectl --context shortener-staging "$@"; }`), que funcionam igual no zsh e no bash.
  - A Pod Identity é conferida pela spec do pod (`.spec.containers[0].env`), onde o webhook do EKS injeta `AWS_CONTAINER_CREDENTIALS_FULL_URI`. Medido em 22/10/2026: `AWS_REGION`, `AWS_STS_REGIONAL_ENDPOINTS`, `AWS_CONTAINER_CREDENTIALS_FULL_URI` e `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`.

---

## Pegadinhas de ambiente (não são bugs do código)

- **`docker compose --profile app stop api worker` derrubou o Kafka junto.** Depois de parar serviços específicos, confira o resto com `docker compose ps` e suba de novo com `docker compose up -d --wait`.
- **O volume reaproveitado esconde o script de init.** O `docker-entrypoint-initdb.d` do Postgres só roda com o volume vazio. Para validar o script, use um container descartável sem volume.
- **Ferramentas mudam de flag.** O `create-playwright` atual não tem mais `--test-dir` nem `--no-gha`. O Vite 8 não emite mais o aviso sobre `<script>` sem `type="module"`. O `typescript@latest` já é a 7, mas o `typescript-eslint` exige menos de 6.1. Antes de seguir um comando do plano, rode `--help`.
