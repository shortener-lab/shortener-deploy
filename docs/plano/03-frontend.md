# Fase 3: painel React (`shortener-web`)

**Status:** concluída em 2026-10-12 em `~/Documents/projects/shortener-web` (um commit por tarefa). Problemas encontrados na execução: [achados.md](achados.md).
**Entrega:** o painel React em `~/Documents/projects/shortener-web`. Ele tem login OIDC (PKCE), criação de links, a lista "meus links" e uma página de estatísticas. Vem com testes (unit, componente e e2e local) e com uma imagem nginx não-root que lê a configuração em runtime.
**Custo:** zero. Tudo roda no seu Mac.
**Ciclo de trabalho:** a api, o worker e o IdP mock rodam no compose do `shortener-api` (Fase 2). O painel roda no host com `npm run dev` (Vite, porta `5173`). No fim da fase, o painel também roda em container (porta `8081`).
**Pré-requisito:** a Fase 2 concluída. A api precisa aceitar Bearer do mock, ter `/me/links` e liberar CORS para `http://localhost:5173` e `http://localhost:8081`.

Convenção de TDD em cada tarefa:
1. Escreva o teste.
2. Rode e veja falhar.
3. Implemente.
4. Rode e veja passar.
5. Faça o commit.

Todo o código desta fase fica no repositório **novo** `shortener-web`, que é pasta irmã do `shortener-api`. Os commits ficam no repositório local. O GitHub entra só na Fase 4.

### Versões conferidas em 2026-10-12

| Pacote | Versão usada | Observação |
|---|---|---|
| `create-vite` (template `react-ts`) | 9.x | Gera React 19, Vite 8, TypeScript 6 e **Oxlint** (não ESLint) |
| `react-router` | **7** (fixado com `@7`) | A 8 já saiu. O spec pede a 7, e o modo declarativo é o mesmo. Subir para a 8 fica como extensão |
| `@tanstack/react-query` | 5 | `useInfiniteQuery` com `initialPageParam` e `getNextPageParam` |
| `oidc-client-ts` / `react-oidc-context` | 3 / 3 | `AuthProvider`, `useAuth`, `AuthContext` exportado |
| `zod` | 4 | `z.url()`, `z.iso.datetime()`, `z.prettifyError()` |
| `msw` | **2** (fixado com `@2`) | A 3 já saiu e mudou opções do `listen`. O spec pede a 2 |
| `vitest` | atual | `environment: 'jsdom'` e `setupFiles` |
| `@playwright/test` | atual | Instalado pelo `npm init playwright` |
| `nginxinc/nginx-unprivileged` | `1.30.5-alpine3.24` | Linha *stable*. UID 101, porta 8080, pid e temporários em `/tmp` |

Se alguma versão tiver mudado quando você implementar, use a mais nova da **mesma major** da tabela.

---

## Tarefa 3.1: esqueleto do projeto pela CLI

**Arquivos:**
- Gerados pela CLI (não crie à mão): `package.json`, `tsconfig.json`, `tsconfig.app.json`, `tsconfig.node.json`, `vite.config.ts`, `index.html`, `.oxlintrc.json`, `.gitignore`, `src/*`, `public/*`, `playwright.config.ts`
- Alterar: `vite.config.ts`, `tsconfig.app.json` e `tsconfig.node.json`
- Criar: `.nvmrc`, `src/test/setup.ts`, `src/test/server.ts` e `src/test/setup.test.tsx`

**Interfaces que esta tarefa entrega:**
- Os scripts `dev`, `build`, `lint`, `typecheck`, `test`, `test:watch` e `test:e2e`
- `server` (MSW, `setupServer()` sem handlers), `TEST_API` e `TEST_AUTHORITY` em `src/test/server.ts`

**Conceitos:**
- **SPA (*single-page application*):** o servidor entrega sempre o mesmo `index.html` e um bundle JS. As "páginas" são rotas resolvidas no navegador pelo React Router. Por isso o nginx, mais adiante, precisa devolver o `index.html` para qualquer caminho que não seja arquivo.
- **Vite:** em dev, serve os módulos direto e faz *hot reload*. No `build`, gera `dist/` com arquivos de nome com hash (`assets/index-3f9a1c.js`).
- **Vitest + jsdom:** os testes rodam no Node, com um DOM simulado. Não precisam de navegador.
- **MSW (*Mock Service Worker*):** intercepta o `fetch` no nível da rede. O código de produção não sabe que está sendo testado: ele chama `fetch` de verdade, e o MSW responde.

- [ ] **Passo 1: gere o projeto com a CLI do Vite**

```bash
cd ~/Documents/projects
npm create vite@latest shortener-web -- --template react-ts --no-interactive --no-immediate
cd shortener-web
git init -b main
echo "24" > .nvmrc
nvm use
npm install
```

`--no-interactive` evita as perguntas, e `--no-immediate` não sobe o servidor de dev no fim. O template atual já vem com o Oxlint (`npm run lint`), e vamos ficar com ele. Existe a flag `--eslint` para quem prefere ESLint, mas o padrão da CLI basta aqui.

- [ ] **Passo 2: confira o que a CLI gerou**

```bash
ls -a
# .gitignore .nvmrc .oxlintrc.json README.md index.html node_modules package-lock.json package.json
# public src tsconfig.app.json tsconfig.json tsconfig.node.json vite.config.ts
npm run dev    # abra http://localhost:5173, veja a página do template e pare com Ctrl+C
npm run build && npm run lint
```

- [ ] **Passo 3: ajuste o `package.json` pela CLI do npm**

```bash
npm pkg set name=shortener-web version=0.1.0 'engines.node=>=24'
npm pkg set 'scripts.typecheck=tsc -b' 'scripts.test=vitest run' 'scripts.test:watch=vitest' 'scripts.test:e2e=playwright test'
```

- [ ] **Passo 4: instale as dependências**

```bash
npm i react-router@7 @tanstack/react-query oidc-client-ts react-oidc-context zod
npm i -D vitest jsdom @testing-library/react @testing-library/dom @testing-library/user-event \
  @testing-library/jest-dom msw@2
```

O `@testing-library/dom` é *peer dependency* do `@testing-library/react`. Por isso ele entra explicitamente.

- [ ] **Passo 5: inicialize o Playwright pela CLI dele**

```bash
npm init playwright@latest -- --quiet --lang=ts --browser=chromium --no-examples
sed -i '' "s|testDir: './tests'|testDir: './e2e'|" playwright.config.ts
```

O `create-playwright` atual não tem mais `--test-dir` (no modo `--quiet` ele usa `tests`), e o GitHub Actions já é opt-in (`--gha`). Por isso o `testDir` é trocado à mão.

O comando instala o `@playwright/test`, baixa o Chromium, gera o `playwright.config.ts` e acrescenta as pastas de relatório ao `.gitignore`. O config gerado será reescrito na Tarefa 3.9.

- [ ] **Passo 6: escreva o teste do ambiente de testes** `src/test/setup.test.tsx`

Ele prova duas coisas: que os *matchers* do jest-dom estão registrados e que o MSW intercepta o `fetch`.

```tsx
import { render, screen } from '@testing-library/react';
import { http, HttpResponse } from 'msw';
import { describe, expect, it } from 'vitest';
import { server, TEST_API } from './server';

describe('ambiente de testes', () => {
  it('tem DOM e os matchers do jest-dom', () => {
    render(<p>olá</p>);
    expect(screen.getByText('olá')).toBeInTheDocument();
  });

  it('o MSW intercepta o fetch', async () => {
    server.use(http.get(`${TEST_API}/ping`, () => HttpResponse.json({ pong: true })));
    const res = await fetch(`${TEST_API}/ping`);
    expect(await res.json()).toEqual({ pong: true });
  });
});
```

- [ ] **Passo 7: rode e veja falhar.** `npm test` falha com `Failed to resolve import "./server" from "src/test/setup.test.tsx"`. Se você criar o `server.ts` antes do config do Vitest, o erro passa a ser `document is not defined`, porque ainda não existe jsdom.

- [ ] **Passo 8: crie** `src/test/server.ts`

```ts
import { setupServer } from 'msw/node';

// Hosts fictícios: nenhum teste fala com a api ou com o IdP de verdade.
export const TEST_API = 'http://api.test';
export const TEST_AUTHORITY = 'http://idp.test/shortener';

// Sem handlers padrão: cada teste declara o que a "api" responde (server.use).
export const server = setupServer();
```

- [ ] **Passo 9: crie** `src/test/setup.ts`

```ts
import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterAll, afterEach, beforeAll } from 'vitest';
import { server } from './server';

// "error": request sem handler derruba o teste. Assim nenhuma chamada passa despercebida.
beforeAll(() => server.listen({ onUnhandledRequest: 'error' }));
afterEach(() => {
  cleanup(); // sem "globals: true", o Testing Library não limpa o DOM sozinho
  server.resetHandlers();
  sessionStorage.clear();
});
afterAll(() => server.close());
```

- [ ] **Passo 10: deixe o `vite.config.ts` assim** (arquivo final)

```ts
/// <reference types="vitest/config" />
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, strictPort: true }, // a porta precisa bater com o CORS da api
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/test/setup.ts'],
    include: ['src/**/*.test.{ts,tsx}'], // e2e/ é do Playwright, não do Vitest
  },
})
```

- [ ] **Passo 11: ajuste os `tsconfig` gerados.** Mostramos só o que muda.

Em `tsconfig.app.json`, acrescente `strict` no bloco `/* Linting */`. O TypeScript 6 já liga `strict` por padrão, mas deixar explícito evita surpresa:

```diff
     /* Linting */
+    "strict": true,
     "noUnusedLocals": true,
```

Em `tsconfig.node.json`, inclua o config do Playwright e a pasta `e2e` no typecheck:

```diff
-  "include": ["vite.config.ts"]
+  "include": ["vite.config.ts", "playwright.config.ts", "e2e"]
```

Atenção ao que o template liga e que vale para todo o código desta fase:
- `verbatimModuleSyntax`: import só de tipo usa `import type` (ou `import { type X }`).
- `erasableSyntaxOnly`: nada de `enum` nem de *parameter properties* (`constructor(public x)`).
- `noUnusedLocals` e `noUnusedParameters`.

- [ ] **Passo 12: rode e veja passar.** `npm test` (2 testes). Depois rode `npm run typecheck && npm run lint && npm run build`.

- [ ] **Passo 13: commit**

```bash
git add -A && git commit -m "chore: esqueleto do shortener-web (vite react-ts, vitest, msw, playwright)"
```

**Pronto quando:** `npm test`, `npm run typecheck`, `npm run lint` e `npm run build` passam, e `npm run dev` abre a página do template em `http://localhost:5173`.

---

## Tarefa 3.2: configuração de runtime

**Arquivos:**
- Criar `src/config.ts`, `src/config.test.ts` e `public/runtime/config.js`
- Alterar `index.html` e `src/test/setup.ts`

**Interfaces que esta tarefa entrega:**
- `type AppConfig = { apiBaseUrl: string; oidcAuthority: string; oidcClientId: string; oidcLogoutUrl?: string }`
- `loadConfig(raw: unknown): AppConfig`, que valida e lança um erro com mensagem clara
- `getConfig(): AppConfig`, que lê `window.__APP_CONFIG__`
- A declaração global `Window.__APP_CONFIG__`

**Conceitos:**
- **Config de build-time × runtime.** Com `import.meta.env.VITE_API_URL`, o Vite **cola o valor dentro do bundle** no `build`. Aí a imagem de staging seria diferente da de prod, o que quebra o "build once, deploy many": a imagem testada em staging não seria a mesma que vai para prod. Com config de runtime, o bundle não sabe nada do ambiente. Ele lê `window.__APP_CONFIG__`, que vem de `/runtime/config.js`, um arquivo que o container gera ao subir a partir de variáveis de ambiente.
- **Ordem de carregamento:** um `<script>` clássico (sem `type="module"`) roda na hora em que aparece. O bundle é `type="module"` e, portanto, é adiado. Então o config sempre existe quando o app começa.
- **Fail fast também no navegador:** config inválida mostra uma tela de erro dizendo qual campo está errado, em vez de um app quebrado e mudo.

- [ ] **Passo 1: escreva o teste** `src/config.test.ts`

```ts
import { describe, expect, it } from 'vitest';
import { getConfig, loadConfig } from './config';
import { TEST_API } from './test/server';

const valid = {
  apiBaseUrl: 'http://localhost:3000/',
  oidcAuthority: 'http://localhost:8090/shortener',
  oidcClientId: 'shortener-web',
};

describe('config', () => {
  it('aceita config válida e tira a barra final das URLs', () => {
    const c = loadConfig(valid);
    expect(c.apiBaseUrl).toBe('http://localhost:3000');
    expect(c.oidcAuthority).toBe('http://localhost:8090/shortener');
    expect(c.oidcLogoutUrl).toBeUndefined();
  });

  it('aceita oidcLogoutUrl opcional', () => {
    const c = loadConfig({ ...valid, oidcLogoutUrl: 'https://x.auth.us-east-1.amazoncognito.com/logout' });
    expect(c.oidcLogoutUrl).toBe('https://x.auth.us-east-1.amazoncognito.com/logout');
  });

  it('falha dizendo qual campo está errado', () => {
    expect(() => loadConfig({ ...valid, apiBaseUrl: 'nao-e-url' })).toThrow(/apiBaseUrl/);
    expect(() => loadConfig({ ...valid, oidcClientId: '' })).toThrow(/oidcClientId/);
  });

  it('rejeita protocolo que não é http(s)', () => {
    expect(() => loadConfig({ ...valid, apiBaseUrl: 'javascript:alert(1)' })).toThrow(/apiBaseUrl/);
  });

  it('explica quando o /runtime/config.js não carregou', () => {
    expect(() => loadConfig(undefined)).toThrow(/runtime\/config\.js/);
  });

  it('getConfig lê window.__APP_CONFIG__', () => {
    expect(getConfig().apiBaseUrl).toBe(TEST_API);
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm test` falha com `Failed to resolve import "./config"`.

- [ ] **Passo 3: implemente** `src/config.ts`

```ts
import { z } from 'zod';

declare global {
  interface Window {
    // Definido por /runtime/config.js antes do bundle. "unknown" de propósito: só confiamos depois do zod.
    __APP_CONFIG__?: unknown;
  }
}

// Sem barra no fim: depois concatenamos caminhos ("/links", "/me/links").
const httpUrl = z.url({ protocol: /^https?$/ }).transform((s) => s.replace(/\/+$/, ''));

const configSchema = z.object({
  apiBaseUrl: httpUrl,
  oidcAuthority: httpUrl,
  oidcClientId: z.string().min(1),
  oidcLogoutUrl: httpUrl.optional(), // só o Cognito precisa; o mock usa o end_session_endpoint
});

export type AppConfig = z.infer<typeof configSchema>;

export function loadConfig(raw: unknown): AppConfig {
  if (raw === undefined) {
    throw new Error('Configuração ausente: window.__APP_CONFIG__ não existe. O /runtime/config.js carregou?');
  }
  const result = configSchema.safeParse(raw);
  if (!result.success) {
    throw new Error(`Configuração inválida em /runtime/config.js:\n${z.prettifyError(result.error)}`);
  }
  return result.data;
}

export function getConfig(): AppConfig {
  return loadConfig(window.__APP_CONFIG__);
}
```

- [ ] **Passo 4: dê config aos testes.** `src/test/setup.ts` (arquivo final)

```ts
import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterAll, afterEach, beforeAll } from 'vitest';
import { server, TEST_API, TEST_AUTHORITY } from './server';

// O mesmo papel do /runtime/config.js, mas apontando para os hosts fictícios do MSW.
window.__APP_CONFIG__ = {
  apiBaseUrl: TEST_API,
  oidcAuthority: TEST_AUTHORITY,
  oidcClientId: 'shortener-web',
};

// "error": request sem handler derruba o teste. Assim nenhuma chamada passa despercebida.
beforeAll(() => server.listen({ onUnhandledRequest: 'error' }));
afterEach(() => {
  cleanup(); // sem "globals: true", o Testing Library não limpa o DOM sozinho
  server.resetHandlers();
  sessionStorage.clear();
});
afterAll(() => server.close());
```

- [ ] **Passo 5: rode e veja passar.** `npm test` (8 testes no total).

- [ ] **Passo 6: crie o config de dev** `public/runtime/config.js`

O que está em `public/` é servido na raiz pelo Vite em dev e copiado para `dist/` no build. A imagem apaga a cópia (Tarefa 3.10), porque lá o arquivo é gerado em runtime.

```js
// Config de DEV. No container, este arquivo é gerado pelo /docker-entrypoint.d/40-runtime-config.sh.
window.__APP_CONFIG__ = {
  apiBaseUrl: 'http://localhost:3000',
  oidcAuthority: 'http://localhost:8090/shortener',
  oidcClientId: 'shortener-web',
};
```

