# Fase 1: ambiente de dev local e aplicação

**Status:** concluída em 2026-10-12 em `~/Documents/projects/shortener-api` (um commit por tarefa, projeto iniciado pelas CLIs).
**Entrega:** o app completo (api, worker e setup), com testes, rodando no docker-compose.
**Custo:** zero. Tudo roda no seu Mac.
**Ciclo de trabalho:** a infra (Postgres, Valkey, Kafka) roda no compose, e o código roda no host com hot reload. No fim da fase, o app também roda em container.

Convenção de TDD em cada tarefa:
1. Escreva o teste.
2. Rode e veja falhar.
3. Implemente.
4. Rode e veja passar.
5. Faça o commit.

---

## Tarefa 1.1: esqueleto do projeto

**Arquivos:** gerar pelas CLIs `package.json` (`npm init` + `npm pkg set`), `tsconfig.json` (`tsc --init`) e `.gitignore` (`npx gitignore node`). Criar à mão só o que nenhuma CLI gera: `tsconfig.build.json`, `eslint.config.js`, `.nvmrc` e `.env.example`.

**Conceitos:**
- Projeto ESM em TypeScript.
- Separar `tsconfig` de typecheck (inclui os testes) de `tsconfig` de build (só `src`).
- **Comece pela CLI.** O que a ferramenta gera vem com os defaults atuais dela, e você aprende o que mudou entre versões. Edite o arquivo gerado em vez de escrevê-lo do zero.

- [ ] **Passo 1: crie a pasta e inicialize o repositório**

```bash
mkdir ~/Documents/projects/shortener-api && cd ~/Documents/projects/shortener-api
git init -b main
echo "24" > .nvmrc
npm init -y          # o "name" vem da pasta: shortener-api
```

- [ ] **Passo 2: ajuste o `package.json` com `npm pkg`** (as dependências entram no passo 3)

```bash
npm pkg delete main keywords author description license scripts.test
npm pkg set version=0.1.0 type=module engines.node='>=24' \
  scripts.dev:api='node --env-file=.env --watch --import tsx src/api.ts | pino-pretty' \
  scripts.dev:worker='node --env-file=.env --watch --import tsx src/worker.ts | pino-pretty' \
  scripts.setup='node --env-file=.env --import tsx src/setup.ts | pino-pretty' \
  scripts.build='tsc -p tsconfig.build.json' \
  scripts.typecheck='tsc --noEmit' \
  scripts.lint='eslint .' \
  scripts.test:unit='LOG_LEVEL=silent vitest run test/unit' \
  scripts.test:integration='LOG_LEVEL=silent vitest run test/integration --no-file-parallelism' \
  scripts.test='npm run test:unit && npm run test:integration'
npm pkg set private=true --json     # --json grava o boolean true, não a string "true"
```

- [ ] **Passo 3: instale as dependências**

```bash
npm i express pg ioredis @confluentinc/kafka-javascript pino pino-http zod
npm i -D typescript@~6.0.3 tsx @types/node @types/express @types/pg vitest supertest @types/supertest \
  eslint @eslint/js typescript-eslint pino-pretty
```

Por que `typescript@~6.0.3` e não a última: a `latest` já é a 7.x (o compilador reescrito em Go), mas o `typescript-eslint` ainda exige `typescript <6.1` (`npm view typescript-eslint peerDependencies`). Fixar a versão por compatibilidade do ecossistema é rotina em empresa.

- [ ] **Passo 4: confira se o cliente Kafka (nativo) instalou no seu Mac**

```bash
node -e "import('@confluentinc/kafka-javascript').then(() => console.log('kafka ok'))"
```

Esperado: `kafka ok`.

Se falhar (falta binário pré-compilado para macOS), siga as tarefas normalmente: os testes não usam o cliente Kafka. Nesse caso, rode `api` e `worker` só via compose, a partir da Tarefa 1.12.

- [ ] **Passo 5: gere o `tsconfig.json` com `tsc --init`** (usado no typecheck e no editor)

```bash
npx tsc --init --target es2023 --module nodenext --moduleResolution nodenext --strict \
  --esModuleInterop --skipLibCheck --types node --noEmit
```

O TS 6 gera um arquivo comentado com defaults mais rígidos que os de antigamente. Mantenha-os: `noUncheckedIndexedAccess` (`arr[0]` pode ser `undefined`), `exactOptionalPropertyTypes` (`campo?: T` não aceita `undefined` explícito; declare `campo?: T | undefined` quando precisar), `verbatimModuleSyntax` e `isolatedModules`. No arquivo gerado, faça só três ajustes:
- apague `"jsx": "react-jsx"` (não há React na api);
- apague `"declaration"` e `"declarationMap"` (`.d.ts` serve para biblioteca, não para app);
- depois de `compilerOptions`, acrescente `"include": ["src", "test"]`.

- [ ] **Passo 6: crie `tsconfig.build.json`** (gera o `dist/`; nenhuma CLI cria um `extends`)

```json
{
  "extends": "./tsconfig.json",
  "compilerOptions": { "noEmit": false, "rootDir": "src", "outDir": "dist" },
  "include": ["src"]
}
```

- [ ] **Passo 7: crie `eslint.config.js`**

O `npm init @eslint/config@latest` é um assistente interativo e serve para projetos JS. Para TypeScript, o caminho oficial é o quickstart do `typescript-eslint`: instalar os pacotes (já feito no passo 3) e escrever a config:

```js
import { defineConfig } from 'eslint/config';
import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default defineConfig([
  { ignores: ['dist/', 'node_modules/'] },
  js.configs.recommended,
  tseslint.configs.recommended,
  {
    rules: {
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_', ignoreRestSiblings: true },
      ],
    },
  },
]);
```

- [ ] **Passo 8: gere o `.gitignore`** a partir do template oficial do GitHub para Node

```bash
npx gitignore node
grep -nE '^(node_modules/|dist|\.env|!\.env\.example)$' .gitignore   # já ignora node_modules, dist e .env, mas não o .env.example
```

As regras de Terraform (`.terraform/`, `*.tfstate`) não entram aqui: o Terraform mora no `shortener-deploy`.

- [ ] **Passo 9: crie `.env.example` e copie para `.env`** (`cp .env.example .env`)

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
```

- [ ] **Passo 10: commit**

```bash
git add -A && git commit -m "chore: esqueleto do projeto Node/TypeScript"
```

**Pronto quando:** `npm ls --depth=0` lista as dependências sem erro e `npx eslint .` roda limpo.

---

## Tarefa 1.2: infra local com docker-compose

**Arquivos:** criar `docker-compose.yml` e `docker/postgres-init.sql`.

**Conceitos:**
- Kafka em modo KRaft (sem Zookeeper).
- *Listeners* diferentes para quem acessa de dentro da rede do compose e de fora dela (o seu host).
- Healthchecks.

- [ ] **Passo 1: crie `docker/postgres-init.sql`** (banco separado para os testes)

```sql
CREATE DATABASE shortener_test;
```

- [ ] **Passo 2: crie `docker-compose.yml`.** Os serviços `setup`, `api` e `worker` ficam no profile `app` e só serão usados na Tarefa 1.12.

```yaml
name: shortener

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

services:
  postgres:
    image: postgres:17
    environment:
      POSTGRES_USER: shortener
      POSTGRES_PASSWORD: shortener
      POSTGRES_DB: shortener
    ports: ["5432:5432"]
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./docker/postgres-init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U shortener"]
      interval: 5s
      timeout: 3s
      retries: 20

  valkey:
    image: valkey/valkey:8
    ports: ["6379:6379"]
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 20

  kafka:
    image: apache/kafka:3.9.1
    ports: ["9092:9092"]
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      # PLAINTEXT (19092) = dentro da rede do compose; PLAINTEXT_HOST (9092) = seu Mac
      KAFKA_LISTENERS: PLAINTEXT://:19092,CONTROLLER://:9093,PLAINTEXT_HOST://:9092
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka:19092,PLAINTEXT_HOST://localhost:9092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:PLAINTEXT
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka:9093
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 1
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "false"   # igual ao MSK: tópicos são criados pelo setup
    healthcheck:
      test: ["CMD-SHELL", "/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 > /dev/null 2>&1"]
      interval: 10s
      timeout: 10s
      retries: 20
      start_period: 20s

  kafka-ui:
    profiles: [tools]
    image: ghcr.io/kafbat/kafka-ui:latest   # fixe a versão atual depois do primeiro uso
    ports: ["8080:8080"]
    environment:
      KAFKA_CLUSTERS_0_NAME: local
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: kafka:19092
    depends_on: [kafka]

  setup:
    profiles: [app]
    build: .
    command: ["node", "dist/setup.js"]
    environment: *app-env
    depends_on:
      postgres: { condition: service_healthy }
      kafka: { condition: service_healthy }

  api:
    profiles: [app]
    build: .
    ports: ["3000:3000"]
    environment: *app-env
    depends_on:
      setup: { condition: service_completed_successfully }
      valkey: { condition: service_healthy }

  worker:
    profiles: [app]
    build: .
    command: ["node", "dist/worker.js"]
    environment: *app-env
    depends_on:
      setup: { condition: service_completed_successfully }

volumes:
  pgdata: {}
