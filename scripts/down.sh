#!/usr/bin/env bash
set -euo pipefail
ENV="${1:?uso: scripts/down.sh <staging|prod>}"
case "$ENV" in staging|prod) ;; *) echo "ambiente inválido: $ENV" >&2; exit 2 ;; esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AWS_PROFILE="shortener-$ENV"
export AWS_REGION=us-east-1
: "${TF_VAR_cloudflare_api_token:?exporte TF_VAR_cloudflare_api_token (veja a rotina de sessão)}"
aws sts get-caller-identity >/dev/null 2>&1 || { echo "Sessão SSO expirada: aws sso login --sso-session shortener" >&2; exit 1; }
export TF_VAR_admin_cidrs="[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
CTX="shortener-$ENV"
CLUSTER="shortener-$ENV"

# ALBs criados pelo controller DESTE cluster (o IngressGroup "shortener" gera um só).
alb_count() {
  aws resourcegroupstaggingapi get-resources --region us-east-1 \
    --resource-type-filters elasticloadbalancing:loadbalancer \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER" \
    --query 'length(ResourceTagMappingList)' --output text
}

# Se o cluster existe, garante o contexto no kubeconfig (pode ser outra máquina ou um kubeconfig limpo).
if aws eks describe-cluster --name "$CLUSTER" --region us-east-1 >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER" --region us-east-1 \
    --profile "shortener-$ENV" --alias "$CTX" >/dev/null
fi

if kubectl --context "$CTX" get namespace argocd >/dev/null 2>&1; then
  echo ">> [1/4] Apagando as Applications shortener-api e shortener-web"
  echo "   (ArgoCD remove os Ingresses → controller remove o ALB → external-dns remove o DNS)"
  # Um único delete com os dois nomes: as duas exclusões correm em paralelo e o --wait espera ambas.
  kubectl --context "$CTX" -n argocd delete application shortener-api shortener-web \
    --ignore-not-found --wait=true --timeout=10m
  echo ">> Aguardando o ALB compartilhado sumir..."
  for _ in $(seq 1 60); do
    [ "$(alb_count)" = "0" ] && break
    sleep 10
  done
  if [ "$(alb_count)" != "0" ]; then
    echo "!! O ALB ainda existe. Investigue (logs do aws-load-balancer-controller) antes de continuar."
    exit 1
  fi
  sleep 60 # dá tempo para o external-dns remover os 3 registros na Cloudflare
fi

echo ">> [2/4] Destruindo a camada plataforma"
terraform -chdir="$ROOT/infra/envs/$ENV/platform" init -input=false >/dev/null
terraform -chdir="$ROOT/infra/envs/$ENV/platform" destroy -input=false -auto-approve

echo ">> [3/4] Destruindo a camada AWS: ~20–30 min"
terraform -chdir="$ROOT/infra/envs/$ENV/aws" init -input=false >/dev/null
terraform -chdir="$ROOT/infra/envs/$ENV/aws" destroy -input=false -auto-approve

echo ">> [4/4] Procurando sobras"
"$ROOT/scripts/leftovers.sh" "$ENV"