- [ ] **Passo 7: carregue o config antes do bundle.** Em `index.html`, mude o idioma, o título e acrescente o script antes do `main.tsx`:

```diff
-<html lang="en">
+<html lang="pt-BR">
...
-    <title>shortener-web</title>
+    <title>shortener</title>
   </head>
   <body>
     <div id="root"></div>
+    <script src="/runtime/config.js"></script>
     <script type="module" src="/src/main.tsx"></script>
```

Um `<script>` sem `type="module"` fica de fora do bundle: no `dist/index.html`, ele continua como `<script src="/runtime/config.js">`, sem hash, e é buscado em runtime. É exatamente isso que queremos. (Versões antigas do Vite avisavam `can't be bundled without type="module"`; o Vite 8 não avisa mais.)

- [ ] **Passo 8: confira em dev.** Rode `npm run dev`, abra `http://localhost:5173`, abra o console do navegador e rode `window.__APP_CONFIG__`. Deve aparecer o objeto do passo 6.

- [ ] **Passo 9: commit**

```bash
git add -A && git commit -m "feat: configuração de runtime validada com zod"
```

**Pronto quando:** os testes passam e `window.__APP_CONFIG__` existe no navegador em dev.

---

## Tarefa 3.3: cliente da API

**Arquivos:**
- Criar `src/api/client.ts`, `src/api/client.test.ts`, `src/api/queryClient.ts` e `src/api/queryClient.test.ts`

**Interfaces que esta tarefa entrega:**
- `createApiClient(baseUrl: string, getToken: () => string | undefined): ApiClient`
- `ApiClient`:
  - `createLink(url): Promise<Link>`
  - `listMyLinks({ cursor?, limit? }): Promise<MyLinksPage>`
  - `getStats(code): Promise<LinkStats>`
- `class ApiError extends Error { status; code; retryAfter? }`
- `parseRetryAfter(value, now?)` e `describeError(error): string` (mensagem para o usuário)
- Os tipos `Link`, `MyLink`, `MyLinksPage`, `LinkStats` e `DailyClicks`
- `createQueryClient()` e `shouldRetry(failureCount, error)`

**Conceitos:**
- **Validar a resposta, não só a entrada.** O `fetch` devolve `any`. Com zod, o tipo do TypeScript passa a ser verdade em runtime. Se a api mudar o contrato, o erro aparece na borda (`invalid_response`), e não como `undefined` três componentes depois.
- **Erros como dados.** `ApiError` carrega `status`, `code` (do corpo `{error}`) e `retryAfter`. A UI decide a mensagem e o hook decide se manda para o login.
- **`Retry-After`** pode vir em segundos ou como data HTTP. A api expõe o header via CORS (`exposedHeaders`); sem isso, o navegador esconde o header do JS.
- **Retry só faz sentido para erro transitório.** Repetir um 400, 401 ou 404 não muda nada. Rede e 5xx merecem mais 2 tentativas.

- [ ] **Passo 1: escreva o teste** `src/api/client.test.ts`

```ts
import { http, HttpResponse } from 'msw';
import { describe, expect, it } from 'vitest';
import { server, TEST_API } from '../test/server';
import { ApiError, createApiClient, describeError, parseRetryAfter } from './client';

const api = createApiClient(TEST_API, () => 'tok-123');

const link = {
  code: 'abc1234',
  shortUrl: 'http://localhost:3000/abc1234',
  url: 'https://example.com/',
  createdAt: '2026-10-12T12:00:00.000Z',
};

describe('createLink', () => {
  it('manda Bearer e JSON e devolve o link', async () => {
    let seen: { auth: string | null; body: unknown } | undefined;
    server.use(
      http.post(`${TEST_API}/links`, async ({ request }) => {
        seen = { auth: request.headers.get('Authorization'), body: await request.json() };
        return HttpResponse.json(link, { status: 201 });
      }),
    );
    await expect(api.createLink('https://example.com/')).resolves.toEqual(link);
    expect(seen).toEqual({ auth: 'Bearer tok-123', body: { url: 'https://example.com/' } });
  });

  it('sem token não manda Authorization', async () => {
    let auth: string | null = 'não lido';
    server.use(
      http.post(`${TEST_API}/links`, ({ request }) => {
        auth = request.headers.get('Authorization');
        return HttpResponse.json(link, { status: 201 });
      }),
    );
    await createApiClient(TEST_API, () => undefined).createLink('https://example.com/');
    expect(auth).toBeNull();
  });

  it('400 vira ApiError com o código do corpo', async () => {
    server.use(http.post(`${TEST_API}/links`, () => HttpResponse.json({ error: 'invalid_url' }, { status: 400 })));
    await expect(api.createLink('x')).rejects.toMatchObject({ name: 'ApiError', status: 400, code: 'invalid_url' });
  });

  it('401 sem corpo vira ApiError 401', async () => {
    server.use(http.post(`${TEST_API}/links`, () => new HttpResponse(null, { status: 401 })));
    await expect(api.createLink('https://example.com/')).rejects.toMatchObject({ status: 401, code: 'http_401' });
  });

  it('429 lê o Retry-After', async () => {
    server.use(
      http.post(`${TEST_API}/links`, () =>
        HttpResponse.json({ error: 'rate_limited' }, { status: 429, headers: { 'Retry-After': '30' } }),
      ),
    );
    await expect(api.createLink('https://example.com/')).rejects.toMatchObject({ status: 429, retryAfter: 30 });
  });
});

describe('listMyLinks', () => {
  it('manda limit e cursor e valida a página', async () => {
    let params: URLSearchParams | undefined;
    server.use(
      http.get(`${TEST_API}/me/links`, ({ request }) => {
        params = new URL(request.url).searchParams;
        return HttpResponse.json({ items: [{ ...link, totalClicks: 2 }], nextCursor: null });
      }),
    );
    const page = await api.listMyLinks({ cursor: 'c2', limit: 5 });
    expect(params?.get('limit')).toBe('5');
    expect(params?.get('cursor')).toBe('c2');
    expect(page).toEqual({ items: [{ ...link, totalClicks: 2 }], nextCursor: null });
  });

  it('resposta malformada vira invalid_response', async () => {
    server.use(http.get(`${TEST_API}/me/links`, () => HttpResponse.json({ items: 'não é lista' })));
    await expect(api.listMyLinks()).rejects.toMatchObject({ status: 200, code: 'invalid_response' });
  });
});

describe('getStats', () => {
  it('devolve as estatísticas validadas', async () => {
    const stats = {
      code: 'abc1234',
      url: 'https://example.com/',
      totalClicks: 3,
      daily: [{ day: '2026-10-12', clicks: 3 }],
      browsers: [{ browser: 'Chrome', clicks: 3 }],
    };
    server.use(http.get(`${TEST_API}/links/abc1234/stats`, () => HttpResponse.json(stats)));
    await expect(api.getStats('abc1234')).resolves.toEqual(stats);
  });

  it('404 vira ApiError not_found', async () => {
    server.use(http.get(`${TEST_API}/links/nope123/stats`, () => HttpResponse.json({ error: 'not_found' }, { status: 404 })));
    await expect(api.getStats('nope123')).rejects.toMatchObject({ status: 404, code: 'not_found' });
  });
});

describe('parseRetryAfter', () => {
  const now = Date.parse('2026-10-12T12:00:00Z');
  it('aceita segundos', () => expect(parseRetryAfter('42', now)).toBe(42));
  it('aceita data HTTP', () => expect(parseRetryAfter(new Date(now + 10_000).toUTCString(), now)).toBe(10));
  it('ignora lixo e ausência', () => {
    expect(parseRetryAfter('amanhã', now)).toBeUndefined();
    expect(parseRetryAfter(null, now)).toBeUndefined();
  });
});

describe('describeError', () => {
  it('429 diz quanto esperar', () => {
    expect(describeError(new ApiError(429, 'rate_limited', 30))).toBe('Muitas requisições. Tente de novo em 30 s.');
  });
  it('erro desconhecido tem mensagem genérica', () => {
    expect(describeError(new TypeError('Failed to fetch'))).toBe('Algo deu errado. Tente de novo em instantes.');
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm test` falha com `Failed to resolve import "./client"`.

- [ ] **Passo 3: implemente** `src/api/client.ts`

```ts
import { z } from 'zod';

const clicks = z.number().int().nonnegative();

const linkSchema = z.object({
  code: z.string().min(1),
  shortUrl: z.url(),
  url: z.url(),
  createdAt: z.iso.datetime({ offset: true }),
});

const myLinkSchema = linkSchema.extend({ totalClicks: clicks });

const myLinksPageSchema = z.object({
  items: z.array(myLinkSchema),
  nextCursor: z.string().min(1).nullable(),
});

const statsSchema = z.object({
  code: z.string().min(1),
  url: z.url(),
  totalClicks: clicks,
  daily: z.array(z.object({ day: z.iso.date(), clicks })),
  browsers: z.array(z.object({ browser: z.string(), clicks })),
});

const errorBodySchema = z.object({ error: z.string() });

export type Link = z.infer<typeof linkSchema>;
export type MyLink = z.infer<typeof myLinkSchema>;
export type MyLinksPage = z.infer<typeof myLinksPageSchema>;
export type LinkStats = z.infer<typeof statsSchema>;
export type DailyClicks = LinkStats['daily'][number];

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly retryAfter?: number;

  constructor(status: number, code: string, retryAfter?: number) {
    super(`A API respondeu ${status} (${code})`);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.retryAfter = retryAfter;
  }
}

// Retry-After: "120" (segundos) ou "Wed, 21 Oct 2026 07:28:00 GMT" (data HTTP).
export function parseRetryAfter(value: string | null, now = Date.now()): number | undefined {
  if (!value) return undefined;
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed);
  const date = Date.parse(trimmed);
  if (Number.isNaN(date)) return undefined;
  return Math.max(0, Math.ceil((date - now) / 1000));
}

export function describeError(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.status === 429) return `Muitas requisições. Tente de novo em ${error.retryAfter ?? 60} s.`;
    if (error.status === 400 && error.code === 'invalid_url') {
      return 'A API recusou a URL. Use um endereço http:// ou https:// válido.';
    }
    if (error.status === 401) return 'Sua sessão expirou ou não foi aceita. Se não for redirecionado, saia e entre de novo.';
    if (error.status === 404) return 'Não encontrado.';
    if (error.code === 'invalid_response') return 'A API respondeu num formato inesperado.';
  }
  return 'Algo deu errado. Tente de novo em instantes.';
}

export type GetToken = () => string | undefined;

export interface ApiClient {
  createLink(url: string): Promise<Link>;
  listMyLinks(params?: { cursor?: string; limit?: number }): Promise<MyLinksPage>;
  getStats(code: string): Promise<LinkStats>;
}

export function createApiClient(baseUrl: string, getToken: GetToken): ApiClient {
  async function request<S extends z.ZodType>(
    path: string,
    schema: S,
    init: { method?: string; body?: unknown } = {},
  ): Promise<z.infer<S>> {
    const headers = new Headers({ Accept: 'application/json' });
    const token = getToken();
    if (token) headers.set('Authorization', `Bearer ${token}`);
    let body: string | undefined;
    if (init.body !== undefined) {
      headers.set('Content-Type', 'application/json');
      body = JSON.stringify(init.body);
    }

    const res = await fetch(`${baseUrl}${path}`, { method: init.method ?? 'GET', headers, body });
    const payload: unknown = await res.json().catch(() => undefined); // corpo vazio ou não-JSON

    if (!res.ok) {
      const errorBody = errorBodySchema.safeParse(payload);
      throw new ApiError(
        res.status,
        errorBody.success ? errorBody.data.error : `http_${res.status}`,
        res.status === 429 ? parseRetryAfter(res.headers.get('Retry-After')) : undefined,
      );
    }

    const parsed = schema.safeParse(payload);
    if (!parsed.success) throw new ApiError(res.status, 'invalid_response');
    return parsed.data;
  }

  return {
    createLink: (url) => request('/links', linkSchema, { method: 'POST', body: { url } }),
    listMyLinks: ({ cursor, limit = 20 } = {}) => {
      const query = new URLSearchParams({ limit: String(limit) });
      if (cursor) query.set('cursor', cursor);
      return request(`/me/links?${query}`, myLinksPageSchema);
    },
    getStats: (code) => request(`/links/${encodeURIComponent(code)}/stats`, statsSchema),
  };
}
```

- [ ] **Passo 4: rode e veja passar.** `npm test`.

- [ ] **Passo 5: escreva o teste da política de retry** `src/api/queryClient.test.ts`

```ts
import { describe, expect, it } from 'vitest';
import { ApiError } from './client';
import { shouldRetry } from './queryClient';

describe('shouldRetry', () => {
  it('não repete erro 4xx nem resposta inválida', () => {
    expect(shouldRetry(0, new ApiError(401, 'http_401'))).toBe(false);
    expect(shouldRetry(0, new ApiError(404, 'not_found'))).toBe(false);
    expect(shouldRetry(0, new ApiError(200, 'invalid_response'))).toBe(false);
  });

  it('repete 5xx e falha de rede até 2 vezes', () => {
    expect(shouldRetry(0, new ApiError(503, 'http_503'))).toBe(true);
    expect(shouldRetry(1, new TypeError('Failed to fetch'))).toBe(true);
    expect(shouldRetry(2, new TypeError('Failed to fetch'))).toBe(false);
  });
});
```

- [ ] **Passo 6: rode e veja falhar.** `npm test` falha com `Failed to resolve import "./queryClient"`.

- [ ] **Passo 7: implemente** `src/api/queryClient.ts`

```ts
import { QueryClient } from '@tanstack/react-query';
import { ApiError } from './client';

export function shouldRetry(failureCount: number, error: unknown): boolean {
  if (error instanceof ApiError && error.status < 500) return false; // repetir não resolve
  return failureCount < 2;
}

export function createQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        retry: shouldRetry,
        staleTime: 15_000, // evita refetch a cada troca de página dentro do painel
      },
    },
  });
}
```

- [ ] **Passo 8: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 9: commit**

```bash
git add -A && git commit -m "feat: cliente da API validado com zod e política de retry"
```

**Pronto quando:** os testes de sucesso, 400, 401, 429 e resposta malformada passam.

---

## Tarefa 3.4: autenticação (OIDC com PKCE)

**Arquivos:**
- Criar `src/auth/oidc.ts`, `src/auth/AuthProvider.tsx`, `src/auth/RequireAuth.tsx`, `src/auth/CallbackPage.tsx` e `src/auth/useLogout.ts`
- Testes: criar `src/test/render.tsx`, `src/auth/oidc.test.ts`, `src/auth/RequireAuth.test.tsx`, `src/auth/CallbackPage.test.tsx` e `src/auth/useLogout.test.tsx`

**Interfaces que esta tarefa entrega:**
- `buildOidcSettings(cfg, origin): UserManagerSettings`
- `clearAuthParamsFromUrl()`, usado como `onSigninCallback`
- `returnToFrom(state): string`, que só aceita caminho interno
- `buildLogoutUrl(logoutUrl, clientId, origin)`
- Os componentes `<AppAuthProvider>`, `<RequireAuth>` e `<CallbackPage>`
- O hook `useLogout(): () => Promise<void>`
- Nos testes: `fakeAuth(overrides?)`, `anonymousAuth(overrides?)`, `createWrapper({ route?, auth? })`, `renderWithProviders(ui, { route?, auth? })` e `TEST_TOKEN`

**Conceitos:**
- **Authorization Code + PKCE.** O SPA é um *client* público: não pode guardar segredo, porque todo o JS é legível. Por isso o fluxo funciona assim:
  1. Antes do redirect, o `oidc-client-ts` gera um `code_verifier` aleatório e guarda no `sessionStorage`.
  2. Ele manda ao IdP só o `code_challenge = base64url(SHA-256(verifier))`.
  3. Na volta (`/callback?code=...&state=...`), troca o `code` por tokens enviando o `verifier`.
  4. O IdP recalcula o hash e confere.

  Quem interceptar o `code` (histórico, log, extensão) não consegue trocá-lo sem o `verifier`. O `state` amarra a resposta ao pedido (anti-CSRF) e carrega o `returnTo`.
- **Onde guardar os tokens: `sessionStorage` × BFF.** Tudo que o JS lê, um XSS também lê. Então, se houver XSS, o atacante leva o access token (1h) e o refresh token (1 dia no Cognito).
  - **Mitigações aqui:** `sessionStorage` (some ao fechar a aba e não vaza para outras abas), tokens de vida curta, React escapando HTML por padrão e nenhuma lib de terceiros carregada de CDN.
  - **A alternativa forte é um BFF** (*backend for frontend*): o servidor faz o fluxo OIDC, guarda os tokens e dá ao navegador só um cookie `HttpOnly; Secure; SameSite`. Custa um serviço a mais e muda a arquitetura. Fica nas extensões.
  - **Efeito colateral do `sessionStorage`:** uma aba nova não tem tokens. Ela redireciona ao IdP, que ainda tem sessão (cookie dele) e devolve na hora, quase sempre sem pedir senha.
