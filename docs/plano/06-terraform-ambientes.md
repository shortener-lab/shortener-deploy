# Fase 6: Terraform dos ambientes (staging e prod), cada um na sua conta

**Repositório:** tudo nesta fase vive no **`shortener-deploy`** (`~/Documents/projects/shortener-deploy`). Todos os caminhos (`infra/...`, `scripts/...`, `.github/...`) são relativos à raiz desse repo, e todo comando roda a partir dela. O trabalho entra **via PR**: uma branch por tarefa (`git switch -c infra/<tarefa>`), `gh pr create --fill` e merge depois do check `infra` verde (ele nasce na Tarefa 6.7; antes disso, revise o diff você mesmo).

**Entrega:**
- `scripts/up.sh staging` cria do zero, **na conta `shortener-staging`**, VPC, EKS, RDS, ElastiCache, MSK e a plataforma Kubernetes (controllers, ArgoCD, Argo Rollouts e a configuração da app, incluindo o OIDC lido do bootstrap da conta).
- `scripts/down.sh staging` destrói tudo e confirma que nada sobrou na conta de staging.
- Prod fica pronto no código (conta `shortener-prod`), mas só sobe na Fase 8.
- O `shortener-deploy` ganha CI: `terraform fmt` e `validate` em todas as raízes.

**Pré-requisitos (Fase 5):**
- Contas `shortener-shared`, `shortener-staging` e `shortener-prod` criadas, com os profiles SSO `shortener-shared`, `shortener-staging` e `shortener-prod` no `~/.aws/config` (sessão `shortener`).
- Bucket `shortener-tfstate-<SHARED_ACCOUNT_ID>` na conta shared.
- Bootstrap de staging aplicado (`bootstrap/staging.tfstate`), com certificado ACM e Cognito, e as saídas `certificate_arn`, `oidc_issuer`, `oidc_jwks_url`, `oidc_authority`, `oidc_client_id` e `oidc_logout_url`.

**Custo:** ~US$ 0,38 por hora com staging de pé, igual a antes. Argo Rollouts cabe nos nós existentes. **Termine toda sessão com `scripts/down.sh staging`.**

**Tempos de espera:** `apply` completo leva de 30 a 40 min (o MSK é o mais lento) e `destroy` de 20 a 30 min. Use o tempo para ler o que está sendo criado no console (entrando na conta de staging pelo portal do SSO).

## Rotina de início de sessão (use daqui em diante)

```bash
cd ~/Documents/projects/shortener-deploy
aws sso login --sso-session shortener        # um login vale para os 4 profiles (8h)
export AWS_PROFILE=shortener-staging         # para os comandos manuais da AWS CLI
export CLOUDFLARE_API_TOKEN=$(security find-generic-password -s shortener-cloudflare-token -w)  # do Keychain (Tarefa 5.5)
export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"
export CLOUDFLARE_ZONE_ID='<ZONE_ID>'        # usado pelo leftovers.sh
aws sts get-caller-identity --query Account --output text   # deve mostrar <STAGING_ACCOUNT_ID>
```

O `AWS_PROFILE` serve só para a AWS CLI que você digita à mão. O Terraform **não depende dele**: cada raiz diz explicitamente qual profile usa (veja abaixo). Os scripts da Tarefa 6.5 exportam o profile certo sozinhos.

## Organização em duas camadas

```
infra/
├── organization/                  # Fase 5 (conta management)
├── bootstrap/{shared,staging,prod,modules/account-baseline}/   # Fase 5 (permanente)
├── modules/
│   ├── aws-environment/   # camada 1: recursos AWS (VPC, EKS, dados, Pod Identities)
│   └── platform/          # camada 2: dentro do cluster (Helm, namespace, config da app)
└── envs/
    ├── staging/{aws,platform}/   # "raízes": backend + valores do ambiente
    └── prod/{aws,platform}/
```

**Por que duas camadas:**
- Os providers `kubernetes` e `helm` precisam do endereço de um cluster que **já existe**. Na mesma execução que cria o cluster, isso é frágil.
- Separar também permite destruir na ordem certa: primeiro o que roda dentro do cluster, depois o cluster.

A camada 2 lê as saídas da 1 via `terraform_remote_state`, e também lê o state do **bootstrap da conta** (Fase 5) para montar o ConfigMap `shortener-oidc`.

## Duas contas em cada `terraform apply`

Cada raiz de ambiente fala com **duas contas ao mesmo tempo**:

| O quê | Conta | Profile | Onde se configura |
|---|---|---|---|
| State (backend S3 e `terraform_remote_state`) | shared | `shortener-shared` | bloco `backend "s3"` e `config` do remote state |
| Recursos (VPC, EKS, RDS...) | staging ou prod | `shortener-<env>` | `provider "aws"` |
| Token do cluster (kubernetes/helm) | staging ou prod | `shortener-<env>` | `exec` dos providers, com `--profile` |

**A trava `allowed_account_ids`.** No `provider "aws"`, `allowed_account_ids = ["<STAGING_ACCOUNT_ID>"]` faz o provider conferir, **antes de qualquer leitura ou escrita**, em que conta as credenciais caíram (via `sts:GetCallerIdentity`). Se for outra conta, o plan falha com erro na hora. Isso protege contra os enganos clássicos: profile errado, `AWS_ACCESS_KEY_ID` esquecido no shell (credenciais em variável de ambiente podem ter precedência sobre o profile) ou uma raiz de prod copiada sem ajustar o profile. Sem a trava, o Terraform criaria um segundo cluster de "staging" dentro da conta de prod sem reclamar. O backend não precisa da trava: ele só lê e escreve o state no bucket, cujo nome já contém o ID da conta shared.

**Sobre as versões dos módulos**

Os blocos abaixo usam `terraform-aws-modules/vpc` v6, `terraform-aws-modules/eks` **v21** e `terraform-aws-modules/eks-pod-identity` v2.
- **A v21 do EKS renomeou várias entradas:** tirou o prefixo `cluster_` (por exemplo `cluster_name` → `name` e `cluster_version` → `kubernetes_version`).
- **Antes de aplicar, abra o README e os `examples/` da versão exata** no [Terraform Registry](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest).
- Se o `terraform validate` reclamar de um nome, a fonte da verdade é a documentação do módulo, não este plano.

---

## Tarefa 6.1: escolher versões e preparar variáveis

