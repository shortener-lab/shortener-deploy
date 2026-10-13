# Fase 2: autenticação OIDC na api

**Status:** concluída em 2026-10-12 em `~/Documents/projects/shortener-api` (um commit por tarefa, mais a correção do cursor da revisão final).
**Entrega:** a api aceita usuários logados (token OIDC) além da API key. Cada link ganha um dono, existe `GET /me/links` paginado, as stats só aparecem para o dono, o CORS libera o painel React e um IdP de mentira roda no compose.
**Custo:** zero. Tudo roda no seu Mac.
**Repo:** `shortener-api` (`~/Documents/projects/shortener-api`; o plano continua em `~/Documents/projects/teste/docs/plano` até a Fase 4).

**tsconfig rígido.** O `tsconfig.json` do `shortener-api` saiu do `tsc --init` do TypeScript 6 e mantém `noUncheckedIndexedAccess` e `exactOptionalPropertyTypes`. O código desta fase já está escrito para eles: `rows[0]` pode ser `undefined` (checamos antes de usar) e um campo opcional que recebe `undefined` explícito é declarado como `campo?: T | undefined`. Se o `typecheck` reclamar de algo assim num trecho novo, a correção segue esse mesmo padrão. Ainda local: um commit por tarefa, sem PR (os PRs começam na Fase 4).

**Por que não basta a API key.** O painel React (Fase 3) roda no navegador. Tudo o que vai para o navegador é público: qualquer pessoa abre o DevTools e copia. Uma API key embutida no bundle vira a chave de todo mundo, sem expiração e sem saber quem é quem. O que precisamos é que **cada pessoa** prove quem é e receba uma credencial **dela**, de vida curta.

**Por que OIDC com Authorization Code + PKCE.** O navegador manda o usuário para o provedor de identidade (Cognito na AWS, `mock-oauth2-server` em dev). O usuário faz login lá, e o navegador volta com um `code` de uso único. O app troca esse `code` por um access token (um JWT assinado pelo provedor). Como o app no navegador não consegue guardar segredo, o PKCE substitui o *client secret*: o app inventa um segredo por login (`code_verifier`), manda só o hash dele no início (`code_challenge`) e mostra o original na troca. Quem interceptar o `code` não tem o verifier e não consegue trocá-lo. A api não participa do login: ela só **confere a assinatura do JWT** com a chave pública do provedor (JWKS) e lê o `sub`, que é o ID do usuário.

A API key continua existindo para máquina-a-máquina (scripts, k6, smoke tests).

Convenção de TDD em cada tarefa:
1. Escreva o teste.
2. Rode e veja falhar.
3. Implemente.
4. Rode e veja passar (`npm test && npm run typecheck && npm run lint`).
5. Faça o commit.

Antes de começar, a infra local precisa estar de pé: `docker compose up -d`.

---

## Tarefa 2.1: dependências e IdP mock no compose

**Arquivos:**
- Criar `docker/oidc-config.json`
- Modificar `docker-compose.yml`, `.env.example` e `.env`
- `package.json` e `package-lock.json` mudam via `npm i`

**Conceitos:**
- **IdP mock:** o `mock-oauth2-server` fala OIDC de verdade (discovery, `authorize`, `token`, `jwks`), mas aceita qualquer usuário e senha. Cada "issuer" é só um prefixo de caminho: usamos `shortener`, então o issuer é `http://localhost:8090/shortener`.
- **O `iss` sai do host que o cliente usou.** O mock monta o issuer a partir do `Host` da requisição. O navegador (e o seu `curl`) pede o token em `localhost:8090`, então o token sai com `iss = http://localhost:8090/shortener`.
- **Por que `OIDC_JWKS_URL` é separada de `OIDC_ISSUER`.** Dentro de um container, `localhost` é o próprio container, não o seu Mac. A api em container precisa buscar a chave pública pelo nome do serviço (`http://oidc:8090/shortener/jwks`), mas continua validando `iss = http://localhost:8090/shortener`, porque foi esse o emissor que o navegador viu. Na AWS os dois apontam para o Cognito, e a separação não custa nada.
- **Token callback:** por padrão, o mock põe `aud = default`. O callback abaixo põe `aud = shortener-web` (o client id do painel), que é o que a api vai exigir. O `sub` vem do usuário digitado no login (`${subject}`). Para `client_credentials` (não há usuário), o `sub` vira o próprio client id.
- **Config em arquivo, não em variável:** o Compose interpreta `${...}` no `docker-compose.yml`. Se o JSON ficasse inline, `${subject}` seria trocado por vazio. Dentro de um arquivo montado, o Compose não mexe.

- [ ] **Passo 1: instale as dependências da fase**

```bash
npm i jose cors
npm i -D @types/cors
```

O `jose` traz os tipos próprios. O `cors` não, por isso o `@types/cors`.

- [ ] **Passo 2: crie `docker/oidc-config.json`**

```json
{
  "interactiveLogin": true,
  "httpServer": "NettyWrapper",
  "tokenCallbacks": [
    {
      "issuerId": "shortener",
      "tokenExpiry": 3600,
      "requestMappings": [
        {
          "requestParam": "grant_type",
          "match": "client_credentials",
          "claims": { "sub": "${clientId}", "aud": ["shortener-web"] }
        },
        {
          "requestParam": "client_id",
          "match": "shortener-web",
          "claims": { "sub": "${subject}", "aud": ["shortener-web"] }
        }
      ]
    }
  ]
}
```

As regras são avaliadas em ordem e a primeira que casa vence. A primeira pega o `client_credentials`; a segunda pega qualquer outro fluxo do client `shortener-web` (o Authorization Code do painel e o `password`, que usaremos no `curl`).

- [ ] **Passo 3: no `docker-compose.yml`, troque o bloco `x-app-env` inteiro por este**

```yaml
x-app-env: &app-env
  NODE_ENV: development
  LOG_LEVEL: info
  PUBLIC_BASE_URL: http://localhost:3000
  DATABASE_URL: postgres://shortener:shortener@postgres:5432/shortener
  DATABASE_SSL: "false"
  REDIS_URL: redis://valkey:6379
  KAFKA_BROKERS: kafka:19092
  KAFKA_SSL: "false"
  KAFKA_REPLICATION_FACTOR: "1"
  API_KEY: dev-api-key-change-me-0123456789
  # O token é emitido para o navegador, em localhost:8090: é esse o iss que a api confere...
  OIDC_ISSUER: http://localhost:8090/shortener
  OIDC_AUDIENCE: shortener-web
  # ...mas, dentro do container, "localhost" é o próprio container: a chave pública vem pelo nome do serviço.
  OIDC_JWKS_URL: http://oidc:8090/shortener/jwks
  CORS_ALLOWED_ORIGINS: http://localhost:5173,http://localhost:8081
```

O `worker` e o `setup` também recebem essas variáveis pelo anchor, mas ignoram: o `baseSchema` do zod descarta chaves que não conhece.

- [ ] **Passo 4: adicione o serviço `oidc`** em `services:`, logo depois do `kafka` (sem `profiles`: ele sobe com a infra, porque o frontend em dev também precisa dele)

```yaml
  oidc:
    image: ghcr.io/navikt/mock-oauth2-server:6.0.4
    ports: ["8090:8090"]
    environment:
      SERVER_PORT: "8090"
      JSON_CONFIG_PATH: /config/oidc-config.json
    volumes:
      - ./docker/oidc-config.json:/config/oidc-config.json:ro
```

E, no serviço `api`, troque o `depends_on` por este (a api só busca o JWKS na primeira requisição com token, então basta o container ter iniciado):

```yaml
    depends_on:
      setup: { condition: service_completed_successfully }
      valkey: { condition: service_healthy }
      oidc: { condition: service_started }
```

- [ ] **Passo 5: atualize `.env.example`** (a api roda no host, então aqui tudo é `localhost`)

```
NODE_ENV=development
LOG_LEVEL=debug
PORT=3000
PUBLIC_BASE_URL=http://localhost:3000
DATABASE_URL=postgres://shortener:shortener@localhost:5432/shortener
DATABASE_SSL=false
REDIS_URL=redis://localhost:6379
KAFKA_BROKERS=localhost:9092
KAFKA_SSL=false
KAFKA_REPLICATION_FACTOR=1
API_KEY=dev-api-key-change-me-0123456789
OIDC_ISSUER=http://localhost:8090/shortener
OIDC_AUDIENCE=shortener-web
OIDC_JWKS_URL=http://localhost:8090/shortener/jwks
CORS_ALLOWED_ORIGINS=http://localhost:5173,http://localhost:8081
```

E acrescente as mesmas 4 linhas ao seu `.env` (não copie o arquivo inteiro por cima, para não perder ajustes seus):

```bash
cat >> .env <<'EOF'
OIDC_ISSUER=http://localhost:8090/shortener
OIDC_AUDIENCE=shortener-web
OIDC_JWKS_URL=http://localhost:8090/shortener/jwks
CORS_ALLOWED_ORIGINS=http://localhost:5173,http://localhost:8081
EOF
```

- [ ] **Passo 6: suba e confira o IdP**

```bash
docker compose up -d
curl -s localhost:8090/shortener/.well-known/openid-configuration | grep -E '"(issuer|jwks_uri|token_endpoint)"'
```

Esperado:

```
  "issuer" : "http://localhost:8090/shortener",
  "token_endpoint" : "http://localhost:8090/shortener/token",
  "jwks_uri" : "http://localhost:8090/shortener/jwks",
```

- [ ] **Passo 7: emita um token sem navegador e olhe as claims**

```bash
TOKEN=$(curl -s -X POST localhost:8090/shortener/token \
  -d grant_type=password -d username=alice -d password=qualquer \
  -d client_id=shortener-web -d scope=openid \
  | node -pe 'JSON.parse(require("fs").readFileSync(0, "utf8")).access_token')
node -pe 'JSON.parse(Buffer.from(process.argv[1].split(".")[1], "base64url"))' "$TOKEN"
```

Esperado (datas e `jti` mudam):

```
{
  sub: 'alice',
  aud: 'shortener-web',
  nbf: ...,
  iss: 'http://localhost:8090/shortener',
  exp: ...,
  iat: ...,
  jti: '...'
}
```

O `grant_type=password` é só um atalho de dev para o `curl`: o mock aceita qualquer senha. O painel vai usar Authorization Code + PKCE (você faz esse fluxo na mão na Tarefa 2.7). O Cognito, aliás, nem habilita o fluxo `password` no nosso app client.

- [ ] **Passo 8: confira que nada quebrou.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 9: commit.** `git add -A && git commit -m "feat: IdP mock (mock-oauth2-server) no compose e dependências de auth"`

**Pronto quando:** o discovery responde em `localhost:8090` e o token do `curl` tem `sub = alice`, `aud = shortener-web` e `iss = http://localhost:8090/shortener`.

---

## Tarefa 2.2: configuração de OIDC e CORS

**Arquivos:** modificar `src/config.ts` e `test/unit/config.test.ts`.

**Interfaces que esta tarefa entrega:** `ApiConfig` ganha `OIDC_ISSUER: string`, `OIDC_AUDIENCE: string`, `OIDC_JWKS_URL: string` e `CORS_ALLOWED_ORIGINS: string[]`.

**Conceitos:**
- As 4 variáveis são obrigatórias só na api. O worker e o setup continuam sem saber de OIDC.
- `OIDC_ISSUER` é comparado **byte a byte** com o `iss` do token. Uma barra a mais no fim (`.../shortener/`) já faz todo token ser recusado.
- Lista separada por vírgula vira `string[]`, com o mesmo helper (`csv`) que agora também atende `KAFKA_BROKERS`.

- [ ] **Passo 1: atualize o teste** `test/unit/config.test.ts` (arquivo inteiro)