- **Renovação silenciosa:** com `automaticSilentRenew`, o `oidc-client-ts` usa o refresh token pouco antes do access token expirar. Cognito e mock emitem refresh token no fluxo `code`.
- **`onSigninCallback`:** depois do login, a URL ainda tem `?code=&state=`. Precisamos limpá-la. Sem isso, um F5 tentaria trocar o mesmo código de novo, e a renovação quebraria.
- **Logout:**
  - O mock publica `end_session_endpoint` na *discovery*, então `signoutRedirect()` basta.
  - O Cognito **não** publica. O logout dele é `https://<domínio>/logout?client_id=...&logout_uri=...`, com `logout_uri` igual ao cadastrado no app client.
  - Por isso existe `oidcLogoutUrl` opcional: se ele vier na config, montamos a URL estilo Cognito.
- **Open redirect:** o `returnTo` volta do IdP dentro do `state`. Só aceitamos caminhos internos (`/algo`), nunca `//evil.com` nem `https://...`.

- [ ] **Passo 1: crie os utilitários de teste** `src/test/render.tsx`

Os componentes leem a autenticação via `useAuth()`, que consome o `AuthContext` exportado pelo `react-oidc-context`. Nos testes, injetamos um valor falso nesse mesmo contexto. Sem IdP, sem redirect de verdade, e com `vi.fn()` para conferir as chamadas.

```tsx
import type { ReactElement, ReactNode } from 'react';
import { render } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { QueryClientProvider } from '@tanstack/react-query';
import { MemoryRouter } from 'react-router';
import { AuthContext, type AuthContextProps } from 'react-oidc-context';
import { vi } from 'vitest';
import { createQueryClient } from '../api/queryClient';

export const TEST_TOKEN = 'token-de-teste';

// Só os campos que o app usa; o resto do AuthContextProps não é tocado nos testes.
export function fakeAuth(overrides: Partial<AuthContextProps> = {}): AuthContextProps {
  const base = {
    isLoading: false,
    isAuthenticated: true,
    activeNavigator: undefined,
    error: undefined,
    user: {
      access_token: TEST_TOKEN,
      profile: { sub: 'user-1', email: 'ana@example.com' },
      state: undefined,
    },
    signinRedirect: vi.fn(() => Promise.resolve()),
    signoutRedirect: vi.fn(() => Promise.resolve()),
    removeUser: vi.fn(() => Promise.resolve()),
  };
  return { ...base, ...overrides } as unknown as AuthContextProps;
}

export function anonymousAuth(overrides: Partial<AuthContextProps> = {}): AuthContextProps {
  return fakeAuth({ isAuthenticated: false, user: null, ...overrides });
}

interface Options {
  route?: string;
  auth?: AuthContextProps;
}

export function createWrapper({ route = '/', auth = fakeAuth() }: Options = {}) {
  const queryClient = createQueryClient(); // um por teste: nada de cache vazando entre testes
  function Wrapper({ children }: { children: ReactNode }) {
    return (
      <AuthContext.Provider value={auth}>
        <QueryClientProvider client={queryClient}>
          <MemoryRouter initialEntries={[route]}>{children}</MemoryRouter>
        </QueryClientProvider>
      </AuthContext.Provider>
    );
  }
  return Wrapper;
}

export function renderWithProviders(ui: ReactElement, options: Options = {}) {
  const auth = options.auth ?? fakeAuth();
  const user = userEvent.setup(); // também instala um clipboard falso em navigator.clipboard
  return { user, auth, ...render(ui, { wrapper: createWrapper({ ...options, auth }) }) };
}
```

- [ ] **Passo 2: escreva os testes**

`src/auth/oidc.test.ts`

```ts
import { WebStorageStateStore } from 'oidc-client-ts';
import { describe, expect, it } from 'vitest';
import {
  buildLogoutUrl,
  buildOidcSettings,
  clearAuthParamsFromUrl,
  completeSignin,
  loginJustCompleted,
  returnToFrom,
} from './oidc';

const cfg = {
  apiBaseUrl: 'http://localhost:3000',
  oidcAuthority: 'http://localhost:8090/shortener',
  oidcClientId: 'shortener-web',
};

describe('buildOidcSettings', () => {
  it('usa code + PKCE, callback na origem e tokens no sessionStorage', () => {
    const s = buildOidcSettings(cfg, 'http://localhost:5173');
    expect(s).toMatchObject({
      authority: 'http://localhost:8090/shortener',
      client_id: 'shortener-web',
      redirect_uri: 'http://localhost:5173/callback',
      post_logout_redirect_uri: 'http://localhost:5173/',
      response_type: 'code',
      scope: 'openid email profile',
      automaticSilentRenew: true,
    });
    expect(s.userStore).toBeInstanceOf(WebStorageStateStore);
  });
});

describe('clearAuthParamsFromUrl', () => {
  it('remove code e state da URL sem mudar o caminho', () => {
    window.history.replaceState({}, '', '/callback?code=abc&state=xyz');
    clearAuthParamsFromUrl();
    expect(window.location.pathname).toBe('/callback');
    expect(window.location.search).toBe('');
  });
});

describe('returnToFrom', () => {
  it('aceita caminho interno', () => {
    expect(returnToFrom({ returnTo: '/links/abc1234' })).toBe('/links/abc1234');
  });
  it('recusa URL externa, protocolo relativo e lixo', () => {
    expect(returnToFrom({ returnTo: 'https://evil.example' })).toBe('/links');
    expect(returnToFrom({ returnTo: '//evil.example' })).toBe('/links');
    expect(returnToFrom({ returnTo: '/\\evil.example' })).toBe('/links');
    expect(returnToFrom(undefined)).toBe('/links');
  });
});

describe('buildLogoutUrl', () => {
  it('monta a URL de logout estilo Cognito', () => {
    const url = new URL(
      buildLogoutUrl('https://x.auth.us-east-1.amazoncognito.com/logout', 'abc123', 'https://app.example.com'),
    );
    expect(url.origin + url.pathname).toBe('https://x.auth.us-east-1.amazoncognito.com/logout');
    expect(url.searchParams.get('client_id')).toBe('abc123');
    expect(url.searchParams.get('logout_uri')).toBe('https://app.example.com/');
  });
});

describe('completeSignin e loginJustCompleted', () => {
  it('sem login registrado: false', () => {
    expect(loginJustCompleted()).toBe(false);
  });

  it('limpa a URL e marca o login; vale por 30 s', () => {
    window.history.replaceState({}, '', '/callback?code=abc&state=xyz');
    completeSignin();
    expect(window.location.search).toBe('');
    const now = Date.now();
    expect(loginJustCompleted(now + 29_000)).toBe(true);
    expect(loginJustCompleted(now + 31_000)).toBe(false);
  });

  it('valor estranho no storage: false', () => {
    sessionStorage.setItem('shortener.loginAt', 'lixo');
    expect(loginJustCompleted()).toBe(false);
  });
});
```

`src/auth/RequireAuth.test.tsx`

```tsx
import { screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Route, Routes } from 'react-router';
import { describe, expect, it } from 'vitest';
import { anonymousAuth, fakeAuth, renderWithProviders } from '../test/render';
import { RequireAuth } from './RequireAuth';

const ui = (
  <Routes>
    <Route path="/links" element={<RequireAuth><p>área protegida</p></RequireAuth>} />
  </Routes>
);

describe('RequireAuth', () => {
  it('logado: mostra o conteúdo', () => {
    renderWithProviders(ui, { route: '/links' });
    expect(screen.getByText('área protegida')).toBeInTheDocument();
  });

  it('anônimo: manda para o login guardando o caminho de volta', async () => {
    const { auth } = renderWithProviders(ui, { route: '/links?x=1', auth: anonymousAuth() });
    expect(screen.getByText('Redirecionando para o login…')).toBeInTheDocument();
    await waitFor(() => expect(auth.signinRedirect).toHaveBeenCalledWith({ state: { returnTo: '/links?x=1' } }));
    expect(auth.signinRedirect).toHaveBeenCalledTimes(1);
    expect(screen.queryByText('área protegida')).not.toBeInTheDocument();
  });

  it('carregando: ainda não redireciona', () => {
    const { auth } = renderWithProviders(ui, { route: '/links', auth: anonymousAuth({ isLoading: true }) });
    expect(auth.signinRedirect).not.toHaveBeenCalled();
  });

  it('erro de login: mostra o erro e não entra em loop', () => {
    const error = Object.assign(new Error('invalid_grant'), { source: 'signinCallback' as const });
    const { auth } = renderWithProviders(ui, { route: '/links', auth: anonymousAuth({ error }) });
    expect(screen.getByRole('alert')).toHaveTextContent('invalid_grant');
    expect(auth.signinRedirect).not.toHaveBeenCalled();
  });

  it('erro de login: oferece "Entrar de novo", que volta para o caminho atual', async () => {
    const error = Object.assign(new Error('invalid_grant'), { source: 'signinCallback' as const });
    const { auth } = renderWithProviders(ui, { route: '/links?x=1', auth: anonymousAuth({ error }) });
    await userEvent.click(screen.getByRole('button', { name: 'Entrar de novo' }));
    expect(auth.signinRedirect).toHaveBeenCalledWith({ state: { returnTo: '/links?x=1' } });
  });

  it('renovação silenciosa falhou, mas o usuário segue logado: o conteúdo continua', () => {
    const error = Object.assign(new Error('Failed to fetch'), { source: 'renewSilent' as const });
    const { auth } = renderWithProviders(ui, { route: '/links', auth: fakeAuth({ error }) });
    expect(screen.getByText('área protegida')).toBeInTheDocument();
    expect(auth.signinRedirect).not.toHaveBeenCalled();
  });

  it('com usuário logado nunca chama o login', () => {
    const { auth } = renderWithProviders(ui, { route: '/links', auth: fakeAuth() });
    expect(auth.signinRedirect).not.toHaveBeenCalled();
  });
});
```

`src/auth/CallbackPage.test.tsx`

```tsx
import { screen } from '@testing-library/react';
import { Route, Routes } from 'react-router';
import type { User } from 'oidc-client-ts';
import { describe, expect, it } from 'vitest';
import { anonymousAuth, fakeAuth, renderWithProviders } from '../test/render';
import { CallbackPage } from './CallbackPage';

const ui = (
  <Routes>
    <Route path="/" element={<p>início</p>} />
    <Route path="/callback" element={<CallbackPage />} />
    <Route path="/links" element={<p>meus links</p>} />
    <Route path="/links/:code" element={<p>detalhe</p>} />
  </Routes>
);

const withState = (state: unknown) =>
  fakeAuth({ user: { access_token: 't', profile: { sub: 'u' }, state } as unknown as User });

describe('CallbackPage', () => {
  it('logado: volta para o returnTo do state', () => {
    renderWithProviders(ui, { route: '/callback', auth: withState({ returnTo: '/links/abc1234' }) });
    expect(screen.getByText('detalhe')).toBeInTheDocument();
  });

  it('returnTo externo é ignorado: vai para /links', () => {
    renderWithProviders(ui, { route: '/callback', auth: withState({ returnTo: 'https://evil.example' }) });
    expect(screen.getByText('meus links')).toBeInTheDocument();
  });

  it('enquanto troca o código, mostra "Concluindo login…"', () => {
    renderWithProviders(ui, { route: '/callback', auth: anonymousAuth({ isLoading: true }) });
    expect(screen.getByText('Concluindo login…')).toBeInTheDocument();
  });

  it('erro na troca do código: mostra o erro com link de volta', () => {
    const error = Object.assign(new Error('invalid_pkce'), { source: 'signinCallback' as const });
    renderWithProviders(ui, { route: '/callback', auth: anonymousAuth({ error }) });
    expect(screen.getByRole('alert')).toHaveTextContent('invalid_pkce');
    expect(screen.getByRole('link', { name: 'Voltar ao início' })).toHaveAttribute('href', '/');
  });

  it('acesso direto sem login: volta ao início', () => {
    renderWithProviders(ui, { route: '/callback', auth: anonymousAuth() });
    expect(screen.getByText('início')).toBeInTheDocument();
  });
});
```

`src/auth/useLogout.test.tsx`

```tsx
import { renderHook } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { createWrapper, fakeAuth } from '../test/render';
import { useLogout } from './useLogout';

describe('useLogout', () => {
  it('sem oidcLogoutUrl (mock), usa o end_session do IdP via signoutRedirect', async () => {
    const auth = fakeAuth();
    const { result } = renderHook(() => useLogout(), { wrapper: createWrapper({ auth }) });
    await result.current();
    expect(auth.signoutRedirect).toHaveBeenCalledTimes(1);
    expect(auth.removeUser).not.toHaveBeenCalled();
  });
});
```

O ramo do Cognito (`window.location.assign`) não é testado aqui, porque o jsdom não navega. A montagem da URL está coberta por `buildLogoutUrl`.

- [ ] **Passo 3: rode e veja falhar.** `npm test` falha com `Failed to resolve import "./oidc"` (e o mesmo para os outros arquivos).

- [ ] **Passo 4: implemente** `src/auth/oidc.ts`

```ts
import { WebStorageStateStore, type UserManagerSettings } from 'oidc-client-ts';
import type { AppConfig } from '../config';

export function buildOidcSettings(cfg: AppConfig, origin: string): UserManagerSettings {
  return {
    authority: cfg.oidcAuthority,
    client_id: cfg.oidcClientId,
    redirect_uri: `${origin}/callback`,
    post_logout_redirect_uri: `${origin}/`,
    response_type: 'code', // Authorization Code; o PKCE é ligado por padrão no oidc-client-ts
    scope: 'openid email profile',
    userStore: new WebStorageStateStore({ store: window.sessionStorage }),
    automaticSilentRenew: true, // usa o refresh token antes do access token expirar
  };
}

// Tira ?code=&state= da barra de endereço depois que o oidc-client-ts já trocou o código.
export function clearAuthParamsFromUrl(): void {
  window.history.replaceState({}, document.title, window.location.pathname);
}

// Hora do último login concluído. Um 401 logo depois dele não deve mandar ao IdP de novo:
// se a api recusa o token recém-emitido (chave em cache, aud errado, relógio), seria um loop infinito.
const LOGIN_AT_KEY = 'shortener.loginAt';
const LOGIN_GRACE_MS = 30_000;

// onSigninCallback: limpa a URL e registra o login.
export function completeSignin(): void {
  clearAuthParamsFromUrl();
  sessionStorage.setItem(LOGIN_AT_KEY, String(Date.now()));
}

export function loginJustCompleted(now: number = Date.now()): boolean {
  const at = Number(sessionStorage.getItem(LOGIN_AT_KEY));
  return Number.isFinite(at) && at > 0 && now - at < LOGIN_GRACE_MS;
}

// O state volta do IdP; só confiamos em caminho interno (evita open redirect).
export function returnToFrom(state: unknown): string {
  if (typeof state === 'object' && state !== null && 'returnTo' in state) {
    const returnTo = (state as { returnTo: unknown }).returnTo;
    if (
      typeof returnTo === 'string' &&
      returnTo.startsWith('/') &&
      !returnTo.startsWith('//') &&
      !returnTo.startsWith('/\\')
    ) {
      return returnTo;
    }
  }
  return '/links';
}

// Cognito: GET https://<domínio>/logout?client_id=...&logout_uri=... (logout_uri igual ao cadastrado).
export function buildLogoutUrl(logoutUrl: string, clientId: string, origin: string): string {
  const url = new URL(logoutUrl);
  url.searchParams.set('client_id', clientId);
  url.searchParams.set('logout_uri', `${origin}/`);
  return url.toString();
}
```

- [ ] **Passo 5: implemente** `src/auth/AuthProvider.tsx`

```tsx
import { useState, type ReactNode } from 'react';
import { AuthProvider } from 'react-oidc-context';
import { getConfig } from '../config';
import { buildOidcSettings, completeSignin } from './oidc';

export function AppAuthProvider({ children }: { children: ReactNode }) {
  // O AuthProvider cria o UserManager uma vez; calculamos as settings uma vez também.
  const [settings] = useState(() => buildOidcSettings(getConfig(), window.location.origin));
  return (
    <AuthProvider {...settings} onSigninCallback={completeSignin}>
      {children}
    </AuthProvider>
  );
}
```

- [ ] **Passo 6: implemente** `src/auth/RequireAuth.tsx`