- [x] **Passo 1: consulte as versões disponíveis na conta de staging** (com a sessão SSO ativa)

```bash
export AWS_PROFILE=shortener-staging AWS_REGION=us-east-1
aws eks describe-cluster-versions --query 'clusterVersions[].[clusterVersion,versionStatus,endOfStandardSupportDate]' --output text   # use a mais nova em STANDARD_SUPPORT
aws kafka list-kafka-versions --query 'KafkaVersions[?Status==`ACTIVE`].Version'   # use 3.9.x
aws rds describe-db-engine-versions --engine postgres --query "DBEngineVersions[?starts_with(EngineVersion,'17')].EngineVersion"
aws elasticache describe-cache-engine-versions --engine valkey --query 'CacheEngineVersions[].EngineVersion'
```

Não guarde as flags numa variável (`P="--profile ... --region ..."` e depois `aws ... $P`). O zsh, shell padrão do macOS, não divide variáveis em palavras como o bash: o `$P` chega ao `aws` como **um** argumento, e ele responde `Unknown options`. As variáveis `AWS_PROFILE` e `AWS_REGION` resolvem sem esse problema.

Anote a versão do Kubernetes; ela vai no `terraform.tfvars` de cada ambiente.

**Fique sempre em uma versão em "standard support".** Em "extended support", o preço do plano de controle sobe de US$ 0,10 para US$ 0,60 por hora.

- [x] **Passo 2: libere o acesso à API do EKS só para o seu IP**

```bash
export TF_VAR_admin_cidrs="[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
```

O `up.sh` faz isso sozinho. Se o seu IP mudar (outra rede, VPN), rode `apply` de novo na camada `aws`.

**Pronto quando:** você tem as quatro versões anotadas e `aws sts get-caller-identity --profile shortener-staging` mostra `<STAGING_ACCOUNT_ID>`.

---

## Tarefa 6.2: módulo `aws-environment` (rede, EKS e Pod Identities)

**Arquivos:** criar `infra/modules/aws-environment/{versions,variables,network,eks,outputs}.tf` e `infra/envs/staging/aws/{main.tf,terraform.tfvars}`.

**Conceitos:**
- **Subnets públicas e privadas**, com NAT para os pods saírem para a internet.
- **Tags de subnet** que o AWS Load Balancer Controller usa para descobrir onde criar o ALB.
- **Node group gerenciado ARM (Graviton).**
- **Acesso ao cluster via EKS Access Entries.**
- **EKS Pod Identity:** um service account do Kubernetes recebe um papel IAM sem chave nenhuma. Usamos duas: o Load Balancer Controller (cria ALBs) e o controller do Argo Rollouts (lê métricas do CloudWatch para decidir se o canary avança, Fase 7).

- [x] **Passo 1:** `infra/modules/aws-environment/versions.tf`

```hcl
terraform {
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
```

- [x] **Passo 2:** `infra/modules/aws-environment/variables.tf`

```hcl
variable "environment" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"] # fixas: algumas AZs da us-east-1 não suportam EKS
}

variable "kubernetes_version" {
  type = string
}

variable "admin_cidrs" {
  type        = list(string)
  description = "IPs que podem acessar a API do EKS (o seu IP /32)"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t4g.medium"]
}

variable "node_min_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "node_desired_size" {
  type = number
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "rds_multi_az" {
  type    = bool
  default = false # produção real: true
}

variable "deletion_protection" {
  type    = bool
  default = false # produção real: true. Aqui é false porque o ambiente é efêmero.
}

variable "kafka_version" {
  type    = string
  default = "3.9.x"
}

variable "kafka_instance_type" {
  type    = string
  default = "kafka.t3.small"
}

variable "valkey_version" {
  type    = string
  default = "8.0"
}

variable "valkey_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

locals {
  name = "shortener-${var.environment}"
}
```

- [x] **Passo 3:** `infra/modules/aws-environment/network.tf`

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = var.vpc_cidr
  azs  = var.azs

  private_subnets = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 4, i)]      # /20: 10.x.0.0, 10.x.16.0
  public_subnets  = [for i, _ in var.azs : cidrsubnet(var.vpc_cidr, 8, 48 + i)] # /24: 10.x.48.0, 10.x.49.0

  enable_nat_gateway = true
  single_nat_gateway = true # produção real: um por AZ (alta disponibilidade, ~US$ 33/mês cada)

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }          # ALB público vai aqui
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
```

Como cada ambiente tem a sua conta, os CIDRs (`10.10.0.0/16` em staging e `10.20.0.0/16` em prod) nem precisariam ser diferentes. Mantemos separados porque custa zero e deixa a porta aberta para um peering ou Transit Gateway no futuro.

- [x] **Passo 4:** `infra/modules/aws-environment/eks.tf`

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.admin_cidrs

  # Quem roda o apply vira admin do cluster via Access Entry. Com o profile shortener-<env>,
  # esse "quem" é o papel SSO AWSReservedSSO_AdministratorAccess_... DA CONTA DO AMBIENTE.
  enable_cluster_creator_admin_permissions = true

  # Logs do control plane desligados: geram custo e sobram depois do destroy. Em produção real, ligue.
  enabled_log_types           = []
  create_cloudwatch_log_group = false

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
    }
  }
}

# Permissão IAM para o AWS Load Balancer Controller criar ALBs (via EKS Pod Identity).
module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0" # confira a última no registry

  name                            = "${local.name}-aws-lbc"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

# Permissão IAM para o controller do Argo Rollouts ler métricas do CloudWatch
# (AnalysisTemplate api-error-rate, Fase 7). Política mínima: só leitura de métricas.
module "argo_rollouts_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                      = "${local.name}-argo-rollouts"
  attach_custom_policy      = true
  custom_policy_description = "Argo Rollouts: leitura de metricas do CloudWatch"

  policy_statements = [
    {
      sid       = "CloudWatchReadMetrics"
      actions   = ["cloudwatch:GetMetricData", "cloudwatch:ListMetrics"]
      resources = ["*"] # estas ações não aceitam restrição por recurso
    }
  ]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "argo-rollouts"
      service_account = "argo-rollouts" # o mesmo nome fixado no chart (Tarefa 6.4, rollouts.tf)
    }
  }
}
```

