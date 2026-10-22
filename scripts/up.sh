#!/usr/bin/env bash
set -euo pipefail
ENV="${1:?uso: scripts/up.sh <staging|prod>}"
case "$ENV" in staging|prod) ;; *) echo "ambiente inválido: $ENV" >&2; exit 2 ;; esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AWS_PROFILE="shortener-$ENV"
export AWS_REGION=us-east-1
: "${TF_VAR_cloudflare_api_token:?exporte TF_VAR_cloudflare_api_token (veja a rotina de sessão)}"
aws sts get-caller-identity >/dev/null 2>&1 || { echo "Sessão SSO expirada: aws sso login --sso-session shortener" >&2; exit 1; }
export TF_VAR_admin_cidrs="[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
CTX="shortener-$ENV"

echo ">> [1/3] Camada AWS ($ENV, conta $(aws sts get-caller-identity --query Account --output text)): ~30–40 min"
terraform -chdir="$ROOT/infra/envs/$ENV/aws" init -input=false
terraform -chdir="$ROOT/infra/envs/$ENV/aws" apply -input=false -auto-approve
aws eks update-kubeconfig --name "shortener-$ENV" --region us-east-1 \
  --profile "shortener-$ENV" --alias "$CTX" >/dev/null

echo ">> [2/3] Camada plataforma ($ENV)"
terraform -chdir="$ROOT/infra/envs/$ENV/platform" init -input=false
terraform -chdir="$ROOT/infra/envs/$ENV/platform" apply -input=false -auto-approve

echo ">> [3/3] Aguardando o ArgoCD deixar as duas apps saudáveis"
kubectl --context "$CTX" -n argocd wait application/shortener-api application/shortener-web \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=20m

echo ">> Pronto. API key: terraform -chdir=infra/envs/$ENV/platform output -raw api_key"