```tsx
import { useEffect, useRef, type ReactNode } from 'react';
import { useAuth } from 'react-oidc-context';
import { useLocation } from 'react-router';

export function RequireAuth({ children }: { children: ReactNode }) {
  const auth = useAuth();
  const location = useLocation();
  const redirected = useRef(false);
  const mustLogin = !auth.isLoading && !auth.isAuthenticated && !auth.activeNavigator && !auth.error;

  const returnTo = location.pathname + location.search;

  useEffect(() => {
    if (!mustLogin || redirected.current) return;
    redirected.current = true; // o StrictMode roda efeitos 2x em dev; um redirect basta
    void auth.signinRedirect({ state: { returnTo } });
  }, [mustLogin, auth, returnTo]);

  // Com usuário ainda logado (ex.: a renovação silenciosa falhou por um instante), o app segue usável:
  // se o token vencer de fato, o 401 da api leva ao login.
  if (auth.isAuthenticated) return children;
  if (auth.error) {
    return (
      <div role="alert" className="error">
        <p>Falha no login: {auth.error.message}</p>
        <button type="button" onClick={() => void auth.signinRedirect({ state: { returnTo } })}>
          Entrar de novo
        </button>
      </div>
    );
  }
  return <p className="muted">Redirecionando para o login…</p>;
}
```

- [ ] **Passo 7: implemente** `src/auth/CallbackPage.tsx`

O `AuthProvider` é quem troca o código por tokens: ele faz isso sozinho quando a URL tem `code` e `state`. Esta página só espera e decide para onde ir.

```tsx
import { useAuth } from 'react-oidc-context';
import { Link, Navigate } from 'react-router';
import { returnToFrom } from './oidc';

export function CallbackPage() {
  const auth = useAuth();

  if (auth.error) {
    return (
      <main className="container">
        <p role="alert" className="error">Falha no login: {auth.error.message}</p>
        <Link to="/">Voltar ao início</Link>
      </main>
    );
  }
  if (auth.isLoading) {
    return (
      <main className="container">
        <p className="muted">Concluindo login…</p>
      </main>
    );
  }
  if (auth.isAuthenticated) return <Navigate to={returnToFrom(auth.user?.state)} replace />;
  return <Navigate to="/" replace />; // abriram /callback na mão, sem login em andamento
}
```

- [ ] **Passo 8: implemente** `src/auth/useLogout.ts`

```ts
import { useAuth } from 'react-oidc-context';
import { getConfig } from '../config';
import { buildLogoutUrl } from './oidc';

export function useLogout(): () => Promise<void> {
  const auth = useAuth();
  return async () => {
    const { oidcLogoutUrl, oidcClientId } = getConfig();
    if (oidcLogoutUrl) {
      // Cognito: não há end_session_endpoint na discovery; limpamos local e vamos ao /logout dele.
      await auth.removeUser();
      window.location.assign(buildLogoutUrl(oidcLogoutUrl, oidcClientId, window.location.origin));
      return;
    }
    await auth.signoutRedirect(); // mock: end_session_endpoint → volta para post_logout_redirect_uri
  };
}
```

- [ ] **Passo 9: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 10: commit**

```bash
git add -A && git commit -m "feat: login OIDC com PKCE, rota protegida, callback e logout"
```

**Pronto quando:** os testes de settings, callback, rota protegida, open redirect e logout passam.

---

## Tarefa 3.5: hooks de dados com TanStack Query

**Arquivos:**
- Criar `src/api/hooks.ts`
- Testes: criar `src/test/fixtures.ts` e `src/api/hooks.test.tsx`

**Interfaces que esta tarefa entrega:**
- `useMyLinks()`: `useInfiniteQuery` de `/me/links`, com `PAGE_SIZE = 20`
- `useCreateLink()`: `useMutation` que invalida a lista
- `useStats(code)`: `useQuery` de `/links/:code/stats`
- `linkKeys` (chaves de cache)
- Nos 3 hooks, um **401 dispara `signinRedirect`** com o caminho atual no `state`
- Nos testes: `myLink(code, overrides?)` e `stats(overrides?)`

**Conceitos:**
- **Cache de servidor ≠ estado de UI.** O TanStack Query guarda respostas por chave (`['links','mine']`), deduplica requests, refaz quando fica velho e expõe `isPending`, `error` e `data`.
- **Paginação por cursor:** `initialPageParam` é o cursor da primeira página (`undefined`). `getNextPageParam` lê o `nextCursor` da última página e, se ele vier `null`, `hasNextPage` vira `false`.
- **Invalidação:** depois de criar um link, `invalidateQueries(['links','mine'])` marca a lista como velha e a busca de novo. Assim não precisamos remendar o cache à mão.
- **401 no meio do uso:** o token pode ter expirado sem renovar (refresh vencido, por exemplo). Nesse caso, o caminho certo é um novo login que volte para a mesma tela.

- [ ] **Passo 1: crie as fixtures** `src/test/fixtures.ts`

```ts
import type { LinkStats, MyLink } from '../api/client';

export function myLink(code: string, overrides: Partial<MyLink> = {}): MyLink {
  return {
    code,
    shortUrl: `http://localhost:3000/${code}`,
    url: `https://example.com/${code}`,
    createdAt: '2026-10-12T12:00:00.000Z',
    totalClicks: 0,
    ...overrides,
  };
}

export function stats(overrides: Partial<LinkStats> = {}): LinkStats {
  return {
    code: 'abc1234',
    url: 'https://example.com/abc1234',
    totalClicks: 0,
    daily: [],
    browsers: [],
    ...overrides,
  };
}
```

- [ ] **Passo 2: escreva o teste** `src/api/hooks.test.tsx`

```tsx
import { act, renderHook, waitFor } from '@testing-library/react';
import { http, HttpResponse } from 'msw';
import { describe, expect, it } from 'vitest';
import { myLink, stats } from '../test/fixtures';
import { createWrapper, fakeAuth, TEST_TOKEN } from '../test/render';
import { server, TEST_API } from '../test/server';
import { completeSignin } from '../auth/oidc';
import { useCreateLink, useMyLinks, useStats } from './hooks';

describe('useMyLinks', () => {
  it('pagina com o cursor e para quando nextCursor é null', async () => {
    server.use(
      http.get(`${TEST_API}/me/links`, ({ request }) => {
        const cursor = new URL(request.url).searchParams.get('cursor');
        return HttpResponse.json(
          cursor === 'c2' ? { items: [myLink('bbb2222')], nextCursor: null } : { items: [myLink('aaa1111')], nextCursor: 'c2' },
        );
      }),
    );
    const { result } = renderHook(() => useMyLinks(), { wrapper: createWrapper() });
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.hasNextPage).toBe(true);

    await act(async () => {
      await result.current.fetchNextPage();
    });
    await waitFor(() => expect(result.current.data?.pages).toHaveLength(2));
    expect(result.current.hasNextPage).toBe(false);
  });

  it('manda o access token do usuário logado', async () => {
    let auth: string | null = null;
    server.use(
      http.get(`${TEST_API}/me/links`, ({ request }) => {
        auth = request.headers.get('Authorization');
        return HttpResponse.json({ items: [], nextCursor: null });
      }),
    );
    const { result } = renderHook(() => useMyLinks(), { wrapper: createWrapper() });
    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(auth).toBe(`Bearer ${TEST_TOKEN}`);
  });
});

describe('useCreateLink', () => {
  it('cria e invalida a lista', async () => {
    let listCalls = 0;
    server.use(
      http.get(`${TEST_API}/me/links`, () => {
        listCalls += 1;
        return HttpResponse.json({ items: [], nextCursor: null });
      }),
      http.post(`${TEST_API}/links`, () => {
        const { totalClicks: _omit, ...link } = myLink('new1234');
        return HttpResponse.json(link, { status: 201 });
      }),
    );
    const { result } = renderHook(() => ({ list: useMyLinks(), create: useCreateLink() }), {
      wrapper: createWrapper(),
    });
    await waitFor(() => expect(result.current.list.isSuccess).toBe(true));

    await act(async () => {
      await result.current.create.mutateAsync('https://example.com/new');
    });
    await waitFor(() => expect(listCalls).toBe(2));
  });
});

describe('401', () => {
  it('dispara novo login voltando para a tela atual', async () => {
    server.use(http.get(`${TEST_API}/links/abc1234/stats`, () => new HttpResponse(null, { status: 401 })));
    const auth = fakeAuth();
    renderHook(() => useStats('abc1234'), { wrapper: createWrapper({ route: '/links/abc1234', auth }) });
    await waitFor(() =>
      expect(auth.signinRedirect).toHaveBeenCalledWith({ state: { returnTo: '/links/abc1234' } }),
    );
  });

  it('401 logo depois de um login não redireciona de novo (evita loop com o IdP)', async () => {
    server.use(http.get(`${TEST_API}/links/abc1234/stats`, () => new HttpResponse(null, { status: 401 })));
    completeSignin(); // acabamos de voltar do IdP, e a api ainda recusa o token novo
    const auth = fakeAuth();
    const { result } = renderHook(() => useStats('abc1234'), { wrapper: createWrapper({ route: '/links/abc1234', auth }) });
    await waitFor(() => expect(result.current.isError).toBe(true));
    expect(auth.signinRedirect).not.toHaveBeenCalled();
  });

  it('erro que não é 401 não chama o login', async () => {
    server.use(http.get(`${TEST_API}/links/abc1234/stats`, () => HttpResponse.json({ error: 'not_found' }, { status: 404 })));
    const auth = fakeAuth();
    const { result } = renderHook(() => useStats('abc1234'), { wrapper: createWrapper({ auth }) });
    await waitFor(() => expect(result.current.isError).toBe(true));
    expect(auth.signinRedirect).not.toHaveBeenCalled();
  });

  it('useStats devolve as estatísticas', async () => {
    server.use(http.get(`${TEST_API}/links/abc1234/stats`, () => HttpResponse.json(stats({ totalClicks: 4 }))));
    const { result } = renderHook(() => useStats('abc1234'), { wrapper: createWrapper() });
    await waitFor(() => expect(result.current.data?.totalClicks).toBe(4));
  });
});
```

- [ ] **Passo 3: rode e veja falhar.** `npm test` falha com `Failed to resolve import "./hooks"`.

- [ ] **Passo 4: implemente** `src/api/hooks.ts`

```ts
import { useEffect, useMemo } from 'react';
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from 'react-oidc-context';
import { useLocation } from 'react-router';
import { loginJustCompleted } from '../auth/oidc';
import { getConfig } from '../config';
import { ApiError, createApiClient, type ApiClient } from './client';

export const PAGE_SIZE = 20;

export const linkKeys = {
  mine: ['links', 'mine'] as const,
  stats: (code: string) => ['links', code, 'stats'] as const,
};

function useApiClient(): ApiClient {
  const auth = useAuth();
  const token = auth.user?.access_token; // muda quando o oidc-client-ts renova o token
  return useMemo(() => createApiClient(getConfig().apiBaseUrl, () => token), [token]);
}

function useLoginOnUnauthorized(error: unknown): void {
  const auth = useAuth();
  const location = useLocation();
  const unauthorized = error instanceof ApiError && error.status === 401;

  useEffect(() => {
    // Logo depois de um login, outro redirect viraria loop: deixamos o erro aparecer na tela.
    if (unauthorized && !auth.activeNavigator && !loginJustCompleted()) {
      void auth.signinRedirect({ state: { returnTo: location.pathname + location.search } });
    }
  }, [unauthorized, auth, location.pathname, location.search]);
}

export function useMyLinks() {
  const api = useApiClient();
  const query = useInfiniteQuery({
    queryKey: linkKeys.mine,
    queryFn: ({ pageParam }) => api.listMyLinks({ cursor: pageParam, limit: PAGE_SIZE }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.nextCursor ?? undefined, // undefined = acabou
  });
  useLoginOnUnauthorized(query.error);
  return query;
}

export function useCreateLink() {
  const api = useApiClient();
  const queryClient = useQueryClient();
  const mutation = useMutation({
    mutationFn: (url: string) => api.createLink(url),
    // Retornar a promise mantém a mutation "pending" até a lista ser buscada de novo.
    onSuccess: () => queryClient.invalidateQueries({ queryKey: linkKeys.mine }),
  });
  useLoginOnUnauthorized(mutation.error);
  return mutation;
}

export function useStats(code: string) {
  const api = useApiClient();
  const query = useQuery({
    queryKey: linkKeys.stats(code),
    queryFn: () => api.getStats(code),
  });
  useLoginOnUnauthorized(query.error);
  return query;
}
```

- [ ] **Passo 5: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 6: commit**

```bash
git add -A && git commit -m "feat: hooks de dados com TanStack Query e novo login em 401"
```

**Pronto quando:** paginação, invalidação e o 401 → login passam nos testes.

---

## Tarefa 3.6: página "Meus links"

**Arquivos:**
- Criar `src/lib/url.ts`, `src/lib/format.ts`, `src/components/CopyButton.tsx`, `src/components/CreateLinkForm.tsx`, `src/components/LinkList.tsx` e `src/pages/LinksPage.tsx`
- Testes: criar `src/lib/url.test.ts` e `src/pages/LinksPage.test.tsx`

**Interfaces que esta tarefa entrega:**
- `toTargetUrl(input): string | null` e `MAX_URL_LENGTH`
- `clicksLabel(n)`, `formatDate(iso)` e `formatDay('YYYY-MM-DD')`
- Os componentes `<CopyButton text>`, `<CreateLinkForm>`, `<LinkList>` e `<LinksPage>`

**Conceitos:**
- **Validação no cliente espelha a do servidor** (`src/links/url.ts` do `shortener-api`): não vazia, até 2048 caracteres, `new URL()` válido e protocolo `http:` ou `https:`. Ela existe para dar feedback rápido. Quem decide continua sendo o servidor, por isso o 400 da api também é tratado.
- **Acessibilidade de graça para os testes:** `label` ligado ao input, erro com `role="alert"`, resultado com `role="status"`. Os testes buscam pelo que o usuário vê (`getByRole`, `getByLabelText`), não por classes CSS.
- **`noValidate` no formulário:** desliga a validação nativa do navegador. Assim a mensagem é sempre a nossa, igual em todo navegador e no jsdom.

- [ ] **Passo 1: escreva o teste da validação** `src/lib/url.test.ts`

```ts
import { describe, expect, it } from 'vitest';
import { MAX_URL_LENGTH, toTargetUrl } from './url';

describe('toTargetUrl', () => {
  it('aceita http e https (com espaços em volta)', () => {
    expect(toTargetUrl('https://example.com/a?b=1')).toBe('https://example.com/a?b=1');
    expect(toTargetUrl('  http://example.com  ')).toBe('http://example.com');
  });

  it('recusa outros protocolos, texto sem esquema e vazio', () => {
    expect(toTargetUrl('ftp://example.com')).toBeNull();
    expect(toTargetUrl('javascript:alert(1)')).toBeNull();
    expect(toTargetUrl('example.com')).toBeNull();
    expect(toTargetUrl('   ')).toBeNull();
  });

  it('recusa acima do limite do servidor', () => {
    const longa = `https://example.com/${'a'.repeat(MAX_URL_LENGTH)}`;
    expect(toTargetUrl(longa)).toBeNull();
  });
});
```

- [ ] **Passo 2: escreva o teste da página** `src/pages/LinksPage.test.tsx`

```tsx
import { screen, waitFor, within } from '@testing-library/react';
import { http, HttpResponse } from 'msw';
import { describe, expect, it } from 'vitest';
import { myLink } from '../test/fixtures';
import { renderWithProviders } from '../test/render';
import { server, TEST_API } from '../test/server';
import { LinksPage } from './LinksPage';

const emptyList = () => http.get(`${TEST_API}/me/links`, () => HttpResponse.json({ items: [], nextCursor: null }));

describe('LinksPage', () => {
  it('lista meus links com total de cliques e link para o detalhe', async () => {
    server.use(
      http.get(`${TEST_API}/me/links`, () =>
        HttpResponse.json({ items: [myLink('abc1234', { totalClicks: 3 })], nextCursor: null }),
      ),
    );
    renderWithProviders(<LinksPage />, { route: '/links' });

    const item = await screen.findByRole('listitem');
    expect(item).toHaveTextContent('3 cliques');
    expect(within(item).getByRole('link', { name: '/abc1234' })).toHaveAttribute('href', '/links/abc1234');
    expect(screen.queryByRole('button', { name: 'Carregar mais' })).not.toBeInTheDocument();
  });

  it('carrega a próxima página com o cursor', async () => {
    server.use(
      http.get(`${TEST_API}/me/links`, ({ request }) => {
        const cursor = new URL(request.url).searchParams.get('cursor');
        return HttpResponse.json(
          cursor === 'c2' ? { items: [myLink('bbb2222')], nextCursor: null } : { items: [myLink('aaa1111')], nextCursor: 'c2' },
        );
      }),
    );
    const { user } = renderWithProviders(<LinksPage />, { route: '/links' });

    await user.click(await screen.findByRole('button', { name: 'Carregar mais' }));
    await waitFor(() => expect(screen.getAllByRole('listitem')).toHaveLength(2));
    expect(screen.queryByRole('button', { name: 'Carregar mais' })).not.toBeInTheDocument();
  });

  it('lista vazia convida a criar o primeiro link', async () => {
    server.use(emptyList());
    renderWithProviders(<LinksPage />, { route: '/links' });
    expect(await screen.findByText('Você ainda não criou links.')).toBeInTheDocument();
  });

  it('valida a URL no cliente sem chamar a API', async () => {
    let posted = false;
    server.use(
      emptyList(),
      http.post(`${TEST_API}/links`, () => {
        posted = true;
        return new HttpResponse(null, { status: 500 });
      }),
    );
    const { user } = renderWithProviders(<LinksPage />, { route: '/links' });

    await user.type(screen.getByLabelText('URL de destino'), 'ftp://example.com');
    await user.click(screen.getByRole('button', { name: 'Encurtar' }));

    expect(await screen.findByRole('alert')).toHaveTextContent('http:// ou https://');
    expect(posted).toBe(false);
  });

  it('cria o link, mostra a URL curta, copia e atualiza a lista', async () => {
    let created = false;
    server.use(
      http.get(`${TEST_API}/me/links`, () =>
        HttpResponse.json({ items: created ? [myLink('new1234')] : [], nextCursor: null }),
      ),
      http.post(`${TEST_API}/links`, async ({ request }) => {
        expect(await request.json()).toEqual({ url: 'https://example.com/novo' });
        created = true;
        const { totalClicks: _omit, ...link } = myLink('new1234');
        return HttpResponse.json(link, { status: 201 });
      }),
    );
    const { user } = renderWithProviders(<LinksPage />, { route: '/links' });
    const input = screen.getByLabelText('URL de destino');

    await user.type(input, 'https://example.com/novo');
    await user.click(screen.getByRole('button', { name: 'Encurtar' }));

    const status = await screen.findByRole('status');
    expect(within(status).getByRole('link', { name: 'http://localhost:3000/new1234' })).toBeInTheDocument();
    await user.click(within(status).getByRole('button', { name: 'Copiar' }));
    expect(await navigator.clipboard.readText()).toBe('http://localhost:3000/new1234');
    expect(within(status).getByRole('button', { name: 'Copiado!' })).toBeInTheDocument();

    expect(await screen.findByRole('listitem')).toHaveTextContent('/new1234');
    expect(input).toHaveValue('');
  });

  it('429 diz quanto tempo esperar', async () => {
    server.use(
      emptyList(),
      http.post(`${TEST_API}/links`, () =>
        HttpResponse.json({ error: 'rate_limited' }, { status: 429, headers: { 'Retry-After': '30' } }),
      ),
    );
    const { user } = renderWithProviders(<LinksPage />, { route: '/links' });

    await user.type(screen.getByLabelText('URL de destino'), 'https://example.com');
    await user.click(screen.getByRole('button', { name: 'Encurtar' }));

    expect(await screen.findByRole('alert')).toHaveTextContent('Muitas requisições. Tente de novo em 30 s.');
  });

  it('401 na lista dispara novo login', async () => {
    server.use(http.get(`${TEST_API}/me/links`, () => new HttpResponse(null, { status: 401 })));
    const { auth } = renderWithProviders(<LinksPage />, { route: '/links' });
    await waitFor(() => expect(auth.signinRedirect).toHaveBeenCalledWith({ state: { returnTo: '/links' } }));
  });
});
```

- [ ] **Passo 3: rode e veja falhar.** `npm test` falha com `Failed to resolve import "./url"` e `Failed to resolve import "./LinksPage"`.

- [ ] **Passo 4: implemente** `src/lib/url.ts`

```ts
// Espelha src/links/url.ts do shortener-api. Quem decide de verdade é o servidor.
export const MAX_URL_LENGTH = 2048;

export function toTargetUrl(input: string): string | null {
  const value = input.trim();
  if (value.length === 0 || value.length > MAX_URL_LENGTH) return null;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
  return value;
}
```

- [ ] **Passo 5: implemente** `src/lib/format.ts`

```ts
export function clicksLabel(n: number): string {
  return `${n.toLocaleString('pt-BR')} ${n === 1 ? 'clique' : 'cliques'}`;
}

export function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString('pt-BR');
}

