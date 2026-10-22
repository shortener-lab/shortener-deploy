#!/usr/bin/env bash
set -uo pipefail
ENV="${1:?uso: scripts/leftovers.sh <staging|prod>}"
case "$ENV" in staging|prod) ;; *) echo "ambiente inválido: $ENV" >&2; exit 2 ;; esac
export AWS_PROFILE="shortener-$ENV"   # tudo abaixo olha SÓ a conta deste ambiente
R=us-east-1
FOUND=0

ACCOUNT=$(aws sts get-caller-identity --query Account --output text) \
  || { echo "Sessão SSO expirada: aws sso login --sso-session shortener" >&2; exit 2; }
echo ">> Procurando sobras de $ENV na conta $ACCOUNT"

check() { # $1 = descrição, $2 = saída do comando
  if [ -n "$2" ] && [ "$2" != "None" ]; then
    echo "!! $1:"; echo "$2" | tr '\t' '\n' | sed 's/^/   /'; FOUND=1
  fi
}

# A API de tags é um índice com atraso: recursos apagados há pouco (NAT, security groups e
# regras) continuam listados por minutos ou até 1h, e a chave KMS do EKS fica listada nos
# 30 dias de PendingDeletion (sem custo). Para esses tipos, confirma no serviço dono.
still_exists() { # $1 = ARN
  local arn="$1" id="${1##*/}" out
  case "$arn" in
    *:security-group/*)      out=$(aws ec2 describe-security-groups --region $R --group-ids "$id" --query 'SecurityGroups[0].GroupId' --output text 2>&1) ;;
    *:security-group-rule/*) out=$(aws ec2 describe-security-group-rules --region $R --security-group-rule-ids "$id" --query 'SecurityGroupRules[0].SecurityGroupRuleId' --output text 2>&1) ;;
    *:natgateway/*)          out=$(aws ec2 describe-nat-gateways --region $R --nat-gateway-ids "$id" --query 'NatGateways[0].State' --output text 2>&1) ;;
    *:loadbalancer/*)        out=$(aws elbv2 describe-load-balancers --region $R --load-balancer-arns "$arn" --query 'LoadBalancers[0].State.Code' --output text 2>&1) ;;
    *:targetgroup/*)         out=$(aws elbv2 describe-target-groups --region $R --target-group-arns "$arn" --query 'TargetGroups[0].TargetGroupName' --output text 2>&1) ;;
    *:kms:*)                 out=$(aws kms describe-key --region $R --key-id "$id" --query 'KeyMetadata.KeyState' --output text 2>&1) ;;
    *) return 0 ;; # outros tipos: confia no índice
  esac
  case "$out" in *NotFound*|deleted|PendingDeletion) return 1 ;; *) return 0 ;; esac
}

confirmed() { # lê ARNs (separados por tab) e devolve só os que ainda existem
  local arn
  for arn in $(cat); do still_exists "$arn" && echo "$arn"; done
}

# Recursos criados pelo Terraform deste ambiente.
# EXCLUI ACM e Cognito de propósito: o certificado e o user pool são do bootstrap PERMANENTE
# da conta (Fase 5), que também usa default_tags Environment=<env> e ManagedBy=terraform.
# Eles não são sobra: ficam de pé (custo zero) entre um "up" e outro.
check "Recursos do Terraform com tag Environment=$ENV (fora o bootstrap: ACM e Cognito)" \
  "$(aws resourcegroupstaggingapi get-resources --region $R \
    --tag-filters "Key=ManagedBy,Values=terraform" "Key=Environment,Values=$ENV" \
    --query "ResourceTagMappingList[?!contains(ResourceARN, ':acm:') && !contains(ResourceARN, ':cognito-idp:')].ResourceARN" \
    --output text | confirmed)"
# Recursos criados pelo AWS Load Balancer Controller (ALB, target groups, security groups).
check "Recursos do Load Balancer Controller (cluster shortener-$ENV)" \
  "$(aws resourcegroupstaggingapi get-resources --region $R \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=shortener-$ENV" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text | confirmed)"
check "Load balancers" "$(aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].LoadBalancerName' --output text)"
check "NAT Gateways ativos" "$(aws ec2 describe-nat-gateways --region $R --filter Name=state,Values=available,pending \
  --query 'NatGateways[].NatGatewayId' --output text)"
check "Elastic IPs" "$(aws ec2 describe-addresses --region $R --query 'Addresses[].PublicIp' --output text)"
check "Volumes EBS soltos" "$(aws ec2 describe-volumes --region $R --filters Name=status,Values=available \
  --query 'Volumes[].VolumeId' --output text)"
check "Clusters EKS" "$(aws eks list-clusters --region $R --query 'clusters' --output text)"
check "Clusters MSK" "$(aws kafka list-clusters-v2 --region $R --query 'ClusterInfoList[].ClusterName' --output text)"
check "Instâncias RDS" "$(aws rds describe-db-instances --region $R --query 'DBInstances[].DBInstanceIdentifier' --output text)"
check "ElastiCache" "$(aws elasticache describe-replication-groups --region $R --query 'ReplicationGroups[].ReplicationGroupId' --output text)"
check "Log groups do EKS" "$(aws logs describe-log-groups --region $R --log-group-name-prefix /aws/eks/shortener-$ENV \
  --query 'logGroups[].logGroupName' --output text)"

# DNS: os 3 hosts do ambiente (links curtos, api e painel) e os TXT de "dono" do external-dns.
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && [ -n "${CLOUDFLARE_ZONE_ID:-}" ]; then
  case "$ENV" in
    staging) BASE=shortener-staging.fabricioroglio.com ;;
    prod)    BASE=shortener.fabricioroglio.com ;;
  esac
  for HOST in "$BASE" "api.$BASE" "app.$BASE"; do
    # "" = A/CNAME (e TXT no formato antigo); a-/aaaa-/cname- = TXT de registro do external-dns
    for PREFIX in "" "a-" "aaaa-" "cname-"; do
      NAME="$PREFIX$HOST"
      check "DNS na Cloudflare (registro pendurado: $NAME)" "$(curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records?name=$NAME" | jq -r '.result[] | "\(.type) \(.name)"')"
    done
  done
else
  echo "(pulando a checagem de DNS: exporte CLOUDFLARE_API_TOKEN e CLOUDFLARE_ZONE_ID)"
fi

[ "$FOUND" = 0 ] && echo "OK: nenhuma sobra encontrada para $ENV." || { echo "Há sobras: elas podem gerar custo."; exit 1; }