```ts
import { describe, expect, it } from 'vitest';
import { loadApiConfig, loadBaseConfig } from '../../src/config.js';

const base = {
  DATABASE_URL: 'postgres://u:p@localhost:5432/db',
  REDIS_URL: 'redis://localhost:6379',
  KAFKA_BROKERS: 'localhost:9092, localhost:9093',
};
const api = {
  ...base,
  PUBLIC_BASE_URL: 'http://localhost:3000',
  API_KEY: 'a'.repeat(32),
  OIDC_ISSUER: 'http://localhost:8090/shortener',
  OIDC_AUDIENCE: 'shortener-web',
  OIDC_JWKS_URL: 'http://localhost:8090/shortener/jwks',
  CORS_ALLOWED_ORIGINS: 'http://localhost:5173, http://localhost:8081',
};

describe('config', () => {
  it('aplica defaults e converte tipos', () => {
    const c = loadApiConfig(api);
    expect(c.PORT).toBe(3000);
    expect(c.KAFKA_BROKERS).toEqual(['localhost:9092', 'localhost:9093']);
    expect(c.KAFKA_SSL).toBe(false);
    expect(c.KAFKA_REPLICATION_FACTOR).toBe(1);
    expect(c.RATE_LIMIT_PER_MINUTE).toBe(10);
  });

  it('converte "true" em boolean', () => {
    expect(loadApiConfig({ ...api, KAFKA_SSL: 'true' }).KAFKA_SSL).toBe(true);
  });

  it('falha dizendo qual variável falta', () => {
    const { API_KEY: _omit, ...semKey } = api;
    expect(() => loadApiConfig(semKey)).toThrow(/API_KEY/);
  });

  it('rejeita API_KEY curta', () => {
    expect(() => loadApiConfig({ ...api, API_KEY: 'curta' })).toThrow(/API_KEY/);
  });

  it('transforma CORS_ALLOWED_ORIGINS em lista', () => {
    expect(loadApiConfig(api).CORS_ALLOWED_ORIGINS).toEqual(['http://localhost:5173', 'http://localhost:8081']);
  });

  it('exige as variáveis de OIDC na api', () => {
    for (const name of ['OIDC_ISSUER', 'OIDC_AUDIENCE', 'OIDC_JWKS_URL', 'CORS_ALLOWED_ORIGINS'] as const) {
      const { [name]: _omit, ...sem } = api;
      expect(() => loadApiConfig(sem), name).toThrow(new RegExp(name));
    }
  });

  it('rejeita OIDC_ISSUER que não é URL', () => {
    expect(() => loadApiConfig({ ...api, OIDC_ISSUER: 'shortener' })).toThrow(/OIDC_ISSUER/);
  });

  it('a config base não exige variáveis exclusivas da api', () => {
    expect(() => loadBaseConfig(base)).not.toThrow();
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm run test:unit -- test/unit/config.test.ts`: os 3 testes novos falham. O de lista falha com `expected undefined to deeply equal [ 'http://localhost:5173', …(1) ]`, e os outros dois com `expected [Function] to throw an error`, porque o schema ainda não conhece as variáveis.

- [ ] **Passo 3: implemente** `src/config.ts` (arquivo inteiro)

```ts
import { z } from 'zod';

const bool = z
  .enum(['true', 'false'])
  .default('false')
  .transform((v) => v === 'true');

const csv = z
  .string()
  .min(1)
  .transform((s) => s.split(',').map((v) => v.trim()).filter(Boolean));

const baseSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  APP_VERSION: z.string().default('dev'),
  DATABASE_URL: z.string().min(1),
  DATABASE_SSL: bool,
  DATABASE_SSL_CA_FILE: z.string().optional(),
  REDIS_URL: z.string().min(1),
  KAFKA_BROKERS: csv,
  KAFKA_SSL: bool,
  KAFKA_REPLICATION_FACTOR: z.coerce.number().int().min(1).default(1),
});

const apiSchema = baseSchema.extend({
  PORT: z.coerce.number().int().positive().default(3000),
  PUBLIC_BASE_URL: z.string().min(1),
  API_KEY: z.string().min(16),
  CACHE_TTL_SECONDS: z.coerce.number().int().positive().default(86_400),
  RATE_LIMIT_PER_MINUTE: z.coerce.number().int().positive().default(10),
  OIDC_ISSUER: z.url(),
  OIDC_AUDIENCE: z.string().min(1),
  OIDC_JWKS_URL: z.url(),
  CORS_ALLOWED_ORIGINS: csv,
});

const workerSchema = baseSchema.extend({
  WORKER_HEALTH_PORT: z.coerce.number().int().positive().default(3001),
});

export type BaseConfig = z.infer<typeof baseSchema>;
export type ApiConfig = z.infer<typeof apiSchema>;
export type WorkerConfig = z.infer<typeof workerSchema>;

function parse<S extends z.ZodType>(schema: S, env: Record<string, string | undefined>): z.infer<S> {
  const result = schema.safeParse(env);
  if (!result.success) {
    throw new Error(`Configuração inválida:\n${z.prettifyError(result.error)}`);
  }
  return result.data;
}

export const loadBaseConfig = (env: Record<string, string | undefined> = process.env) => parse(baseSchema, env);
export const loadApiConfig = (env: Record<string, string | undefined> = process.env) => parse(apiSchema, env);
export const loadWorkerConfig = (env: Record<string, string | undefined> = process.env) => parse(workerSchema, env);
```

- [ ] **Passo 4: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 5: commit.** `git add -A && git commit -m "feat: config de OIDC e CORS na api"`

**Pronto quando:** `loadApiConfig` falha nomeando a variável de OIDC que falta, e `loadBaseConfig` continua passando sem elas.

---

## Tarefa 2.3: verificador de JWT

**Arquivos:**
- Criar `src/auth/jwt.ts`
- Teste: `test/unit/jwt.test.ts`

**Interfaces que esta tarefa entrega:**

```ts
type VerifyToken = (token: string) => Promise<{ sub: string }>;
class InvalidTokenError extends Error {}
interface TokenVerifierOptions { issuer: string; audience: string; jwks: JWTVerifyGetKey }
createTokenVerifier(opts: TokenVerifierOptions): VerifyToken
```

**Conceitos:**
- **JWT e JWKS:** o token tem três partes (header, payload, assinatura). O provedor assina com a chave privada e publica as chaves públicas num JWKS. O `kid` do header diz qual chave usar.
- **Uma fábrica, duas fontes de chave:** em produção, `createRemoteJWKSet(new URL(OIDC_JWKS_URL))` baixa o JWKS e o mantém em cache. Nos testes, `createLocalJWKSet({ keys: [...] })` usa uma chave gerada na hora. O verificador não sabe a diferença: os dois são um `JWTVerifyGetKey`.
- **Fixe o algoritmo (`algorithms: ['RS256']`):** sem isso, um token forjado poderia pedir um algoritmo fraco no header.
- **`aud` OU `client_id`:** o access token do Cognito **não tem `aud`**. Ele traz `client_id` e `token_use = access`. O mock traz `aud`. A regra aceita os dois formatos e recusa o ID token do Cognito (`token_use = id`), que não foi feito para autorizar chamadas à API.
- **`jwtVerify` já confere** assinatura, `alg`, `exp`, `nbf` e `iss`. O resto (aud/client_id, token_use, sub) é nosso.

- [ ] **Passo 1: escreva o teste** `test/unit/jwt.test.ts`

```ts
import { beforeAll, describe, expect, it } from 'vitest';
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT, type CryptoKey, type JWTPayload } from 'jose';
import { createTokenVerifier, type VerifyToken } from '../../src/auth/jwt.js';

const ISSUER = 'http://localhost:8090/shortener';
const AUDIENCE = 'shortener-web';

let privateKey: CryptoKey;
let otherPrivateKey: CryptoKey;
let verify: VerifyToken;

beforeAll(async () => {
  const pair = await generateKeyPair('RS256');
  privateKey = pair.privateKey;
  otherPrivateKey = (await generateKeyPair('RS256')).privateKey;
  const jwk = { ...(await exportJWK(pair.publicKey)), kid: 'test-key', alg: 'RS256', use: 'sig' };
  verify = createTokenVerifier({ issuer: ISSUER, audience: AUDIENCE, jwks: createLocalJWKSet({ keys: [jwk] }) });
});

interface SignOptions {
  claims?: JWTPayload;
  issuer?: string;
  expiresIn?: string | number;
  key?: CryptoKey;
}

function sign({ claims = { sub: 'alice', aud: AUDIENCE }, issuer = ISSUER, expiresIn = '5m', key = privateKey }: SignOptions = {}) {
  return new SignJWT(claims)
    .setProtectedHeader({ alg: 'RS256', kid: 'test-key' })
    .setIssuer(issuer)
    .setIssuedAt()
    .setExpirationTime(expiresIn)
    .sign(key);
}

describe('createTokenVerifier', () => {
  it('aceita token válido com aud', async () => {
    expect(await verify(await sign())).toEqual({ sub: 'alice' });
  });

  it('aceita aud em lista', async () => {
    expect(await verify(await sign({ claims: { sub: 'alice', aud: ['outra-api', AUDIENCE] } }))).toEqual({ sub: 'alice' });
  });

  it('aceita access token no estilo Cognito (sem aud, com client_id e token_use=access)', async () => {
    const token = await sign({ claims: { sub: 'bob', client_id: AUDIENCE, token_use: 'access' } });
    expect(await verify(token)).toEqual({ sub: 'bob' });
  });

  it('rejeita issuer errado', async () => {
    await expect(verify(await sign({ issuer: 'http://evil.test/shortener' }))).rejects.toThrow();
  });

  it('rejeita token expirado', async () => {
    const past = Math.floor(Date.now() / 1000) - 60;
    await expect(verify(await sign({ expiresIn: past }))).rejects.toThrow();
  });

  it('rejeita aud e client_id de outro cliente', async () => {
    await expect(verify(await sign({ claims: { sub: 'alice', aud: 'outro-app' } }))).rejects.toThrow(/outro cliente/);
    await expect(verify(await sign({ claims: { sub: 'alice', client_id: 'outro-app' } }))).rejects.toThrow(/outro cliente/);
  });

  it('rejeita ID token do Cognito (token_use=id)', async () => {
    const token = await sign({ claims: { sub: 'bob', aud: AUDIENCE, token_use: 'id' } });
    await expect(verify(token)).rejects.toThrow(/token_use/);
  });

  it('rejeita token sem sub', async () => {
    await expect(verify(await sign({ claims: { aud: AUDIENCE } }))).rejects.toThrow(/sub/);
  });

  it('rejeita token assinado por outra chave', async () => {
    await expect(verify(await sign({ key: otherPrivateKey }))).rejects.toThrow();
  });

  it('rejeita algo que nem é JWT', async () => {
    await expect(verify('nao-sou-um-jwt')).rejects.toThrow();
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm run test:unit -- test/unit/jwt.test.ts`: falha com `Error: Cannot find module '../../src/auth/jwt.js'`.

- [ ] **Passo 3: implemente** `src/auth/jwt.ts`

```ts
import { jwtVerify, type JWTVerifyGetKey } from 'jose';

export type VerifyToken = (token: string) => Promise<{ sub: string }>;

export class InvalidTokenError extends Error {}

export interface TokenVerifierOptions {
  issuer: string;
  audience: string;
  jwks: JWTVerifyGetKey; // createRemoteJWKSet em produção, createLocalJWKSet nos testes
}

export function createTokenVerifier(opts: TokenVerifierOptions): VerifyToken {
  return async (token) => {
    // jwtVerify confere assinatura, alg, exp, nbf e iss. O aud fica conosco: o Cognito não manda aud no access token.
    const { payload } = await jwtVerify(token, opts.jwks, { issuer: opts.issuer, algorithms: ['RS256'] });

    const aud = payload.aud === undefined ? [] : Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    if (!aud.includes(opts.audience) && payload.client_id !== opts.audience) {
      throw new InvalidTokenError('token emitido para outro cliente');
    }
    if (payload.token_use !== undefined && payload.token_use !== 'access') {
      throw new InvalidTokenError('token_use precisa ser "access"');
    }
    if (typeof payload.sub !== 'string' || payload.sub === '') {
      throw new InvalidTokenError('token sem sub');
    }
    return { sub: payload.sub };
  };
}
```