// '2026-10-12' → '12/10' (sem passar por Date, para não sofrer com fuso)
export function formatDay(day: string): string {
  const [, month, date] = day.split('-');
  return `${date}/${month}`;
}
```

- [ ] **Passo 6: implemente** `src/components/CopyButton.tsx`

```tsx
import { useEffect, useState } from 'react';

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 2000);
    return () => clearTimeout(timer);
  }, [copied]);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
    } catch {
      // Sem permissão de clipboard (ex.: http fora de localhost): o link continua visível para copiar à mão.
    }
  }

  return (
    <button type="button" className="secondary" onClick={() => void copy()}>
      {copied ? 'Copiado!' : 'Copiar'}
    </button>
  );
}
```

- [ ] **Passo 7: implemente** `src/components/CreateLinkForm.tsx`

```tsx
import { useState, type FormEvent } from 'react';
import { describeError } from '../api/client';
import { useCreateLink } from '../api/hooks';
import { toTargetUrl } from '../lib/url';
import { CopyButton } from './CopyButton';

export function CreateLinkForm() {
  const [value, setValue] = useState('');
  const [clientError, setClientError] = useState<string | null>(null);
  const create = useCreateLink();

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const url = toTargetUrl(value);
    if (!url) {
      setClientError('Informe uma URL http:// ou https:// válida (até 2048 caracteres).');
      return;
    }
    setClientError(null);
    create.mutate(url, { onSuccess: () => setValue('') });
  }

  const error = clientError ?? (create.error ? describeError(create.error) : null);

  return (
    <section className="card">
      <form className="create-form" onSubmit={onSubmit} noValidate>
        <label htmlFor="target-url">URL de destino</label>
        <div className="row">
          <input
            id="target-url"
            type="url"
            inputMode="url"
            placeholder="https://..."
            value={value}
            onChange={(e) => setValue(e.target.value)}
            aria-invalid={error ? true : undefined}
            aria-describedby={error ? 'target-url-error' : undefined}
          />
          <button type="submit" disabled={create.isPending}>
            {create.isPending ? 'Encurtando…' : 'Encurtar'}
          </button>
        </div>
        {error && (
          <p id="target-url-error" role="alert" className="error">
            {error}
          </p>
        )}
      </form>
      {create.data && !error && (
        <div role="status" className="created">
          <span>Link criado:</span>
          <a href={create.data.shortUrl} target="_blank" rel="noreferrer">
            {create.data.shortUrl}
          </a>
          <CopyButton text={create.data.shortUrl} />
        </div>
      )}
    </section>
  );
}
```

- [ ] **Passo 8: implemente** `src/components/LinkList.tsx`

```tsx
import { Link } from 'react-router';
import { describeError } from '../api/client';
import { useMyLinks } from '../api/hooks';
import { clicksLabel, formatDate } from '../lib/format';
import { CopyButton } from './CopyButton';

export function LinkList() {
  const query = useMyLinks();

  if (query.isPending) return <p className="muted">Carregando links…</p>;
  if (query.isLoadingError) return <p role="alert" className="error">{describeError(query.error)}</p>;

  const items = query.data.pages.flatMap((page) => page.items);
  if (items.length === 0) return <p className="muted">Você ainda não criou links.</p>;

  return (
    <section>
      <ul className="link-list">
        {items.map((link) => (
          <li key={link.code} className="link-item">
            <div className="link-main">
              <Link to={`/links/${link.code}`} className="code">/{link.code}</Link>
              <a href={link.shortUrl} target="_blank" rel="noreferrer">{link.shortUrl}</a>
              <span className="dest" title={link.url}>{link.url}</span>
            </div>
            <div className="link-meta">
              <span>{clicksLabel(link.totalClicks)}</span>
              <span className="muted">{formatDate(link.createdAt)}</span>
              <CopyButton text={link.shortUrl} />
            </div>
          </li>
        ))}
      </ul>
      {query.isError && <p role="alert" className="error">{describeError(query.error)}</p>}
      {query.hasNextPage && (
        <button
          type="button"
          className="secondary more"
          onClick={() => void query.fetchNextPage()}
          disabled={query.isFetchingNextPage}
        >
          {query.isFetchingNextPage ? 'Carregando…' : 'Carregar mais'}
        </button>
      )}
    </section>
  );
}
```

- [ ] **Passo 9: implemente** `src/pages/LinksPage.tsx`

```tsx
import { CreateLinkForm } from '../components/CreateLinkForm';
import { LinkList } from '../components/LinkList';

export function LinksPage() {
  return (
    <>
      <h1>Meus links</h1>
      <CreateLinkForm />
      <h2>Criados por você</h2>
      <LinkList />
    </>
  );
}
```

- [ ] **Passo 10: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 11: commit**

```bash
git add -A && git commit -m "feat: página Meus links com criação, cópia e paginação"
```

**Pronto quando:** os testes de validação, criação, cópia, paginação, 429 e 401 passam.

---

## Tarefa 3.7: página de detalhe com gráfico SVG

**Arquivos:**
- Criar `src/lib/days.ts`, `src/components/DailyChart.tsx` e `src/pages/LinkDetailPage.tsx`
- Testes: criar `src/lib/days.test.ts` e `src/pages/LinkDetailPage.test.tsx`

**Interfaces que esta tarefa entrega:**
- `lastNDays(daily, today, n = 30): DailyClicks[]`, que preenche com zero os dias sem clique
- Os componentes `<DailyChart days>` e `<LinkDetailPage>`

**Conceitos:**
- **A api só manda os dias com clique.** O gráfico precisa dos 30 dias, então completamos com zero no cliente.
- **Dia em UTC:** o Postgres do compose e o RDS rodam em UTC, e `current_date` da query das stats é UTC. Montamos as chaves `YYYY-MM-DD` em UTC também, para as barras baterem com o servidor. Perto da meia-noite no Brasil, "hoje" no gráfico já é amanhã: é o esperado.
- **Gráfico sem lib:** um `<svg viewBox>` com um `<rect>` por dia escala sozinho com CSS (`width: 100%`). O `<title>` de cada barra vira tooltip nativo e texto acessível.
- **404 não vaza existência:** a api devolve 404 tanto para link inexistente quanto para link de outra pessoa. A mensagem diz as duas coisas.

- [ ] **Passo 1: escreva o teste** `src/lib/days.test.ts`

```ts
import { describe, expect, it } from 'vitest';
import { lastNDays } from './days';

const today = new Date('2026-10-12T23:30:00Z');

describe('lastNDays', () => {
  it('devolve 30 dias terminando hoje (UTC), com zero onde não houve clique', () => {
    const days = lastNDays(
      [
        { day: '2026-10-12', clicks: 3 },
        { day: '2026-09-13', clicks: 1 },
      ],
      today,
    );
    expect(days).toHaveLength(30);
    expect(days[0]).toEqual({ day: '2026-09-13', clicks: 1 });
    expect(days[1]).toEqual({ day: '2026-09-14', clicks: 0 });
    expect(days[29]).toEqual({ day: '2026-10-12', clicks: 3 });
  });

  it('ignora dias fora da janela', () => {
    const days = lastNDays([{ day: '2026-09-12', clicks: 9 }], today);
    expect(days.reduce((sum, d) => sum + d.clicks, 0)).toBe(0);
  });
});
```

- [ ] **Passo 2: escreva o teste da página** `src/pages/LinkDetailPage.test.tsx`

```tsx
import { screen, within } from '@testing-library/react';
import { http, HttpResponse } from 'msw';
import { Route, Routes } from 'react-router';
import { describe, expect, it } from 'vitest';
import { stats } from '../test/fixtures';
import { renderWithProviders } from '../test/render';
import { server, TEST_API } from '../test/server';
import { LinkDetailPage } from './LinkDetailPage';

const ui = (
  <Routes>
    <Route path="/links/:code" element={<LinkDetailPage />} />
  </Routes>
);

describe('LinkDetailPage', () => {
  it('mostra total, 30 barras e a tabela de navegadores', async () => {
    const today = new Date().toISOString().slice(0, 10);
    server.use(
      http.get(`${TEST_API}/links/abc1234/stats`, () =>
        HttpResponse.json(
          stats({
            totalClicks: 5,
            daily: [{ day: today, clicks: 3 }],
            browsers: [
              { browser: 'Chrome', clicks: 4 },
              { browser: 'Firefox', clicks: 1 },
            ],
          }),
        ),
      ),
    );
    const { container } = renderWithProviders(ui, { route: '/links/abc1234' });

    expect(await screen.findByTestId('total-clicks')).toHaveTextContent('5');

    const bars = container.querySelectorAll('rect.bar');
    expect(bars).toHaveLength(30);
    expect(bars[29]).toHaveAttribute('data-clicks', '3');
    expect(bars[0]).toHaveAttribute('data-clicks', '0');

    const rows = within(screen.getByRole('table')).getAllByRole('row');
    expect(rows).toHaveLength(3); // cabeçalho + 2 navegadores
    expect(within(rows[1]).getAllByRole('cell').map((c) => c.textContent)).toEqual(['Chrome', '4']);
  });

  it('sem cliques mostra aviso no lugar da tabela', async () => {
    server.use(http.get(`${TEST_API}/links/abc1234/stats`, () => HttpResponse.json(stats())));
    renderWithProviders(ui, { route: '/links/abc1234' });
    expect(await screen.findByText('Nenhum clique ainda.')).toBeInTheDocument();
    expect(screen.queryByRole('table')).not.toBeInTheDocument();
  });

  it('404 mostra mensagem amigável com caminho de volta', async () => {
    server.use(
      http.get(`${TEST_API}/links/abc1234/stats`, () => HttpResponse.json({ error: 'not_found' }, { status: 404 })),
    );
    renderWithProviders(ui, { route: '/links/abc1234' });
    expect(await screen.findByRole('heading', { name: 'Link não encontrado' })).toBeInTheDocument();
    expect(screen.getByRole('link', { name: 'Voltar para meus links' })).toHaveAttribute('href', '/links');
  });
});
```

- [ ] **Passo 3: rode e veja falhar.** `npm test` falha com `Failed to resolve import "./days"` e `Failed to resolve import "./LinkDetailPage"`.

- [ ] **Passo 4: implemente** `src/lib/days.ts`

```ts
import type { DailyClicks } from '../api/client';

export function lastNDays(daily: DailyClicks[], today: Date, n = 30): DailyClicks[] {
  const byDay = new Map(daily.map((d) => [d.day, d.clicks]));
  const result: DailyClicks[] = [];
  for (let offset = n - 1; offset >= 0; offset--) {
    // Date.UTC normaliza dia negativo (ex.: 12 - 29 → mês anterior).
    const date = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() - offset));
    const day = date.toISOString().slice(0, 10);
    result.push({ day, clicks: byDay.get(day) ?? 0 });
  }
  return result;
}
```

- [ ] **Passo 5: implemente** `src/components/DailyChart.tsx`

```tsx
import type { DailyClicks } from '../api/client';
import { clicksLabel, formatDay } from '../lib/format';

const WIDTH = 600;
const HEIGHT = 160;
const AXIS_GAP = 20; // espaço para as datas embaixo

export function DailyChart({ days }: { days: DailyClicks[] }) {
  const max = Math.max(1, ...days.map((d) => d.clicks));
  const plotHeight = HEIGHT - AXIS_GAP;
  const slot = WIDTH / days.length;
  const barWidth = slot * 0.7;
  const first = days[0]?.day ?? '';
  const last = days[days.length - 1]?.day ?? '';

  return (
    <figure className="chart">
      <svg
        viewBox={`0 0 ${WIDTH} ${HEIGHT}`}
        role="img"
        aria-label={`Cliques por dia de ${formatDay(first)} a ${formatDay(last)}; máximo de ${max} em um dia`}
      >
        <line x1={0} y1={plotHeight} x2={WIDTH} y2={plotHeight} className="axis" />
        {days.map((d, i) => {
          const height = (d.clicks / max) * (plotHeight - 4);
          return (
            <rect
              key={d.day}
              className="bar"
              x={i * slot + (slot - barWidth) / 2}
              y={plotHeight - height}
              width={barWidth}
              height={height}
              data-day={d.day}
              data-clicks={d.clicks}
            >
              <title>{`${formatDay(d.day)}: ${clicksLabel(d.clicks)}`}</title>
            </rect>
          );
        })}
        <text x={0} y={HEIGHT - 4} className="tick">{formatDay(first)}</text>
        <text x={WIDTH} y={HEIGHT - 4} className="tick" textAnchor="end">{formatDay(last)}</text>
      </svg>
    </figure>
  );
}
```

- [ ] **Passo 6: implemente** `src/pages/LinkDetailPage.tsx`

```tsx
import { Link, useParams } from 'react-router';
import { ApiError, describeError } from '../api/client';
import { useStats } from '../api/hooks';
import { DailyChart } from '../components/DailyChart';
import { lastNDays } from '../lib/days';