Notas sobre a Pod Identity do Argo Rollouts:
- **Por que o módulo e não recursos nativos:** é o mesmo módulo do Load Balancer Controller, e `attach_custom_policy` + `policy_statements` gera a política inline legível, sem `jsonencode` manual. Fonte da verdade da interface: `variables.tf` do [terraform-aws-eks-pod-identity](https://github.com/terraform-aws-modules/terraform-aws-eks-pod-identity) (na v2, `policy_statements` é uma **lista** de objetos com `sid`, `actions`, `resources` etc.).
- **`Resource "*"`:** `GetMetricData` e `ListMetrics` não suportam permissão por recurso no IAM; o "mínimo" aqui é restringir as **ações**, não os recursos.
- **A associação pode existir antes do namespace e do service account.** Ela é só um registro no EKS ("pods com o SA `argo-rollouts` no namespace `argo-rollouts` recebem este papel"). Quando o chart criar o SA (camada 2), o agente de Pod Identity entrega as credenciais aos pods.
- **Por que na camada `aws`:** é IAM, e o módulo `platform` não usa o provider `aws` para criar recursos.

- [x] **Passo 5:** `infra/modules/aws-environment/outputs.tf` (versão parcial; a Tarefa 6.3 completa)

```hcl
output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
```

- [x] **Passo 6:** raiz de staging, `infra/envs/staging/aws/main.tf`

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }

  # O state vive na conta SHARED. Blocos de backend não aceitam variáveis: tudo literal.
  backend "s3" {
    bucket       = "shortener-tfstate-<SHARED_ACCOUNT_ID>"
    key          = "envs/staging/aws.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    profile      = "shortener-shared"
  }
}

# Os recursos vivem na conta de STAGING.
provider "aws" {
  region              = "us-east-1"
  profile             = "shortener-staging"
  allowed_account_ids = ["<STAGING_ACCOUNT_ID>"] # trava: falha se as credenciais forem de outra conta

  default_tags {
    tags = { Project = "shortener", Environment = "staging", ManagedBy = "terraform" }
  }
}

variable "admin_cidrs" {
  type = list(string)
}

variable "kubernetes_version" {
  type = string
}

module "env" {
  source = "../../../modules/aws-environment"

  environment        = "staging"
  vpc_cidr           = "10.10.0.0/16"
  kubernetes_version = var.kubernetes_version
  admin_cidrs        = var.admin_cidrs

  node_min_size     = 1
  node_max_size     = 3
  node_desired_size = 2
}

output "cluster_name" {
  value = module.env.cluster_name
}

output "vpc_id" {
  value = module.env.vpc_id
}
```

`infra/envs/staging/aws/terraform.tfvars`:

```hcl
kubernetes_version = "<versão da Tarefa 6.1>"
```

- [x] **Passo 7: suba só rede e cluster** (a primeira vez é manual, para você ler o plano)

```bash
cd infra/envs/staging/aws
terraform init          # usa o profile shortener-shared para falar com o bucket
terraform plan          # leia: VPC, subnets, NAT, EKS, node group, addons, 2 roles IAM + 2 Pod Identity associations
terraform apply         # ~15–20 min
cd -
aws eks update-kubeconfig --name shortener-staging --region us-east-1 \
  --profile shortener-staging --alias shortener-staging
kubectl --context shortener-staging get nodes -o wide   # 2 nós Ready, ARCH arm64
aws eks list-pod-identity-associations --cluster-name shortener-staging \
  --profile shortener-staging --region us-east-1 \
  --query 'associations[].[namespace,serviceAccount]' --output table
# kube-system/aws-load-balancer-controller e argo-rollouts/argo-rollouts
```

Com `--profile`, o `update-kubeconfig` grava `AWS_PROFILE=shortener-staging` na entrada `users[].user.exec.env` do `~/.kube/config`. Por isso o `kubectl --context shortener-staging` funciona mesmo que o seu shell esteja com outro `AWS_PROFILE` exportado.

Para ver a trava funcionando, rode `AWS_PROFILE=shortener-prod terraform plan` e repare que **nada muda**: o profile do provider é explícito. Agora troque, num rascunho que você **não** vai commitar, `profile = "shortener-prod"` no provider e rode `terraform plan`: o erro `AWS account ID not allowed: <PROD_ACCOUNT_ID>` aparece antes de qualquer leitura. Desfaça a mudança.

- [x] **Passo 8: commit** (em uma branch, abrindo PR)

```bash
git switch -c infra/aws-environment
git add infra && git commit -m "infra: módulo de ambiente com VPC, EKS e Pod Identities"
git push -u origin infra/aws-environment && gh pr create --fill
```

Confira se os `.terraform.lock.hcl` foram incluídos: eles **devem** ser versionados. A pasta `.terraform/` não (o `.gitignore` da Fase 4 cuida disso).

Se for parar por aqui hoje, rode **`terraform -chdir=infra/envs/staging/aws destroy`** antes de sair.

**Pronto quando:** `kubectl get nodes` mostra 2 nós `Ready` arm64 e as duas associações de Pod Identity existem.

---

## Tarefa 6.3: dados gerenciados (RDS, ElastiCache Valkey e MSK)

**Arquivos:** criar `infra/modules/aws-environment/data.tf` e alterar `outputs.tf`, além da raiz de staging.

**Conceitos:**
- **Security group que referencia outro security group:** só os nós do EKS falam com os bancos.
- **Criptografia em trânsito em tudo.**
- **Configuração de broker no MSK.**
- **Senha gerada pelo Terraform.** Ela fica no state, que é criptografado no S3 da conta shared; a evolução é usar o Secrets Manager.

- [x] **Passo 1:** `infra/modules/aws-environment/data.tf`

```hcl
# ---------- Security group compartilhado pelos serviços de dados ----------
# (produção real: um SG por serviço)
resource "aws_security_group" "data" {
  name        = "${local.name}-data"
  description = "Acesso aos dados a partir dos nos do EKS"
  vpc_id      = module.vpc.vpc_id
}

locals {
  data_ports = { postgres = 5432, valkey = 6379, kafka_tls = 9094 }
}

resource "aws_vpc_security_group_ingress_rule" "from_nodes" {
  for_each                     = local.data_ports
  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = module.eks.node_security_group_id
  from_port                    = each.value
  to_port                      = each.value
  ip_protocol                  = "tcp"
  description                  = "${each.key} a partir dos nos do EKS"
}