- [ ] **Passo 4: rode e veja passar.** `npm test && npm run typecheck && npm run lint` (10 testes novos).

- [ ] **Passo 5: commit.** `git add -A && git commit -m "feat: verificador de JWT (OIDC) com jose"`

**Pronto quando:** os 10 casos passam, incluindo o token no estilo Cognito.

---

## Tarefa 2.4: dono do link, migration 002 e listagem paginada

**Arquivos:**
- Criar `migrations/002_link_owner.sql`
- Modificar `src/links/repository.ts`, `src/links/service.ts` e (ajuste mínimo) `src/http/app.ts`
- Testes: `test/integration/repository.test.ts`, `test/integration/migrate.test.ts` e `test/unit/service.test.ts`

**Interfaces que esta tarefa entrega:**

```ts
interface LinkSummary { code: string; url: string; createdAt: string; totalClicks: number }
interface LinkPage { items: LinkSummary[]; nextCursor: string | null }
class InvalidCursorError extends Error {}

interface LinkRepository {
  insert(code: string, url: string, ownerId: string | null): Promise<{ createdAt: string }>;
  findUrl(code: string): Promise<string | null>;
  getOwner(code: string): Promise<string | null | undefined>; // undefined = não existe; null = sem dono
  listByOwner(ownerId: string, opts: { limit: number; cursor?: string | undefined }): Promise<LinkPage>;
  getStats(code: string): Promise<LinkStats | null>;
}

interface CreatedLink { code: string; createdAt: string }
createShortLink(repo, url, ownerId: string | null, gen?, maxAttempts?): Promise<CreatedLink>
```

**Conceitos:**
- **Expand/contract:** a migration só **adiciona** uma coluna opcional. A versão anterior da api continua funcionando com o banco novo, o que é pré-requisito para o canary da Fase 7 (as duas versões rodam juntas por alguns minutos). `ADD COLUMN` sem default é instantâneo no Postgres, mesmo com a tabela grande.
- **`insert` devolve `createdAt`** (via `RETURNING created_at`). Assim a resposta do `POST /links` usa a data que o banco gravou, e não um `new Date()` do Node que pode divergir.
- **Paginação keyset em vez de `OFFSET`:** a página seguinte começa "depois do último item visto", com `WHERE (created_at, code) < ($t, $c)`. O custo não cresce com o número da página, e um link criado no meio da navegação não faz itens repetirem. O `code` desempata links com o mesmo `created_at`.
- **Índice casado com a ordem:** `(owner_id, created_at DESC, code DESC)` entrega as linhas do dono já na ordem do `ORDER BY`, e o Postgres para de ler depois de `limit + 1`. A spec citava `(owner_id, created_at DESC, code)`, mas um `code` ascendente não serve um `ORDER BY ... code DESC`: as direções precisam bater (ou ser todas invertidas).
- **Valide o cursor no formato exato que você emite.** O `Date.parse` do JS aceita `"1"` e anos que o Postgres recusa; se o cursor passasse, a query estouraria e a api responderia 500 em vez de 400. Por isso o `decodeCursor` exige `YYYY-MM-DDTHH:MM:SS.ffffffZ` e confere que a data existe.
- **Cursor opaco:** base64url de `{"t": "<created_at>", "c": "<code>"}`. O cliente não deve montar nem interpretar o cursor; só devolver o que recebeu. Cursor que não decodifica vira `InvalidCursorError`, e a rota responde 400.
- **Armadilha da precisão:** o Postgres guarda microssegundos; o `Date` do JS, só milissegundos. Se o cursor usasse o `Date`, o `<` compararia `10:00:00.123` com `10:00:00.123456` e a próxima página repetiria o último link. Por isso o cursor leva o texto exato, gerado no SQL com `to_char(... 'US')`.
- **`limit + 1`:** pedir uma linha a mais diz se existe próxima página sem fazer um `COUNT`.
- **`sum(bigint)` vira `numeric`, que chega como string no `pg`.** Convertemos com `Number()`, como já fazíamos nas stats.

- [ ] **Passo 1: atualize o teste de migrations** `test/integration/migrate.test.ts` (arquivo inteiro)

```ts
import { afterAll, describe, expect, it } from 'vitest';
import { runMigrations } from '../../src/db/migrate.js';
import { createTestPool, resetDatabase } from './helpers.js';

const pool = createTestPool();
afterAll(() => pool.end());

describe('runMigrations', () => {
  it('aplica cada migration uma única vez', async () => {
    await resetDatabase(pool);

    const first = await runMigrations(pool, 'migrations');
    expect(first).toEqual(['001_init.sql', '002_link_owner.sql']);

    const second = await runMigrations(pool, 'migrations');
    expect(second).toEqual([]);

    const { rows } = await pool.query("SELECT to_regclass('public.links')::text AS t");
    expect(rows[0]?.t).toBe('links');
  });

  it('002 cria owner_id opcional e o índice da paginação', async () => {
    const col = await pool.query(
      "SELECT is_nullable FROM information_schema.columns WHERE table_name = 'links' AND column_name = 'owner_id'",
    );
    expect(col.rows).toEqual([{ is_nullable: 'YES' }]);
    const idx = await pool.query("SELECT indexdef FROM pg_indexes WHERE indexname = 'links_owner_created_idx'");
    expect(idx.rows[0]?.indexdef).toContain('(owner_id, created_at DESC, code DESC)');
  });
});
```

O segundo teste aproveita o banco migrado pelo primeiro (o vitest roda os `it` de um arquivo em ordem).

- [ ] **Passo 2: reescreva** `test/integration/repository.test.ts` (arquivo inteiro)

```ts
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type pg from 'pg';
import { createLinkRepository, DuplicateCodeError, InvalidCursorError } from '../../src/links/repository.js';
import { migratedPool } from './helpers.js';

let pool: pg.Pool;
beforeAll(async () => { pool = await migratedPool(); });
afterAll(() => pool.end());
beforeEach(() => pool.query('TRUNCATE links, click_stats_daily, click_stats_browser, processed_events'));

// Datas fixas deixam a ordem da paginação previsível (o now() de inserts seguidos pode empatar).
async function insertAt(code: string, ownerId: string | null, createdAt: string) {
  await pool.query('INSERT INTO links (code, url, owner_id, created_at) VALUES ($1, $2, $3, $4)', [
    code, `https://example.com/${code}`, ownerId, createdAt,
  ]);
}

describe('linkRepository', () => {
  it('insere e encontra pelo código', async () => {
    const repo = createLinkRepository(pool);
    await repo.insert('abcDEF1', 'https://example.com', null);
    expect(await repo.findUrl('abcDEF1')).toBe('https://example.com');
    expect(await repo.findUrl('zzzzzz9')).toBeNull();
  });

  it('insert devolve a data de criação em ISO 8601', async () => {
    const repo = createLinkRepository(pool);
    const { createdAt } = await repo.insert('abcDEF1', 'https://example.com', 'alice');
    expect(new Date(createdAt).toISOString()).toBe(createdAt);
  });

  it('lança DuplicateCodeError para código repetido', async () => {
    const repo = createLinkRepository(pool);
    await repo.insert('abcDEF1', 'https://a.com', null);
    await expect(repo.insert('abcDEF1', 'https://b.com', null)).rejects.toBeInstanceOf(DuplicateCodeError);
  });

  it('getOwner: undefined se não existe, null sem dono, o sub com dono', async () => {
    const repo = createLinkRepository(pool);
    await repo.insert('semDono', 'https://a.com', null);
    await repo.insert('comDono', 'https://b.com', 'alice');
    expect(await repo.getOwner('zzzzzz9')).toBeUndefined();
    expect(await repo.getOwner('semDono')).toBeNull();
    expect(await repo.getOwner('comDono')).toBe('alice');
  });

  it('listByOwner: pagina do mais novo para o mais antigo', async () => {
    const repo = createLinkRepository(pool);
    await insertAt('link001', 'alice', '2026-10-01T10:00:00Z');
    await insertAt('link002', 'alice', '2026-10-02T10:00:00Z');
    await insertAt('link003', 'alice', '2026-10-03T10:00:00Z');

    const first = await repo.listByOwner('alice', { limit: 2 });
    expect(first.items.map((i) => i.code)).toEqual(['link003', 'link002']);
    expect(first.items[0]).toEqual({
      code: 'link003', url: 'https://example.com/link003', createdAt: '2026-10-03T10:00:00.000Z', totalClicks: 0,
    });
    expect(first.nextCursor).toEqual(expect.any(String));

    const second = await repo.listByOwner('alice', { limit: 2, cursor: first.nextCursor ?? undefined });
    expect(second.items.map((i) => i.code)).toEqual(['link001']);
    expect(second.nextCursor).toBeNull();
  });

  it('listByOwner: desempata pelo código quando a data é igual', async () => {
    const repo = createLinkRepository(pool);
    for (const code of ['sameAAA', 'sameBBB', 'sameCCC']) await insertAt(code, 'alice', '2026-10-01T10:00:00.123456Z');
    const first = await repo.listByOwner('alice', { limit: 2 });
    const second = await repo.listByOwner('alice', { limit: 2, cursor: first.nextCursor ?? undefined });
    expect([...first.items, ...second.items].map((i) => i.code)).toEqual(['sameCCC', 'sameBBB', 'sameAAA']);
  });

  it('listByOwner: só devolve os links do dono', async () => {
    const repo = createLinkRepository(pool);
    await insertAt('alice01', 'alice', '2026-10-01T10:00:00Z');
    await insertAt('bob0001', 'bob', '2026-10-01T11:00:00Z');
    await insertAt('semdono', null, '2026-10-01T12:00:00Z');
    expect((await repo.listByOwner('alice', { limit: 20 })).items.map((i) => i.code)).toEqual(['alice01']);
    expect((await repo.listByOwner('carol', { limit: 20 })).items).toEqual([]);
  });

  it('listByOwner: soma os cliques e converte bigint para number', async () => {
    const repo = createLinkRepository(pool);
    await insertAt('alice01', 'alice', '2026-10-01T10:00:00Z');
    await pool.query("INSERT INTO click_stats_browser VALUES ('alice01', 'Chrome', 3), ('alice01', 'curl', 2)");
    const page = await repo.listByOwner('alice', { limit: 20 });
    expect(page.items[0]?.totalClicks).toBe(5);
  });

  it('listByOwner: cursor inválido lança InvalidCursorError', async () => {
    const repo = createLinkRepository(pool);
    const cursorOf = (t: string) => Buffer.from(JSON.stringify({ t, c: 'abcDEF1' })).toString('base64url');
    // "1" e o ano 275760 passam no Date.parse do JS, mas o Postgres recusa como timestamptz.
    // 30 de fevereiro tem o formato certo, mas não existe.
    const bads = ['ontem', '1', '+275760-09-13T00:00:00.000Z', '2026-02-30T10:00:00.000000Z'].map(cursorOf);
    for (const cursor of ['nao-e-base64-json', ...bads]) {
      await expect(repo.listByOwner('alice', { limit: 20, cursor })).rejects.toBeInstanceOf(InvalidCursorError);
    }
  });

  it('getStats: null se não existe, zerado se não tem cliques', async () => {
    const repo = createLinkRepository(pool);
    expect(await repo.getStats('zzzzzz9')).toBeNull();
    await repo.insert('abcDEF1', 'https://example.com', null);
    expect(await repo.getStats('abcDEF1')).toEqual({
      code: 'abcDEF1', url: 'https://example.com', totalClicks: 0, daily: [], browsers: [],
    });
  });

  it('getStats: soma e converte bigint para number', async () => {
    const repo = createLinkRepository(pool);
    await repo.insert('abcDEF1', 'https://example.com', null);
    await pool.query("INSERT INTO click_stats_daily VALUES ('abcDEF1', current_date, 4)");
    await pool.query("INSERT INTO click_stats_browser VALUES ('abcDEF1', 'Chrome', 3), ('abcDEF1', 'curl', 1)");
    const stats = await repo.getStats('abcDEF1');
    expect(stats?.totalClicks).toBe(4);
    expect(stats?.browsers).toEqual([{ browser: 'Chrome', clicks: 3 }, { browser: 'curl', clicks: 1 }]);
    expect(stats?.daily).toHaveLength(1);
    expect(stats?.daily[0]?.clicks).toBe(4);
  });
});
```

- [ ] **Passo 3: atualize** `test/unit/service.test.ts` (arquivo inteiro; o `fakeRepo` precisa implementar os métodos novos para satisfazer o tipo)

```ts
import { describe, expect, it } from 'vitest';
import { createShortLink } from '../../src/links/service.js';
import { DuplicateCodeError, type LinkRepository } from '../../src/links/repository.js';

