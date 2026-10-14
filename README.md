# shortener-deploy

Estado desejado dos ambientes do encurtador (`shortener`) e o plano de estudo.

- `apps/`: manifests Kubernetes (Kustomize) da api e do web, por ambiente. O ArgoCD de cada cluster aplica.
- `infra/`: Terraform (organização AWS, bootstrap das contas, ambientes efêmeros).
- `scripts/`: `up.sh`, `down.sh` e `leftovers.sh`.
- `load/`: testes de carga (k6).
- `docs/plano/`: o plano, fase por fase. Comece pelo [README do plano](docs/plano/README.md).

Código: [shortener-api](https://github.com/shortener-lab/shortener-api) e [shortener-web](https://github.com/shortener-lab/shortener-web).