# Brokers do MSK conversam entre si
resource "aws_vpc_security_group_ingress_rule" "self" {
  security_group_id            = aws_security_group.data.id
  referenced_security_group_id = aws_security_group.data.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.data.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- RDS Postgres ----------
resource "random_password" "db" {
  length  = 32
  special = false # evita ter que fazer URL-encode na DATABASE_URL
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.vpc.private_subnets
}

resource "aws_db_instance" "this" {
  identifier              = local.name
  engine                  = "postgres"
  engine_version          = "17"
  instance_class          = var.rds_instance_class
  allocated_storage       = 20
  storage_type            = "gp3"
  storage_encrypted       = true
  db_name                 = "shortener"
  username                = "shortener"
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.data.id]
  publicly_accessible     = false
  multi_az                = var.rds_multi_az
  backup_retention_period = var.deletion_protection ? 7 : 0
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = !var.deletion_protection
  apply_immediately       = true
}

# ---------- ElastiCache Valkey ----------
resource "aws_elasticache_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = local.name
  description                = "Cache do shortener (${var.environment})"
  engine                     = "valkey"
  engine_version             = var.valkey_version
  node_type                  = var.valkey_node_type
  num_cache_clusters         = 1 # produção real: 2+ com failover automático
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.data.id]
  transit_encryption_enabled = true # o app conecta com rediss://
  at_rest_encryption_enabled = true
  automatic_failover_enabled = false
  apply_immediately          = true
}

# ---------- MSK (Kafka gerenciado) ----------
resource "aws_msk_configuration" "this" {
  name           = local.name
  kafka_versions = [var.kafka_version]
  server_properties = <<-EOT
    auto.create.topics.enable=false
    default.replication.factor=2
    min.insync.replicas=1
    num.partitions=3
  EOT
}