const CREATED_AT = '2026-10-12T12:00:00.000Z';

function fakeRepo(duplicatesBeforeSuccess: number, otherError?: Error) {
  let calls = 0;
  const owners: (string | null)[] = [];
  const repo: LinkRepository = {
    async insert(code, _url, ownerId) {
      calls++;
      owners.push(ownerId);
      if (otherError) throw otherError;
      if (calls <= duplicatesBeforeSuccess) throw new DuplicateCodeError(code);
      return { createdAt: CREATED_AT };
    },
    findUrl: async () => null,
    getOwner: async () => undefined,
    listByOwner: async () => ({ items: [], nextCursor: null }),
    getStats: async () => null,
  };
  return { repo, calls: () => calls, owners };
}

describe('createShortLink', () => {
  it('devolve código e data de criação quando insere de primeira', async () => {
    const { repo } = fakeRepo(0);
    expect(await createShortLink(repo, 'https://x.com', 'alice', () => 'AAAAAA1')).toEqual({
      code: 'AAAAAA1',
      createdAt: CREATED_AT,
    });
  });
  it('repassa o dono (ou null) para o repositório', async () => {
    const { repo, owners } = fakeRepo(0);
    await createShortLink(repo, 'https://x.com', 'alice');
    await createShortLink(repo, 'https://x.com', null);
    expect(owners).toEqual(['alice', null]);
  });
  it('tenta outro código em caso de colisão', async () => {
    const { repo, calls } = fakeRepo(2);
    await createShortLink(repo, 'https://x.com', null);
    expect(calls()).toBe(3);
  });
  it('desiste depois de N colisões', async () => {
    const { repo } = fakeRepo(99);
    await expect(createShortLink(repo, 'https://x.com', null, undefined, 3)).rejects.toThrow(/código único/);
  });
  it('não engole outros erros', async () => {
    const { repo } = fakeRepo(0, new Error('banco fora'));
    await expect(createShortLink(repo, 'https://x.com', null)).rejects.toThrow('banco fora');
  });
});
```

- [ ] **Passo 4: rode e veja falhar.**
  - `npm run test:unit`: o service falha com `TypeError: gen is not a function` (o terceiro argumento ainda é o gerador de código).
  - `npm run test:integration`: o de migrations falha com `expected [ '001_init.sql' ] to deeply equal [ Array(2) ]`; o de repositório falha com `repo.getOwner is not a function` e `repo.listByOwner is not a function`.

- [ ] **Passo 5: crie** `migrations/002_link_owner.sql`

```sql
-- Expand: coluna nova e opcional. A versão anterior da api continua funcionando (ela só ignora a coluna).
-- NULL = link criado por um serviço (API key), sem dono.
ALTER TABLE links ADD COLUMN owner_id text;

-- Serve o "meus links": filtra pelo dono e já entrega na ordem da paginação (mais novos primeiro).
CREATE INDEX links_owner_created_idx ON links (owner_id, created_at DESC, code DESC);
```

- [ ] **Passo 6: implemente** `src/links/repository.ts` (arquivo inteiro)

```ts
import type pg from 'pg';
import { isValidCode } from './code.js';

export interface LinkStats {
  code: string;
  url: string;
  totalClicks: number;
  daily: { day: string; clicks: number }[];
  browsers: { browser: string; clicks: number }[];
}

export interface LinkSummary {
  code: string;
  url: string;
  createdAt: string; // ISO 8601
  totalClicks: number;
}

export interface LinkPage {
  items: LinkSummary[];
  nextCursor: string | null;
}

export class DuplicateCodeError extends Error {
  constructor(code: string) {
    super(`código já existe: ${code}`);
  }
}

export class InvalidCursorError extends Error {
  constructor() {
    super('cursor inválido');
  }
}

export interface LinkRepository {
  insert(code: string, url: string, ownerId: string | null): Promise<{ createdAt: string }>;
  findUrl(code: string): Promise<string | null>;
  getOwner(code: string): Promise<string | null | undefined>; // undefined = o link não existe
  listByOwner(ownerId: string, opts: { limit: number; cursor?: string | undefined }): Promise<LinkPage>;
  getStats(code: string): Promise<LinkStats | null>;
}

// O cursor guarda a posição do último item da página: (created_at exato, code).
// created_at vai como texto com microssegundos: um Date do JS só tem milissegundos, e
// perder precisão aqui faria a próxima página pular ou repetir links.
interface CursorData {
  t: string;
  c: string;
}

export function encodeCursor(data: CursorData): string {
  return Buffer.from(JSON.stringify(data)).toString('base64url');
}

// Exatamente o formato que o to_char da query emite (microssegundos, UTC).
const CURSOR_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;

// O Date.parse aceita "1" e anos que o Postgres recusa, e o Postgres recusaria com 500.
// Ida e volta pelo Date (em milissegundos) também pega datas que não existem, como 30 de fevereiro.
function isCursorTime(t: string): boolean {
  if (!CURSOR_TIME.test(t)) return false;
  const ms = `${t.slice(0, 23)}Z`;
  const d = new Date(ms);
  return !Number.isNaN(d.getTime()) && d.toISOString() === ms;
}

export function decodeCursor(cursor: string): CursorData {
  try {
    const data: unknown = JSON.parse(Buffer.from(cursor, 'base64url').toString('utf8'));
    if (typeof data === 'object' && data !== null && 't' in data && 'c' in data) {
      const { t, c } = data;
      if (typeof t === 'string' && typeof c === 'string' && isCursorTime(t) && isValidCode(c)) {
        return { t, c };
      }
    }
  } catch {
    // cai no throw abaixo
  }
  throw new InvalidCursorError();
}

export function createLinkRepository(pool: pg.Pool): LinkRepository {
  return {
    async insert(code, url, ownerId) {
      try {
        const { rows } = await pool.query<{ created_at: Date }>(
          'INSERT INTO links (code, url, owner_id) VALUES ($1, $2, $3) RETURNING created_at',
          [code, url, ownerId],
        );
        return { createdAt: rows[0]!.created_at.toISOString() }; // RETURNING de um INSERT devolve sempre 1 linha
      } catch (err) {
        if ((err as { code?: string }).code === '23505') throw new DuplicateCodeError(code); // unique_violation
        throw err;
      }
    },

    async findUrl(code) {
      const { rows } = await pool.query<{ url: string }>('SELECT url FROM links WHERE code = $1', [code]);
      return rows[0]?.url ?? null;
    },

    async getOwner(code) {
      const { rows } = await pool.query<{ owner_id: string | null }>('SELECT owner_id FROM links WHERE code = $1', [
        code,
      ]);
      return rows[0]?.owner_id;
    },

    async listByOwner(ownerId, { limit, cursor }) {
      const after = cursor === undefined ? null : decodeCursor(cursor);
      // Pede 1 a mais: se ele vier, existe próxima página.
      const { rows } = await pool.query<{
        code: string;
        url: string;
        created_at: Date;
        created_at_exact: string;
        total_clicks: string; // sum(bigint) chega como string
      }>(
        `SELECT l.code, l.url, l.created_at,
                to_char(l.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at_exact,
                COALESCE((SELECT sum(b.clicks) FROM click_stats_browser b WHERE b.code = l.code), 0) AS total_clicks
           FROM links l
          WHERE l.owner_id = $1
            AND ($2::timestamptz IS NULL OR (l.created_at, l.code) < ($2::timestamptz, $3::text))
          ORDER BY l.created_at DESC, l.code DESC
          LIMIT $4`,
        [ownerId, after?.t ?? null, after?.c ?? null, limit + 1],
      );
      const page = rows.slice(0, limit);
      const last = page.at(-1);
      return {
        items: page.map((r) => ({
          code: r.code,
          url: r.url,
          createdAt: r.created_at.toISOString(),
          totalClicks: Number(r.total_clicks),
        })),
        nextCursor: rows.length > limit && last ? encodeCursor({ t: last.created_at_exact, c: last.code }) : null,
      };
    },

    async getStats(code) {
      const link = await pool.query<{ url: string }>('SELECT url FROM links WHERE code = $1', [code]);
      const linkRow = link.rows[0];
      if (!linkRow) return null;
      // bigint chega como string no pg (pode passar de 2^53); aqui convertemos conscientemente.
      const daily = await pool.query<{ day: string; clicks: string }>(
        `SELECT to_char(day, 'YYYY-MM-DD') AS day, clicks FROM click_stats_daily
          WHERE code = $1 AND day >= current_date - 29 ORDER BY day`,
        [code],
      );
      const browsers = await pool.query<{ browser: string; clicks: string }>(
        'SELECT browser, clicks FROM click_stats_browser WHERE code = $1 ORDER BY clicks DESC, browser',
        [code],
      );
      const browserRows = browsers.rows.map((r) => ({ browser: r.browser, clicks: Number(r.clicks) }));
      return {
        code,
        url: linkRow.url,
        totalClicks: browserRows.reduce((sum, b) => sum + b.clicks, 0), // total de todos os tempos
        daily: daily.rows.map((r) => ({ day: r.day, clicks: Number(r.clicks) })), // últimos 30 dias
        browsers: browserRows,
      };
    },
  };
}
```

- [ ] **Passo 7: implemente** `src/links/service.ts` (arquivo inteiro)

```ts
import { generateCode } from './code.js';
import { DuplicateCodeError, type LinkRepository } from './repository.js';

export interface CreatedLink {
  code: string;
  createdAt: string;
}

export async function createShortLink(
  repo: LinkRepository,
  url: string,
  ownerId: string | null,
  gen: () => string = generateCode,
  maxAttempts = 5,
): Promise<CreatedLink> {
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const code = gen();
    try {
      const { createdAt } = await repo.insert(code, url, ownerId);
      return { code, createdAt };
    } catch (err) {
      if (!(err instanceof DuplicateCodeError)) throw err;
    }
  }
  throw new Error('Não foi possível gerar um código único');
}
```

- [ ] **Passo 8: ajuste mínimo em `src/http/app.ts`** para continuar compilando. Troque o handler do `POST /links` inteiro por este (a autenticação por usuário entra na Tarefa 2.6; por enquanto, todo link criado é de serviço):

```ts
  app.post('/links', deps.rateLimiter, auth, async (req, res) => {
    const url = normalizeTargetUrl(req.body?.url);
    if (!url) {
      res.status(400).json({ error: 'invalid_url' });
      return;
    }
    const { code, createdAt } = await createShortLink(deps.links, url, null);
    await deps.linkCache.setUrl(code, url); // aquece o cache e sobrescreve um eventual "não existe"
    res.status(201).json({ code, shortUrl: `${deps.publicBaseUrl}/${code}`, url, createdAt });
  });