```

- [ ] **Passo 3: suba e confira**

```bash
docker compose up -d
docker compose ps                                    # postgres, valkey e kafka "healthy"
docker compose exec postgres psql -U shortener -lqt | cut -d'|' -f1 | grep shortener   # shortener e shortener_test
docker compose exec valkey valkey-cli ping           # PONG
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list   # vazio, sem erro
```

Se o banco `shortener_test` não aparecer, o volume foi criado antes do script de init. Rode `docker compose down -v && docker compose up -d`.

- [ ] **Passo 4: commit**

```bash
git add -A && git commit -m "chore: infra local com postgres, valkey e kafka (KRaft)"
```

**Pronto quando:** os 3 serviços estão `healthy` e os comandos do passo 3 retornam o esperado.

---

## Tarefa 1.3: configuração validada

**Arquivos:** criar `src/config.ts` e `test/unit/config.test.ts`.

**Interfaces que esta tarefa entrega:**
- `loadBaseConfig(env?)`, `loadApiConfig(env?)` e `loadWorkerConfig(env?)`
- Os tipos `BaseConfig`, `ApiConfig` e `WorkerConfig`

**Conceitos:**
- *Fail fast:* o app não sobe com configuração inválida, e a mensagem diz qual variável está errada.
- Cada processo exige só o que usa. O Job de setup não recebe `API_KEY` nem `PUBLIC_BASE_URL`.

- [ ] **Passo 1: escreva o teste** `test/unit/config.test.ts`

```ts
import { describe, expect, it } from 'vitest';
import { loadApiConfig, loadBaseConfig } from '../../src/config.js';

const base = {
  DATABASE_URL: 'postgres://u:p@localhost:5432/db',
  REDIS_URL: 'redis://localhost:6379',
  KAFKA_BROKERS: 'localhost:9092, localhost:9093',
};
const api = { ...base, PUBLIC_BASE_URL: 'http://localhost:3000', API_KEY: 'a'.repeat(32) };

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

  it('a config base não exige variáveis exclusivas da api', () => {
    expect(() => loadBaseConfig(base)).not.toThrow();
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm run test:unit`: falha porque `src/config.js` não existe.

- [ ] **Passo 3: implemente** `src/config.ts`

```ts
import { z } from 'zod';

const bool = z
  .enum(['true', 'false'])
  .default('false')
  .transform((v) => v === 'true');

const baseSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  APP_VERSION: z.string().default('dev'),
  DATABASE_URL: z.string().min(1),
  DATABASE_SSL: bool,
  DATABASE_SSL_CA_FILE: z.string().optional(),
  REDIS_URL: z.string().min(1),
  KAFKA_BROKERS: z
    .string()
    .min(1)
    .transform((s) => s.split(',').map((b) => b.trim()).filter(Boolean)),
  KAFKA_SSL: bool,
  KAFKA_REPLICATION_FACTOR: z.coerce.number().int().min(1).default(1),
});

const apiSchema = baseSchema.extend({
  PORT: z.coerce.number().int().positive().default(3000),
  PUBLIC_BASE_URL: z.string().min(1),
  API_KEY: z.string().min(16),
  CACHE_TTL_SECONDS: z.coerce.number().int().positive().default(86_400),
  RATE_LIMIT_PER_MINUTE: z.coerce.number().int().positive().default(10),
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

- [ ] **Passo 4: rode e veja passar.** `npm run test:unit` (5 testes) e depois `npm run typecheck && npm run lint`.

- [ ] **Passo 5: commit.** `git add -A && git commit -m "feat: configuração validada com zod"`

**Pronto quando:** testes, typecheck e lint passam.

---

## Tarefa 1.4: logger, pool do Postgres e migrations

**Arquivos:**
- Criar `src/logger.ts`, `src/db/pool.ts`, `src/db/migrate.ts` e `migrations/001_init.sql`
- Testes: criar `test/integration/helpers.ts` e `test/integration/migrate.test.ts`

**Interfaces que esta tarefa entrega:**
- `logger` (pino)
- `createPool(cfg: { DATABASE_URL; DATABASE_SSL; DATABASE_SSL_CA_FILE? }): pg.Pool`
- `runMigrations(pool, dir): Promise<string[]>` (devolve os nomes aplicados)
- Nos testes: `migratedPool()`, `connectedRedis()`, `TEST_REDIS_URL` e `DEAD_REDIS_URL`

**Conceitos:**
- **Migrations versionadas**, aplicadas uma única vez.
- **Advisory lock:** se 2 pods de setup rodarem juntos, só um migra.
- **TLS com o RDS** (CA própria da AWS).
- **Por que não usamos lib de migration:** para você ver o mecanismo por dentro.

- [ ] **Passo 1: crie** `migrations/001_init.sql`

```sql
CREATE TABLE links (
  code        text PRIMARY KEY,
  url         text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Idempotência do worker: um evento só é contado se o seu ID ainda não estiver aqui.
CREATE TABLE processed_events (
  event_id      uuid PRIMARY KEY,
  processed_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE click_stats_daily (
  code    text NOT NULL REFERENCES links (code),
  day     date NOT NULL,
  clicks  bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (code, day)
);

CREATE TABLE click_stats_browser (
  code     text NOT NULL REFERENCES links (code),
  browser  text NOT NULL,
  clicks   bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (code, browser)
);
```

- [ ] **Passo 2: crie** `src/logger.ts`

```ts
import pino from 'pino';

export const logger = pino({
  level: process.env.LOG_LEVEL ?? 'info',
  base: { version: process.env.APP_VERSION ?? 'dev' },
});
```

- [ ] **Passo 3: crie** `src/db/pool.ts`

```ts
import { readFileSync } from 'node:fs';
import pg from 'pg';

export interface DbConfig {
  DATABASE_URL: string;
  DATABASE_SSL: boolean;
  DATABASE_SSL_CA_FILE?: string | undefined;
}

// Atenção: não coloque "sslmode=" na DATABASE_URL. Se colocar, o pg ignora o objeto ssl abaixo.
export function createPool(cfg: DbConfig): pg.Pool {
  const ssl = cfg.DATABASE_SSL
    ? {
        rejectUnauthorized: true,
        ...(cfg.DATABASE_SSL_CA_FILE ? { ca: readFileSync(cfg.DATABASE_SSL_CA_FILE, 'utf8') } : {}),
      }
    : undefined;
  return new pg.Pool({
    connectionString: cfg.DATABASE_URL,
    ssl,
    max: 10,
    connectionTimeoutMillis: 3_000,
    idleTimeoutMillis: 30_000,
  });
}
```

- [ ] **Passo 4: crie os helpers de teste** `test/integration/helpers.ts`

```ts
import type pg from 'pg';
import type { Redis } from 'ioredis';
import { createPool } from '../../src/db/pool.js';
import { runMigrations } from '../../src/db/migrate.js';
import { createRedis } from '../../src/cache/redis.js';

export const TEST_DATABASE_URL =
  process.env.TEST_DATABASE_URL ?? 'postgres://shortener:shortener@localhost:5432/shortener_test';
export const TEST_REDIS_URL = process.env.TEST_REDIS_URL ?? 'redis://localhost:6379/1';
export const DEAD_REDIS_URL = 'redis://localhost:6399'; // porta onde não há nada: simula Redis fora do ar

export function createTestPool(): pg.Pool {
  return createPool({ DATABASE_URL: TEST_DATABASE_URL, DATABASE_SSL: false });
}

export async function resetDatabase(pool: pg.Pool): Promise<void> {
  await pool.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
}

export async function migratedPool(): Promise<pg.Pool> {
  const pool = createTestPool();
  await resetDatabase(pool);
  await runMigrations(pool, 'migrations');
  return pool;
}

export async function connectedRedis(url = TEST_REDIS_URL): Promise<Redis> {
  const redis = createRedis(url);
  if (redis.status !== 'ready') {
    await new Promise<void>((resolve) => redis.once('ready', () => resolve()));
  }
  return redis;
}
```

Os helpers importam `src/cache/redis.ts`, que só nasce na Tarefa 1.6. Para não travar agora, crie esse arquivo já neste passo, com o conteúdo do Passo 3 da Tarefa 1.6.

- [ ] **Passo 5: escreva o teste** `test/integration/migrate.test.ts`

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
    expect(first).toContain('001_init.sql');

    const second = await runMigrations(pool, 'migrations');
    expect(second).toEqual([]);

    const { rows } = await pool.query("SELECT to_regclass('public.links')::text AS t");
    expect(rows[0].t).toBe('links');
  });
});
```

- [ ] **Passo 6: rode e veja falhar.** `npm run test:integration`: falha porque `migrate.js` não existe. O compose precisa estar de pé.

- [ ] **Passo 7: implemente** `src/db/migrate.ts`

```ts
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import type pg from 'pg';

const LOCK_ID = 727274; // número arbitrário que identifica "a migração do shortener"