resource "aws_msk_cluster" "this" {
  cluster_name           = local.name
  kafka_version          = var.kafka_version
  number_of_broker_nodes = length(var.azs) # 1 broker por AZ

  broker_node_group_info {
    instance_type   = var.kafka_instance_type
    client_subnets  = module.vpc.private_subnets
    security_groups = [aws_security_group.data.id]
    storage_info {
      ebs_storage_info {
        volume_size = 10
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    unauthenticated = true # rede restrita pelo SG; evolução: IAM auth
  }
}
```

- [x] **Passo 2:** adicione ao fim de `infra/modules/aws-environment/outputs.tf`

```hcl
output "database_url" {
  value     = "postgres://shortener:${random_password.db.result}@${aws_db_instance.this.address}:5432/shortener"
  sensitive = true
}

output "redis_url" {
  value = "rediss://${aws_elasticache_replication_group.this.primary_endpoint_address}:6379"
}

output "kafka_brokers" {
  value = aws_msk_cluster.this.bootstrap_brokers_tls # "b-1...:9094,b-2...:9094"
}
```

- [x] **Passo 3:** repasse as saídas, adicionando ao fim da raiz `infra/envs/staging/aws/main.tf`

```hcl
output "database_url" {
  value     = module.env.database_url
  sensitive = true
}

output "redis_url" {
  value = module.env.redis_url
}

output "kafka_brokers" {
  value = module.env.kafka_brokers
}
```

- [x] **Passo 4: aplique e teste a conectividade a partir de dentro do cluster**

```bash
terraform -chdir=infra/envs/staging/aws apply          # +25–35 min (MSK)
RDS=$(terraform -chdir=infra/envs/staging/aws output -raw database_url | sed -E 's|.*@([^:]+):.*|\1|')
REDIS=$(terraform -chdir=infra/envs/staging/aws output -raw redis_url | sed -E 's|rediss://([^:]+):.*|\1|')
BROKER=$(terraform -chdir=infra/envs/staging/aws output -raw kafka_brokers | cut -d, -f1)

kubectl --context shortener-staging run netcheck --rm -it --restart=Never --image=nicolaka/netshoot -- bash -c "
  nc -zv $RDS 5432 && nc -zv $REDIS 6379 && nc -zv ${BROKER%:*} 9094 &&
  echo | openssl s_client -connect $BROKER -brief 2>&1 | head -3"
```

Esperado: três `succeeded` e um handshake TLS, mostrando `Protocol version` e o certificado da Amazon.

- [x] **Passo 5: commit e PR** (`git add infra && git commit -m "infra: RDS, Valkey e MSK"`, push e `gh pr create --fill`).

**Pronto quando:** os três serviços respondem a partir de um pod do cluster.

---

## Tarefa 6.4: módulo `platform` (controllers, Argo Rollouts, ArgoCD e configuração da app)

**Arquivos:**
- Criar `infra/modules/platform/{versions,variables,controllers,rollouts,argocd,app-config,outputs}.tf`
- Criar `infra/envs/staging/platform/main.tf`

**Conceitos:**
- **AWS Load Balancer Controller:** um Ingress no Kubernetes vira um ALB na AWS. Com IngressGroup (Fase 7), os Ingresses `api` e `web` dividem **um** ALB.
- **external-dns:** o Ingress vira um registro na Cloudflare.
- **metrics-server**, necessário para o HPA.
- **Argo Rollouts:** controller que troca o `Deployment` por um `Rollout` com canary (api) e blue-green (web). A camada de plataforma só instala o controller e os CRDs; os `Rollout`s vêm do Git na Fase 7.
- **ArgoCD com "app of apps" mínimo**, via chart `argocd-apps`, agora com **duas** Applications (`shortener-api` e `shortener-web`).
- **O Terraform entrega ao cluster os endereços, segredos e identificadores que mudam a cada ambiente/conta.** Assim o Git não precisa conhecê-los. Inclui o OIDC (Cognito), que vem do bootstrap da conta.

- [x] **Passo 1: descubra as versões atuais dos charts e anote**

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm search repo eks/aws-load-balancer-controller
helm search repo external-dns/external-dns
helm search repo metrics-server/metrics-server
helm search repo argo/argo-cd
helm search repo argo/argocd-apps
helm search repo argo/argo-rollouts
```

Confira também as chaves de valores que este plano usa no chart do Argo Rollouts: `helm show values argo/argo-rollouts --version <versão> | grep -nE '^installCRDs|^keepCRDs|^serviceAccount|^dashboard|extraEnv'`. A fonte da verdade é o [`values.yaml` do chart](https://github.com/argoproj/argo-helm/blob/main/charts/argo-rollouts/values.yaml).

- [x] **Passo 2:** `infra/modules/platform/versions.tf`

```hcl
terraform {
  required_providers {
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
```

- [x] **Passo 3:** `infra/modules/platform/variables.tf` (preencha `chart_versions` com o resultado do Passo 1)

```hcl
variable "environment" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "database_url" {
  type      = string
  sensitive = true
}

variable "redis_url" {
  type = string
}

variable "kafka_brokers" {
  type = string
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "domain_filter" {
  type    = string
  default = "fabricioroglio.com"
}

variable "git_repo_url" {
  type        = string
  description = "Repo GitOps lido pelo ArgoCD (https://github.com/<org>/shortener-deploy.git)"
}

variable "git_revision" {
  type    = string
  default = "main"
}

# ---------- OIDC (vem do bootstrap da conta, Fase 5) ----------
variable "oidc_issuer" {
  type        = string
  description = "https://cognito-idp.us-east-1.amazonaws.com/<pool_id>"
}

variable "oidc_jwks_url" {
  type        = string
  description = "<issuer>/.well-known/jwks.json"
}

variable "oidc_authority" {
  type        = string
  description = "Authority que o oidc-client-ts usa no navegador (no Cognito, igual ao issuer)"
}

variable "oidc_client_id" {
  type        = string
  description = "Client id do app client shortener-web (público, sem secret)"
}

variable "oidc_logout_url" {
  type        = string
  description = "https://<prefixo>.auth.us-east-1.amazoncognito.com/logout"
}

# Um lugar só para as versões: staging e prod usam sempre as mesmas.
variable "chart_versions" {
  type = object({
    aws_lb_controller = string
    external_dns      = string
    metrics_server    = string
    argocd            = string
    argocd_apps       = string
    argo_rollouts     = string
  })
  default = {
    aws_lb_controller = "<versão do helm search>"
    external_dns      = "<versão do helm search>"
    metrics_server    = "<versão do helm search>"
    argocd            = "<versão do helm search>"
    argocd_apps       = "<versão do helm search>"
    argo_rollouts     = "<versão do helm search>"
  }
}
```

- [x] **Passo 4:** `infra/modules/platform/controllers.tf`

```hcl
resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_versions.aws_lb_controller
  namespace  = "kube-system"

  values = [yamlencode({
    clusterName    = var.cluster_name
    region         = var.region
    vpcId          = var.vpc_id
    serviceAccount = { name = "aws-load-balancer-controller" } # o mesmo nome da Pod Identity (Tarefa 6.2)
    defaultTags    = { Project = "shortener", Environment = var.environment } # para achar sobras depois
  })]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.chart_versions.metrics_server
  namespace  = "kube-system"
}

resource "kubernetes_namespace_v1" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_secret_v1" "cloudflare" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace_v1.external_dns.metadata[0].name
  }
  data = { token = var.cloudflare_api_token }
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.chart_versions.external_dns
  namespace  = kubernetes_namespace_v1.external_dns.metadata[0].name

  values = [yamlencode({
    provider = { name = "cloudflare" }
    env = [{
      name      = "CF_API_TOKEN"
      valueFrom = { secretKeyRef = { name = "cloudflare-api-token", key = "token" } }
    }]
    sources       = ["ingress"]
    domainFilters = [var.domain_filter]
    policy        = "sync"                         # apaga o registro quando o Ingress some
    txtOwnerId    = "shortener-${var.environment}" # staging e prod não apagam os registros um do outro
  })]
}
```

O `txtOwnerId` continua essencial mesmo com contas separadas: os dois clusters escrevem na **mesma zona** da Cloudflare, que não sabe nada de contas AWS.

- [x] **Passo 5:** `infra/modules/platform/rollouts.tf`

```hcl
# Argo Rollouts: controller + CRDs (Rollout, AnalysisTemplate, AnalysisRun, Experiment).
# Os Rollouts em si vêm do Git (Fase 7).
resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = var.chart_versions.argo_rollouts
  namespace        = "argo-rollouts"
  create_namespace = true

  values = [yamlencode({
    installCRDs = true # instala e atualiza os CRDs junto com o chart
    keepCRDs    = true # padrão do chart: o uninstall não apaga CRDs (e os Rollouts) por acidente

    # Nome fixo, igual ao da Pod Identity (Tarefa 6.2). Sem isso o chart gera o nome
    # a partir do "fullname" do release, que hoje também daria "argo-rollouts", mas por acaso.
    serviceAccount = { create = true, name = "argo-rollouts" }

    controller = {
      replicas = 1 # produção real: 2 (leader election). Aqui economiza recurso nos nós.
      # O provider CloudWatch das análises exige a região no ambiente do controller;
      # a Pod Identity entrega só as credenciais.
      extraEnv = [{ name = "AWS_REGION", value = var.region }]
    }

    # Dashboard desligado no cluster: use o plugin local "kubectl argo rollouts dashboard",
    # que roda no seu Mac (localhost:3100) com as credenciais do seu kubeconfig. Nada exposto.
    dashboard = { enabled = false }
  })]
}
```

Repare: a chave do service account no chart é `serviceAccount` **na raiz** dos valores (não `controller.serviceAccount`), e os CRDs usam `installCRDs` (não `crds.install`, que é a convenção do chart do ArgoCD). Confira no `helm show values` da versão que você fixou.

- [x] **Passo 6:** `infra/modules/platform/app-config.tf`

```hcl
resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = "shortener"
    labels = {
      # O ALB só manda tráfego para o pod depois de registrá-lo no target group: zero downtime real.
      # Vale também para os pods canary/preview criados pelo Argo Rollouts.
      "elbv2.k8s.aws/pod-readiness-gate-inject" = "enabled"
    }
  }
}

resource "random_password" "api_key" {
  length  = 40
  special = false
}

# Endereços que mudam a cada "up": vêm do Terraform, não do Git. Usado por api, worker e setup.
resource "kubernetes_config_map_v1" "infra" {
  metadata {
    name      = "shortener-infra"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    KAFKA_BROKERS            = var.kafka_brokers
    KAFKA_SSL                = "true"
    KAFKA_REPLICATION_FACTOR = "2"
    REDIS_URL                = var.redis_url
    DATABASE_SSL             = "true"
    DATABASE_SSL_CA_FILE     = "/app/certs/rds-global-bundle.pem"
  }
}

resource "kubernetes_secret_v1" "app" {
  metadata {
    name      = "shortener-secrets"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    DATABASE_URL = var.database_url
    API_KEY      = random_password.api_key.result
  }
}

# Identidade (Cognito da conta). Nada aqui é segredo: o client é público (PKCE, sem secret).
# A api usa OIDC_ISSUER, OIDC_AUDIENCE e OIDC_JWKS_URL; o web usa OIDC_AUTHORITY,
# OIDC_CLIENT_ID e OIDC_LOGOUT_URL (viram /runtime/config.js no container nginx).
resource "kubernetes_config_map_v1" "oidc" {
  metadata {
    name      = "shortener-oidc"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    OIDC_ISSUER     = var.oidc_issuer
    OIDC_AUDIENCE   = var.oidc_client_id # a api aceita aud OU client_id igual a este valor
    OIDC_JWKS_URL   = var.oidc_jwks_url
    OIDC_AUTHORITY  = var.oidc_authority
    OIDC_CLIENT_ID  = var.oidc_client_id
    OIDC_LOGOUT_URL = var.oidc_logout_url
  }
}
```

- [x] **Passo 7:** `infra/modules/platform/argocd.tf`

```hcl
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_versions.argocd
  namespace        = "argocd"
  create_namespace = true

  values = [yamlencode({
    dex           = { enabled = false } # sem SSO no ArgoCD: login admin via port-forward
    notifications = { enabled = false }
    configs       = { params = { "server.insecure" = true } } # TLS fica a cargo do port-forward local
  })]
}

locals {
  # Uma Application por app, cada uma com o seu overlay. Mesma política de sync para as duas.
  argocd_applications = {
    for app in ["api", "web"] : "shortener-${app}" => {
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"] # apagar a App apaga o que ela criou
      project    = "default"
      source = {
        repoURL        = var.git_repo_url
        targetRevision = var.git_revision
        path           = "apps/${app}/overlays/${var.environment}"
      }
      destination = { server = "https://kubernetes.default.svc", namespace = "shortener" }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
        retry     = { limit = 5, backoff = { duration = "10s", factor = 2, maxDuration = "3m" } }
      }
    }
  }
}

resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.chart_versions.argocd_apps
  namespace  = "argocd"

  # Garante a ordem: tudo de que as apps dependem existe antes (inclusive os CRDs do Rollout
  # e o ConfigMap do OIDC); no destroy, as apps saem primeiro.
  depends_on = [
    helm_release.argocd,
    helm_release.argo_rollouts,
    helm_release.aws_lb_controller,
    helm_release.external_dns,
    helm_release.metrics_server,
    kubernetes_config_map_v1.infra,
    kubernetes_config_map_v1.oidc,
    kubernetes_secret_v1.app,
  ]

  values = [yamlencode({
    applications = local.argocd_applications
  })]
}
```

Notas:
- A partir da v2 do chart `argocd-apps`, `applications` é um **mapa** indexado pelo nome. Confira o `values.yaml` da versão que você fixou.
- **Health de `Rollout`:** o ArgoCD já sabe avaliar `argoproj.io/Rollout` sem configuração extra: a verificação Lua vem embutida ([`resource_customizations/argoproj.io/Rollout/health.lua`](https://github.com/argoproj/argo-cd/tree/master/resource_customizations/argoproj.io/Rollout)). Um Rollout pausado no meio de um canary aparece como `Suspended`, e a Application fica `Suspended` até ele terminar; isso importa na Fase 8.
- As duas Applications compartilham o namespace `shortener`, mas cada uma só gerencia (e faz prune de) os recursos que ela mesma criou.

- [x] **Passo 8:** `infra/modules/platform/outputs.tf`

```hcl
output "api_key" {
  value     = random_password.api_key.result
  sensitive = true
}
```

- [x] **Passo 9:** raiz `infra/envs/staging/platform/main.tf`

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    helm       = { source = "hashicorp/helm", version = "~> 3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }

  backend "s3" {
    bucket       = "shortener-tfstate-<SHARED_ACCOUNT_ID>"
    key          = "envs/staging/platform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    profile      = "shortener-shared"
  }
}

provider "aws" {
  region              = "us-east-1"
  profile             = "shortener-staging"
  allowed_account_ids = ["<STAGING_ACCOUNT_ID>"]

  default_tags {
    tags = { Project = "shortener", Environment = "staging", ManagedBy = "terraform" }
  }
}

# Saídas da camada aws deste ambiente (state na conta shared).
data "terraform_remote_state" "aws" {
  backend = "s3"
  config = {
    bucket  = "shortener-tfstate-<SHARED_ACCOUNT_ID>"
    key     = "envs/staging/aws.tfstate"
    region  = "us-east-1"
    profile = "shortener-shared"
  }
}

# Saídas do bootstrap PERMANENTE da conta deste ambiente (Fase 5): Cognito e certificado.
data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket  = "shortener-tfstate-<SHARED_ACCOUNT_ID>"
    key     = "bootstrap/staging.tfstate"
    region  = "us-east-1"
    profile = "shortener-shared"
  }
}

data "aws_eks_cluster" "this" {
  name = data.terraform_remote_state.aws.outputs.cluster_name
}

locals {
  bootstrap = data.terraform_remote_state.bootstrap.outputs

  # O token do cluster é pedido com o profile da conta do ambiente, explicitamente.
  k8s_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", data.aws_eks_cluster.this.name,
      "--region", "us-east-1",
      "--profile", "shortener-staging",
    ]
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = local.k8s_exec.api_version
    command     = local.k8s_exec.command
    args        = local.k8s_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec                   = local.k8s_exec
  }
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

module "platform" {
  source = "../../../modules/platform"

  environment          = "staging"
  cluster_name         = data.aws_eks_cluster.this.name
  vpc_id               = data.terraform_remote_state.aws.outputs.vpc_id
  database_url         = data.terraform_remote_state.aws.outputs.database_url
  redis_url            = data.terraform_remote_state.aws.outputs.redis_url
  kafka_brokers        = data.terraform_remote_state.aws.outputs.kafka_brokers
  cloudflare_api_token = var.cloudflare_api_token
  git_repo_url         = "https://github.com/<org>/shortener-deploy.git"

  oidc_issuer     = local.bootstrap.oidc_issuer
  oidc_jwks_url   = local.bootstrap.oidc_jwks_url
  oidc_authority  = local.bootstrap.oidc_authority
  oidc_client_id  = local.bootstrap.oidc_client_id
  oidc_logout_url = local.bootstrap.oidc_logout_url
}

output "api_key" {
  value     = module.platform.api_key
  sensitive = true
}
```

Notas sobre a raiz:
- **`--profile` no `exec` em vez de `AWS_PROFILE`:** o comando `aws eks get-token` roda como processo filho do Terraform. Daria para usar `env = { AWS_PROFILE = "shortener-staging" }` no `exec`, ou herdar o `AWS_PROFILE` do shell. Escolhemos o argumento explícito porque fica visível no código, não depende do shell de quem roda e casa com o `profile` do provider `aws` logo acima: as três credenciais que tocam a conta do ambiente estão escritas no mesmo arquivo.
- O `terraform_remote_state` não herda o profile do backend: o `profile` precisa estar no `config` de cada um, senão ele tenta ler o bucket com as credenciais padrão (de outra conta) e dá `AccessDenied`.
- O provider `helm` v3 usa `kubernetes = { ... }` (atributo, com `=`). Na v2 era um bloco `kubernetes { ... }`. Se encontrar exemplos antigos na internet, é por isso que diferem.

- [x] **Passo 10: aplique e confira**

```bash
terraform -chdir=infra/envs/staging/platform init
terraform -chdir=infra/envs/staging/platform apply     # ~5–7 min
k() { kubectl --context shortener-staging "$@"; }   # função, não variável: funciona no zsh e no bash
k -n kube-system get deploy aws-load-balancer-controller metrics-server
k top nodes                                            # o metrics-server está funcionando
k -n argo-rollouts get deploy,sa                       # deploy argo-rollouts Available, SA argo-rollouts
k get crd rollouts.argoproj.io analysistemplates.argoproj.io
k -n argo-rollouts get pod -l app.kubernetes.io/name=argo-rollouts -o json \
  | jq -r '.items[0].spec.containers[0].env[].name'
# AWS_REGION (nosso extraEnv) e AWS_CONTAINER_CREDENTIALS_FULL_URI (injetada pela Pod Identity).
# Não use "exec ... env": a imagem do controller é distroless, sem shell nem o binário env.
k -n shortener get cm shortener-infra shortener-oidc
k -n shortener get cm shortener-oidc -o yaml           # 6 chaves OIDC_*, com o pool de staging
k -n argocd get applications                           # shortener-api e shortener-web
```

As duas Applications aparecem com `SYNC STATUS` `Unknown` e uma condição `ComparisonError` ("app path does not exist"), porque `apps/api/overlays/staging` e `apps/web/overlays/staging` só são criados na Fase 7. Isso é esperado.

Opcional: instale o plugin do Argo Rollouts, que a Fase 7 usa (`brew install argoproj/tap/kubectl-argo-rollouts`), e rode `kubectl argo rollouts version`.

- [x] **Passo 11: commit e PR** (`git add infra && git commit -m "infra: plataforma com Argo Rollouts, OIDC e Applications do ArgoCD"`, push e `gh pr create --fill`).

**Pronto quando:** os controllers estão `Available`, `kubectl top nodes` funciona, o ConfigMap `shortener-oidc` tem as 6 chaves e as Applications `shortener-api` e `shortener-web` existem (o erro de path é esperado até a Fase 7).

---

## Tarefa 6.5: scripts de subir, derrubar e verificar sobras

**Arquivos:** criar `scripts/up.sh`, `scripts/down.sh` e `scripts/leftovers.sh` (lembre do `chmod +x scripts/*.sh`).

**Conceitos:**
- **O ALB não é criado pelo Terraform**, e sim pelo controller, a partir dos Ingresses. Se você destruir o cluster primeiro, o ALB fica órfão, continua cobrando e trava o destroy da VPC. **A ordem importa.**
- **Um ALB, dois donos.** Com IngressGroup (Fase 7), o ALB só some quando **os dois** Ingresses (`api` e `web`) somem. Por isso o `down` apaga as duas Applications antes de esperar o ALB.
- **Cada script trabalha numa conta só:** todos exportam `AWS_PROFILE=shortener-$ENV`, então a AWS CLI e o `kubectl` falam com a conta do ambiente. O Terraform usa os profiles explícitos das raízes.

- [x] **Passo 1:** `scripts/up.sh`

```bash
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
```

- [x] **Passo 2:** `scripts/down.sh`

```bash
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
```

Se o cluster já não existir (um `down` que caiu no meio, por exemplo), o script pula o passo 1 e vai direto aos destroys. Se o destroy da plataforma falhar porque o cluster sumiu, rode `terraform -chdir=infra/envs/$ENV/platform state list` e remova do state o que não existe mais (`terraform state rm`), e então siga com a camada aws.

- [x] **Passo 3:** `scripts/leftovers.sh`

```bash
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
```

Observações sobre o script:
- **Agora ele roda dentro da conta do ambiente.** Load balancers, NAT, EIPs, volumes, clusters e bancos são listados para a conta inteira, mas a conta inteira **é** o ambiente. Por isso o aviso antigo ("se o outro ambiente estiver de pé, os recursos dele aparecem como sobra") deixou de existir: você pode ter prod de pé e derrubar staging com o `leftovers.sh staging` limpo. Qualquer coisa que apareça é sobra deste ambiente, inclusive o que alguém criou à mão no console, sem tag.
- **Por que excluir ACM e Cognito pelo ARN, e não por tag:** o bootstrap da conta (Fase 5) usa as mesmas `default_tags` (`Environment=<env>`, `ManagedBy=terraform`). Em vez de mudar a Fase 5 para ganhar uma tag `Layer=bootstrap`, o filtro aqui pula os ARNs `:acm:` e `:cognito-idp:`, que são exatamente os recursos permanentes do bootstrap. Se um dia a camada efêmera passar a criar certificado ou user pool, este filtro precisa ser revisto.
- O bucket de state não aparece: ele vive na conta shared.
- Os registros de validação do ACM (`_xxxx.shortener...`) são permanentes e não aparecem na checagem de DNS, porque ela consulta só os nomes exatos dos 3 hosts e os TXT do external-dns.
- **A API de tags é um índice com atraso, não a fonte da verdade.** Logo depois do destroy, ela ainda lista o NAT Gateway, os security groups e as regras que acabaram de ser apagados (o NAT por até 1h). Ela também lista a chave KMS do EKS durante os 30 dias de `PendingDeletion`, um estado que não é cobrado. Por isso, o `still_exists` confirma esses tipos no serviço dono (`NotFound`, `deleted` ou `PendingDeletion` = não é sobra). Para os outros tipos, ele confia no índice: na dúvida, acusa.

- [ ] **Passo 4: teste o ciclo completo**

```bash
chmod +x scripts/*.sh
scripts/down.sh staging     # derruba o que você criou nas tarefas anteriores
scripts/leftovers.sh staging
scripts/up.sh staging       # o "wait" do passo 3 vai expirar por enquanto (os overlays só existem na Fase 7). Ctrl+C é seguro aqui.
scripts/down.sh staging
```

- [ ] **Passo 5: commit e PR.** `git add scripts infra && git commit -m "infra: scripts up/down/leftovers por conta de ambiente"`, push e `gh pr create --fill`.

**Pronto quando:** `down.sh` termina com "OK: nenhuma sobra encontrada" e `up.sh` recria tudo sem intervenção manual (até o wait das Applications).

---

## Tarefa 6.6: ambiente de produção (só código; ainda não aplicar)

O bootstrap da conta de prod (Fase 5) já existe; o que falta são as raízes efêmeras.

- [x] **Passo 1: copie as raízes**

```bash
cp -r infra/envs/staging infra/envs/prod
rm -rf infra/envs/prod/*/.terraform
```

- [x] **Passo 2: ajuste `infra/envs/prod/aws/main.tf`**
  - Backend: `key = "envs/prod/aws.tfstate"` (bucket e `profile = "shortener-shared"` continuam iguais)
  - Provider: `profile = "shortener-prod"` e `allowed_account_ids = ["<PROD_ACCOUNT_ID>"]`
  - `Environment = "prod"` no `default_tags`
  - No módulo: `environment = "prod"` e `vpc_cidr = "10.20.0.0/16"`
  - Nós: `node_min_size = 2`, `node_max_size = 4` e `node_desired_size = 2`
- [x] **Passo 3: ajuste `infra/envs/prod/platform/main.tf`**
  - Backend: `key = "envs/prod/platform.tfstate"`
  - Provider: `profile = "shortener-prod"` e `allowed_account_ids = ["<PROD_ACCOUNT_ID>"]`
  - `Environment = "prod"` no `default_tags`
  - Remote state `aws`: `key = "envs/prod/aws.tfstate"`
  - Remote state `bootstrap`: `key = "bootstrap/prod.tfstate"`
  - `local.k8s_exec`: `"--profile", "shortener-prod"`
  - No módulo: `environment = "prod"`
- [x] **Passo 4: confira que não sobrou nada de staging**

```bash
grep -rn "staging" infra/envs/prod      # deve voltar vazio
```

- [x] **Passo 5: valide sem aplicar**

```bash
for d in infra/envs/prod/aws infra/envs/prod/platform; do
  terraform -chdir=$d init -backend=false >/dev/null && terraform -chdir=$d validate
done
```

- [x] **Passo 6: commit e PR** (`git add infra/envs/prod && git commit -m "infra: raízes de prod na conta de prod"`).

**Pronto quando:** `validate` passa nas duas raízes de prod e o `grep` não acha `staging`.

**Para refletir:** staging e prod rodam o **mesmo módulo** e só os valores mudam, inclusive a conta. A infra testada em staging é a mesma que vai para produção, e um erro de profile em prod é barrado pelo `allowed_account_ids` antes de tocar em qualquer recurso.

---

## Tarefa 6.7: CI do `shortener-deploy` (validação de infra)

**Arquivos:** criar `.github/workflows/ci.yml` (o workflow nasce nesta fase; a Fase 7 acrescenta a validação dos manifests).

**Conceitos:**
- **`init -backend=false`** baixa providers e módulos, mas não configura o backend. Não precisa de credencial nem do profile `shortener-shared`.
- **`validate` não autentica.** Ele confere sintaxe, tipos, referências e argumentos dos providers e módulos, sem chamar nenhuma API (nem a da AWS, nem o state remoto). Por isso `profile = "shortener-<env>"` e `allowed_account_ids` no provider não quebram o CI: são só atributos de configuração, que seriam usados no `plan`/`apply`. O runner do GitHub não tem `~/.aws/config` e isso não importa.
- O `plan` em PR, com credenciais via GitHub OIDC → papel na conta, fica nas extensões.

- [ ] **Passo 1:** `.github/workflows/ci.yml`

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  infra:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v7
      - uses: hashicorp/setup-terraform@v4
      - name: terraform fmt
        run: terraform fmt -check -recursive infra
      - name: terraform validate
        run: |
          for dir in infra/organization infra/bootstrap/shared infra/bootstrap/staging infra/bootstrap/prod \
                     infra/envs/*/aws infra/envs/*/platform; do
            echo "::group::$dir"
            terraform -chdir="$dir" init -backend=false -input=false >/dev/null
            terraform -chdir="$dir" validate
            echo "::endgroup::"
          done
```

Notas:
- O nome do job (`infra`) vira o nome do check no PR. A Fase 8 pode exigi-lo no ruleset da `main`.
- `infra/bootstrap/modules/account-baseline` e `infra/modules/*` não entram no loop: módulos são validados através das raízes que os usam.
- Se a raiz de organização usar um provider com `profile = "shortener-mgmt"`, vale o mesmo raciocínio: `validate` não autentica.

- [ ] **Passo 2: abra o PR e veja o job verde.** Rode `terraform fmt -recursive infra` localmente antes, se o `fmt -check` reclamar.

**Pronto quando:** o PR mostra o check `infra` verde.

---

## Checkpoint da Fase 6

- [ ] `scripts/up.sh staging` cria tudo na conta de staging e `scripts/down.sh staging` destrói tudo sem sobras
- [ ] O ConfigMap `shortener-oidc` tem as 6 chaves e as Applications `shortener-api` e `shortener-web` existem (esperando os overlays da Fase 7)
- [ ] O controller do Argo Rollouts roda com a Pod Identity (credenciais e `AWS_REGION` no ambiente do pod)
- [ ] Você sabe explicar por que existem duas camadas de Terraform, por que a ordem do destroy importa e o que a trava `allowed_account_ids` evita
- [ ] O CI do `shortener-deploy` valida todas as raízes
- [ ] **O ambiente está derrubado** se você não for continuar agora