```

- [ ] **Passo 9: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 10: aplique a migration no banco de dev.** `npm run setup` (roda as migrations e confere os tópicos). Esperado no log: `002_link_owner.sql` aplicada.

- [ ] **Passo 11: commit.** `git add -A && git commit -m "feat: dono do link, getOwner e listagem paginada por dono"`

**Pronto quando:** a paginação com 3 links e `limit: 2` devolve 2 + 1 sem repetir, links de outro dono nunca aparecem e um cursor inválido lança `InvalidCursorError`.

---

## Tarefa 2.5: middleware `authenticate` e `requireUser`

**Arquivos:**
- Criar `src/http/auth.ts`
- Teste: `test/unit/auth.test.ts`

**Interfaces que esta tarefa entrega:**

```ts
type Principal = { kind: 'user'; sub: string } | { kind: 'service' };
apiKeyMatcher(expected: string): (provided: string | undefined) => boolean
authenticate(opts: { apiKey: string; verifyToken: VerifyToken }): RequestHandler // grava res.locals.principal
requireUser: RequestHandler // 403 { error: 'forbidden' } para service
principalOf(res: Response): Principal
```

**Conceitos:**
- **Principal:** "quem está chamando", decidido uma vez no middleware e guardado em `res.locals.principal`. Os handlers leem com `principalOf(res)` e não olham mais headers.
- **401 × 403:** 401 = "não sei quem você é" (sem credencial ou credencial inválida). 403 = "sei quem você é, mas isso não é para você" (um serviço chamando `/me/links`, que não tem "me").
- **Bearer inválido não cai para a API key.** Se o cliente mandou `Authorization`, ele quer ser tratado como usuário. Tentar outra credencial em silêncio esconderia bugs (token expirado parecendo funcionar) e misturaria identidades.
- **`apiKey.ts` vira parte de `auth.ts`.** A comparação em tempo constante (hash SHA-256 dos dois lados + `timingSafeEqual`) é a mesma da Fase 1, agora como `apiKeyMatcher`, que devolve `boolean` em vez de responder. O `apiKey.ts` é apagado na Tarefa 2.6, quando o `app.ts` deixa de usá-lo; até lá, os dois convivem e cada commit continua verde.
- **Teste unitário com app Express mínimo:** o middleware é testado com um `verifyToken` falso. O JWT de verdade já está coberto pela Tarefa 2.3, e a integração completa vem na 2.6.

- [ ] **Passo 1: escreva o teste** `test/unit/auth.test.ts`

```ts
import { describe, expect, it } from 'vitest';
import express from 'express';
import request from 'supertest';
import { authenticate, principalOf, requireUser } from '../../src/http/auth.js';
import type { VerifyToken } from '../../src/auth/jwt.js';

const API_KEY = 'test-api-key-0123456789';

// Verificador falso: só o token "token-da-alice" é válido. O JWT de verdade é testado em jwt.test.ts.
const fakeVerify: VerifyToken = async (token) => {
  if (token === 'token-da-alice') return { sub: 'alice' };
  throw new Error('token inválido');
};

function buildApp() {
  const app = express();
  const auth = authenticate({ apiKey: API_KEY, verifyToken: fakeVerify });
  app.get('/quem-sou', auth, (_req, res) => {
    res.json(principalOf(res));
  });
  app.get('/so-usuario', auth, requireUser, (_req, res) => {
    res.json({ ok: true });
  });
  return app;
}

describe('authenticate', () => {
  it('Bearer válido vira usuário com o sub do token', async () => {
    const res = await request(buildApp()).get('/quem-sou').set('authorization', 'Bearer token-da-alice');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ kind: 'user', sub: 'alice' });
  });

  it('aceita o esquema "bearer" em minúsculas', async () => {
    const res = await request(buildApp()).get('/quem-sou').set('authorization', 'bearer token-da-alice');
    expect(res.status).toBe(200);
  });

  it('API key válida vira serviço', async () => {
    const res = await request(buildApp()).get('/quem-sou').set('x-api-key', API_KEY);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ kind: 'service' });
  });

  it('sem credencial ou com API key errada: 401', async () => {
    const app = buildApp();
    for (const res of [await request(app).get('/quem-sou'), await request(app).get('/quem-sou').set('x-api-key', 'errada')]) {
      expect(res.status).toBe(401);
      expect(res.body).toEqual({ error: 'unauthorized' });
    }
  });

  it('Bearer inválido é 401 mesmo com API key válida (não cai para a chave)', async () => {
    const res = await request(buildApp())
      .get('/quem-sou')
      .set('authorization', 'Bearer token-falso')
      .set('x-api-key', API_KEY);
    expect(res.status).toBe(401);
  });

  it('Authorization que não é Bearer: 401', async () => {
    const res = await request(buildApp()).get('/quem-sou').set('authorization', 'Basic dXNlcjpwYXNz');
    expect(res.status).toBe(401);
  });
});