export async function runMigrations(pool: pg.Pool, dir: string): Promise<string[]> {
  const client = await pool.connect();
  try {
    await client.query('SELECT pg_advisory_lock($1)', [LOCK_ID]);
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      name text PRIMARY KEY,
      applied_at timestamptz NOT NULL DEFAULT now()
    )`);
    const { rows } = await client.query<{ name: string }>('SELECT name FROM schema_migrations');
    const done = new Set(rows.map((r) => r.name));
    const files = (await readdir(dir)).filter((f) => f.endsWith('.sql')).sort();

    const applied: string[] = [];
    for (const file of files) {
      if (done.has(file)) continue;
      const sql = await readFile(path.join(dir, file), 'utf8');
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query('INSERT INTO schema_migrations (name) VALUES ($1)', [file]);
        await client.query('COMMIT');
        applied.push(file);
      } catch (err) {
        await client.query('ROLLBACK');
        throw new Error(`Migration ${file} falhou: ${(err as Error).message}`, { cause: err });
      }
    }
    return applied;
  } finally {
    await client.query('SELECT pg_advisory_unlock($1)', [LOCK_ID]).catch(() => undefined);
    client.release();
  }
}
```

- [ ] **Passo 8: rode e veja passar.** `npm run test:integration` e depois `npm run typecheck && npm run lint`.

- [ ] **Passo 9: commit.** `git add -A && git commit -m "feat: pool do postgres e migrations versionadas"`

**Pronto quando:** o teste de migration passa duas vezes seguidas.

---

## Tarefa 1.5: domínio de links (código, URL, repositório e serviço)

**Arquivos:**
- Criar `src/links/code.ts`, `src/links/url.ts`, `src/links/repository.ts` e `src/links/service.ts`
- Testes: `test/unit/code.test.ts`, `test/unit/url.test.ts`, `test/unit/service.test.ts` e `test/integration/repository.test.ts`

**Interfaces que esta tarefa entrega:**
- `generateCode(): string`, `isValidCode(s): boolean` e `CODE_LENGTH = 7`
- `normalizeTargetUrl(input: unknown): string | null` e `MAX_URL_LENGTH = 2048`
- `createLinkRepository(pool): LinkRepository`, com:
  - `insert(code, url)`
  - `findUrl(code)` → `string | null`
  - `getStats(code)` → `LinkStats | null`
- `LinkStats = { code, url, totalClicks, daily: {day, clicks}[], browsers: {browser, clicks}[] }`
- `DuplicateCodeError`
- `createShortLink(repo, url, gen?, maxAttempts?): Promise<string>`

**Conceitos:**
- Validação de entrada como defesa contra phishing e XSS.
- Colisão de chave resolvida com retry.
- O `pg` devolve `bigint` como string.

- [ ] **Passo 1: escreva os testes unitários**

`test/unit/code.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { generateCode, isValidCode } from '../../src/links/code.js';

describe('code', () => {
  it('gera 7 caracteres alfanuméricos', () => {
    expect(generateCode()).toMatch(/^[0-9A-Za-z]{7}$/);
  });
  it('praticamente não repete', () => {
    const codes = new Set(Array.from({ length: 1000 }, generateCode));
    expect(codes.size).toBe(1000);
  });
  it('valida formato', () => {
    expect(isValidCode('abcDEF1')).toBe(true);
    expect(isValidCode('abc')).toBe(false);
    expect(isValidCode('abc-EF1')).toBe(false);
    expect(isValidCode('favicon.ico')).toBe(false);
    expect(isValidCode('healthz')).toBe(true); // por isso a ordem das rotas importa (Tarefa 1.8)
  });
});
```

`test/unit/url.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { MAX_URL_LENGTH, normalizeTargetUrl } from '../../src/links/url.js';

describe('normalizeTargetUrl', () => {
  it('aceita http e https', () => {
    expect(normalizeTargetUrl('https://example.com/a?b=1')).toBe('https://example.com/a?b=1');
    expect(normalizeTargetUrl('http://example.com')).toBe('http://example.com/');
  });
  it.each(['javascript:alert(1)', 'data:text/html,<h1>oi</h1>', 'ftp://example.com', 'file:///etc/passwd'])(
    'rejeita esquema perigoso: %s',
    (url) => expect(normalizeTargetUrl(url)).toBeNull(),
  );
  it('rejeita lixo, vazio e não-string', () => {
    expect(normalizeTargetUrl('nao e url')).toBeNull();
    expect(normalizeTargetUrl('')).toBeNull();
    expect(normalizeTargetUrl(42)).toBeNull();
    expect(normalizeTargetUrl(undefined)).toBeNull();
  });
  it('rejeita URL gigante', () => {
    expect(normalizeTargetUrl(`https://example.com/${'a'.repeat(MAX_URL_LENGTH)}`)).toBeNull();
  });
});
```

`test/unit/service.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { createShortLink } from '../../src/links/service.js';
import { DuplicateCodeError, type LinkRepository } from '../../src/links/repository.js';

function fakeRepo(duplicatesBeforeSuccess: number, otherError?: Error) {
  let calls = 0;
  const repo: LinkRepository = {
    async insert(code) {
      calls++;
      if (otherError) throw otherError;
      if (calls <= duplicatesBeforeSuccess) throw new DuplicateCodeError(code);
    },
    findUrl: async () => null,
    getStats: async () => null,
  };
  return { repo, calls: () => calls };
}

describe('createShortLink', () => {
  it('devolve o código quando insere de primeira', async () => {
    const { repo } = fakeRepo(0);
    expect(await createShortLink(repo, 'https://x.com', () => 'AAAAAA1')).toBe('AAAAAA1');
  });
  it('tenta outro código em caso de colisão', async () => {
    const { repo, calls } = fakeRepo(2);
    await createShortLink(repo, 'https://x.com');
    expect(calls()).toBe(3);
  });
  it('desiste depois de N colisões', async () => {
    const { repo } = fakeRepo(99);
    await expect(createShortLink(repo, 'https://x.com', undefined, 3)).rejects.toThrow(/código único/);
  });
  it('não engole outros erros', async () => {
    const { repo } = fakeRepo(0, new Error('banco fora'));
    await expect(createShortLink(repo, 'https://x.com')).rejects.toThrow('banco fora');
  });
});
```

- [ ] **Passo 2: escreva o teste de integração** `test/integration/repository.test.ts`

```ts
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type pg from 'pg';
import { createLinkRepository, DuplicateCodeError } from '../../src/links/repository.js';
import { migratedPool } from './helpers.js';

let pool: pg.Pool;
beforeAll(async () => { pool = await migratedPool(); });
afterAll(() => pool.end());
beforeEach(() => pool.query('TRUNCATE links, click_stats_daily, click_stats_browser, processed_events'));