export function LinkDetailPage() {
  const { code = '' } = useParams();
  const query = useStats(code);

  if (query.isPending) return <p className="muted">Carregando estatísticas…</p>;

  if (query.isError) {
    if (query.error instanceof ApiError && query.error.status === 404) {
      return (
        <section className="card">
          <h1>Link não encontrado</h1>
          <p className="muted">Ele não existe ou pertence a outra conta.</p>
          <Link to="/links">Voltar para meus links</Link>
        </section>
      );
    }
    return <p role="alert" className="error">{describeError(query.error)}</p>;
  }

  const stats = query.data;
  return (
    <>
      <p>
        <Link to="/links">← Meus links</Link>
      </p>
      <h1>/{stats.code}</h1>
      <p className="dest">
        Destino: <a href={stats.url} target="_blank" rel="noreferrer">{stats.url}</a>
      </p>

      <section className="card stat">
        <span className="muted">Total de cliques</span>
        <strong data-testid="total-clicks">{stats.totalClicks.toLocaleString('pt-BR')}</strong>
      </section>

      <h2>Últimos 30 dias</h2>
      <DailyChart days={lastNDays(stats.daily, new Date())} />

      <h2>Navegadores</h2>
      {stats.browsers.length === 0 ? (
        <p className="muted">Nenhum clique ainda.</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Navegador</th>
              <th className="num">Cliques</th>
            </tr>
          </thead>
          <tbody>
            {stats.browsers.map((b) => (
              <tr key={b.browser}>
                <td>{b.browser}</td>
                <td className="num">{b.clicks.toLocaleString('pt-BR')}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
```

- [ ] **Passo 7: rode e veja passar.** `npm test && npm run typecheck && npm run lint`.

- [ ] **Passo 8: commit**

```bash
git add -A && git commit -m "feat: detalhe do link com gráfico SVG de 30 dias e navegadores"
```

**Pronto quando:** os testes de 30 barras, tabela, sem cliques e 404 passam.

---

## Tarefa 3.8: rotas, layout, landing, 404 e estilo

**Arquivos:**
- Criar `src/components/Layout.tsx`, `src/pages/Landing.tsx` e `src/pages/NotFound.tsx`
- Substituir o conteúdo de `src/App.tsx`, `src/main.tsx` e `src/index.css` (gerados pelo template)
- Apagar `src/App.css`, `src/assets/` e `public/icons.svg` (do template)
- Testes: criar `src/App.test.tsx`

**Interfaces que esta tarefa entrega:**
- `<AppRoutes>`, com as rotas `/`, `/callback`, `/links`, `/links/:code` e `*`
- `<Layout>` (topo com usuário e "Sair"), `<Landing>` e `<NotFound>`
- O ponto de entrada `main.tsx`, que mostra uma tela de erro de configuração se o `config.js` estiver inválido

**Conceitos:**
- **Modo declarativo do React Router:** `<BrowserRouter>` + `<Routes>`/`<Route>`. Uma rota sem `path` com `element={<RequireAuth><Layout/></RequireAuth>}` protege todas as filhas de uma vez, e o `<Outlet/>` do layout renderiza a filha da vez.
- **Por que `AppRoutes` separado do `BrowserRouter`:** nos testes, a mesma árvore de rotas roda dentro de um `MemoryRouter`, com a URL inicial que quisermos.

- [ ] **Passo 1: escreva o teste** `src/App.test.tsx`

```tsx
import { screen, waitFor } from '@testing-library/react';
import { http, HttpResponse } from 'msw';
import { describe, expect, it } from 'vitest';
import { AppRoutes } from './App';
import { anonymousAuth, renderWithProviders } from './test/render';
import { server, TEST_API } from './test/server';

const emptyList = () => http.get(`${TEST_API}/me/links`, () => HttpResponse.json({ items: [], nextCursor: null }));

describe('rotas', () => {
  it('anônimo em / vê "Entrar", que inicia o login rumo a /links', async () => {
    const { user, auth } = renderWithProviders(<AppRoutes />, { route: '/', auth: anonymousAuth() });
    await user.click(screen.getByRole('button', { name: 'Entrar' }));
    expect(auth.signinRedirect).toHaveBeenCalledWith({ state: { returnTo: '/links' } });
  });

  it('logado em / vai direto para /links, com o e-mail no topo', async () => {
    server.use(emptyList());
    renderWithProviders(<AppRoutes />, { route: '/' });
    expect(await screen.findByRole('heading', { name: 'Meus links' })).toBeInTheDocument();
    expect(screen.getByText('ana@example.com')).toBeInTheDocument();
  });

  it('anônimo em /links é mandado ao login', async () => {
    const { auth } = renderWithProviders(<AppRoutes />, { route: '/links', auth: anonymousAuth() });
    await waitFor(() => expect(auth.signinRedirect).toHaveBeenCalledWith({ state: { returnTo: '/links' } }));
  });

  it('"Sair" encerra a sessão no IdP', async () => {
    server.use(emptyList());
    const { user, auth } = renderWithProviders(<AppRoutes />, { route: '/links' });
    await user.click(await screen.findByRole('button', { name: 'Sair' }));
    expect(auth.signoutRedirect).toHaveBeenCalledTimes(1);
  });

  it('rota desconhecida mostra 404', () => {
    renderWithProviders(<AppRoutes />, { route: '/nao/existe', auth: anonymousAuth() });
    expect(screen.getByRole('heading', { name: 'Página não encontrada' })).toBeInTheDocument();
  });
});
```

- [ ] **Passo 2: rode e veja falhar.** `npm test` falha: `src/App.tsx` (do template) não exporta `AppRoutes` (`AppRoutes is not exported` ou *element type is invalid*).

- [ ] **Passo 3: limpe o que o template trouxe e não usamos**

```bash
rm -rf src/App.css src/assets public/icons.svg
```

- [ ] **Passo 4: crie** `src/components/Layout.tsx`

```tsx
import { useAuth } from 'react-oidc-context';
import { Link, Outlet } from 'react-router';
import { useLogout } from '../auth/useLogout';

export function Layout() {
  const auth = useAuth();
  const logout = useLogout();
  const who = auth.user?.profile.email ?? auth.user?.profile.sub;

  return (
    <>
      <header className="topbar">
        <Link to="/links" className="brand">shortener</Link>
        <span className="spacer" />
        {who && <span className="muted">{who}</span>}
        <button type="button" className="secondary" onClick={() => void logout()}>
          Sair
        </button>
      </header>
      <main className="container">
        <Outlet />
      </main>
    </>
  );
}
```

- [ ] **Passo 5: crie** `src/pages/Landing.tsx`

```tsx
import { useAuth } from 'react-oidc-context';
import { Navigate } from 'react-router';

export function Landing() {
  const auth = useAuth();

  if (auth.isLoading) {
    return (
      <main className="container">
        <p className="muted">Carregando…</p>
      </main>
    );
  }
  if (auth.isAuthenticated) return <Navigate to="/links" replace />;

  return (
    <main className="container landing">
      <h1>shortener</h1>
      <p>Encurte URLs e acompanhe os cliques de cada link.</p>
      <button type="button" onClick={() => void auth.signinRedirect({ state: { returnTo: '/links' } })}>
        Entrar
      </button>
    </main>
  );
}
```

- [ ] **Passo 6: crie** `src/pages/NotFound.tsx`

```tsx
import { Link } from 'react-router';

export function NotFound() {
  return (
    <main className="container">
      <h1>Página não encontrada</h1>
      <p className="muted">Esse endereço não existe no painel.</p>
      <Link to="/">Voltar ao início</Link>
    </main>
  );
}
```

- [ ] **Passo 7: substitua** `src/App.tsx`

```tsx
import { Route, Routes } from 'react-router';
import { CallbackPage } from './auth/CallbackPage';
import { RequireAuth } from './auth/RequireAuth';
import { Layout } from './components/Layout';
import { Landing } from './pages/Landing';
import { LinkDetailPage } from './pages/LinkDetailPage';
import { LinksPage } from './pages/LinksPage';
import { NotFound } from './pages/NotFound';

export function AppRoutes() {
  return (
    <Routes>
      <Route path="/" element={<Landing />} />
      <Route path="/callback" element={<CallbackPage />} />
      <Route
        element={
          <RequireAuth>
            <Layout />
          </RequireAuth>
        }
      >
        <Route path="/links" element={<LinksPage />} />
        <Route path="/links/:code" element={<LinkDetailPage />} />
      </Route>
      <Route path="*" element={<NotFound />} />
    </Routes>
  );
}
```

- [ ] **Passo 8: substitua** `src/main.tsx`

```tsx
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClientProvider } from '@tanstack/react-query';
import { BrowserRouter } from 'react-router';
import './index.css';
import { AppRoutes } from './App';
import { createQueryClient } from './api/queryClient';
import { AppAuthProvider } from './auth/AuthProvider';
import { getConfig } from './config';

const root = createRoot(document.getElementById('root')!);

try {
  getConfig(); // falha cedo e de forma visível se o /runtime/config.js estiver errado
  const queryClient = createQueryClient();
  root.render(
    <StrictMode>
      <AppAuthProvider>
        <QueryClientProvider client={queryClient}>
          <BrowserRouter>
            <AppRoutes />
          </BrowserRouter>
        </QueryClientProvider>
      </AppAuthProvider>
    </StrictMode>,
  );
} catch (err) {
  root.render(
    <main className="container">
      <h1>Erro de configuração</h1>
      <pre role="alert">{err instanceof Error ? err.message : String(err)}</pre>
    </main>,
  );
}
```

- [ ] **Passo 9: substitua** `src/index.css`

```css
:root {
  --bg: #f6f7f9;
  --surface: #ffffff;
  --text: #1d2330;
  --muted: #5f6b7a;
  --border: #dde2e8;
  --accent: #2f6fde;
  --accent-text: #ffffff;
  --error: #b3261e;
  --radius: 8px;
  font-family: system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif;
  line-height: 1.5;
  color: var(--text);
  background: var(--bg);
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14171c;
    --surface: #1d2128;
    --text: #e6e9ee;
    --muted: #9aa5b1;
    --border: #2e343d;
    --accent: #6c9cf0;
    --accent-text: #0b1220;
    --error: #f2b8b5;
  }
}

* { box-sizing: border-box; }
body { margin: 0; }
a { color: var(--accent); }
h1 { font-size: 1.6rem; margin: 0 0 1rem; }
h2 { font-size: 1.1rem; margin: 1.5rem 0 0.5rem; }
pre { white-space: pre-wrap; }

.container { max-width: 880px; margin: 0 auto; padding: 1.5rem 1rem; }
.muted { color: var(--muted); }
.error { color: var(--error); }
.spacer { flex: 1; }

.topbar {
  display: flex;
  align-items: center;
  gap: 1rem;
  padding: 0.75rem 1rem;
  background: var(--surface);
  border-bottom: 1px solid var(--border);
}
.brand { font-weight: 700; color: var(--text); text-decoration: none; }

.card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1rem;
  margin-bottom: 1.5rem;
}

button {
  font: inherit;
  padding: 0.45rem 0.9rem;
  border: 1px solid var(--accent);
  border-radius: 6px;
  background: var(--accent);
  color: var(--accent-text);
  cursor: pointer;
}
button:disabled { opacity: 0.6; cursor: default; }
button.secondary { background: transparent; color: var(--accent); }

input {
  font: inherit;
  padding: 0.45rem 0.6rem;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--bg);
  color: var(--text);
}
input[aria-invalid='true'] { border-color: var(--error); }

.create-form label { display: block; font-weight: 600; margin-bottom: 0.35rem; }
.create-form .row { display: flex; gap: 0.5rem; }
.create-form input { flex: 1; min-width: 0; }
.created { display: flex; flex-wrap: wrap; align-items: center; gap: 0.5rem; margin-top: 0.75rem; }

.link-list { list-style: none; margin: 0; padding: 0; }
.link-item {
  display: flex;
  justify-content: space-between;
  gap: 1rem;
  padding: 0.75rem 0;
  border-bottom: 1px solid var(--border);
}
.link-main { display: flex; flex-direction: column; min-width: 0; }
.link-main .code { font-weight: 600; }
.dest { color: var(--muted); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.link-meta { display: flex; align-items: center; gap: 0.75rem; white-space: nowrap; }
.more { margin-top: 1rem; }

.stat strong { display: block; font-size: 2rem; }

.chart { margin: 0; }
.chart svg { display: block; width: 100%; height: auto; }
.chart .bar { fill: var(--accent); }
.chart .axis { stroke: var(--border); }
.chart .tick { fill: var(--muted); font-size: 12px; }

table { width: 100%; max-width: 420px; border-collapse: collapse; }
th, td { padding: 0.4rem 0.5rem; text-align: left; border-bottom: 1px solid var(--border); }
th.num, td.num { text-align: right; }

.landing { padding-top: 4rem; text-align: center; }

@media (max-width: 560px) {
  .link-item { flex-direction: column; }
}
```

- [ ] **Passo 10: rode e veja passar.** `npm test && npm run typecheck && npm run lint && npm run build`.

- [ ] **Passo 11: teste no navegador contra o compose.** No `shortener-api`, suba tudo:

```bash
cd ~/Documents/projects/shortener-api
docker compose --profile app up -d --build
cd ~/Documents/projects/shortener-web
npm run dev
```

Em `http://localhost:5173`:
1. Clique em **Entrar**. A tela do mock abre; digite qualquer usuário (`ana`) e clique em **Sign-in**.
2. Você volta em `/links`. Crie um link e copie a URL curta.
3. Abra a URL curta numa aba. Ela redireciona para o destino.
4. Volte e abra o detalhe do link. O clique aparece em alguns segundos: o worker processa de forma assíncrona, e a api guarda as stats em cache por 60 s.
5. No DevTools → Application → Session Storage, veja a chave `oidc.user:http://localhost:8090/shortener:shortener-web`.
6. Clique em **Sair**. Você volta à landing.

- [ ] **Passo 12: commit**

```bash
git add -A && git commit -m "feat: rotas, layout, landing, 404 e estilo"
```

**Pronto quando:** os testes passam e o fluxo do passo 11 funciona no navegador.

---

## Tarefa 3.9: e2e com Playwright (local)

**Arquivos:**
- Reescrever `playwright.config.ts` (gerado na Tarefa 3.1)
- Criar `e2e/fluxo.spec.ts`

**Interfaces que esta tarefa entrega:**
- `npm run test:e2e` contra o Vite (padrão) ou contra o container (`E2E_BASE_URL=http://localhost:8081`)

**Conceitos:**
- **E2E prova a integração**, que os testes com MSW não cobrem: o redirect real ao IdP, o PKCE de verdade, o CORS da api, o Kafka, o worker e o Postgres.
- **Assíncrono de verdade:** o clique vira evento no Kafka, e só depois o worker grava no banco. Além disso, a api guarda `GET /links/:code/stats` em cache por **60 s**. Se abrirmos o detalhe **antes** de o worker processar, o cache guarda "0 cliques" por um minuto. Para evitar isso, esperamos o clique na **lista** (`/me/links`, que lê do banco sem cache) com `expect(...).toPass()`, recarregando a página. Só depois abrimos o detalhe. Assim, o primeiro `GET` de stats já acontece com o clique gravado.
- **Sem internet:** o redirect é conferido com `page.request.get(shortUrl, { maxRedirects: 0 })`: status 302 e header `Location`. Não seguimos até `example.com`. O request conta como clique, como qualquer acesso.
- **Usuário novo por execução** (`e2e-<timestamp>`): o `username` do formulário do mock vira o `sub`. Com isso, a lista começa vazia e o teste não depende de execuções anteriores.

**Pré-requisito:** no `shortener-api`, `docker compose --profile app up -d --build`. Isso sobe api (com CORS para 5173 e 8081), worker, setup, infra e o IdP mock.

- [ ] **Passo 1: escreva o teste** `e2e/fluxo.spec.ts`

```ts
import { expect, test } from '@playwright/test';

test('login no mock → criar link → abrir a URL curta → ver o clique nas stats', async ({ page }) => {
  test.setTimeout(90_000);
  const id = Date.now().toString(36);
  const destino = `https://example.com/e2e-${id}`;

  // 1. Login: o botão leva ao /authorize do mock-oauth2-server (login interativo).
  await page.goto('/');
  await page.getByRole('button', { name: 'Entrar' }).click();
  await page.waitForURL(/localhost:8090\/shortener\/authorize/);
  await page.locator('input[name="username"]').fill(`e2e-${id}`); // vira o "sub" do token
  await page.getByRole('button', { name: 'Sign-in' }).click();
  await expect(page).toHaveURL(/\/links$/);
  await expect(page.getByText('Você ainda não criou links.')).toBeVisible();

  // 2. Criar o link.
  await page.getByLabel('URL de destino').fill(destino);
  await page.getByRole('button', { name: 'Encurtar' }).click();
  const shortUrl = (await page.getByRole('status').getByRole('link').textContent()) ?? '';
  expect(shortUrl).toMatch(/^http:\/\/localhost:3000\/[A-Za-z0-9]+$/);
  const code = shortUrl.split('/').pop() ?? '';

  // 3. Abrir a URL curta: 302 para o destino (sem seguir, para não depender da internet).
  const res = await page.request.get(shortUrl, { maxRedirects: 0 });
  expect(res.status()).toBe(302);
  expect(res.headers()['location']).toBe(destino);

  // 4. Esperar o worker: a lista lê do banco sem cache. Só abrimos o detalhe depois,
  //    para o cache de 60 s das stats não guardar "0 cliques".
  const row = page.getByRole('listitem').filter({ hasText: shortUrl });
  await expect(async () => {
    await page.reload();
    await expect(row).toContainText('1 clique', { timeout: 2_000 });
  }).toPass({ timeout: 45_000 });

  // 5. Detalhe com o clique.
  // exact: o nome casa por substring, e "/<code>" também está dentro da URL curta da mesma linha.
  await row.getByRole('link', { name: `/${code}`, exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/links/${code}$`));
  await expect(page.getByTestId('total-clicks')).toHaveText('1');
  await expect(page.getByRole('table').getByRole('row')).toHaveCount(2); // cabeçalho + 1 navegador

  // 6. Logout volta para a landing.
  await page.getByRole('button', { name: 'Sair' }).click();
  await expect(page.getByRole('button', { name: 'Entrar' })).toBeVisible();
});
```

- [ ] **Passo 2: rode e veja falhar.** Com o compose **parado** (`docker compose --profile app down` no `shortener-api`), rode `npm run test:e2e`. O config gerado pela CLI ainda não sobe o Vite nem tem `baseURL`, então o teste falha em `page.goto('/')` com `Cannot navigate to invalid URL`.

- [ ] **Passo 3: reescreva** `playwright.config.ts`

```ts
import { defineConfig, devices } from '@playwright/test';

// Padrão: Vite em 5173. Para testar o container: E2E_BASE_URL=http://localhost:8081 npm run test:e2e
const externalBaseUrl = process.env.E2E_BASE_URL;
const baseURL = externalBaseUrl ?? 'http://localhost:5173';

export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  workers: 1, // um fluxo só, e ele depende de estado no compose
  retries: 0,
  forbidOnly: !!process.env.CI,
  reporter: 'list',
  use: {
    baseURL,
    trace: 'retain-on-failure', // npx playwright show-trace test-results/.../trace.zip
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: externalBaseUrl
    ? undefined
    : {
        command: 'npm run dev',
        url: 'http://localhost:5173',
        reuseExistingServer: true,
        timeout: 60_000,
      },
});
```

- [ ] **Passo 4: rode ainda sem o compose.** `npm run test:e2e`: agora o Vite sobe, mas o teste falha no `waitForURL(/localhost:8090.../authorize/)`. Sem o IdP, o `oidc-client-ts` não consegue ler a *discovery*. Essa é a falha certa.

- [ ] **Passo 5: suba o compose e rode de novo**

```bash
(cd ~/Documents/projects/shortener-api && docker compose --profile app up -d --build)
npm run test:e2e
```

Esperado: `1 passed`. Se falhar, abra o trace (`npx playwright show-trace test-results/*/trace.zip`). Falhas comuns:
- Erro de CORS no console: confira `CORS_ALLOWED_ORIGINS` da api no compose.
- 401 na api: confira se o token do mock tem `aud = shortener-web` (token callback da Fase 2).
- Timeout no passo 4: rode `docker compose logs worker` para ver se o worker está consumindo.

- [ ] **Passo 6: confira o typecheck.** `npm run typecheck` também cobre `e2e/` e o `playwright.config.ts` (Tarefa 3.1, passo 11).

- [ ] **Passo 7: commit**

```bash
git add -A && git commit -m "test: e2e local com Playwright (login, criar, clicar, stats)"
```

**Pronto quando:** `npm run test:e2e` passa com o compose de pé.

---

## Tarefa 3.10: imagem nginx com config de runtime

**Arquivos:**
- Criar `nginx/default.conf`, `nginx/security-headers.conf`, `nginx/40-runtime-config.sh`, `nginx/test-runtime-config.sh`, `scripts/smoke-container.sh`, `Dockerfile` e `.dockerignore`

**Interfaces que esta tarefa entrega:**
- Imagem `shortener-web`: porta **8080**, usuário **101**
- Env vars: `API_BASE_URL`, `OIDC_AUTHORITY` e `OIDC_CLIENT_ID` (obrigatórias); `OIDC_LOGOUT_URL` (opcional)
- Endpoints: `/healthz` → `200 ok`; `/runtime/config.js` gerado na subida; fallback de SPA
- Diretórios graváveis com root FS somente leitura: `/tmp` e `/usr/share/nginx/html/runtime`
- `scripts/smoke-container.sh [base-url]`

**Conceitos:**
- **Multi-stage:** o estágio `node:24-slim` instala e builda. A imagem final só tem nginx e os arquivos estáticos: sem Node, sem `node_modules` e sem código-fonte.
- **Cache busting com hash:** o Vite gera `assets/index-3f9a1c.js`. Se o conteúdo muda, o nome muda. Por isso `/assets/*` pode ter `max-age` de 1 ano e `immutable`, e o navegador nem revalida. Já o `index.html` (que aponta para os nomes novos) e o `config.js` (que muda por ambiente) usam `no-store`, para que o navegador sempre pegue a versão atual.
- **Asset inexistente é 404, não `index.html`.** Se o fallback de SPA respondesse `index.html` para `/assets/velho.js`, o navegador receberia HTML com tipo de JS e quebraria de forma confusa. No blue-green da Fase 7, o 404 é o sinal claro.
- **nginx não-root** (`nginxinc/nginx-unprivileged`): o processo roda como UID 101 e escuta na 8080, porque portas abaixo de 1024 exigem root. Se alguém explorar o nginx, não vira root no container. No K8s, isso combina com `runAsNonRoot` e `readOnlyRootFilesystem`. A imagem já põe o pid e os diretórios temporários em `/tmp`. Então, com root FS somente leitura, só `/tmp` e o diretório do `config.js` precisam ser graváveis (`emptyDir` no K8s).
- **Gerar JS a partir de env com segurança.** A imagem alpine não tem `jq` nem Node, então geramos o arquivo com `printf`. O risco é um valor com `"` ou quebra de linha virar código JS. A defesa é uma **allowlist por regex**: URLs só com `http(s)://`, host, porta e caminho com caracteres seguros, e client id só com `[A-Za-z0-9._-]`. Também recusamos qualquer quebra de linha. Nenhum caractere aceito precisa de escape numa string JS, então o `printf '%s'` não consegue produzir JS inválido nem injetar código. Valor fora do padrão faz o container **não subir**, com mensagem clara.
- **`/docker-entrypoint.d/`:** o entrypoint da imagem roda, em ordem, os `*.sh` executáveis dessa pasta antes do nginx, com `set -e`. Se o script falha, o container sai com erro (*fail fast*, como no `config.ts` da api).
- **Headers de segurança e a pegadinha do `add_header`:** um `location` que tem qualquer `add_header` **não herda** os do `server`. Por isso os headers de segurança ficam num snippet incluído no `server` e em cada `location` que define `Cache-Control`.

- [ ] **Passo 1: escreva o teste do gerador** `nginx/test-runtime-config.sh`

Ele roda **dentro da imagem do nginx**, com o mesmo busybox de produção.

```sh
#!/bin/sh
# Testa o 40-runtime-config.sh dentro da imagem do nginx (mesmo busybox de produção).
set -u

script="$(dirname "$0")/40-runtime-config.sh"
dir="$(mktemp -d)"
falhas=0

ok_api='API_BASE_URL=https://api.shortener-staging.fabricioroglio.com'
ok_auth='OIDC_AUTHORITY=https://cognito-idp.us-east-1.amazonaws.com/us-east-1_AbC123'
ok_id='OIDC_CLIENT_ID=shortener-web'

gera() { # uso: gera VAR=valor...
  rm -f "$dir/config.js"
  env -i PATH="$PATH" RUNTIME_CONFIG_DIR="$dir" "$@" sh "$script" >/dev/null 2>&1
}

passa() {
  desc="$1"; shift
  if gera "$@"; then echo "ok    - $desc"; else echo "FALHA - $desc (devia passar)"; falhas=$((falhas + 1)); fi
}

recusa() {
  desc="$1"; shift
  if gera "$@"; then echo "FALHA - $desc (devia recusar)"; falhas=$((falhas + 1)); else echo "ok    - $desc"; fi
}

contem() {
  if grep -qF "$1" "$dir/config.js" 2>/dev/null; then echo "ok    - config.js contém $1"
  else echo "FALHA - config.js não contém $1"; falhas=$((falhas + 1)); fi
}

passa 'variáveis válidas (staging)' "$ok_api" "$ok_auth" "$ok_id" \
  'OIDC_LOGOUT_URL=https://shortener-staging-x1y2.auth.us-east-1.amazoncognito.com/logout'
contem 'window.__APP_CONFIG__ = {'
contem '"apiBaseUrl": "https://api.shortener-staging.fabricioroglio.com",'
contem '"oidcAuthority": "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_AbC123",'
contem '"oidcLogoutUrl": "https://shortener-staging-x1y2.auth.us-east-1.amazoncognito.com/logout"'

passa 'logout é opcional' "$ok_api" "$ok_auth" "$ok_id"
if grep -q oidcLogoutUrl "$dir/config.js" 2>/dev/null; then
  echo "FALHA - oidcLogoutUrl apareceu sem a variável"; falhas=$((falhas + 1))
else
  echo "ok    - sem OIDC_LOGOUT_URL, sem oidcLogoutUrl"
fi

passa 'URLs de dev com porta' 'API_BASE_URL=http://localhost:3000' \
  'OIDC_AUTHORITY=http://localhost:8090/shortener' "$ok_id"

recusa 'falta API_BASE_URL' "$ok_auth" "$ok_id"
recusa 'falta OIDC_AUTHORITY' "$ok_api" "$ok_id"
recusa 'falta OIDC_CLIENT_ID' "$ok_api" "$ok_auth"
recusa 'aspas na URL' 'API_BASE_URL=https://x.com/"+alert(1)+"' "$ok_auth" "$ok_id"
recusa 'protocolo javascript:' 'API_BASE_URL=javascript:alert(1)' "$ok_auth" "$ok_id"
recusa 'quebra de linha' "API_BASE_URL=https://x.com
\"};alert(1);//" "$ok_auth" "$ok_id"
recusa 'client id com espaço' "$ok_api" "$ok_auth" 'OIDC_CLIENT_ID=a b'
recusa 'logout inválido' "$ok_api" "$ok_auth" "$ok_id" 'OIDC_LOGOUT_URL=ftp://x.com/logout'

if [ "$falhas" -eq 0 ]; then echo "todos os testes passaram"; else echo "$falhas falha(s)"; exit 1; fi
```

- [ ] **Passo 2: rode e veja falhar**

```bash
docker run --rm -v "$PWD/nginx:/t:ro" --entrypoint sh \
  nginxinc/nginx-unprivileged:1.30.5-alpine3.24 /t/test-runtime-config.sh
```

Esperado: vários `FALHA - ... (devia passar)`, porque o script ainda não existe, e saída `N falha(s)` com código 1.

- [ ] **Passo 3: implemente** `nginx/40-runtime-config.sh`

```sh
#!/bin/sh
# Gera o /runtime/config.js a partir das variáveis de ambiente.
# Roda pelo /docker-entrypoint.sh da imagem do nginx, antes do nginx subir.
set -eu

out_dir="${RUNTIME_CONFIG_DIR:-/usr/share/nginx/html/runtime}"
out_file="$out_dir/config.js"

fail() {
  echo "40-runtime-config: $*" >&2
  exit 1
}

# Allowlist: nenhum caractere aceito precisa de escape numa string JS entre aspas duplas.
URL_RE='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$'
ID_RE='^[A-Za-z0-9._-]{1,128}$'

check() { # uso: check NOME VALOR REGEX
  # O grep testa linha a linha; por isso recusamos quebra de linha antes.
  [ "$(printf '%s' "$2" | wc -l)" -eq 0 ] || fail "$1 não pode ter quebra de linha"
  printf '%s' "$2" | grep -Eq "$3" || fail "$1 inválida: '$2'"
}

require() { # uso: require NOME VALOR REGEX
  [ -n "$2" ] || fail "$1 é obrigatória"
  check "$1" "$2" "$3"
}

require API_BASE_URL "${API_BASE_URL:-}" "$URL_RE"
require OIDC_AUTHORITY "${OIDC_AUTHORITY:-}" "$URL_RE"
require OIDC_CLIENT_ID "${OIDC_CLIENT_ID:-}" "$ID_RE"
if [ -n "${OIDC_LOGOUT_URL:-}" ]; then
  check OIDC_LOGOUT_URL "$OIDC_LOGOUT_URL" "$URL_RE"
fi

tmp="$out_file.tmp"
# Testa escrevendo de verdade: o "-w" do BusyBox olha só as permissões e não percebe um FS somente leitura.
# O subshell é necessário: redirecionamento que falha em builtin especial (":") encerra o script na hora.
if [ ! -d "$out_dir" ] || ! (: > "$tmp") 2>/dev/null; then
  fail "$out_dir não existe ou não é gravável (no K8s, monte um emptyDir)"
fi

{
  printf 'window.__APP_CONFIG__ = {\n'
  printf '  "apiBaseUrl": "%s",\n' "$API_BASE_URL"
  printf '  "oidcAuthority": "%s",\n' "$OIDC_AUTHORITY"
  printf '  "oidcClientId": "%s"' "$OIDC_CLIENT_ID"
  if [ -n "${OIDC_LOGOUT_URL:-}" ]; then
    printf ',\n  "oidcLogoutUrl": "%s"' "$OIDC_LOGOUT_URL"
  fi
  printf '\n};\n'
} > "$tmp"
mv "$tmp" "$out_file" # troca atômica: o nginx nunca serve um arquivo pela metade
echo "40-runtime-config: $out_file gerado"
```

- [ ] **Passo 4: rode e veja passar.** O mesmo `docker run` do passo 2 deve terminar com `todos os testes passaram`.

- [ ] **Passo 5: escreva o smoke test do container** `scripts/smoke-container.sh` (e `chmod +x scripts/smoke-container.sh`)

```bash
#!/usr/bin/env bash
# Smoke test da imagem: ./scripts/smoke-container.sh [base-url]
set -euo pipefail

BASE="${1:-http://localhost:8081}"
falhou() { echo "FALHOU: $*" >&2; exit 1; }

health=$(curl -fsS "$BASE/healthz") || falhou "/healthz não respondeu"
[ "$health" = "ok" ] || falhou "/healthz devolveu '$health'"

cfg_headers=$(curl -fsS -D - -o /dev/null "$BASE/runtime/config.js") || falhou "/runtime/config.js não respondeu"
grep -qi '^cache-control: no-store' <<<"$cfg_headers" || falhou "config.js sem Cache-Control: no-store"
cfg=$(curl -fsS "$BASE/runtime/config.js")
grep -q 'window.__APP_CONFIG__' <<<"$cfg" || falhou "config.js sem window.__APP_CONFIG__"

index_headers=$(curl -fsS -D - -o /dev/null "$BASE/")
grep -qi '^cache-control: no-store' <<<"$index_headers" || falhou "index.html sem Cache-Control: no-store"
grep -qi '^x-frame-options: DENY' <<<"$index_headers" || falhou "sem X-Frame-Options"
grep -qi '^x-content-type-options: nosniff' <<<"$index_headers" || falhou "sem X-Content-Type-Options"
grep -qi '^referrer-policy: ' <<<"$index_headers" || falhou "sem Referrer-Policy"

index=$(curl -fsS "$BASE/")
asset=$(grep -o '/assets/[^"]*\.js' <<<"$index" | head -n 1 || true)
[ -n "$asset" ] || falhou "index.html não referencia nenhum /assets/*.js"
asset_headers=$(curl -fsS -D - -o /dev/null "$BASE$asset")
grep -qi '^cache-control: public, max-age=31536000, immutable' <<<"$asset_headers" \
  || falhou "$asset sem cache imutável"
grep -qi '^x-content-type-options: nosniff' <<<"$asset_headers" || falhou "$asset sem headers de segurança"

spa=$(curl -fsS "$BASE/links/abc1234")
grep -q 'id="root"' <<<"$spa" || falhou "fallback de SPA não devolveu o index.html"

status=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/assets/nao-existe.js")
[ "$status" = "404" ] || falhou "asset inexistente devolveu $status (esperado 404)"

echo "smoke OK em $BASE"
```

- [ ] **Passo 6: rode e veja falhar.** `./scripts/smoke-container.sh` falha com `FALHOU: /healthz não respondeu`, porque ainda não existe container.

- [ ] **Passo 7: crie** `nginx/security-headers.conf`

```nginx
# Incluído no server e em todo location que tem add_header (add_header não é herdado).
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header X-Frame-Options "DENY" always;
```

- [ ] **Passo 8: crie** `nginx/default.conf`

```nginx
server {
    listen 8080;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    server_tokens off;
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;

    include /etc/nginx/snippets/security-headers.conf;

    # Liveness/readiness e smoke do blue-green. Herda os headers do server (não tem add_header).
    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    # Nome com hash: o conteúdo nunca muda, então pode ficar 1 ano no cache do navegador.
    location /assets/ {
        include /etc/nginx/snippets/security-headers.conf;
        add_header Cache-Control "public, max-age=31536000, immutable";
        try_files $uri =404; # asset que não existe é 404, nunca o index.html
    }

    # Gerado na subida do container; muda por ambiente.
    location = /runtime/config.js {
        include /etc/nginx/snippets/security-headers.conf;
        add_header Cache-Control "no-store" always;
        try_files $uri =404;
    }

    # Aponta para os assets da versão atual: sempre buscar de novo.
    location = /index.html {
        include /etc/nginx/snippets/security-headers.conf;
        add_header Cache-Control "no-store" always;
    }

    # Fallback de SPA: qualquer rota do React Router devolve o index.html.
    location / {
        include /etc/nginx/snippets/security-headers.conf;
        add_header Cache-Control "no-cache";
        try_files $uri $uri/ /index.html;
    }
}
```

O `always` fica nos headers de segurança e no `no-store`. No `immutable` dos assets ele fica de fora de propósito: um 404 de asset não pode ser guardado por um ano.

- [ ] **Passo 9: crie** `.dockerignore`

```
node_modules
dist
.git
playwright-report
test-results
blob-report
*.log
.DS_Store
Dockerfile
.dockerignore
```

- [ ] **Passo 10: crie** `Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1

FROM node:24-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
# O config.js de dev (public/runtime) não vai para a imagem: em runtime ele é gerado.
RUN npm run build && rm -rf dist/runtime

FROM nginxinc/nginx-unprivileged:1.30.5-alpine3.24
USER root
RUN rm -rf /usr/share/nginx/html/*
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY nginx/security-headers.conf /etc/nginx/snippets/security-headers.conf
COPY --chmod=0755 nginx/40-runtime-config.sh /docker-entrypoint.d/40-runtime-config.sh
COPY --from=build /app/dist /usr/share/nginx/html
# Gravável pelo UID 101 quando o root FS não é read-only (docker run simples).
# No K8s, um emptyDir é montado aqui por cima.
RUN mkdir -p /usr/share/nginx/html/runtime && chown 101:101 /usr/share/nginx/html/runtime
USER 101
EXPOSE 8080
# ENTRYPOINT (/docker-entrypoint.sh) e CMD (nginx -g 'daemon off;') vêm da imagem base.
```

O `npm run build` roda `tsc -b` antes do `vite build`. Assim, código com erro de tipo nem vira imagem.

Se o `npm ci` falhar no container com `Cannot find module '@rolldown/binding-linux-...'`, o `package-lock.json` foi gerado sem os binários opcionais do Linux. Rode `rm -rf node_modules package-lock.json && npm install` no Mac e faça commit do lock novo.

- [ ] **Passo 11: builde e rode**

```bash
docker build -t shortener-web:dev .
docker run --rm -d --name shortener-web -p 8081:8080 \
  -e API_BASE_URL=http://localhost:3000 \
  -e OIDC_AUTHORITY=http://localhost:8090/shortener \
  -e OIDC_CLIENT_ID=shortener-web \
  shortener-web:dev
docker logs shortener-web | grep runtime-config   # "40-runtime-config: .../config.js gerado"
./scripts/smoke-container.sh                       # smoke OK em http://localhost:8081
curl -s http://localhost:8081/runtime/config.js
docker exec shortener-web id -u                    # 101
docker stop shortener-web
```

- [ ] **Passo 12: rode como no K8s (root FS somente leitura)**

```bash
docker run --rm -d --name shortener-web -p 8081:8080 --read-only \
  --tmpfs /tmp:mode=1777 \
  --tmpfs /usr/share/nginx/html/runtime:mode=1777 \
  -e API_BASE_URL=http://localhost:3000 \
  -e OIDC_AUTHORITY=http://localhost:8090/shortener \
  -e OIDC_CLIENT_ID=shortener-web \
  shortener-web:dev
./scripts/smoke-container.sh
```

Se faltar um dos `--tmpfs`, o container não sobe. Faça o teste: sem o segundo `--tmpfs`, o log mostra `40-runtime-config: ... não existe ou não é gravável`. Sem o primeiro, o nginx falha ao criar os temporários em `/tmp` (`mkdir() "/tmp/proxy_temp" failed (30: Read-only file system)`).

- [ ] **Passo 13: confira o fail fast**

```bash
docker run --rm -e API_BASE_URL='https://x.com/"oops' -e OIDC_AUTHORITY=http://localhost:8090/shortener \
  -e OIDC_CLIENT_ID=shortener-web shortener-web:dev; echo "saída=$?"
# 40-runtime-config: API_BASE_URL inválida: 'https://x.com/"oops'
# saída=1
```

- [ ] **Passo 14: login real no container.** Com o container do passo 12 de pé e o compose do `shortener-api` também:
1. Abra `http://localhost:8081` e faça o fluxo completo (entrar, criar, abrir, stats, sair). O mock-oauth2-server não valida `redirect_uri` contra uma lista: ele aceita qualquer uma (conferido no código dele), então `http://localhost:8081/callback` funciona sem configuração. A api já libera CORS para 8081.
2. Rode o e2e contra o container: `E2E_BASE_URL=http://localhost:8081 npm run test:e2e`.
3. No DevTools → Network, recarregue: o `index.html` e o `config.js` vêm sempre do servidor, e os `/assets/*` vêm *from memory/disk cache*.

- [ ] **Passo 15: commit**

```bash
git add -A && git commit -m "feat: imagem nginx não-root com config de runtime e cache por tipo de arquivo"
```

**Pronto quando:** o teste do gerador passa, o smoke passa com e sem `--read-only`, o container com variável inválida não sobe, e o login funciona em `http://localhost:8081`.

---

## Tarefa 3.11: frescor das estatísticas (api + painel)

Acrescentada depois da fase, a pedido: a tela de detalhe mostra **quando** os números foram calculados e **quando** serão atualizados.

**Arquivos:**
- `shortener-api`: `src/cache/jsonCache.ts`, `src/http/app.ts` e `src/api.ts`; testes em `test/integration/app.test.ts` e `test/integration/cache.test.ts`
- `shortener-web`: `src/api/client.ts`, `src/api/hooks.ts`, `src/components/Freshness.tsx`, `src/pages/LinkDetailPage.tsx` e `src/index.css`; testes ao lado de cada arquivo

**Conceitos:**
- **Quem sabe a idade do dado é o servidor.** A api grava `computedAt` **dentro** do valor em cache. Num *hit*, o horário original continua lá, então o cliente sabe a idade real, mesmo que outra pessoa tenha montado o cache. Adivinhar pelo lado do cliente (contar a partir de quando a tela recebeu os dados) erra sempre que o cache já estava pela metade.
- **Absoluto para exibir, relativo para contar.** `computedAt` (relógio da api) só aparece na tela ("Atualizado às 14:32:10"). A contagem usa `refreshInSeconds`, a partir do momento em que a resposta chegou. Assim, um relógio do usuário adiantado ou atrasado não estraga a contagem.
- **Zero custo extra no Valkey.** `refreshInSeconds = computedAt + TTL − agora`, calculado na api. Não precisa de um `TTL` a cada requisição.
- **O servidor dita o ritmo do *polling*.** É o mesmo princípio do header `X-Poll-Interval` do GitHub. O painel busca de novo quando o cache expira, com **jitter** (0–2 s aleatórios) para mil telas abertas no mesmo link não pedirem no mesmo segundo.
- **Expand/contract também no contrato da api.**
  - **Entrada antiga sem `computedAt`:** uma entrada de cache gravada pela versão anterior da api (no canary, as duas convivem) é tratada como *miss* e recalculada.
  - **Api antiga sem os campos:** o painel aceita a resposta, porque os campos são **opcionais** no zod. Ele só não mostra o texto e não agenda a busca.
- **Desempenho e acessibilidade:** só o componente pequeno do texto redesenha a cada segundo. Com a aba em segundo plano, o TanStack Query não busca. O texto **não** é `aria-live`, para o leitor de tela não anunciar a contagem a cada segundo.

**Contrato novo de `GET /links/:code/stats`:**

```json
{ "code": "abc1234", "totalClicks": 42, "daily": [], "browsers": [],
  "computedAt": "2026-10-13T14:32:10.000Z", "refreshInSeconds": 25 }
```

- [ ] **Passo 1 (api): escreva os testes.**
  - Em `app.test.ts`:
    - **Miss:** devolve `computedAt` agora e `refreshInSeconds = 60`.
    - **Hit:** um cache montado há 45 s mantém o `computedAt` original e devolve 14–15 s.
    - **Entrada sem `computedAt`:** é recalculada a partir do banco.
  - Em `cache.test.ts`: `cache.ttlSeconds === 60`.
- [ ] **Passo 2 (api): rode e veja falhar.** `npm run test:integration`: 4 falhas.
- [ ] **Passo 3 (api): implemente.**
  - O `JsonCache` expõe `readonly ttlSeconds` (o objeto devolvido pelo `createJsonCache` ganha `ttlSeconds,`).
  - Em `src/api.ts`, o cache passa a ser `createJsonCache<CachedStats>(redis, 'stats', 60)`.
  - Em `src/http/app.ts`, antes de `AppDeps` (que passa a usar `statsCache: JsonCache<CachedStats>`):

```ts
// O que fica no cache: as stats mais o instante em que foram calculadas (relógio da api).
export type CachedStats = LinkStats & { computedAt: string };

// O que a rota devolve: o cliente mostra "atualizado às ..." e sabe quando buscar de novo.
export type StatsResponse = CachedStats & { refreshInSeconds: number };

export function withFreshness(cached: CachedStats, ttlSeconds: number, now = Date.now()): StatsResponse {
  const expiresAt = Date.parse(cached.computedAt) + ttlSeconds * 1000;
  const refreshInSeconds = Math.min(ttlSeconds, Math.max(0, Math.ceil((expiresAt - now) / 1000)));
  return { ...cached, refreshInSeconds };
}
```

E a parte de cache da rota `GET /links/:code/stats`, depois da checagem do dono:

```ts
    const ttl = deps.statsCache.ttlSeconds;
    const cached = await deps.statsCache.get(code);
    // Entrada sem computedAt foi gravada por uma versão anterior da api (ex.: durante o canary): recalcula.
    if (cached && typeof cached.computedAt === 'string') {
      res.json(withFreshness(cached, ttl));
      return;
    }
    const stats = await deps.links.getStats(code);
    if (!stats) {
      res.status(404).json({ error: 'not_found' });
      return;
    }
    const fresh: CachedStats = { ...stats, computedAt: new Date().toISOString() };
    await deps.statsCache.set(code, fresh);
    res.json(withFreshness(fresh, ttl));
```

- [ ] **Passo 4 (api): rode e veja passar.** `npm test && npm run typecheck && npm run lint`. Depois, `docker compose --profile app up -d --build api`, e duas chamadas com alguns segundos de intervalo devolvem o **mesmo** `computedAt` com `refreshInSeconds` menor.
- [ ] **Passo 5 (web): escreva os testes.**
  - **Schema:** lê os campos novos e aceita uma resposta sem eles.
  - **Hook:** com `refreshInSeconds: 5`, não busca aos 4 s e busca até os 7 s; sem o campo, não busca sozinho.
  - **`Freshness`:** horário em `<time>` e contagem que desce.
  - **Página:** mostra o texto, ou não mostra se a api não mandar os campos.
- [ ] **Passo 6 (web): rode e veja falhar.** `npm test`.
- [ ] **Passo 7 (web): implemente.**
  - **Schema:** no `statsSchema`, acrescente `computedAt: z.iso.datetime().optional()` e `refreshInSeconds: z.number().int().min(0).optional()`.
  - **Hook:** no `useStats`, acrescente:

```ts
    // O servidor diz quando o cache dele expira; buscamos logo depois. A folga aleatória (jitter)
    // evita que todas as telas abertas no mesmo link peçam no mesmo segundo.
    refetchInterval: (query) => {
      const seconds = query.state.data?.refreshInSeconds;
      if (seconds === undefined) return false;
      return (Math.max(1, seconds) + Math.random() * 2) * 1000;
    },
```

`src/components/Freshness.tsx`:

```tsx
import { useEffect, useState } from 'react';

const timeFormat = new Intl.DateTimeFormat('pt-BR', { timeStyle: 'medium' });

// computedAt vem do relógio da api e só é exibido. A contagem usa refreshInSeconds a partir de quando
// a resposta chegou (receivedAt), então não depende do relógio do usuário bater com o do servidor.
export function Freshness({
  computedAt,
  refreshInSeconds,
  receivedAt,
}: {
  computedAt: string;
  refreshInSeconds: number;
  receivedAt: number;
}) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);

  const elapsed = Math.max(0, Math.floor((now - receivedAt) / 1000));
  const remaining = Math.max(0, refreshInSeconds - elapsed);

  // Sem aria-live de propósito: um leitor de tela anunciaria a contagem a cada segundo.
  return (
    <p className="freshness muted">
      Atualizado às <time dateTime={computedAt}>{timeFormat.format(new Date(computedAt))}</time>
      <span aria-hidden="true"> · </span>
      <span>{remaining > 0 ? `próxima atualização em ${remaining} s` : 'atualizando…'}</span>
    </p>
  );
}
```

Na `LinkDetailPage`, dentro do card do total, renderize `<Freshness computedAt=... refreshInSeconds=... receivedAt={query.dataUpdatedAt} />` quando os dois campos existirem. No CSS: `.freshness { margin: 0.5rem 0 0; font-size: 0.85rem; }`.

- [ ] **Passo 8 (web): rode e veja passar.** `npm test && npm run typecheck && npm run lint && npm run build`. No navegador, o texto conta para baixo, e a segunda chamada de stats sai cerca de 60 s depois da primeira.
- [ ] **Passo 9: commit nos dois repos.** No `shortener-api`: `feat: stats informam quando foram calculadas e quando atualizam`. No `shortener-web`: `feat: detalhe mostra quando as stats foram atualizadas e quando atualizam`.

**Extensão (não feita):** mostrar "dados até HH:MM:SS", o horário do último clique **processado pelo worker**. O cache não é o único atraso: o clique também passa pelo Kafka e pelo worker.

---

## Checkpoint da Fase 3

- [ ] `npm run lint`, `npm run typecheck`, `npm test` e `npm run build` passam no `shortener-web`
- [ ] `npm run test:e2e` passa contra o Vite (5173) e contra o container (8081), com o compose do `shortener-api` de pé
- [ ] Você sabe explicar o PKCE e por que um SPA não pode usar a `API_KEY`
- [ ] Você sabe dizer onde estão os tokens (`sessionStorage`), o risco (XSS) e a alternativa (BFF)
- [ ] A mesma imagem roda com outra api e outro IdP só trocando variáveis de ambiente (*build once, deploy many*)
- [ ] O container roda como UID 101, com root FS somente leitura, gravando só em `/tmp` e em `/usr/share/nginx/html/runtime`
- [ ] `/assets/*` tem cache imutável, `index.html` e `config.js` têm `no-store`, e asset inexistente dá 404

### O que as próximas fases assumem desta

| Item | Valor |
|---|---|
| Repositório | `~/Documents/projects/shortener-web`, branch `main`, ainda sem remoto (GitHub na Fase 4) |
| Node | `.nvmrc` = `24` (o CI usa `node-version-file: .nvmrc`) |
| Comandos de CI | `npm ci`, `npm run lint`, `npm run typecheck`, `npm test`, `npm run build`. O e2e (`npm run test:e2e`) é **só local** |
| Imagem | `Dockerfile` na raiz, sem `build-args`. Base final `nginxinc/nginx-unprivileged:1.30.5-alpine3.24` |
| Porta do container | `8080` (nome sugerido no Service: `http`) |
| Usuário | UID/GID `101` (`runAsNonRoot: true`, `runAsUser: 101`) |
| Variáveis | `API_BASE_URL`, `OIDC_AUTHORITY` e `OIDC_CLIENT_ID` (obrigatórias); `OIDC_LOGOUT_URL` (opcional, Cognito). No K8s: `API_BASE_URL` vem do ConfigMap `shortener-web-config`; as `OIDC_*` vêm do `shortener-oidc` |
| Root FS read-only | `emptyDir` em `/tmp` e em `/usr/share/nginx/html/runtime` |
| Probes | `GET /healthz` na 8080 → `200`, corpo `ok` |
| Smoke do blue-green (`web-smoke`) | `/healthz` (200), `/` (200, contém `id="root"`) e `/runtime/config.js` (200, contém `window.__APP_CONFIG__`) |
| Falha de config | O container sai com código 1 na subida (CrashLoopBackOff no K8s), com a mensagem `40-runtime-config: ...` no log |
| Callback e logout OIDC | `https://app.<host>/callback` e `https://app.<host>/` (iguais aos do app client do Cognito) |