describe('requireUser', () => {
  it('deixa passar usuário', async () => {
    const res = await request(buildApp()).get('/so-usuario').set('authorization', 'Bearer token-da-alice');
    expect(res.status).toBe(200);
  });

  it('serviço recebe 403', async () => {
    const res = await request(buildApp()).get('/so-usuario').set('x-api-key', API_KEY);
    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: 'forbidden' });
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm run test:unit -- test/unit/auth.test.ts`: falha com `Error: Cannot find module '../../src/http/auth.js'`.

- [ ] **Passo 3: implemente** `src/http/auth.ts`

```ts
import { createHash, timingSafeEqual } from 'node:crypto';
import type { RequestHandler, Response } from 'express';
import { logger } from '../logger.js';
import type { VerifyToken } from '../auth/jwt.js';

export type Principal = { kind: 'user'; sub: string } | { kind: 'service' };

const digest = (value: string) => createHash('sha256').update(value).digest();

// Compara hashes de tamanho fixo em tempo constante: não vaza, pelo tempo de resposta, quantos caracteres acertou.
export function apiKeyMatcher(expected: string): (provided: string | undefined) => boolean {
  const expectedDigest = digest(expected);
  return (provided) => provided !== undefined && timingSafeEqual(digest(provided), expectedDigest);
}

const BEARER = /^Bearer (\S+)$/i;

export function authenticate(opts: { apiKey: string; verifyToken: VerifyToken }): RequestHandler {
  const isValidApiKey = apiKeyMatcher(opts.apiKey);
  return async (req, res, next) => {
    const authorization = req.get('authorization');
    if (authorization !== undefined) {
      // Quem manda Authorization quer ser tratado como usuário: token ruim é 401, sem tentar a API key.
      const token = BEARER.exec(authorization)?.[1];
      if (!token) {
        res.status(401).json({ error: 'unauthorized' });
        return;
      }
      try {
        const { sub } = await opts.verifyToken(token);
        res.locals.principal = { kind: 'user', sub } satisfies Principal;
      } catch (err) {
        logger.debug({ err }, 'token rejeitado');
        res.status(401).json({ error: 'unauthorized' });
        return;
      }
      next();
      return;
    }
    if (isValidApiKey(req.get('x-api-key'))) {
      res.locals.principal = { kind: 'service' } satisfies Principal;
      next();
      return;
    }
    res.status(401).json({ error: 'unauthorized' });
  };
}

// Só para rotas que vêm depois de authenticate.
export function principalOf(res: Response): Principal {
  const principal = res.locals.principal as Principal | undefined;
  if (!principal) throw new Error('principalOf chamado numa rota sem authenticate');
  return principal;
}

export const requireUser: RequestHandler = (_req, res, next) => {
  if (principalOf(res).kind !== 'user') {
    res.status(403).json({ error: 'forbidden' });
    return;
  }
  next();
};
```

O `satisfies Principal` faz o TypeScript checar o objeto contra o tipo sem perder a forma literal. O `res.locals` do Express é tipado como `Record<string, any>`, então sem isso nada impediria um `{ kind: 'usuario' }` digitado errado.

- [ ] **Passo 4: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 5: commit.** `git add -A && git commit -m "feat: middleware authenticate (usuário ou serviço) e requireUser"`

**Pronto quando:** os 8 casos passam, inclusive "Bearer inválido com API key válida → 401".

---

## Tarefa 2.6: rotas `/me/links`, stats por dono e CORS

**Arquivos:**
- Modificar `src/http/app.ts` e `src/api.ts`
- Apagar `src/http/apiKey.ts`
- Teste: `test/integration/app.test.ts`

**Interfaces que esta tarefa entrega:**

```ts
interface AppDeps {
  links: LinkRepository;
  linkCache: LinkCache;
  statsCache: JsonCache<LinkStats>;
  publisher: ClickPublisher;
  rateLimiter: RequestHandler;
  apiKey: string;
  verifyToken: VerifyToken;   // novo
  corsOrigins: string[];      // novo
  publicBaseUrl: string;
  version: string;
  isReady: () => Promise<boolean>;
}
```

`AppDeps` recebe as peças (`apiKey` e `verifyToken`) e o próprio `createApp` monta o `authenticate`. Assim o teste injeta um verificador com chave local, e o `api.ts` injeta o verificador com JWKS remoto.

**Endpoints:**

| Método e rota | Auth | Resposta |
|---|---|---|
| `GET /healthz`, `GET /readyz` | não | sem mudança |
| `POST /links` `{url}` | rate limit → user **ou** service | `201 {code, shortUrl, url, createdAt}`. `owner_id = sub` (user) ou `null` (service). `400 invalid_url`, `401`, `429` |
| `GET /me/links?limit&cursor` | user | `200 {items: [{code, url, createdAt, totalClicks, shortUrl}], nextCursor}`. `limit` padrão 20, de 1 a 100. `400 invalid_query` ou `400 invalid_cursor`; `401`; `403` para service |
| `GET /links/:code/stats` | user dono **ou** service | `200 LinkStats`. `404` se não existe **ou** se o user não é o dono |
| `GET /:code` | não | sem mudança |

**Conceitos:**
- **CORS:** o navegador bloqueia a **leitura** da resposta de um `fetch` para outra origem, a menos que o servidor diga `Access-Control-Allow-Origin: <origem>`. Como o painel manda `Authorization` e `Content-Type: application/json`, o navegador antes faz um *preflight* (`OPTIONS`) perguntando se pode. O pacote `cors` responde com a allowlist; origem fora da lista recebe a resposta sem `Access-Control-Allow-Origin`, e o navegador barra.
- **`exposedHeaders`:** por padrão, o JavaScript só lê alguns headers da resposta. Sem expor `Retry-After`, o painel não consegue mostrar "tente em N s" num 429.
- **`maxAge: 600`:** o navegador guarda o resultado do preflight por 10 minutos e não repete o `OPTIONS` a cada chamada.
- **CORS só em `/links` e `/me`, montado antes das rotas.** Ele precisa vir antes para responder o preflight antes de qualquer autenticação (o navegador nunca manda `Authorization` no `OPTIONS`). E não atrapalha o redirect por dois motivos: `GET /:code` nem passa pelo middleware, e abrir um link curto é **navegação**, não `fetch`; o navegador não aplica CORS a navegação.
- **Ordem das rotas:** `/me/links` e `/links/:code/stats` têm mais de um segmento. O parâmetro `/:code` casa com **um** segmento só (ele não atravessa `/`), então não há colisão. O que colide com `/:code` são rotas de um segmento, como `/healthz`: por isso elas continuam antes. E `/me` sozinho cai em `/:code`, onde `me` não é código válido e vira 404.
- **Checar o dono antes do cache.** O cache de stats é por código e compartilhado. Se o cache viesse antes, um não-dono leria as stats que o dono acabou de aquecer.
- **Validar a query com zod:** `z.coerce.number().int().min(1).max(100).default(20)` cobre `limit` ausente, `abc`, `1.5`, `0` e `101` numa linha só.

- [ ] **Passo 1: reescreva** `test/integration/app.test.ts` (arquivo inteiro)

```ts
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import type pg from 'pg';
import type { Redis } from 'ioredis';
import type { Express } from 'express';
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT, type CryptoKey } from 'jose';
import { createApp, type AppDeps } from '../../src/http/app.js';
import { createTokenVerifier, type VerifyToken } from '../../src/auth/jwt.js';
import { createLinkRepository } from '../../src/links/repository.js';
import { createLinkCache } from '../../src/cache/linkCache.js';
import { createJsonCache } from '../../src/cache/jsonCache.js';
import { createRedis } from '../../src/cache/redis.js';
import { rateLimit } from '../../src/http/rateLimit.js';
import { createClickPublisher } from '../../src/events/clickPublisher.js';
import type { ClickEvent } from '../../src/events/clickEvent.js';
import { connectedRedis, DEAD_REDIS_URL, migratedPool } from './helpers.js';

const API_KEY = 'test-api-key-0123456789';
const ISSUER = 'http://oidc.test/shortener';
const AUDIENCE = 'shortener-web';
const ALLOWED_ORIGIN = 'http://localhost:5173';

let pool: pg.Pool;
let redis: Redis;
let deadRedis: Redis;
let signingKey: CryptoKey;
let verifyToken: VerifyToken;

beforeAll(async () => {
  pool = await migratedPool();
  redis = await connectedRedis();
  deadRedis = createRedis(DEAD_REDIS_URL);
  // Um "IdP de mentira" dentro do teste: par de chaves RSA e um JWKS local com a chave pública.
  const { publicKey, privateKey } = await generateKeyPair('RS256');
  signingKey = privateKey;
  const jwk = { ...(await exportJWK(publicKey)), kid: 'test-key', alg: 'RS256', use: 'sig' };
  verifyToken = createTokenVerifier({ issuer: ISSUER, audience: AUDIENCE, jwks: createLocalJWKSet({ keys: [jwk] }) });
});
afterAll(async () => {
  await pool.end();
  redis.disconnect();
  deadRedis.disconnect();
});
beforeEach(async () => {
  await pool.query('TRUNCATE links, click_stats_daily, click_stats_browser, processed_events');
  await redis.flushdb();
});

function userToken(sub: string): Promise<string> {
  return new SignJWT({ sub, aud: AUDIENCE })
    .setProtectedHeader({ alg: 'RS256', kid: 'test-key' })
    .setIssuer(ISSUER)
    .setIssuedAt()
    .setExpirationTime('5m')
    .sign(signingKey);
}

function buildApp(overrides: Partial<AppDeps> = {}, cacheRedis: Redis = redis) {
  const published: ClickEvent[] = [];
  const deps: AppDeps = {
    links: createLinkRepository(pool),
    linkCache: createLinkCache(cacheRedis, 60),
    statsCache: createJsonCache(cacheRedis, 'stats', 60),
    publisher: { publish: (e) => { published.push(e); } },
    rateLimiter: rateLimit(cacheRedis, { limit: 100, windowSeconds: 60 }),
    apiKey: API_KEY,
    verifyToken,
    corsOrigins: [ALLOWED_ORIGIN],
    publicBaseUrl: 'http://short.test',
    version: 'test',
    isReady: async () => true,
    ...overrides,
  };
  return { app: createApp(deps), deps, published };
}

async function createLink(app: Express, url = 'https://example.com/pagina'): Promise<string> {
  const res = await request(app).post('/links').set('x-api-key', API_KEY).send({ url });
  expect(res.status).toBe(201);
  return res.body.code;
}

async function createUserLink(app: Express, sub: string, url = 'https://example.com/pagina'): Promise<string> {
  const res = await request(app).post('/links').auth(await userToken(sub), { type: 'bearer' }).send({ url });
  expect(res.status).toBe(201);
  return res.body.code;
}

describe('health', () => {
  it('/healthz responde e não é confundido com um código', async () => {
    const res = await request(buildApp().app).get('/healthz');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok', version: 'test' });
  });
  it('/readyz devolve 503 quando o banco não responde', async () => {
    const res = await request(buildApp({ isReady: async () => false }).app).get('/readyz');
    expect(res.status).toBe(503);
  });
});

describe('autenticação', () => {
  it('sem credencial: 401', async () => {
    const res = await request(buildApp().app).post('/links').send({ url: 'https://example.com' });
    expect(res.status).toBe(401);
    expect(res.body).toEqual({ error: 'unauthorized' });
  });

  it('API key errada: 401', async () => {
    const res = await request(buildApp().app).post('/links').set('x-api-key', 'errada').send({ url: 'https://example.com' });
    expect(res.status).toBe(401);
  });

  it('Bearer inválido: 401, mesmo com API key válida junto', async () => {
    const res = await request(buildApp().app)
      .post('/links')
      .auth('nao-sou-um-jwt', { type: 'bearer' })
      .set('x-api-key', API_KEY)
      .send({ url: 'https://example.com' });
    expect(res.status).toBe(401);
  });

  it('Authorization que não é Bearer: 401', async () => {
    const res = await request(buildApp().app).post('/links').auth('user', 'pass').send({ url: 'https://example.com' });
    expect(res.status).toBe(401);
  });
});

describe('POST /links', () => {
  it('rejeita URLs perigosas ou inválidas', async () => {
    const { app } = buildApp();
    for (const url of ['javascript:alert(1)', 'data:text/html,oi', 'nao-e-url', `https://x.com/${'a'.repeat(3000)}`]) {
      const res = await request(app).post('/links').set('x-api-key', API_KEY).send({ url });
      expect(res.status, url).toBe(400);
    }
  });

  it('serviço (API key) cria link sem dono', async () => {
    const res = await request(buildApp().app).post('/links').set('x-api-key', API_KEY).send({ url: 'https://example.com' });
    expect(res.status).toBe(201);
    expect(res.body.code).toMatch(/^[0-9A-Za-z]{7}$/);
    expect(res.body.shortUrl).toBe(`http://short.test/${res.body.code}`);
    expect(res.body.url).toBe('https://example.com/');
    expect(new Date(res.body.createdAt).toISOString()).toBe(res.body.createdAt);
    const { rows } = await pool.query('SELECT owner_id FROM links WHERE code = $1', [res.body.code]);
    expect(rows).toEqual([{ owner_id: null }]);
  });

  it('usuário (Bearer) cria link com dono = sub', async () => {
    const code = await createUserLink(buildApp().app, 'alice');
    const { rows } = await pool.query('SELECT owner_id FROM links WHERE code = $1', [code]);
    expect(rows).toEqual([{ owner_id: 'alice' }]);
  });

  it('limita por IP real do cliente (X-Forwarded-For do ALB)', async () => {
    const { app } = buildApp({ rateLimiter: rateLimit(redis, { limit: 2, windowSeconds: 60 }) });
    const post = (ip: string) =>
      request(app).post('/links').set('x-api-key', API_KEY).set('x-forwarded-for', ip).send({ url: 'https://example.com' });
    expect((await post('203.0.113.1')).status).toBe(201);
    expect((await post('203.0.113.1')).status).toBe(201);
    expect((await post('203.0.113.1')).status).toBe(429);
    expect((await post('203.0.113.2')).status).toBe(201);
  });

  it('o rate limit vem antes da autenticação', async () => {
    const { app } = buildApp({ rateLimiter: rateLimit(redis, { limit: 1, windowSeconds: 60 }) });
    const post = () => request(app).post('/links').set('x-api-key', 'errada').send({ url: 'https://example.com' });
    expect((await post()).status).toBe(401);
    expect((await post()).status).toBe(429);
  });

  it('continua criando links com o Redis fora do ar', async () => {
    const { app } = buildApp({}, deadRedis);
    expect((await request(app).post('/links').set('x-api-key', API_KEY).send({ url: 'https://example.com' })).status).toBe(201);
  });
});

describe('GET /me/links', () => {
  it('exige usuário: 401 sem credencial, 403 para serviço', async () => {
    const { app } = buildApp();
    expect((await request(app).get('/me/links')).status).toBe(401);
    const res = await request(app).get('/me/links').set('x-api-key', API_KEY);
    expect(res.status).toBe(403);
    expect(res.body).toEqual({ error: 'forbidden' });
  });

  it('lista só os links do usuário, com shortUrl e totalClicks', async () => {
    const { app } = buildApp();
    const mine = await createUserLink(app, 'alice', 'https://example.com/da-alice');
    await createUserLink(app, 'bob');
    await createLink(app); // sem dono
    await pool.query("INSERT INTO click_stats_browser VALUES ($1, 'Chrome', 2)", [mine]);

    const res = await request(app).get('/me/links').auth(await userToken('alice'), { type: 'bearer' });
    expect(res.status).toBe(200);
    expect(res.body.nextCursor).toBeNull();
    expect(res.body.items).toEqual([
      {
        code: mine,
        shortUrl: `http://short.test/${mine}`,
        url: 'https://example.com/da-alice',
        createdAt: expect.any(String),
        totalClicks: 2,
      },
    ]);
  });

  it('pagina com limit e cursor', async () => {
    const { app } = buildApp();
    const codes: string[] = [];
    for (let i = 0; i < 3; i++) codes.push(await createUserLink(app, 'alice', `https://example.com/${i}`));
    const token = await userToken('alice');

    const first = await request(app).get('/me/links?limit=2').auth(token, { type: 'bearer' });
    expect(first.status).toBe(200);
    expect(first.body.items).toHaveLength(2);
    expect(first.body.nextCursor).toEqual(expect.any(String));

    const second = await request(app)
      .get('/me/links')
      .query({ limit: 2, cursor: first.body.nextCursor })
      .auth(token, { type: 'bearer' });
    expect(second.status).toBe(200);
    expect(second.body.items).toHaveLength(1);
    expect(second.body.nextCursor).toBeNull();

    const seen = [...first.body.items, ...second.body.items].map((i: { code: string }) => i.code);
    expect(seen.sort()).toEqual([...codes].sort());
  });

  it('400 para limit ou cursor inválidos', async () => {
    const { app } = buildApp();
    const token = await userToken('alice');
    for (const limit of ['0', '101', 'abc', '1.5']) {
      const res = await request(app).get('/me/links').query({ limit }).auth(token, { type: 'bearer' });
      expect(res.status, limit).toBe(400);
      expect(res.body).toEqual({ error: 'invalid_query' });
    }
    const res = await request(app).get('/me/links').query({ cursor: 'lixo' }).auth(token, { type: 'bearer' });
    expect(res.status).toBe(400);
    expect(res.body).toEqual({ error: 'invalid_cursor' });
  });
});

describe('GET /:code', () => {
  it('redireciona e publica o evento de clique', async () => {
    const { app, published } = buildApp();
    const code = await createLink(app);
    const res = await request(app).get(`/${code}`).set('user-agent', 'curl/8.7.1');
    expect(res.status).toBe(302);
    expect(res.headers.location).toBe('https://example.com/pagina');
    expect(published).toHaveLength(1);
    expect(published[0]).toMatchObject({ code, userAgent: 'curl/8.7.1' });
  });

  it('404 com cache negativo: a segunda consulta não vai ao banco', async () => {
    const { app, deps } = buildApp();
    const spy = vi.spyOn(deps.links, 'findUrl');
    expect((await request(app).get('/abcDEF1')).status).toBe(404);
    expect((await request(app).get('/abcDEF1')).status).toBe(404);
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('formato inválido nem consulta o banco', async () => {
    const { app, deps } = buildApp();
    const spy = vi.spyOn(deps.links, 'findUrl');
    expect((await request(app).get('/favicon.ico')).status).toBe(404);
    expect(spy).not.toHaveBeenCalled();
  });

  it('funciona com o Redis fora do ar', async () => {
    const code = await createLink(buildApp().app);
    const res = await request(buildApp({}, deadRedis).app).get(`/${code}`);
    expect(res.status).toBe(302);
  });

  it('não espera o Kafka: responde mesmo se o envio nunca terminar', async () => {
    const code = await createLink(buildApp().app);
    const hanging = createClickPublisher({ send: () => new Promise<never>(() => {}) });
    const res = await request(buildApp({ publisher: hanging }).app).get(`/${code}`);
    expect(res.status).toBe(302);
  });

  it('o redirect não ganha headers de CORS', async () => {
    const { app } = buildApp();
    const code = await createLink(app);
    const res = await request(app).get(`/${code}`).set('origin', ALLOWED_ORIGIN);
    expect(res.status).toBe(302);
    expect(res.headers['access-control-allow-origin']).toBeUndefined();
  });
});

describe('GET /links/:code/stats', () => {
  it('exige credencial e devolve 404 para inexistente', async () => {
    const { app } = buildApp();
    expect((await request(app).get('/links/abcDEF1/stats')).status).toBe(401);
    expect((await request(app).get('/links/abcDEF1/stats').set('x-api-key', API_KEY)).status).toBe(404);
  });

  it('serviço vê os agregados de qualquer link', async () => {
    const { app } = buildApp();
    const code = await createLink(app);
    await pool.query('INSERT INTO click_stats_daily VALUES ($1, current_date, 5)', [code]);
    await pool.query("INSERT INTO click_stats_browser VALUES ($1, 'Chrome', 3), ($1, 'curl', 2)", [code]);
    const res = await request(app).get(`/links/${code}/stats`).set('x-api-key', API_KEY);
    expect(res.status).toBe(200);
    expect(res.body.totalClicks).toBe(5);
    expect(res.body.browsers).toEqual([{ browser: 'Chrome', clicks: 3 }, { browser: 'curl', clicks: 2 }]);
  });

  it('o dono vê as estatísticas do próprio link', async () => {
    const { app } = buildApp();
    const code = await createUserLink(app, 'alice');
    const res = await request(app).get(`/links/${code}/stats`).auth(await userToken('alice'), { type: 'bearer' });
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ code, totalClicks: 0 });
  });

  it('outro usuário recebe 404, igual a um link inexistente', async () => {
    const { app } = buildApp();
    const code = await createUserLink(app, 'alice');
    const asBob = await userToken('bob');
    const res = await request(app).get(`/links/${code}/stats`).auth(asBob, { type: 'bearer' });
    expect(res.status).toBe(404);
    expect(res.body).toEqual({ error: 'not_found' });
  });

  it('usuário também recebe 404 para link de serviço (sem dono)', async () => {
    const { app } = buildApp();
    const code = await createLink(app);
    const res = await request(app).get(`/links/${code}/stats`).auth(await userToken('alice'), { type: 'bearer' });
    expect(res.status).toBe(404);
  });
});

describe('CORS', () => {
  const preflight = (app: Express, origin: string) =>
    request(app)
      .options('/links')
      .set('origin', origin)
      .set('access-control-request-method', 'POST')
      .set('access-control-request-headers', 'authorization,content-type');

  it('preflight de origem permitida libera método e headers', async () => {
    const res = await preflight(buildApp().app, ALLOWED_ORIGIN);
    expect(res.status).toBe(204);
    expect(res.headers['access-control-allow-origin']).toBe(ALLOWED_ORIGIN);
    expect(res.headers['access-control-allow-methods']).toBe('GET,POST');
    expect(res.headers['access-control-allow-headers']).toBe('Authorization,Content-Type');
    expect(res.headers['access-control-max-age']).toBe('600');
  });

  it('preflight de origem negada não devolve Access-Control-Allow-Origin', async () => {
    const res = await preflight(buildApp().app, 'https://evil.example');
    expect(res.headers['access-control-allow-origin']).toBeUndefined();
  });

  it('resposta normal expõe os headers de rate limit para o navegador', async () => {
    const res = await request(buildApp().app)
      .post('/links')
      .set('origin', ALLOWED_ORIGIN)
      .set('x-api-key', API_KEY)
      .send({ url: 'https://example.com' });
    expect(res.status).toBe(201);
    expect(res.headers['access-control-allow-origin']).toBe(ALLOWED_ORIGIN);
    expect(res.headers['access-control-expose-headers']).toBe('RateLimit-Limit,RateLimit-Remaining,Retry-After');
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm run typecheck` acusa `Object literal may only specify known properties, and 'verifyToken' does not exist in type 'AppDeps'`. E `npm run test:integration` falha nos testes novos: Bearer válido recebe 401 (o app só conhece API key), `/me/links` recebe 404 e o preflight volta sem `access-control-allow-origin`.

- [ ] **Passo 3: implemente** `src/http/app.ts` (arquivo inteiro)

```ts
import express, { type ErrorRequestHandler, type RequestHandler } from 'express';
import cors from 'cors';
import { pinoHttp } from 'pino-http';
import { z } from 'zod';
import { logger } from '../logger.js';
import type { LinkCache } from '../cache/linkCache.js';
import type { JsonCache } from '../cache/jsonCache.js';
import type { ClickPublisher } from '../events/clickPublisher.js';
import { buildClickEvent } from '../events/clickEvent.js';
import { isValidCode } from '../links/code.js';
import { normalizeTargetUrl } from '../links/url.js';
import { createShortLink } from '../links/service.js';
import { InvalidCursorError, type LinkRepository, type LinkStats } from '../links/repository.js';
import type { VerifyToken } from '../auth/jwt.js';
import { authenticate, principalOf, requireUser } from './auth.js';

export interface AppDeps {
  links: LinkRepository;
  linkCache: LinkCache;
  statsCache: JsonCache<LinkStats>;
  publisher: ClickPublisher;
  rateLimiter: RequestHandler;
  apiKey: string;
  verifyToken: VerifyToken;
  corsOrigins: string[];
  publicBaseUrl: string;
  version: string;
  isReady: () => Promise<boolean>;
}

const listQuery = z.object({
  limit: z.coerce.number().int().min(1).max(100).default(20),
  cursor: z.string().min(1).max(512).optional(),
});

export function createApp(deps: AppDeps): express.Express {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1); // exatamente 1 proxy na frente (o ALB): req.ip = IP real do cliente
  app.use(pinoHttp({ logger, autoLogging: { ignore: (req) => req.url === '/healthz' || req.url === '/readyz' } }));

  // CORS só nos prefixos da API REST. O redirect (GET /:code) é navegação, não fetch: não precisa de CORS.
  app.use(
    ['/links', '/me'],
    cors({
      origin: deps.corsOrigins,
      methods: ['GET', 'POST'],
      allowedHeaders: ['Authorization', 'Content-Type'],
      exposedHeaders: ['RateLimit-Limit', 'RateLimit-Remaining', 'Retry-After'],
      maxAge: 600,
    }),
  );

  app.use(express.json({ limit: '10kb' }));
  const auth = authenticate({ apiKey: deps.apiKey, verifyToken: deps.verifyToken });
  const shortUrl = (code: string) => `${deps.publicBaseUrl}/${code}`;

  // Rotas fixas ANTES de "/:code": "healthz" também tem formato de código válido.
  app.get('/healthz', (_req, res) => {
    res.json({ status: 'ok', version: deps.version });
  });

  app.get('/readyz', async (_req, res) => {
    const ready = await deps.isReady();
    res.status(ready ? 200 : 503).json({ ready });
  });

  app.post('/links', deps.rateLimiter, auth, async (req, res) => {
    const url = normalizeTargetUrl(req.body?.url);
    if (!url) {
      res.status(400).json({ error: 'invalid_url' });
      return;
    }
    const principal = principalOf(res);
    const ownerId = principal.kind === 'user' ? principal.sub : null;
    const { code, createdAt } = await createShortLink(deps.links, url, ownerId);
    await deps.linkCache.setUrl(code, url); // aquece o cache e sobrescreve um eventual "não existe"
    res.status(201).json({ code, shortUrl: shortUrl(code), url, createdAt });
  });

  app.get('/me/links', auth, requireUser, async (req, res) => {
    const query = listQuery.safeParse(req.query);
    if (!query.success) {
      res.status(400).json({ error: 'invalid_query' });
      return;
    }
    const principal = principalOf(res);
    if (principal.kind !== 'user') return; // requireUser já garantiu; isto só estreita o tipo
    try {
      const page = await deps.links.listByOwner(principal.sub, query.data);
      res.json({
        items: page.items.map((item) => ({ ...item, shortUrl: shortUrl(item.code) })),
        nextCursor: page.nextCursor,
      });
    } catch (err) {
      if (err instanceof InvalidCursorError) {
        res.status(400).json({ error: 'invalid_cursor' });
        return;
      }
      throw err;
    }
  });

  app.get('/links/:code/stats', auth, async (req, res) => {
    const { code } = req.params as { code: string }; // @types/express 5 tipa params como string | string[]
    if (!isValidCode(code)) {
      res.status(404).json({ error: 'not_found' });
      return;
    }
    const principal = principalOf(res);
    if (principal.kind === 'user') {
      // Não-dono recebe o mesmo 404 de "não existe": não confirmamos que o código é de outra pessoa.
      const owner = await deps.links.getOwner(code);
      if (owner !== principal.sub) {
        res.status(404).json({ error: 'not_found' });
        return;
      }
    }
    const cached = await deps.statsCache.get(code);
    if (cached) {
      res.json(cached);
      return;
    }
    const stats = await deps.links.getStats(code);
    if (!stats) {
      res.status(404).json({ error: 'not_found' });
      return;
    }
    await deps.statsCache.set(code, stats);
    res.json(stats);
  });

  app.get('/:code', async (req, res) => {
    const { code } = req.params as { code: string }; // @types/express 5 tipa params como string | string[]
    if (!isValidCode(code)) {
      res.status(404).json({ error: 'not_found' });
      return;
    }
    let url: string | null;
    const cached = await deps.linkCache.get(code);
    if (cached.hit) {
      url = cached.url;
    } else {
      url = await deps.links.findUrl(code);
      if (url) await deps.linkCache.setUrl(code, url);
      else await deps.linkCache.setNotFound(code);
    }
    if (!url) {
      res.status(404).json({ error: 'not_found' });
      return;
    }
    deps.publisher.publish(buildClickEvent(code, req.get('user-agent'))); // sem await, de propósito
    res.set('Cache-Control', 'no-store'); // sem isso o navegador cacheia o redirect e os cliques seguintes não chegam até nós
    res.redirect(302, url);
  });

  const onError: ErrorRequestHandler = (err, _req, res, _next) => {
    const status = typeof err?.status === 'number' && err.status >= 400 && err.status < 500 ? err.status : 500;
    if (status === 500) logger.error({ err }, 'erro não tratado');
    res.status(status).json({ error: status === 500 ? 'internal_error' : 'bad_request' });
  };
  app.use(onError);

  return app;
}
```

O `if (principal.kind !== 'user') return;` em `/me/links` nunca executa (o `requireUser` já barrou serviços). Ele existe para o TypeScript estreitar o tipo e liberar `principal.sub`.

- [ ] **Passo 4: apague o `apiKey.ts`**, que ficou sem uso

```bash
git rm src/http/apiKey.ts
```

- [ ] **Passo 5: atualize** `src/api.ts` (arquivo inteiro)

```ts
import { createRemoteJWKSet } from 'jose';
import { loadApiConfig } from './config.js';
import { logger } from './logger.js';
import { createPool } from './db/pool.js';
import { createRedis } from './cache/redis.js';
import { createLinkCache } from './cache/linkCache.js';
import { createJsonCache } from './cache/jsonCache.js';
import { createLinkRepository, type LinkStats } from './links/repository.js';
import { rateLimit } from './http/rateLimit.js';
import { createApp } from './http/app.js';
import { createTokenVerifier } from './auth/jwt.js';
import { createKafka } from './events/kafka.js';
import { createClickPublisher } from './events/clickPublisher.js';
import { onShutdown } from './shutdown.js';

const config = loadApiConfig();
const pool = createPool(config);
const redis = createRedis(config.REDIS_URL);
const producer = createKafka(config, 'shortener-api').producer({ kafkaJS: { idempotent: true } });
await producer.connect();

// Baixa o JWKS na primeira verificação e guarda em memória; busca de novo se aparecer um kid desconhecido.
const verifyToken = createTokenVerifier({
  issuer: config.OIDC_ISSUER,
  audience: config.OIDC_AUDIENCE,
  jwks: createRemoteJWKSet(new URL(config.OIDC_JWKS_URL)),
});

const app = createApp({
  links: createLinkRepository(pool),
  linkCache: createLinkCache(redis, config.CACHE_TTL_SECONDS),
  statsCache: createJsonCache<LinkStats>(redis, 'stats', 60),
  publisher: createClickPublisher(producer),
  rateLimiter: rateLimit(redis, { limit: config.RATE_LIMIT_PER_MINUTE, windowSeconds: 60 }),
  apiKey: config.API_KEY,
  verifyToken,
  corsOrigins: config.CORS_ALLOWED_ORIGINS,
  publicBaseUrl: config.PUBLIC_BASE_URL,
  version: config.APP_VERSION,
  isReady: async () => {
    try {
      await pool.query('SELECT 1');
      return true;
    } catch {
      return false;
    }
  },
});

const server = app.listen(config.PORT, () => logger.info({ port: config.PORT }, 'api ouvindo'));
// O ALB reaproveita conexões por até 60s. Se o Node fechar antes (o padrão é 5s), o ALB pode
// mandar uma requisição numa conexão já fechada e devolver 502. Por isso, keep-alive > 60s.
server.keepAliveTimeout = 65_000;
server.headersTimeout = 66_000;

onShutdown([
  () => new Promise<void>((resolve, reject) => server.close((err) => (err ? reject(err) : resolve()))),
  () => producer.disconnect(),
  () => redis.quit(),
  () => pool.end(),
]);
```

O `createRemoteJWKSet` não faz requisição na criação. Ele baixa o JWKS na primeira verificação, guarda em memória e busca de novo quando o cache envelhece ou aparece um `kid` desconhecido (rotação de chave no provedor). Por isso a api sobe mesmo com o IdP fora do ar.

- [ ] **Passo 6: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 7: commit.** `git add -A && git commit -m "feat: rotas /me/links, stats por dono e CORS"`

**Pronto quando:** todos os testes passam, inclusive os antigos de redirect, rate limit e Redis fora do ar.

**Para pensar:**
- **404 × 403 para o não-dono.** Um 403 diria "esse código existe, mas é de outra pessoa". Com códigos de 7 caracteres, isso permitiria varrer o espaço de códigos e descobrir quais estão em uso. O 404 não vaza nada. O custo é a depuração: um usuário confuso não sabe se errou o código ou a conta. GitHub faz o mesmo com repositórios privados.
- **Rate limit por IP × por `sub`.** Hoje o limite do `POST /links` é por IP e vem **antes** da autenticação, então também freia força bruta na API key. A desvantagem: usuários atrás do mesmo NAT (uma empresa, uma rede 4G) dividem a cota. Uma evolução comum é ter dois limites: um por IP antes do `authenticate` (barato, contra abuso anônimo) e outro por `sub` depois (justo por usuário). Fica como reflexão.
- **IdP fora do ar vira 401.** Se o JWKS não puder ser baixado, `verifyToken` lança e o usuário recebe 401, como se o token fosse ruim. O painel vai mandá-lo logar de novo, o que também falha. Um 503 seria mais honesto. Para isso, separe os erros de rede do `jose` (`JWKSTimeout` e falhas de `fetch`) dos erros de token. Fica como reflexão.

---

## Tarefa 2.7: teste manual ponta a ponta

Sem código novo: aqui você vê o fluxo inteiro com o IdP de verdade (o mock), primeiro com a api no host e depois em container.

**Conceitos:**
- O mesmo token serve para a api no host e em container, porque o `iss` é sempre `http://localhost:8090/shortener`. Muda só de onde cada uma busca o JWKS.
- O fluxo Authorization Code + PKCE feito na mão é exatamente o que o `oidc-client-ts` vai fazer no painel na Fase 3.

- [ ] **Passo 1: suba a api no host** (infra e `oidc` já no ar)

```bash
npm run dev:api
```

- [ ] **Passo 2: em outro terminal, prepare as variáveis**

```bash
token_for() {
  curl -s -X POST localhost:8090/shortener/token \
    -d grant_type=password -d username="$1" -d password=qualquer \
    -d client_id=shortener-web -d scope=openid \
    | node -pe 'JSON.parse(require("fs").readFileSync(0, "utf8")).access_token'
}
ALICE=$(token_for alice)
BOB=$(token_for bob)
KEY=dev-api-key-change-me-0123456789
```

- [ ] **Passo 3: crie links como usuário e como serviço**

```bash
curl -s -X POST localhost:3000/links -H "Authorization: Bearer $ALICE" \
  -H 'content-type: application/json' -d '{"url":"https://example.com/da-alice"}'
curl -s -X POST localhost:3000/links -H "x-api-key: $KEY" \
  -H 'content-type: application/json' -d '{"url":"https://example.com/do-servico"}'
```

Esperado: dois `201` com `code`, `shortUrl`, `url` e `createdAt`. Anote o `code` da alice em `CODE=...`.

- [ ] **Passo 4: liste "meus links"**

```bash
curl -s "localhost:3000/me/links?limit=1" -H "Authorization: Bearer $ALICE"
curl -s localhost:3000/me/links -H "Authorization: Bearer $BOB"
curl -s -o /dev/null -w '%{http_code}\n' localhost:3000/me/links -H "x-api-key: $KEY"
curl -s -o /dev/null -w '%{http_code}\n' "localhost:3000/me/links?limit=500" -H "Authorization: Bearer $ALICE"
```

Esperado:
- A alice vê só o link dela (o do serviço não aparece).
- O bob vê `{"items":[],"nextCursor":null}`.
- O serviço recebe `403`.
- `limit=500` recebe `400`.

Crie mais dois links como alice e repita com `limit=1`, seguindo o `nextCursor` (`...&cursor=<valor>`) até ele vir `null`.

- [ ] **Passo 5: stats como dono, como outro usuário e como serviço**

```bash
curl -s -o /dev/null -w 'dono: %{http_code}\n'    localhost:3000/links/$CODE/stats -H "Authorization: Bearer $ALICE"
curl -s -o /dev/null -w 'bob: %{http_code}\n'     localhost:3000/links/$CODE/stats -H "Authorization: Bearer $BOB"
curl -s -o /dev/null -w 'servico: %{http_code}\n' localhost:3000/links/$CODE/stats -H "x-api-key: $KEY"
curl -s -o /dev/null -w 'lixo: %{http_code}\n'    localhost:3000/links/$CODE/stats -H "Authorization: Bearer lixo"
```

Esperado: `dono: 200`, `bob: 404`, `servico: 200`, `lixo: 401`.

- [ ] **Passo 6: preflight de CORS**

```bash
curl -s -i -X OPTIONS localhost:3000/links \
  -H 'Origin: http://localhost:5173' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: authorization,content-type' | grep -i '^access-control'
curl -s -i -X OPTIONS localhost:3000/links \
  -H 'Origin: https://evil.example' \
  -H 'Access-Control-Request-Method: POST' | grep -i '^access-control-allow-origin' || echo 'sem allow-origin: bloqueado'
```

Esperado na origem permitida:

```
Access-Control-Allow-Origin: http://localhost:5173
Access-Control-Allow-Methods: GET,POST
Access-Control-Allow-Headers: Authorization,Content-Type
Access-Control-Max-Age: 600
Access-Control-Expose-Headers: RateLimit-Limit,RateLimit-Remaining,Retry-After
```

E na origem negada: `sem allow-origin: bloqueado`. Repare que o `curl` recebe a resposta normalmente: CORS é uma regra do **navegador**, não um firewall. Quem protege a api é o token.

- [ ] **Passo 7: Authorization Code + PKCE na mão** (o fluxo que o painel vai usar)

```bash
VERIFIER=$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n')
CHALLENGE=$(printf %s "$VERIFIER" | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '=\n')
echo "http://localhost:8090/shortener/authorize?client_id=shortener-web&response_type=code&scope=openid&redirect_uri=http://localhost:5173/callback&state=xyz&code_challenge=$CHALLENGE&code_challenge_method=S256"
```

Abra a URL impressa no navegador. Digite `carol` como usuário e envie. O navegador vai para `http://localhost:5173/callback?code=...&state=xyz`, e a página não carrega (o painel ainda não existe), mas o `code` está na barra de endereço. Copie e troque pelo token (sem client secret: quem prova a posse é o `code_verifier`):

```bash
CODE_OIDC=<cole o code aqui>
CAROL=$(curl -s -X POST localhost:8090/shortener/token \
  -d grant_type=authorization_code -d code="$CODE_OIDC" -d client_id=shortener-web \
  -d redirect_uri=http://localhost:5173/callback -d code_verifier="$VERIFIER" \
  | node -pe 'JSON.parse(require("fs").readFileSync(0, "utf8")).access_token')
curl -s localhost:3000/me/links -H "Authorization: Bearer $CAROL"
```

Esperado: `{"items":[],"nextCursor":null}` (a carol ainda não criou nada). Tente trocar o mesmo `code` de novo: o mock responde `unknown or already-used authorization code`. Com outro `code_verifier`, responde `invalid_pkce`.

- [ ] **Passo 8: repita em containers.** Pare o `dev:api` e suba o app:

```bash
docker compose --profile app up -d --build
docker compose --profile app ps
curl -s -X POST localhost:3000/links -H "Authorization: Bearer $(token_for alice)" \
  -H 'content-type: application/json' -d '{"url":"https://example.com/via-container"}'
curl -s localhost:3000/me/links -H "Authorization: Bearer $(token_for alice)"
```

Esperado: `201` e a lista com os links da alice, inclusive os criados no Passo 3 (o banco é o mesmo). Aqui a api busca o JWKS em `http://oidc:8090/...`, mas aceita o token com `iss = http://localhost:8090/shortener`.

Experimento: `docker compose --profile app run --rm --no-deps api node -e "fetch('http://localhost:8090/shortener/jwks').then(r => console.log(r.status)).catch(e => console.log('falhou:', e.cause?.code))"`. Dá `falhou: ECONNREFUSED`, porque `localhost` ali é o container. É o motivo da `OIDC_JWKS_URL` separada.

Se você recriar o container `oidc` e a api começar a recusar tokens novos, reinicie a api (`docker compose restart api`): ela guarda o JWKS em memória por até 10 minutos.

**Pronto quando:** todos os códigos de status batem com o esperado nos dois modos (host e container).

---

## Checkpoint da Fase 2

- [ ] `npm test`, `npm run typecheck` e `npm run lint` passam
- [ ] `docker compose up -d` sobe o `oidc` junto com a infra, e `docker compose --profile app up -d --build` sobe a api aceitando tokens do mock
- [ ] Contrato pronto para o painel (Fase 3):
  - `POST /links` aceita Bearer e devolve `createdAt`
  - `GET /me/links` pagina com `limit` e `cursor`
  - `GET /links/:code/stats` responde 404 para não-dono
  - CORS libera `http://localhost:5173` e `http://localhost:8081`
- [ ] Você consegue explicar:
  - Por que uma API key não pode ir para o navegador e o que o PKCE protege
  - Por que `OIDC_JWKS_URL` é diferente de `OIDC_ISSUER` dentro do compose
  - Por que a api aceita `aud` **ou** `client_id`, e recusa `token_use = id`
  - Por que um Bearer inválido não cai para a API key
  - Por que a paginação usa keyset e por que o cursor carrega microssegundos
  - Por que o CORS não afeta o redirect, e por que ele não protege a api