describe('linkRepository', () => {
  it('insere e encontra pelo código', async () => {
    const repo = createLinkRepository(pool);
    await repo.insert('abcDEF1', 'https://example.com');
    expect(await repo.findUrl('abcDEF1')).toBe('https://example.com');
    expect(await repo.findUrl('zzzzzz9')).toBeNull();
  });

  it('lança DuplicateCodeError para código repetido', async () => {
    const repo = createLinkRepository(pool);
    await repo.insert('abcDEF1', 'https://a.com');
    await expect(repo.insert('abcDEF1', 'https://b.com')).rejects.toBeInstanceOf(DuplicateCodeError);
  });

  it('getStats: null se não existe, zerado se não tem cliques', async () => {
    const repo = createLinkRepository(pool);
    expect(await repo.getStats('zzzzzz9')).toBeNull();
    await repo.insert('abcDEF1', 'https://example.com');
    expect(await repo.getStats('abcDEF1')).toEqual({
      code: 'abcDEF1', url: 'https://example.com', totalClicks: 0, daily: [], browsers: [],
    });
  });

  it('getStats: soma e converte bigint para number', async () => {
    const repo = createLinkRepository(pool);
    await repo.insert('abcDEF1', 'https://example.com');
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

- [ ] **Passo 3: rode e veja falhar.** `npm run test:unit && npm run test:integration`.

- [ ] **Passo 4: implemente**

`src/links/code.ts`:

```ts
import { randomInt } from 'node:crypto';

const ALPHABET = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
export const CODE_LENGTH = 7;
const CODE_REGEX = /^[0-9A-Za-z]{7}$/;

export function generateCode(): string {
  let code = '';
  for (let i = 0; i < CODE_LENGTH; i++) code += ALPHABET[randomInt(ALPHABET.length)];
  return code;
}

export function isValidCode(value: string): boolean {
  return CODE_REGEX.test(value);
}
```

`src/links/url.ts`:

```ts
export const MAX_URL_LENGTH = 2048;

export function normalizeTargetUrl(input: unknown): string | null {
  if (typeof input !== 'string' || input.length === 0 || input.length > MAX_URL_LENGTH) return null;
  let url: URL;
  try {
    url = new URL(input);
  } catch {
    return null;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
  return url.toString();
}
```

`src/links/repository.ts`:

```ts
import type pg from 'pg';

export interface LinkStats {
  code: string;
  url: string;
  totalClicks: number;
  daily: { day: string; clicks: number }[];
  browsers: { browser: string; clicks: number }[];
}

export class DuplicateCodeError extends Error {
  constructor(code: string) {
    super(`código já existe: ${code}`);
  }
}

export interface LinkRepository {
  insert(code: string, url: string): Promise<void>;
  findUrl(code: string): Promise<string | null>;
  getStats(code: string): Promise<LinkStats | null>;
}

export function createLinkRepository(pool: pg.Pool): LinkRepository {
  return {
    async insert(code, url) {
      try {
        await pool.query('INSERT INTO links (code, url) VALUES ($1, $2)', [code, url]);
      } catch (err) {
        if ((err as { code?: string }).code === '23505') throw new DuplicateCodeError(code); // unique_violation
        throw err;
      }
    },

    async findUrl(code) {
      const { rows } = await pool.query<{ url: string }>('SELECT url FROM links WHERE code = $1', [code]);
      return rows[0]?.url ?? null;
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

`src/links/service.ts`:

```ts
import { generateCode } from './code.js';
import { DuplicateCodeError, type LinkRepository } from './repository.js';

export async function createShortLink(
  repo: LinkRepository,
  url: string,
  gen: () => string = generateCode,
  maxAttempts = 5,
): Promise<string> {
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const code = gen();
    try {
      await repo.insert(code, url);
      return code;
    } catch (err) {
      if (!(err instanceof DuplicateCodeError)) throw err;
    }
  }
  throw new Error('Não foi possível gerar um código único');
}
```

- [ ] **Passo 5: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 6: commit.** `git add -A && git commit -m "feat: domínio de links com validação de URL"`

**Pronto quando:** todos os testes passam, inclusive os de esquemas perigosos.

---

## Tarefa 1.6: Redis/Valkey (cliente, caches e rate limit)

**Arquivos:**
- Criar `src/cache/redis.ts` (já criado na 1.4), `src/cache/linkCache.ts`, `src/cache/jsonCache.ts` e `src/http/rateLimit.ts`
- Teste: `test/integration/cache.test.ts` (o rate limit é testado pela HTTP, na 1.8)

**Interfaces que esta tarefa entrega:**
- `createRedis(url): Redis`. Falha rápido; aceita `redis://` e `rediss://` (TLS).
- `createLinkCache(redis, ttlSeconds): LinkCache`, com:
  - `get(code)` → `{ hit: true; url: string | null } | { hit: false }`
  - `setUrl(code, url)`
  - `setNotFound(code)`
- `createJsonCache<T>(redis, prefix, ttlSeconds): JsonCache<T>`, com `get(id)` → `T | null` e `set(id, value)`
- `rateLimit(redis, { limit, windowSeconds }): RequestHandler`

**Conceitos:**
- **Cache-aside.**
- **Cache negativo**, para que requisições repetidas a códigos que não existem não martelem o banco.
- **Fail-open:** com o cache fora, o app segue sem ele.
- **Falhar rápido** (`enableOfflineQueue: false`). Sem isso, o ioredis enfileira os comandos e a requisição trava esperando.
- **Atomicidade** com MULTI/EXEC.

- [ ] **Passo 1: escreva o teste** `test/integration/cache.test.ts`

```ts
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { Redis } from 'ioredis';
import { createRedis } from '../../src/cache/redis.js';
import { createLinkCache } from '../../src/cache/linkCache.js';
import { createJsonCache } from '../../src/cache/jsonCache.js';
import { connectedRedis, DEAD_REDIS_URL } from './helpers.js';

let redis: Redis;
let dead: Redis;
beforeAll(async () => {
  redis = await connectedRedis();
  dead = createRedis(DEAD_REDIS_URL);
});
afterAll(() => {
  redis.disconnect();
  dead.disconnect();
});
beforeEach(() => redis.flushdb());

describe('linkCache', () => {
  it('miss → setUrl → hit, com TTL', async () => {
    const cache = createLinkCache(redis, 120);
    expect(await cache.get('abcDEF1')).toEqual({ hit: false });
    await cache.setUrl('abcDEF1', 'https://example.com');
    expect(await cache.get('abcDEF1')).toEqual({ hit: true, url: 'https://example.com' });
    expect(await redis.ttl('link:abcDEF1')).toBeGreaterThan(100);
  });

  it('guarda "não existe" com TTL curto', async () => {
    const cache = createLinkCache(redis, 120);
    await cache.setNotFound('abcDEF1');
    expect(await cache.get('abcDEF1')).toEqual({ hit: true, url: null });
    expect(await redis.ttl('link:abcDEF1')).toBeLessThanOrEqual(60);
  });

  it('com o Redis fora do ar vira miss rápido, sem lançar erro', async () => {
    const cache = createLinkCache(dead, 120);
    const start = Date.now();
    expect(await cache.get('abcDEF1')).toEqual({ hit: false });
    await cache.setUrl('abcDEF1', 'https://example.com');
    expect(Date.now() - start).toBeLessThan(1000);
  });
});

describe('jsonCache', () => {
  it('serializa, expira e tolera Redis fora', async () => {
    const cache = createJsonCache<{ n: number }>(redis, 'stats', 60);
    expect(await cache.get('x')).toBeNull();
    await cache.set('x', { n: 1 });
    expect(await cache.get('x')).toEqual({ n: 1 });
    expect(await createJsonCache(dead, 'stats', 60).get('x')).toBeNull();
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm run test:integration`.

- [ ] **Passo 3: implemente** `src/cache/redis.ts` (se ainda não criou)

```ts
import { Redis } from 'ioredis';
import { logger } from '../logger.js';

export function createRedis(url: string): Redis {
  const redis = new Redis(url, {
    enableOfflineQueue: false, // desconectado? o comando falha na hora em vez de esperar
    maxRetriesPerRequest: 1,
    connectTimeout: 2_000,
    commandTimeout: 500,
  });
  redis.on('error', (err) => logger.warn({ err: err.message }, 'redis: erro de conexão'));
  return redis;
}
```

- [ ] **Passo 4: implemente** `src/cache/linkCache.ts`

```ts
import type { Redis } from 'ioredis';
import { logger } from '../logger.js';

export type CacheLookup = { hit: true; url: string | null } | { hit: false };

export interface LinkCache {
  get(code: string): Promise<CacheLookup>;
  setUrl(code: string, url: string): Promise<void>;
  setNotFound(code: string): Promise<void>;
}

const NOT_FOUND = '__not_found__';
const NOT_FOUND_TTL_SECONDS = 60;

export function createLinkCache(redis: Redis, ttlSeconds: number): LinkCache {
  const key = (code: string) => `link:${code}`;
  return {
    async get(code) {
      try {
        const value = await redis.get(key(code));
        if (value === null) return { hit: false };
        return { hit: true, url: value === NOT_FOUND ? null : value };
      } catch (err) {
        logger.warn({ err }, 'cache indisponível (get); seguindo sem cache');
        return { hit: false };
      }
    },
    async setUrl(code, url) {
      try {
        await redis.set(key(code), url, 'EX', ttlSeconds);
      } catch (err) {
        logger.warn({ err }, 'cache indisponível (set)');
      }
    },
    async setNotFound(code) {
      try {
        await redis.set(key(code), NOT_FOUND, 'EX', NOT_FOUND_TTL_SECONDS);
      } catch (err) {
        logger.warn({ err }, 'cache indisponível (set)');
      }
    },
  };
}
```

- [ ] **Passo 5: implemente** `src/cache/jsonCache.ts`

```ts
import type { Redis } from 'ioredis';
import { logger } from '../logger.js';

export interface JsonCache<T> {
  get(id: string): Promise<T | null>;
  set(id: string, value: T): Promise<void>;
}

export function createJsonCache<T>(redis: Redis, prefix: string, ttlSeconds: number): JsonCache<T> {
  const key = (id: string) => `${prefix}:${id}`;
  return {
    async get(id) {
      try {
        const raw = await redis.get(key(id));
        return raw ? (JSON.parse(raw) as T) : null;
      } catch (err) {
        logger.warn({ err }, 'cache indisponível (get)');
        return null;
      }
    },
    async set(id, value) {
      try {
        await redis.set(key(id), JSON.stringify(value), 'EX', ttlSeconds);
      } catch (err) {
        logger.warn({ err }, 'cache indisponível (set)');
      }
    },
  };
}
```

- [ ] **Passo 6: implemente** `src/http/rateLimit.ts`

```ts
import type { RequestHandler } from 'express';
import type { Redis } from 'ioredis';
import { logger } from '../logger.js';

// Janela fixa: conta requisições por IP dentro de cada bloco de N segundos.
export function rateLimit(redis: Redis, opts: { limit: number; windowSeconds: number }): RequestHandler {
  return async (req, res, next) => {
    const window = Math.floor(Date.now() / 1000 / opts.windowSeconds);
    const key = `rl:${req.ip}:${window}`;
    let count: number;
    try {
      // MULTI/EXEC: INCR e EXPIRE vão juntos; nunca sobra uma chave sem expiração.
      const results = await redis.multi().incr(key).expire(key, opts.windowSeconds).exec();
      count = Number(results?.[0]?.[1] ?? 0);
    } catch (err) {
      // Fail-open: preferimos aceitar a requisição a derrubar o serviço porque o Redis caiu.
      logger.warn({ err }, 'rate limit indisponível; liberando requisição');
      next();
      return;
    }
    res.set('RateLimit-Limit', String(opts.limit));
    res.set('RateLimit-Remaining', String(Math.max(0, opts.limit - count)));
    if (count > opts.limit) {
      res.set('Retry-After', String(opts.windowSeconds));
      res.status(429).json({ error: 'rate_limited' });
      return;
    }
    next();
  };
}
```

- [ ] **Passo 7: rode e veja passar.** `npm run test:integration && npm run typecheck && npm run lint`.

- [ ] **Passo 8: commit.** `git add -A && git commit -m "feat: cache de links, cache json e rate limit com fail-open"`

**Pronto quando:** o teste "Redis fora do ar" passa em menos de 1 segundo.

---

## Tarefa 1.7: eventos e publicação no Kafka

**Arquivos:**
- Criar `src/events/clickEvent.ts`, `src/events/kafka.ts` e `src/events/clickPublisher.ts`
- Testes: `test/unit/clickEvent.test.ts` e `test/unit/clickPublisher.test.ts`

**Interfaces que esta tarefa entrega:**
- `TOPIC_CLICKS = 'link.clicked'` e `TOPIC_CLICKS_DLQ = 'link.clicked.dlq'`
- `ClickEvent = { v: 1; eventId: string; code: string; occurredAt: string; userAgent: string }`
- `buildClickEvent(code, userAgent?, now?)` e `parseClickEvent(raw: Buffer | string | null | undefined)`
- `createKafka(cfg, clientId)`
- `OutgoingMessage = { key: string | null; value: string; headers?: Record<string, string> }`
- `MessageSender = { send(record: { topic; messages: OutgoingMessage[] }): Promise<unknown> }`
- `createClickPublisher(sender): ClickPublisher`, com `publish(event): void`, que **nunca lança erro e não é aguardado**

**Conceitos:**
- **Contrato do evento versionado** (`v: 1`).
- **Chave de partição = código.** Os cliques do mesmo link caem na mesma partição, em ordem.
- **Fire-and-forget:** o redirect não espera o broker.

- [ ] **Passo 1: escreva os testes**

`test/unit/clickEvent.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { buildClickEvent, parseClickEvent } from '../../src/events/clickEvent.js';

describe('clickEvent', () => {
  it('build preenche id, data ISO e versão', () => {
    const e = buildClickEvent('abcDEF1', 'curl/8.7.1', new Date('2026-10-12T15:00:00Z'));
    expect(e).toMatchObject({ v: 1, code: 'abcDEF1', userAgent: 'curl/8.7.1', occurredAt: '2026-10-12T15:00:00.000Z' });
    expect(e.eventId).toMatch(/^[0-9a-f-]{36}$/);
  });
  it('trunca user-agent gigante e aceita ausente', () => {
    expect(buildClickEvent('abcDEF1', 'x'.repeat(2000)).userAgent).toHaveLength(512);
    expect(buildClickEvent('abcDEF1', undefined).userAgent).toBe('');
  });
  it('parse faz ida e volta', () => {
    const e = buildClickEvent('abcDEF1', 'curl/8.7.1');
    expect(parseClickEvent(Buffer.from(JSON.stringify(e)))).toEqual(e);
  });
  it('parse rejeita lixo', () => {
    expect(() => parseClickEvent(Buffer.from('não é json'))).toThrow();
    expect(() => parseClickEvent(Buffer.from('{"v":1}'))).toThrow();
    expect(() => parseClickEvent(null)).toThrow();
  });
});
```

`test/unit/clickPublisher.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { createClickPublisher } from '../../src/events/clickPublisher.js';
import { buildClickEvent } from '../../src/events/clickEvent.js';

describe('clickPublisher', () => {
  it('publica no tópico de cliques com o código como chave', () => {
    const sent: unknown[] = [];
    const publisher = createClickPublisher({ send: async (r) => { sent.push(r); } });
    const e = buildClickEvent('abcDEF1', 'curl/8.7.1');
    publisher.publish(e);
    expect(sent).toEqual([{ topic: 'link.clicked', messages: [{ key: 'abcDEF1', value: JSON.stringify(e) }] }]);
  });

  it('nunca propaga erro do Kafka', async () => {
    const publisher = createClickPublisher({ send: async () => { throw new Error('broker fora'); } });
    expect(() => publisher.publish(buildClickEvent('abcDEF1', undefined))).not.toThrow();
    // Se a rejeição não fosse tratada, o vitest acusaria "unhandled rejection" aqui.
    await new Promise((r) => setTimeout(r, 10));
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm run test:unit`.

- [ ] **Passo 3: implemente** `src/events/clickEvent.ts`

```ts
import { randomUUID } from 'node:crypto';
import { z } from 'zod';

export const TOPIC_CLICKS = 'link.clicked';
export const TOPIC_CLICKS_DLQ = 'link.clicked.dlq';

const schema = z.object({
  v: z.literal(1),
  eventId: z.uuid(),
  code: z.string().regex(/^[0-9A-Za-z]{7}$/),
  occurredAt: z.iso.datetime(),
  userAgent: z.string().max(512),
});

export type ClickEvent = z.infer<typeof schema>;

export function buildClickEvent(code: string, userAgent: string | undefined, now = new Date()): ClickEvent {
  return { v: 1, eventId: randomUUID(), code, occurredAt: now.toISOString(), userAgent: (userAgent ?? '').slice(0, 512) };
}

export function parseClickEvent(raw: Buffer | string | null | undefined): ClickEvent {
  if (raw === null || raw === undefined) throw new Error('mensagem sem valor');
  return schema.parse(JSON.parse(raw.toString()));
}
```

- [ ] **Passo 4: implemente** `src/events/kafka.ts`

```ts
import kafkaLib from '@confluentinc/kafka-javascript';
import type { BaseConfig } from '../config.js';

const { Kafka } = kafkaLib.KafkaJS;

export interface OutgoingMessage {
  key: string | null;
  value: string;
  headers?: Record<string, string>;
}

export interface MessageSender {
  send(record: { topic: string; messages: OutgoingMessage[] }): Promise<unknown>;
}

export function createKafka(cfg: Pick<BaseConfig, 'KAFKA_BROKERS' | 'KAFKA_SSL'>, clientId: string) {
  return new Kafka({ kafkaJS: { clientId, brokers: cfg.KAFKA_BROKERS, ssl: cfg.KAFKA_SSL } });
}
```

Se o TypeScript reclamar do *default import*, troque por `import { KafkaJS } from '@confluentinc/kafka-javascript'` e use `KafkaJS.Kafka`. A API "estilo KafkaJS" coloca as opções dentro de `kafkaJS: {...}`; confira no [guia oficial](https://docs.confluent.io/platform/current/clients/confluent-kafka-javascript/docs/index.html).

- [ ] **Passo 5: implemente** `src/events/clickPublisher.ts`

```ts
import { logger } from '../logger.js';
import { TOPIC_CLICKS, type ClickEvent } from './clickEvent.js';
import type { MessageSender } from './kafka.js';

export interface ClickPublisher {
  publish(event: ClickEvent): void;
}

// Fire-and-forget: o redirect não espera o Kafka. Se o broker cair, o cliente (librdkafka)
// segura as mensagens em memória e tenta de novo por alguns minutos; depois disso, o erro é só logado.
export function createClickPublisher(sender: MessageSender): ClickPublisher {
  return {
    publish(event) {
      sender
        .send({ topic: TOPIC_CLICKS, messages: [{ key: event.code, value: JSON.stringify(event) }] })
        .catch((err) => logger.error({ err, eventId: event.eventId }, 'falha ao publicar clique'));
    },
  };
}
```

- [ ] **Passo 6: rode e veja passar.** `npm run test:unit && npm run typecheck && npm run lint`.

- [ ] **Passo 7: commit.** `git add -A && git commit -m "feat: evento de clique e publicação fire-and-forget"`

**Pronto quando:** os testes passam e o typecheck aceita o import do cliente Kafka.

---

## Tarefa 1.8: aplicação HTTP

**Arquivos:**
- Criar `src/http/apiKey.ts` e `src/http/app.ts`
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
  publicBaseUrl: string;
  version: string;
  isReady: () => Promise<boolean>;
}
createApp(deps: AppDeps): express.Express
requireApiKey(expected: string): RequestHandler
```

**Endpoints:**

| Método e rota | Auth | Resposta |
|---|---|---|
| `GET /healthz` | não | `200 {status:'ok', version}` (liveness) |
| `GET /readyz` | não | `200` ou `503 {ready}`. Checa só o Postgres, porque o Redis é opcional |
| `POST /links` `{url}` | `x-api-key` + rate limit | `201 {code, shortUrl, url}`, `400 invalid_url`, `401` ou `429` |
| `GET /links/:code/stats` | `x-api-key` | `200 LinkStats` (cache de 60s) ou `404` |
| `GET /:code` | não | `302 Location` (+ evento) ou `404` |

**Conceitos:**
- **Ordem das rotas.**
- **`trust proxy`:** atrás do ALB, `req.ip` precisa vir do `X-Forwarded-For`.
- **Comparação de segredo em tempo constante.**
- **O rate limit vem antes da autenticação:** isso também freia quem tenta adivinhar a API key por força bruta.

- [ ] **Passo 1: escreva o teste** `test/integration/app.test.ts`

```ts
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import type pg from 'pg';
import type { Redis } from 'ioredis';
import type { Express } from 'express';
import { createApp, type AppDeps } from '../../src/http/app.js';
import { createLinkRepository } from '../../src/links/repository.js';
import { createLinkCache } from '../../src/cache/linkCache.js';
import { createJsonCache } from '../../src/cache/jsonCache.js';
import { createRedis } from '../../src/cache/redis.js';
import { rateLimit } from '../../src/http/rateLimit.js';
import { createClickPublisher } from '../../src/events/clickPublisher.js';
import type { ClickEvent } from '../../src/events/clickEvent.js';
import { connectedRedis, DEAD_REDIS_URL, migratedPool } from './helpers.js';

const API_KEY = 'test-api-key-0123456789';
let pool: pg.Pool;
let redis: Redis;
let deadRedis: Redis;

beforeAll(async () => {
  pool = await migratedPool();
  redis = await connectedRedis();
  deadRedis = createRedis(DEAD_REDIS_URL);
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

function buildApp(overrides: Partial<AppDeps> = {}, cacheRedis: Redis = redis) {
  const published: ClickEvent[] = [];
  const deps: AppDeps = {
    links: createLinkRepository(pool),
    linkCache: createLinkCache(cacheRedis, 60),
    statsCache: createJsonCache(cacheRedis, 'stats', 60),
    publisher: { publish: (e) => { published.push(e); } },
    rateLimiter: rateLimit(cacheRedis, { limit: 100, windowSeconds: 60 }),
    apiKey: API_KEY,
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

describe('POST /links', () => {
  it('exige API key', async () => {
    const res = await request(buildApp().app).post('/links').send({ url: 'https://example.com' });
    expect(res.status).toBe(401);
  });

  it('rejeita URLs perigosas ou inválidas', async () => {
    const { app } = buildApp();
    for (const url of ['javascript:alert(1)', 'data:text/html,oi', 'nao-e-url', `https://x.com/${'a'.repeat(3000)}`]) {
      const res = await request(app).post('/links').set('x-api-key', API_KEY).send({ url });
      expect(res.status, url).toBe(400);
    }
  });

  it('cria o link e devolve a URL curta', async () => {
    const res = await request(buildApp().app).post('/links').set('x-api-key', API_KEY).send({ url: 'https://example.com' });
    expect(res.status).toBe(201);
    expect(res.body.code).toMatch(/^[0-9A-Za-z]{7}$/);
    expect(res.body.shortUrl).toBe(`http://short.test/${res.body.code}`);
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

  it('continua criando links com o Redis fora do ar', async () => {
    const { app } = buildApp({}, deadRedis);
    expect((await request(app).post('/links').set('x-api-key', API_KEY).send({ url: 'https://example.com' })).status).toBe(201);
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
});

describe('GET /links/:code/stats', () => {
  it('exige API key e devolve 404 para inexistente', async () => {
    const { app } = buildApp();
    expect((await request(app).get('/links/abcDEF1/stats')).status).toBe(401);
    expect((await request(app).get('/links/abcDEF1/stats').set('x-api-key', API_KEY)).status).toBe(404);
  });

  it('devolve os agregados', async () => {
    const { app } = buildApp();
    const code = await createLink(app);
    await pool.query('INSERT INTO click_stats_daily VALUES ($1, current_date, 5)', [code]);
    await pool.query("INSERT INTO click_stats_browser VALUES ($1, 'Chrome', 3), ($1, 'curl', 2)", [code]);
    const res = await request(app).get(`/links/${code}/stats`).set('x-api-key', API_KEY);
    expect(res.status).toBe(200);
    expect(res.body.totalClicks).toBe(5);
    expect(res.body.browsers).toEqual([{ browser: 'Chrome', clicks: 3 }, { browser: 'curl', clicks: 2 }]);
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm run test:integration`.

- [ ] **Passo 3: implemente** `src/http/apiKey.ts`

```ts
import { createHash, timingSafeEqual } from 'node:crypto';
import type { RequestHandler } from 'express';

const digest = (value: string) => createHash('sha256').update(value).digest();

// Compara hashes de tamanho fixo em tempo constante: não vaza, pelo tempo de resposta, quantos caracteres acertou.
export function requireApiKey(expected: string): RequestHandler {
  const expectedDigest = digest(expected);
  return (req, res, next) => {
    if (!timingSafeEqual(digest(req.get('x-api-key') ?? ''), expectedDigest)) {
      res.status(401).json({ error: 'unauthorized' });
      return;
    }
    next();
  };
}
```

- [ ] **Passo 4: implemente** `src/http/app.ts`

```ts
import express, { type ErrorRequestHandler, type RequestHandler } from 'express';
import { pinoHttp } from 'pino-http';
import { logger } from '../logger.js';
import type { LinkCache } from '../cache/linkCache.js';
import type { JsonCache } from '../cache/jsonCache.js';
import type { ClickPublisher } from '../events/clickPublisher.js';
import { buildClickEvent } from '../events/clickEvent.js';
import { isValidCode } from '../links/code.js';
import { normalizeTargetUrl } from '../links/url.js';
import { createShortLink } from '../links/service.js';
import type { LinkRepository, LinkStats } from '../links/repository.js';
import { requireApiKey } from './apiKey.js';

export interface AppDeps {
  links: LinkRepository;
  linkCache: LinkCache;
  statsCache: JsonCache<LinkStats>;
  publisher: ClickPublisher;
  rateLimiter: RequestHandler;
  apiKey: string;
  publicBaseUrl: string;
  version: string;
  isReady: () => Promise<boolean>;
}

export function createApp(deps: AppDeps): express.Express {
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', 1); // exatamente 1 proxy na frente (o ALB): req.ip = IP real do cliente
  app.use(pinoHttp({ logger, autoLogging: { ignore: (req) => req.url === '/healthz' || req.url === '/readyz' } }));
  app.use(express.json({ limit: '10kb' }));
  const auth = requireApiKey(deps.apiKey);

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
    const code = await createShortLink(deps.links, url);
    await deps.linkCache.setUrl(code, url); // aquece o cache e sobrescreve um eventual "não existe"
    res.status(201).json({ code, shortUrl: `${deps.publicBaseUrl}/${code}`, url });
  });

  app.get('/links/:code/stats', auth, async (req, res) => {
    const { code } = req.params as { code: string }; // @types/express 5 tipa params como string | string[]
    if (!isValidCode(code)) {
      res.status(404).json({ error: 'not_found' });
      return;
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

- [ ] **Passo 5: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 6: commit.** `git add -A && git commit -m "feat: API HTTP (criação, redirect, stats e health)"`

**Pronto quando:** todos os testes passam, incluindo "Redis fora", "Kafka travado" e "IP real".

---

## Tarefa 1.9: entrypoints `api` e `setup`, com graceful shutdown

**Arquivos:** criar `src/shutdown.ts`, `src/api.ts` e `src/setup.ts`.

**Interfaces que esta tarefa entrega:** `onShutdown(steps: Array<() => Promise<unknown>>, timeoutMs?)`.

**Conceitos:**
- **SIGTERM é como o Kubernetes pede para o processo sair.** Ele termina o que está fazendo, fecha as conexões e sai. Se demorar demais, leva SIGKILL.
- **Keep-alive maior que o do ALB**, para evitar 502 intermitente.
- **O setup idempotente** pode rodar a cada deploy sem efeito colateral.

- [ ] **Passo 1: crie** `src/shutdown.ts`

```ts
import { logger } from './logger.js';

export function onShutdown(steps: Array<() => Promise<unknown>>, timeoutMs = 25_000): void {
  let shuttingDown = false;
  const shutdown = async (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    logger.info({ signal }, 'encerrando');
    setTimeout(() => {
      logger.error('shutdown passou do tempo; forçando saída');
      process.exit(1);
    }, timeoutMs).unref();
    for (const step of steps) {
      try {
        await step();
      } catch (err) {
        logger.error({ err }, 'erro durante o shutdown');
      }
    }
    logger.info('encerrado');
    process.exit(0);
  };
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
}
```

- [ ] **Passo 2: crie** `src/api.ts`

```ts
import { loadApiConfig } from './config.js';
import { logger } from './logger.js';
import { createPool } from './db/pool.js';
import { createRedis } from './cache/redis.js';
import { createLinkCache } from './cache/linkCache.js';
import { createJsonCache } from './cache/jsonCache.js';
import { createLinkRepository, type LinkStats } from './links/repository.js';
import { rateLimit } from './http/rateLimit.js';
import { createApp } from './http/app.js';
import { createKafka } from './events/kafka.js';
import { createClickPublisher } from './events/clickPublisher.js';
import { onShutdown } from './shutdown.js';

const config = loadApiConfig();
const pool = createPool(config);
const redis = createRedis(config.REDIS_URL);
const producer = createKafka(config, 'shortener-api').producer({ kafkaJS: { idempotent: true } });
await producer.connect();

const app = createApp({
  links: createLinkRepository(pool),
  linkCache: createLinkCache(redis, config.CACHE_TTL_SECONDS),
  statsCache: createJsonCache<LinkStats>(redis, 'stats', 60),
  publisher: createClickPublisher(producer),
  rateLimiter: rateLimit(redis, { limit: config.RATE_LIMIT_PER_MINUTE, windowSeconds: 60 }),
  apiKey: config.API_KEY,
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

- [ ] **Passo 3: crie** `src/setup.ts`

```ts
import path from 'node:path';
import { loadBaseConfig } from './config.js';
import { logger } from './logger.js';
import { createPool } from './db/pool.js';
import { runMigrations } from './db/migrate.js';
import { createKafka } from './events/kafka.js';
import { TOPIC_CLICKS, TOPIC_CLICKS_DLQ } from './events/clickEvent.js';

const config = loadBaseConfig();

const pool = createPool(config);
const applied = await runMigrations(pool, path.resolve('migrations'));
logger.info({ applied }, 'migrations ok');
await pool.end();

const admin = createKafka(config, 'shortener-setup').admin();
await admin.connect();
const existing = await admin.listTopics();
const missing = [
  { topic: TOPIC_CLICKS, numPartitions: 3 },
  { topic: TOPIC_CLICKS_DLQ, numPartitions: 1 },
].filter((t) => !existing.includes(t.topic));
if (missing.length > 0) {
  await admin.createTopics({
    topics: missing.map((t) => ({ ...t, replicationFactor: config.KAFKA_REPLICATION_FACTOR })),
  });
}
logger.info({ created: missing.map((t) => t.topic) }, 'tópicos ok');
await admin.disconnect();
```

- [ ] **Passo 4: teste manual** (com o compose de pé, em dois terminais)

```bash
npm run setup          # rode 2x: na segunda, "applied: []" e "created: []"
npm run dev:api        # terminal 1
```

```bash
export KEY=dev-api-key-change-me-0123456789
curl -s localhost:3000/healthz
curl -s -X POST localhost:3000/links -H "x-api-key: $KEY" -H 'content-type: application/json' \
  -d '{"url":"https://example.com"}' | jq
curl -si localhost:3000/<code> | head -5          # HTTP/1.1 302 + Location
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic link.clicked --from-beginning --max-messages 1 --property print.key=true   # o evento do clique
```

Depois aperte Ctrl+C no terminal da api: o log mostra "encerrando" e em seguida "encerrado".

- [ ] **Passo 5: commit.** `git add -A && git commit -m "feat: entrypoints api e setup com graceful shutdown"`

**Pronto quando:** o redirect funciona, o evento aparece no tópico e o Ctrl+C encerra de forma limpa.

---

## Tarefa 1.10: analytics (navegador e processamento idempotente)

**Arquivos:**
- Criar `src/analytics/browser.ts` e `src/analytics/processClick.ts`
- Testes: `test/unit/browser.test.ts` e `test/integration/processClick.test.ts`

**Interfaces que esta tarefa entrega:**
- `detectBrowser(userAgent: string): string`
- `processClick(pool, event): Promise<'processed' | 'duplicate'>`
- `ProcessResult`

**Conceitos:**
- **Entrega "pelo menos uma vez" + consumidor idempotente = efeito "exatamente uma vez".**
- **Uma transação para tudo:** ou conta e marca o evento, ou não faz nenhum dos dois.

- [ ] **Passo 1: escreva os testes**

`test/unit/browser.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { detectBrowser } from '../../src/analytics/browser.js';

describe('detectBrowser', () => {
  it.each([
    ['Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36', 'Chrome'],
    ['Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0', 'Edge'],
    ['Mozilla/5.0 (Macintosh; Intel Mac OS X 14.7; rv:131.0) Gecko/20100101 Firefox/131.0', 'Firefox'],
    ['Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1', 'Safari'],
    ['Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Googlebot/2.1; +http://www.google.com/bot.html) Chrome/129.0.0.0 Safari/537.36', 'bot'],
    ['curl/8.7.1', 'curl'],
    ['', 'unknown'],
    ['algo-estranho/1.0', 'other'],
  ])('%s → %s', (ua, expected) => expect(detectBrowser(ua)).toBe(expected));
});
```

`test/integration/processClick.test.ts`:

```ts
import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type pg from 'pg';
import { processClick } from '../../src/analytics/processClick.js';
import type { ClickEvent } from '../../src/events/clickEvent.js';
import { migratedPool } from './helpers.js';

let pool: pg.Pool;
beforeAll(async () => { pool = await migratedPool(); });
afterAll(() => pool.end());
beforeEach(async () => {
  await pool.query('TRUNCATE links, click_stats_daily, click_stats_browser, processed_events');
  await pool.query("INSERT INTO links (code, url) VALUES ('abcDEF1', 'https://example.com')");
});

const event = (o: Partial<ClickEvent> = {}): ClickEvent => ({
  v: 1, eventId: randomUUID(), code: 'abcDEF1', occurredAt: '2026-10-12T15:00:00.000Z', userAgent: 'curl/8.7.1', ...o,
});

const clicks = async () =>
  (await pool.query("SELECT to_char(day,'YYYY-MM-DD') AS day, clicks::int FROM click_stats_daily ORDER BY day")).rows;

describe('processClick', () => {
  it('agrega por dia (UTC) e por navegador', async () => {
    await processClick(pool, event());
    await processClick(pool, event({ userAgent: 'Mozilla/5.0 Gecko/20100101 Firefox/131.0' }));
    await processClick(pool, event({ occurredAt: '2026-10-13T02:30:00.000Z' }));
    expect(await clicks()).toEqual([{ day: '2026-10-12', clicks: 2 }, { day: '2026-10-13', clicks: 1 }]);
    // COLLATE "C": ordenação byte a byte, igual em qualquer máquina (maiúsculas antes de minúsculas)
    const { rows } = await pool.query('SELECT browser, clicks::int FROM click_stats_browser ORDER BY browser COLLATE "C"');
    expect(rows).toEqual([{ browser: 'Firefox', clicks: 1 }, { browser: 'curl', clicks: 2 }]);
  });

  it('evento repetido é contado uma vez só', async () => {
    const e = event();
    expect(await processClick(pool, e)).toBe('processed');
    expect(await processClick(pool, e)).toBe('duplicate');
    expect(await clicks()).toEqual([{ day: '2026-10-12', clicks: 1 }]);
  });

  it('se falhar, não deixa rastro (o evento pode ser reprocessado)', async () => {
    const e = event({ code: 'zzzzzz9' }); // link inexistente: viola a foreign key
    await expect(processClick(pool, e)).rejects.toThrow();
    const { rowCount } = await pool.query('SELECT 1 FROM processed_events WHERE event_id = $1', [e.eventId]);
    expect(rowCount).toBe(0);
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm test`.

- [ ] **Passo 3: implemente** `src/analytics/browser.ts`

```ts
// A ordem importa: o UA do Edge contém "Chrome" e "Safari"; o do Chrome contém "Safari"; bots imitam o Chrome.
export function detectBrowser(userAgent: string): string {
  if (!userAgent) return 'unknown';
  if (/bot|crawler|spider/i.test(userAgent)) return 'bot';
  if (/^curl\//i.test(userAgent)) return 'curl';
  if (/Edg\//.test(userAgent)) return 'Edge';
  if (/OPR\//.test(userAgent)) return 'Opera';
  if (/Firefox\//.test(userAgent)) return 'Firefox';
  if (/Chrome\//.test(userAgent)) return 'Chrome';
  if (/Safari\//.test(userAgent)) return 'Safari';
  return 'other';
}
```

- [ ] **Passo 4: implemente** `src/analytics/processClick.ts`

```ts
import type pg from 'pg';
import type { ClickEvent } from '../events/clickEvent.js';
import { detectBrowser } from './browser.js';

export type ProcessResult = 'processed' | 'duplicate';

export async function processClick(pool: pg.Pool, event: ClickEvent): Promise<ProcessResult> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // Se outro worker estiver processando o mesmo evento, este INSERT espera o COMMIT dele e então não insere nada.
    const marked = await client.query(
      'INSERT INTO processed_events (event_id) VALUES ($1) ON CONFLICT DO NOTHING',
      [event.eventId],
    );
    if (marked.rowCount === 0) {
      await client.query('ROLLBACK');
      return 'duplicate';
    }
    await client.query(
      `INSERT INTO click_stats_daily (code, day, clicks) VALUES ($1, $2, 1)
       ON CONFLICT (code, day) DO UPDATE SET clicks = click_stats_daily.clicks + 1`,
      [event.code, event.occurredAt.slice(0, 10)], // occurredAt sempre em UTC ("...Z")
    );
    await client.query(
      `INSERT INTO click_stats_browser (code, browser, clicks) VALUES ($1, $2, 1)
       ON CONFLICT (code, browser) DO UPDATE SET clicks = click_stats_browser.clicks + 1`,
      [event.code, detectBrowser(event.userAgent)],
    );
    await client.query('COMMIT');
    return 'processed';
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw err;
  } finally {
    client.release();
  }
}
```

- [ ] **Passo 5: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 6: commit.** `git add -A && git commit -m "feat: processamento idempotente de cliques"`

**Pronto quando:** o teste "evento repetido" passa.

---

## Tarefa 1.11: worker (consumidor, retries, DLQ)

**Arquivos:**
- Criar `src/worker/handleMessage.ts` e `src/worker.ts`
- Teste: `test/unit/handleMessage.test.ts`

**Interfaces que esta tarefa entrega:**

```ts
handleMessage(
  deps: { process: (e: ClickEvent) => Promise<ProcessResult>; dlq: MessageSender; maxAttempts?: number; sleep?: (ms: number) => Promise<void> },
  message: { key?: Buffer | null; value: Buffer | null },
): Promise<'processed' | 'duplicate' | 'dead-lettered'>
```

**Conceitos:**
- **Consumer group:** as partições são divididas entre as réplicas do worker.
- **Retry com backoff exponencial.**
- **Dead Letter Queue:** a mensagem problemática sai do caminho e não trava a fila.
- **Commit de offset só depois de tratar a mensagem.** Se a DLQ também falhar, o erro sobe, o offset não é commitado e a mensagem volta.

- [ ] **Passo 1: escreva o teste** `test/unit/handleMessage.test.ts`

```ts
import { describe, expect, it, vi } from 'vitest';
import { handleMessage } from '../../src/worker/handleMessage.js';
import { buildClickEvent } from '../../src/events/clickEvent.js';
import type { OutgoingMessage } from '../../src/events/kafka.js';

const noSleep = async () => {};
const validMessage = () => ({
  key: Buffer.from('abcDEF1'),
  value: Buffer.from(JSON.stringify(buildClickEvent('abcDEF1', 'curl/8.7.1'))),
});
function fakeDlq() {
  const sent: { topic: string; messages: OutgoingMessage[] }[] = [];
  return { sent, send: async (r: { topic: string; messages: OutgoingMessage[] }) => { sent.push(r); } };
}

describe('handleMessage', () => {
  it('processa mensagem válida', async () => {
    const dlq = fakeDlq();
    const process = vi.fn().mockResolvedValue('processed');
    expect(await handleMessage({ process, dlq, sleep: noSleep }, validMessage())).toBe('processed');
    expect(dlq.sent).toHaveLength(0);
  });

  it('JSON inválido vai direto para a DLQ, sem tentar processar', async () => {
    const dlq = fakeDlq();
    const process = vi.fn();
    const result = await handleMessage({ process, dlq, sleep: noSleep }, { key: null, value: Buffer.from('{lixo') });
    expect(result).toBe('dead-lettered');
    expect(process).not.toHaveBeenCalled();
    expect(dlq.sent[0]?.topic).toBe('link.clicked.dlq');
  });

  it('tenta de novo em falha temporária', async () => {
    const dlq = fakeDlq();
    const process = vi.fn().mockRejectedValueOnce(new Error('db piscou')).mockResolvedValueOnce('processed');
    expect(await handleMessage({ process, dlq, sleep: noSleep }, validMessage())).toBe('processed');
    expect(process).toHaveBeenCalledTimes(2);
  });

  it('desiste após 3 tentativas e manda para a DLQ com o motivo', async () => {
    const dlq = fakeDlq();
    const process = vi.fn().mockRejectedValue(new Error('db fora'));
    expect(await handleMessage({ process, dlq, sleep: noSleep }, validMessage())).toBe('dead-lettered');
    expect(process).toHaveBeenCalledTimes(3);
    expect(dlq.sent[0]?.messages[0]).toMatchObject({ key: 'abcDEF1', headers: { error: 'db fora' } });
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm run test:unit`.

- [ ] **Passo 3: implemente** `src/worker/handleMessage.ts`

```ts
import { setTimeout as delay } from 'node:timers/promises';
import { parseClickEvent, TOPIC_CLICKS_DLQ, type ClickEvent } from '../events/clickEvent.js';
import type { MessageSender } from '../events/kafka.js';
import type { ProcessResult } from '../analytics/processClick.js';
import { logger } from '../logger.js';

export type HandleResult = ProcessResult | 'dead-lettered';

interface Deps {
  process: (event: ClickEvent) => Promise<ProcessResult>;
  dlq: MessageSender;
  maxAttempts?: number;
  sleep?: (ms: number) => Promise<unknown>;
}

interface IncomingMessage {
  key?: Buffer | null;
  value: Buffer | null;
}

export async function handleMessage(deps: Deps, message: IncomingMessage): Promise<HandleResult> {
  let event: ClickEvent;
  try {
    event = parseClickEvent(message.value);
  } catch (err) {
    await sendToDlq(deps.dlq, message, err); // mensagem malformada nunca vai funcionar: não adianta tentar de novo
    return 'dead-lettered';
  }

  const maxAttempts = deps.maxAttempts ?? 3;
  const sleep = deps.sleep ?? delay;
  for (let attempt = 1; ; attempt++) {
    try {
      return await deps.process(event);
    } catch (err) {
      if (attempt >= maxAttempts) {
        await sendToDlq(deps.dlq, message, err);
        return 'dead-lettered';
      }
      logger.warn({ err, attempt, eventId: event.eventId }, 'falha ao processar; tentando de novo');
      await sleep(200 * 2 ** (attempt - 1)); // 200ms, 400ms...
    }
  }
}

async function sendToDlq(dlq: MessageSender, message: IncomingMessage, err: unknown): Promise<void> {
  const reason = err instanceof Error ? err.message : String(err);
  logger.error({ reason }, 'enviando mensagem para a DLQ');
  await dlq.send({
    topic: TOPIC_CLICKS_DLQ,
    messages: [{ key: message.key?.toString() ?? null, value: message.value?.toString() ?? '', headers: { error: reason } }],
  });
}
```

Para pensar: aqui, uma queda longa do banco manda tudo para a DLQ depois de 3 tentativas. Em produção, costuma-se separar **erro permanente** (que vai para a DLQ) de **erro transitório** (pausa o consumo e tenta depois). Fica como reflexão; não precisa implementar.

- [ ] **Passo 4: implemente** `src/worker.ts`

```ts
import http from 'node:http';
import { loadWorkerConfig } from './config.js';
import { logger } from './logger.js';
import { createPool } from './db/pool.js';
import { createKafka } from './events/kafka.js';
import { TOPIC_CLICKS } from './events/clickEvent.js';
import { processClick } from './analytics/processClick.js';
import { handleMessage } from './worker/handleMessage.js';
import { onShutdown } from './shutdown.js';

const config = loadWorkerConfig();
const pool = createPool(config);
const kafka = createKafka(config, 'shortener-worker');
const dlqProducer = kafka.producer({ kafkaJS: { idempotent: true } });
const consumer = kafka.consumer({ kafkaJS: { groupId: 'shortener-analytics', fromBeginning: true } });

await dlqProducer.connect();
await consumer.connect();
await consumer.subscribe({ topics: [TOPIC_CLICKS] });
await consumer.run({
  eachMessage: async ({ partition, message }) => {
    const result = await handleMessage({ process: (event) => processClick(pool, event), dlq: dlqProducer }, message);
    logger.debug({ partition, offset: message.offset, result }, 'mensagem tratada');
  },
});

// Endpoint mínimo para o livenessProbe do Kubernetes.
const health = http.createServer((_req, res) => {
  res.writeHead(200, { 'content-type': 'text/plain' }).end('ok');
});
health.listen(config.WORKER_HEALTH_PORT);
logger.info('worker consumindo');

onShutdown([
  () => consumer.disconnect(), // devolve as partições ao grupo; outra réplica assume na hora
  () => dlqProducer.disconnect(),
  () => new Promise<void>((resolve) => health.close(() => resolve())),
  () => pool.end(),
]);
```

- [ ] **Passo 5: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 6: teste ponta a ponta local** (api e worker em terminais separados)

```bash
npm run dev:worker     # terminal 2
for i in 1 2 3 4 5; do curl -s -o /dev/null -A "curl/8.7.1" localhost:3000/<code>; done
sleep 2
curl -s localhost:3000/links/<code>/stats -H "x-api-key: $KEY" | jq   # totalClicks: 5 (+ o clique da tarefa 1.9)
```

O cache de stats dura 60 segundos. Se você consultou antes, espere 1 minuto.

- [ ] **Passo 7: commit.** `git add -A && git commit -m "feat: worker com retry, DLQ e graceful shutdown"`

**Pronto quando:** 5 cliques viram +5 nas estatísticas.

---

## Tarefa 1.12: Dockerfile e o app inteiro em containers

**Arquivos:** criar `Dockerfile` e `.dockerignore`. O `docker-compose.yml` não muda: o profile `app` já existe.

**Conceitos:**
- **Build multi-stage:** a imagem final não carrega devDependencies nem o código TypeScript.
- **Usuário não-root.**
- **CA do RDS embutida na imagem.**
- **`ca-certificates`:** sem ele, o TLS com o MSK falha. A imagem `slim` não traz esse pacote.

- [ ] **Passo 1: crie `.dockerignore`**

```
node_modules
dist
.git
.env
infra
deploy
docs
load
test
```

- [ ] **Passo 2: crie o `Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1
FROM node:24-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM deps AS build
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:24-slim AS runtime
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV NODE_ENV=production
# CA da AWS para validar o TLS do RDS (usada via DATABASE_SSL_CA_FILE)
ADD --chmod=644 https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/certs/rds-global-bundle.pem
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
COPY migrations ./migrations
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
USER node
EXPOSE 3000
CMD ["node", "dist/api.js"]
```

- [ ] **Passo 3: suba tudo em container** (pare antes o `dev:api` e o `dev:worker`)

```bash
docker compose --profile app up -d --build
docker compose --profile app ps          # setup "exited (0)", api e worker "running"
docker compose logs setup                # migrations ok / tópicos ok
curl -s localhost:3000/healthz
```

Repita o fluxo de criar link → redirect → stats contra os containers.

- [ ] **Passo 4: experimentos rápidos de resiliência** (mais deles na Fase 9)

```bash
docker compose stop valkey     # o redirect continua 302 (veja o warn no log da api)
docker compose start valkey
docker compose stop worker     # os cliques ficam acumulados no Kafka...
for i in $(seq 1 20); do curl -s -o /dev/null localhost:3000/<code>; done
docker compose start worker    # ...e são processados assim que ele volta
```

- [ ] **Passo 5: commit.** `git add -A && git commit -m "feat: Dockerfile multi-stage e app completo no compose"`

**Pronto quando:** o fluxo completo funciona em containers e os dois experimentos se comportam como descrito.

---

## Checkpoint da Fase 1

- [ ] `npm test`, `npm run typecheck` e `npm run lint` passam
- [ ] O app funciona em dois modos: código no host com infra no compose, e tudo em container
- [ ] Você consegue explicar:
  - Por que o redirect não espera o Kafka
  - Como o worker evita contar o mesmo clique duas vezes
  - Por que `/readyz` não checa o Redis
