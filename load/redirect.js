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
