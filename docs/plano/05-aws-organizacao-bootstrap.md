# Fase 5: AWS Organizations, contas por ambiente e bootstrap

**Entrega:**
- Conta management protegida (MFA, budget da organização, Cost Explorer), sem nenhum workload.
- AWS Organization com as OUs `Infrastructure` e `Workloads`, as contas `shortener-shared`, `shortener-staging` e `shortener-prod`, e 3 SCPs.
- Login SSO no terminal, com um profile por conta.
- Bucket de state do Terraform na conta `shared`, guardando o state de todas as raízes.
- Em cada conta de workload (staging e prod): certificado ACM com os 3 hosts, já validado via Cloudflare, e um Cognito (user pool, Hosted UI e app client do painel).

**Custo:** ~US$ 0. Contas, Organizations, SCPs, Identity Center, ACM e Cognito Lite (até 10 mil usuários ativos por mês) são grátis; o bucket de state custa centavos.
**Tudo desta fase fica de pé para sempre.** O que é efêmero começa na Fase 6.
**Repo:** tudo daqui para a frente vive no `shortener-deploy` (`~/Documents/projects/shortener-deploy`). Os commits seguem a rotina de PR da Fase 4. O deploy repo ainda não tem CI (ele nasce na Fase 6), então o PR aqui serve de registro e revisão.

---

## O modelo de contas

Em empresa, cada ambiente tem a sua conta AWS. A conta é a fronteira mais forte que a AWS oferece: IAM, cotas, rede, custos e "raio de explosão" ficam separados. Um `terraform destroy` errado em staging não alcança prod, porque as credenciais de staging não enxergam a conta de prod.

```
                    ┌────────────────────────────────────────────┐
                    │ management (shortener-mgmt)                 │
                    │ Organizations · Identity Center · billing   │
                    │ budget da org · SCPs · NENHUM workload      │
                    └─────────────────────┬──────────────────────┘
                                          │ Root
                     ┌────────────────────┴────────────────────┐
                     ▼                                         ▼
          OU Infrastructure                              OU Workloads
          (SCPs: regiões, leave-org, root)               (SCPs: regiões, leave-org, root)
                     │                                  ┌──────┴───────┐
                     ▼                                  ▼              ▼
          shortener-shared                     shortener-staging   shortener-prod
          bucket de state                      ACM + Cognito       ACM + Cognito
          de todas as raízes                   (permanentes)       (permanentes)
                                               VPC/EKS/RDS/...     VPC/EKS/RDS/...
                                               (efêmeros, Fase 6)  (efêmeros, Fase 6)
```

| Conta | Profile SSO | Placeholder do ID |
|---|---|---|
| management | `shortener-mgmt` | `<MGMT_ACCOUNT_ID>` |
| shared | `shortener-shared` | `<SHARED_ACCOUNT_ID>` |
| staging | `shortener-staging` | `<STAGING_ACCOUNT_ID>` |
| prod | `shortener-prod` | `<PROD_ACCOUNT_ID>` |

**Por que a management não roda nada?** As SCPs nunca se aplicam à conta management, e quem tem admin nela controla a organização inteira. Quanto menos coisa existir ali, menor a superfície de ataque. É a recomendação da própria AWS.

**Como o Terraform se encaixa:**
- Todas as raízes guardam state no bucket da `shared`, com `profile = "shortener-shared"` no backend.
- O provider `aws` de cada raiz usa o profile da conta onde os recursos vão nascer e trava `allowed_account_ids` nela. Se você rodar a raiz de prod com o profile errado, o Terraform recusa antes de tocar em qualquer coisa.
- Chaves de state: `organization/terraform.tfstate`, `bootstrap/shared.tfstate`, `bootstrap/staging.tfstate`, `bootstrap/prod.tfstate` (e, na Fase 6, `envs/<env>/aws.tfstate` e `envs/<env>/platform.tfstate`).

---

## Tarefa 5.1: conta management e proteção do root

**Conceitos:** esta é a única conta que você cria à mão. As outras 3 nascem pelo Terraform (Tarefa 5.3), dentro da organização.

- [ ] **Passo 1: crie a conta** em <https://aws.amazon.com>
  - Use um e-mail que você controla. As contas-membro vão usar aliases desse e-mail com `+` (por exemplo `<seu-email>+shortener-staging@gmail.com`), então um Gmail é prático.
  - **Escolha o plano "Paid"** (pago). Ele também recebe os créditos de boas-vindas e não tem as restrições de serviço do plano "Free". Além disso, uma conta no plano Free que entra numa Organization é promovida a Paid automaticamente. Você só paga o que passar dos créditos, e o budget do passo 4 avisa antes.
  - Os créditos são para **clientes novos**. Se você já teve uma conta AWS, confira os termos antes de contar com eles.
  - Depois de criada, edite o nome da conta para `shortener-mgmt` (**Account** → *Account name*).
- [ ] **Passo 2: ative MFA no usuário root.** Console → canto superior direito → **Security credentials** → **Assign MFA device**. Use um app autenticador ou uma passkey.
- [ ] **Passo 3: libere o Billing para usuários IAM.** **Account** → *IAM user and role access to Billing information* → **Activate**. Sem isso, o seu usuário SSO não enxerga custos.
- [ ] **Passo 4: crie o budget agora, antes de qualquer recurso.** Console → **Billing and Cost Management** → **Budgets** → **Create budget**:
  - Template: *Monthly cost budget*, valor **US$ 20**
  - Alertas (e-mail): 25% (US$ 5), 80% e 100% do valor real, mais 100% do valor **previsto**

  Um budget na management cobre **a organização inteira**: com billing consolidado, os custos de todas as contas-membro caem na fatura da management. Você não precisa de um budget por conta.

  Criar o budget também conta como uma das atividades que dão US$ 20 de crédito (widget "Explore AWS" na home do console). **Faça as atividades de crédito que quiser antes da Tarefa 5.2:** segundo o FAQ do Free Tier, uma conta que entra numa Organization deixa de poder ganhar créditos novos. Os créditos já ganhos continuam valendo até expirar.
- [ ] **Passo 5: ative o Cost Explorer.** **Billing** → **Cost Explorer** → *Enable*. Os dados levam até 24h para aparecer. Mais tarde, o filtro **Linked account** mostra o custo de cada ambiente separado, um bônus didático da conta por ambiente.

**Pronto quando:** o root tem MFA e o budget aparece na lista.

---

## Tarefa 5.2: IAM Identity Center e a Organization

**Conceitos:**
- Nunca use o root no dia a dia.
- Nunca guarde access keys de longa duração no disco. O SSO gera credenciais temporárias.
- **Identity Center cria a Organization.** Ao habilitar o Identity Center numa conta avulsa, a AWS cria uma Organization com *all features* e faz dessa conta a management. É esperado.
- **SCPs precisam de duas coisas:** a organização com *all features* (o Identity Center já cria assim) e o tipo de política `SERVICE_CONTROL_POLICY` habilitado na raiz (isso **não** vem ligado). Escolha deste plano: em vez de habilitar pelo console ou pela CLI (`aws organizations enable-policy-type`), a Tarefa 5.3 traz a organização existente para o Terraform com um bloco `import` e declara `enabled_policy_types` lá. Assim, a configuração da organização inteira fica no código e aparece em todo `plan`.

- [ ] **Passo 1: ative o IAM Identity Center.** Console → **IAM Identity Center** → **Enable**, na região **us-east-1**. Escolha a opção com AWS Organizations (a recomendada), não a "account instance". A região do Identity Center não muda depois.
- [ ] **Passo 2: exija MFA.** **Settings** → **Authentication** → **Multi-factor authentication** → *Configure*: "Every time they sign in (always-on)" e, se o usuário não tiver dispositivo, "Require them to register an MFA device at sign in".
- [ ] **Passo 3: crie o seu usuário.** **Users** → **Add user**. Escolha um *username* (por exemplo, seu primeiro nome em minúsculas; ele vai para a variável `sso_username` na Tarefa 5.3) e o seu e-mail. Aceite o convite que chega por e-mail, defina a senha e **cadastre o MFA**.
- [ ] **Passo 4: crie a permission set.** **Permission sets** → **Create** → *Predefined* → **AdministratorAccess**, com duração de sessão de **8h**. Mantenha o nome `AdministratorAccess`: o Terraform da Tarefa 5.3 a encontra por esse nome. Para estudo, admin é aceitável; em empresa você teria papéis menores (ReadOnly, PowerUser) e grupos.
- [ ] **Passo 5: dê acesso à management.** **AWS accounts** → selecione a conta management → **Assign users or groups** → o seu usuário → `AdministratorAccess`. As outras 3 contas recebem o acesso pelo Terraform.
- [ ] **Passo 6: configure o profile no terminal**

```bash
aws configure sso
# SSO session name: shortener
# SSO start URL: (painel do Identity Center → "AWS access portal URL")
# SSO region: us-east-1
# SSO registration scopes: (Enter)
# (o navegador abre; faça login com MFA)
# Escolha a conta management e o papel AdministratorAccess
# Default client Region: us-east-1 · Output: json · Profile name: shortener-mgmt
```

- [ ] **Passo 7: teste e anote os IDs**

```bash
aws sts get-caller-identity --profile shortener-mgmt                 # Account = <MGMT_ACCOUNT_ID>
aws organizations describe-organization --profile shortener-mgmt \
  --query 'Organization.{id:Id,featureSet:FeatureSet}'              # featureSet = ALL
aws organizations list-aws-service-access-for-organization --profile shortener-mgmt \
  --query 'EnabledServicePrincipals[].ServicePrincipal'             # deve listar sso.amazonaws.com
aws organizations list-roots --profile shortener-mgmt \
  --query 'Roots[0].PolicyTypes'                                     # vazio: SCP ainda não habilitada
```

Anote o **Account ID** (vira `<MGMT_ACCOUNT_ID>`), o **ID da organização** (`o-...`) e a lista de *service principals*: os três entram na Tarefa 5.3.

- [ ] **Passo 8: confira a cota de contas e peça aumento já**

Organizações novas nascem com a cota de contas **travada abaixo do default**. Medido em out/2026: valor aplicado **2** (a management conta como uma), default 10. A Tarefa 5.3 precisa de 4. Sem o aumento, o `apply` cria uma conta e para no meio.

```bash
aws service-quotas get-service-quota --profile shortener-mgmt --region us-east-1 \
  --service-code organizations --quota-code L-E619E033 --query 'Quota.Value'   # "Maximum number of accounts"
# Se for menor que 4: a API só aceita pedido ACIMA do default (10). Pedir 5 dá
# "You must provide a quota value greater than the default quota value of 10.0".
aws service-quotas request-service-quota-increase --profile shortener-mgmt --region us-east-1 \
  --service-code organizations --quota-code L-E619E033 --desired-value 11
aws service-quotas list-requested-service-quota-change-history --profile shortener-mgmt --region us-east-1 \
  --service-code organizations --query 'RequestedQuotas[].{status:Status,pedido:DesiredValue,caso:CaseId}'
```

O pedido vira um caso de suporte e pode levar de horas a dias. Enquanto espera, dá para escrever o Terraform da Tarefa 5.3 e fazer a Tarefa 5.5.

**Pronto quando:** o `get-caller-identity` funciona com o profile `shortener-mgmt`, a organização aparece com `featureSet = ALL` e a cota de contas é 4 ou mais (ou o pedido está aberto).

---

## Tarefa 5.3: Terraform da organização (`infra/organization/`)

**Arquivos (no `shortener-deploy`):** criar `infra/organization/main.tf`, `scps.tf`, `sso.tf`, `root-access.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars`, `private.auto.tfvars` (fora do Git) e `policies/deny-other-regions.json`, `policies/deny-leave-org.json`, `policies/deny-root-user.json`.

**Conceitos:**
- **`import` block:** traz para o state um recurso que já existe, sem recriá-lo. Aqui, a organização criada pelo Identity Center.
- **Cuidado com o import da organização:** `aws_service_access_principals` é a lista **completa** dos serviços com acesso confiável. Se faltar um que já está habilitado (como o `sso.amazonaws.com`), o Terraform **desabilita** esse serviço no apply. Por isso o `plan` tem que mostrar só adições na organização.
- **Contas como código:** `aws_organizations_account` cria a conta, põe na OU certa e cria nela a role `OrganizationAccountAccessRole` (admin, confiando na management). A API não deixa ler o `role_name` depois, por isso o `ignore_changes`, que só faz diferença se um dia você importar uma conta.
- **`close_on_deletion = true`:** sem isso, um `destroy` só tira a conta da organização, e uma conta avulsa precisa de cartão e credenciais de root próprios, o que é mais trabalho do que fechá-la. Com `true`, o `destroy` fecha a conta: ela fica 90 dias suspensa e depois some, e o e-mail dela não pode ser reaproveitado. A AWS também limita quantas contas se fecha por período. Como fechar uma conta por engano seria ruim, as contas têm `prevent_destroy`; o encerramento (Fase 9) remove essa trava de propósito.
- **SCPs (Service Control Policies)** definem o máximo que **qualquer** principal da conta pode fazer, inclusive admin. Não dão permissão; só limitam. Ficam anexadas às OUs, não à raiz, e nunca afetam a management. Cada alvo aceita até 5 SCPs; a `FullAWSAccess` (padrão) ocupa uma.
- **E-mails fora do Git:** o repo é público. O seu e-mail e o seu usuário do SSO ficam em `private.auto.tfvars`, que está no `.gitignore` desde a Fase 4. O Terraform carrega `*.auto.tfvars` sozinho.
- **State local por enquanto.** O bucket de state ainda não existe (ele nasce na conta `shared`, que esta tarefa cria). A migração para o S3 acontece na Tarefa 5.6.

- [ ] **Passo 1: crie** `infra/organization/main.tf`

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # Tarefa 5.6: descomente depois que o bucket existir e rode `terraform init -migrate-state`.
  # backend "s3" {
  #   bucket       = "shortener-tfstate-<SHARED_ACCOUNT_ID>"
  #   key          = "organization/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  #   profile      = "shortener-shared"
  # }
}

provider "aws" {
  region              = "us-east-1"
  profile             = "shortener-mgmt"
  allowed_account_ids = ["<MGMT_ACCOUNT_ID>"]
  default_tags {
    tags = { Project = "shortener", Environment = "management", ManagedBy = "terraform" }
  }
}

# ---------- A organização (criada pelo Identity Center na Tarefa 5.2) ----------
import {
  to = aws_organizations_organization.this
  id = var.organization_id
}

resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  # Lista COMPLETA de serviços com acesso confiável. Inclua todos os que o
  # `list-aws-service-access-for-organization` da Tarefa 5.2 mostrou.
  aws_service_access_principals = [
    "iam.amazonaws.com", # centralized root access (root-access.tf)
    "sso.amazonaws.com", # IAM Identity Center (já habilitado)
  ]

  enabled_policy_types = ["SERVICE_CONTROL_POLICY"]

  lifecycle {
    prevent_destroy = true
  }
}

# ---------- OUs ----------
locals {
  ous = {
    infrastructure = "Infrastructure"
    workloads      = "Workloads"
  }

  # conta => OU
  accounts = {
    shared  = "infrastructure"
    staging = "workloads"
    prod    = "workloads"
  }
}

resource "aws_organizations_organizational_unit" "this" {
  for_each  = local.ous
  name      = each.value
  parent_id = aws_organizations_organization.this.roots[0].id
}

# ---------- Contas-membro ----------
resource "aws_organizations_account" "this" {
  for_each = local.accounts

  name              = "shortener-${each.key}"
  email             = "${var.email_local_part}+shortener-${each.key}@${var.email_domain}"
  parent_id         = aws_organizations_organizational_unit.this[each.value].id
  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = true

  # Com o centralized root access ligado antes, as contas já nascem sem credenciais de root.
  depends_on = [aws_iam_organizations_features.this]

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name] # a API não permite ler o role_name depois da criação
  }
}
```

- [ ] **Passo 2: crie** `infra/organization/root-access.tf`

**Conceitos:** o *centralized root access management* do IAM remove as credenciais de root (senha, chaves, MFA) das contas-membro. As poucas tarefas que exigem root (por exemplo, destravar uma bucket policy que bloqueou todo mundo) passam a ser feitas a partir da management, com sessões de root curtas (`sts:AssumeRoot`). Exige acesso confiável do IAM na organização (`iam.amazonaws.com`, já no `main.tf`). É opcional, mas recomendado: uma conta sem senha de root não pode ter a senha de root roubada.

```hcl
resource "aws_iam_organizations_features" "this" {
  enabled_features = [
    "RootCredentialsManagement",
    "RootSessions",
  ]

  depends_on = [aws_organizations_organization.this] # precisa do iam.amazonaws.com habilitado
}
```

O equivalente pela CLI (não precisa rodar; é só para referência) é `aws iam enable-organizations-root-credentials-management` seguido de `aws iam enable-organizations-root-sessions`, e `aws iam list-organizations-features` mostra o resultado.

Se preferir pular este passo, apague o `root-access.tf`, o `depends_on` das contas e o `iam.amazonaws.com` da lista de serviços.

- [ ] **Passo 3: crie as SCPs em** `infra/organization/policies/`

`deny-other-regions.json` foi transcrita do exemplo oficial da AWS ("Deny access to AWS based on the requested AWS region", repositório [aws-samples/service-control-policy-examples](https://github.com/aws-samples/service-control-policy-examples/tree/main/Region-controls), que é para onde a página de exemplos de SCP do guia do Organizations aponta hoje). Mudanças em relação ao original: um `Sid` descritivo, a região aprovada é só `us-east-1`, e a exceção de "role privilegiada" virou a `OrganizationAccountAccessRole`, a role que a organização cria em cada conta, que serve de porta de emergência. A lista de `NotAction` (serviços globais, cujos endpoints ficam em us-east-1 e não podem ser bloqueados por região) é a do exemplo, sem cortes. A AWS avisa que ela pode não incluir os serviços globais mais novos; a fonte da verdade é o repositório.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyAllOutsideUsEast1",
      "Effect": "Deny",
      "NotAction": [
        "a4b:*",
        "acm:*",
        "aws-marketplace-management:*",
        "aws-marketplace:*",
        "aws-portal:*",
        "budgets:*",
        "ce:*",
        "chime:*",
        "cloudfront:*",
        "config:*",
        "cur:*",
        "directconnect:*",
        "ec2:DescribeRegions",
        "ec2:DescribeTransitGateways",
        "ec2:DescribeVpnGateways",
        "fms:*",
        "globalaccelerator:*",
        "health:*",
        "iam:*",
        "importexport:*",
        "kms:*",
        "mobileanalytics:*",
        "networkmanager:*",
        "organizations:*",
        "pricing:*",
        "route53:*",
        "route53domains:*",
        "route53-recovery-cluster:*",
        "route53-recovery-control-config:*",
        "route53-recovery-readiness:*",
        "s3:GetAccountPublic*",
        "s3:ListAllMyBuckets",
        "s3:ListMultiRegionAccessPoints",
        "s3:PutAccountPublic*",
        "shield:*",
        "sts:*",
        "support:*",
        "trustedadvisor:*",
        "waf-regional:*",
        "waf:*",
        "wafv2:*",
        "wellarchitected:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": ["us-east-1"]
        },
        "ArnNotLike": {
          "aws:PrincipalARN": "arn:aws:iam::*:role/OrganizationAccountAccessRole"
        }
      }
    }
  ]
}
```

`deny-leave-org.json` (exemplo oficial "Deny member accounts from leaving your AWS organization"): sem isso, um admin da conta poderia tirá-la da organização e, com ela, escapar das SCPs e do billing consolidado.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyLeaveOrganization",
      "Effect": "Deny",
      "Action": ["organizations:LeaveOrganization"],
      "Resource": "*"
    }
  ]
}
```

`deny-root-user.json` (exemplo oficial "Prevent root credentials management in member accounts"): nega qualquer ação do root da conta-membro, **exceto** nas sessões de root centralizadas (`sts:AssumeRoot`, que marcam a requisição com `aws:AssumedRoot`). Com isso, as tarefas privilegiadas continuam possíveis a partir da management, e um login direto como root (se alguém recuperar a senha) não consegue fazer nada.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyRootUserExceptCentralizedSessions",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "ArnLike": {
          "aws:PrincipalArn": ["arn:aws:iam::*:root"]
        },
        "Null": {
          "aws:AssumedRoot": "true"
        }
      }
    }
  ]
}
```

- [ ] **Passo 4: crie** `infra/organization/scps.tf`

```hcl
locals {
  scps = {
    "deny-other-regions" = "Nega ações fora de us-east-1, exceto serviços globais"
    "deny-leave-org"     = "Impede que a conta saia da organização"
    "deny-root-user"     = "Nega o usuário root, exceto sessões de root centralizadas"
  }
}

resource "aws_organizations_policy" "this" {
  for_each    = local.scps
  name        = each.key
  description = each.value
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/${each.key}.json")

  depends_on = [aws_organizations_organization.this] # o tipo SCP precisa estar habilitado
}

# Cada SCP em cada OU: 3 × 2 = 6 anexos
resource "aws_organizations_policy_attachment" "this" {
  for_each = {
    for pair in setproduct(keys(local.scps), keys(local.ous)) :
    "${pair[0]}/${pair[1]}" => { policy = pair[0], ou = pair[1] }
  }
  policy_id = aws_organizations_policy.this[each.value.policy].id
  target_id = aws_organizations_organizational_unit.this[each.value.ou].id
}
```

O `content` vem dos arquivos JSON, e não de `jsonencode`, para que as políticas fiquem legíveis e comparáveis com os exemplos oficiais.

- [ ] **Passo 5: crie** `infra/organization/sso.tf`

**Conceitos:** a permission set `AdministratorAccess` foi criada no console (Tarefa 5.2), então aqui ela é só lida (`data`). Em empresa, as permission sets também seriam código (`aws_ssoadmin_permission_set` + `aws_ssoadmin_managed_policy_attachment`); aqui, ler a existente evita importar e mantém a Tarefa 5.2 simples.

```hcl
data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

data "aws_ssoadmin_permission_set" "admin" {
  instance_arn = local.sso_instance_arn
  name         = "AdministratorAccess"
}

data "aws_identitystore_user" "me" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = var.sso_username
    }
  }
}

# O seu usuário vira admin nas 3 contas-membro (a management foi feita no console)
resource "aws_ssoadmin_account_assignment" "admin" {
  for_each = aws_organizations_account.this

  instance_arn       = local.sso_instance_arn
  permission_set_arn = data.aws_ssoadmin_permission_set.admin.arn
  principal_id       = data.aws_identitystore_user.me.user_id
  principal_type     = "USER"
  target_id          = each.value.id
  target_type        = "AWS_ACCOUNT"
}
```

- [ ] **Passo 6: crie** `infra/organization/variables.tf` e `outputs.tf`

```hcl
# variables.tf
variable "organization_id" {
  type        = string
  description = "ID da organização criada pelo Identity Center (o-...)"
}

variable "email_local_part" {
  type        = string
  description = "Parte antes do @ do seu e-mail; as contas usam <isto>+shortener-<conta>@<dominio>"
}

variable "email_domain" {
  type    = string
  default = "gmail.com"
}

variable "sso_username" {
  type        = string
  description = "Username do seu usuário no Identity Center (Tarefa 5.2)"
}
```

```hcl
# outputs.tf
output "organization_id" {
  value = aws_organizations_organization.this.id
}

output "management_account_id" {
  value = aws_organizations_organization.this.master_account_id
}

output "ou_ids" {
  value = { for k, ou in aws_organizations_organizational_unit.this : k => ou.id }
}

output "account_ids" {
  value = { for k, a in aws_organizations_account.this : k => a.id }
}
```

- [ ] **Passo 7: preencha as variáveis**

`infra/organization/terraform.tfvars` (vai para o Git; o ID da organização não é segredo):

```hcl
organization_id = "o-xxxxxxxxxx" # da Tarefa 5.2
```

`infra/organization/private.auto.tfvars` (**fora do Git**; confira com `git check-ignore -v infra/organization/private.auto.tfvars`):

```hcl
email_local_part = "<seu-email>"   # só a parte antes do @
sso_username     = "seu-username"  # o da Tarefa 5.2
```

- [ ] **Passo 8: plan e apply**

```bash
cd ~/Documents/projects/shortener-deploy/infra/organization
aws sso login --sso-session shortener
terraform init
terraform plan
```

Leia o plano com calma. O esperado:
- `aws_organizations_organization.this` **will be imported** e **updated in-place**, com só adições: `+ "iam.amazonaws.com"` e `+ "SERVICE_CONTROL_POLICY"`. **Se aparecer qualquer `-` em `aws_service_access_principals`, pare:** falta um serviço na lista do `main.tf`.
- Para criar: 2 OUs, 3 contas, 3 policies, 6 anexos, 3 atribuições de SSO e 1 `aws_iam_organizations_features`.

```bash
terraform apply     # criar as contas leva alguns minutos
terraform output
```

Se o apply falhar na criação de uma conta com `CONCURRENT_ACCOUNT_MODIFICATION` ou `TooManyRequestsException`, rode `terraform apply` de novo: a API cria contas de forma assíncrona e às vezes recusa pedidos simultâneos. Se aparecer `ConstraintViolationException: You have exceeded the allowed number of AWS accounts`, a cota do Passo 8 da Tarefa 5.2 ainda não subiu. O state fica consistente: o que foi criado continua lá, e um `terraform apply` depois da aprovação cria só o que falta.

Anote os IDs do `account_ids`: eles viram `<SHARED_ACCOUNT_ID>`, `<STAGING_ACCOUNT_ID>` e `<PROD_ACCOUNT_ID>` daqui em diante.

- [ ] **Passo 9: confira**

```bash
aws organizations list-accounts --profile shortener-mgmt \
  --query 'Accounts[].{nome:Name,id:Id,estado:State}' --output table
aws organizations list-roots --profile shortener-mgmt --query 'Roots[0].PolicyTypes'   # SERVICE_CONTROL_POLICY, ENABLED
aws iam list-organizations-features --profile shortener-mgmt                           # RootCredentialsManagement, RootSessions
```

No console do Identity Center, **AWS accounts** mostra as 4 contas, e o seu usuário tem `AdministratorAccess` em todas. O access portal (a "AWS access portal URL") também lista as 4.

Cada conta-membro manda um e-mail de boas-vindas para o alias `+shortener-<conta>`; ele chega na sua caixa normal. Não precisa fazer nada com ele.

**Pronto quando:** as 3 contas estão `ACTIVE` nas OUs certas, as SCPs estão anexadas às duas OUs e o `terraform plan` diz "No changes".

---

## Tarefa 5.4: profiles SSO das 4 contas

**Conceitos:** uma `sso-session` (um login, com MFA) serve vários profiles. Cada profile é "esta conta, com este papel". Um `aws sso login --sso-session shortener` vale para todos durante as 8h da sessão.

- [ ] **Passo 1: deixe o `~/.aws/config` assim** (o `aws configure sso` da Tarefa 5.2 já criou a `sso-session` e o profile da management; acrescente os outros três)

```ini
[sso-session shortener]
sso_start_url = https://d-xxxxxxxxxx.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile shortener-mgmt]
sso_session = shortener
sso_account_id = <MGMT_ACCOUNT_ID>
sso_role_name = AdministratorAccess
region = us-east-1
output = json

[profile shortener-shared]
sso_session = shortener
sso_account_id = <SHARED_ACCOUNT_ID>
sso_role_name = AdministratorAccess
region = us-east-1
output = json

[profile shortener-staging]
sso_session = shortener
sso_account_id = <STAGING_ACCOUNT_ID>
sso_role_name = AdministratorAccess
region = us-east-1
output = json

[profile shortener-prod]
sso_session = shortener
sso_account_id = <PROD_ACCOUNT_ID>
sso_role_name = AdministratorAccess
region = us-east-1
output = json
```

O `sso_start_url` é a "AWS access portal URL" do Identity Center (a sua, não o exemplo).

- [ ] **Passo 2: teste as 4 contas**

```bash
aws sso login --sso-session shortener
for p in shortener-mgmt shortener-shared shortener-staging shortener-prod; do
  printf '%-18s ' "$p"; aws sts get-caller-identity --profile "$p" --query Account --output text
done
aws sts get-caller-identity --profile shortener-staging   # Arn: ...assumed-role/AWSReservedSSO_AdministratorAccess_.../<seu-username>
```

- [ ] **Passo 3: veja uma SCP funcionando**

```bash
aws ec2 describe-vpcs --profile shortener-staging --region us-west-2
# esperado: AccessDenied ... "with an explicit deny in a service control policy"
aws ec2 describe-vpcs --profile shortener-staging --region us-east-1 --query 'Vpcs[].VpcId'
# funciona (a VPC default da conta)
```

**Pronto quando:** os 4 profiles respondem com o ID certo e a chamada em `us-west-2` é negada pela SCP.

---

## Tarefa 5.5: token da Cloudflare

**Conceitos:** token com o **menor privilégio possível**, limitado a uma única zona. Nesta fase ele valida os certificados ACM das contas staging e prod (3 hosts por conta); na Fase 6, o external-dns de cada cluster o usa para criar os registros dos 3 hosts.

- [x] **Passo 1: crie o token.** Cloudflare → **My Profile** → **API Tokens** → **Create Token** → **Custom token**:
  - Nome: `shortener-dns`
  - Permissões: **Zone → DNS → Edit** e **Zone → Zone → Read** (o external-dns precisa listar a zona)
  - Zone Resources: **Include → Specific zone → fabricioroglio.com**
- [x] **Passo 2: guarde o token no Keychain do macOS** (um gerenciador de senhas que já vem no sistema), e **nunca** no repositório nem num chat:

```bash
security add-generic-password -a "$USER" -s shortener-cloudflare-token -w
# pede o token duas vezes, sem eco: ele não passa pelo histórico do shell
```

- [x] **Passo 3: descubra o Zone ID pela API.** A permissão *Zone Read* do próprio token basta. O Zone ID não é secreto e vai para o `terraform.tfvars` de staging e prod.

```bash
CF_TOKEN=$(security find-generic-password -s shortener-cloudflare-token -w)
curl -s -H "Authorization: Bearer $CF_TOKEN" https://api.cloudflare.com/client/v4/zones \
  | jq '.result[] | {name, id}'      # privilégio mínimo: só fabricioroglio.com aparece
```

- [x] **Passo 4: confira o que ele NÃO consegue.** Com o mesmo token, `GET /zones/<ZONE_ID>/settings`, `GET /zones/<ZONE_ID>/rulesets` e `GET /user` devem dar **403**; `GET /zones/<ZONE_ID>/dns_records` dá 200.
- [x] **Passo 5: exporte para a sessão atual**

```bash
export CLOUDFLARE_API_TOKEN=$(security find-generic-password -s shortener-cloudflare-token -w)  # provider da Cloudflare (bootstrap)
export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"                                     # Terraform da plataforma (external-dns)
```

Neste projeto, o mesmo token serve à validação dos certificados e ao external-dns dos dois ambientes. Em empresa, seriam tokens separados, um por uso e por ambiente.

**Pronto quando:** `curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify | jq .result.status` retorna `"active"`.

---

## Tarefa 5.6: bucket de state na conta `shared` (`infra/bootstrap/shared/`)

**Arquivos:** criar `infra/bootstrap/shared/main.tf`. Depois, editar `infra/organization/main.tf` (backend).

**Conceitos:**
- **O "ovo e a galinha" do state remoto:** o bucket que guarda o state é criado com state local, que depois é migrado para dentro dele.
- **Lock do state no próprio S3** (`use_lockfile`), sem DynamoDB.
- **Backend e provider podem usar contas diferentes.** O backend é só "onde guardar o arquivo de state"; o provider é "onde criar os recursos". A raiz `organization` cria recursos na management (`profile = "shortener-mgmt"` no provider) e guarda o state na shared (`profile = "shortener-shared"` no backend). Funciona porque o seu usuário SSO é admin na shared. Em empresa, o bucket teria uma bucket policy liberando roles específicas de cada conta (e o CI assumiria essas roles), em vez de um humano com admin em tudo.

- [ ] **Passo 1: crie** `infra/bootstrap/shared/main.tf`

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  # Passo 3: descomente depois do primeiro apply e rode `terraform init -migrate-state`.
  # backend "s3" {
  #   bucket       = "shortener-tfstate-<SHARED_ACCOUNT_ID>"
  #   key          = "bootstrap/shared.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  #   profile      = "shortener-shared"
  # }
}

provider "aws" {
  region              = "us-east-1"
  profile             = "shortener-shared"
  allowed_account_ids = ["<SHARED_ACCOUNT_ID>"]
  default_tags {
    tags = { Project = "shortener", Environment = "shared", ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tfstate" {
  bucket = "shortener-tfstate-${data.aws_caller_identity.current.account_id}"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled" # permite recuperar um state corrompido
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}
```

- [ ] **Passo 2: crie o bucket**

```bash
cd ~/Documents/projects/shortener-deploy/infra/bootstrap/shared
terraform init
terraform plan        # 1 bucket + 3 configurações do bucket
terraform apply
terraform output tfstate_bucket   # shortener-tfstate-<SHARED_ACCOUNT_ID>
```

- [ ] **Passo 3: migre o state do próprio bucket para dentro dele.** Descomente o `backend "s3"` e troque `<SHARED_ACCOUNT_ID>` pelo ID real. Blocos de backend não aceitam variáveis; o valor precisa ser literal.

```bash
terraform init -migrate-state     # responda "yes"
rm -f terraform.tfstate terraform.tfstate.backup
terraform plan                    # "No changes": o state agora vive no S3
```

- [ ] **Passo 4: migre o state da organização.** Em `infra/organization/main.tf`, descomente o `backend "s3"` (key `organization/terraform.tfstate`, `profile = "shortener-shared"`) e troque o ID.

```bash
cd ../../organization
terraform init -migrate-state     # "yes"
rm -f terraform.tfstate terraform.tfstate.backup
terraform plan                    # "No changes"
aws s3 ls s3://shortener-tfstate-<SHARED_ACCOUNT_ID> --recursive --profile shortener-shared
# bootstrap/shared.tfstate e organization/terraform.tfstate
```

**Pronto quando:** os dois `plan` dizem "No changes", não há `terraform.tfstate` local em nenhuma das duas pastas e o bucket lista as duas chaves.

---

## Tarefa 5.7: módulo `account-baseline` (ACM + Cognito)

**Arquivos:** criar `infra/bootstrap/modules/account-baseline/main.tf`, `variables.tf` e `outputs.tf`.

**Conceitos:**
- **Por que ACM e Cognito ficam no bootstrap, e não no ambiente efêmero:**
  - São permanentes e grátis. O certificado leva minutos para validar; recriar a cada sessão só atrasaria o `up.sh`.
  - **Os usuários sobrevivem.** Se o user pool fosse destruído junto com o EKS, toda sessão de estudo começaria com "cadastre-se de novo".
  - O `client_id` e o issuer ficam estáveis, então o `shortener-oidc` (Fase 6) sempre recebe os mesmos valores.
- **Um certificado, 3 nomes:** o host curto é o `domain_name` e `api.` e `app.` entram como SANs (*Subject Alternative Names*). O ALB, que é um só por cluster, serve os 3 hosts com o mesmo certificado.
- **3 registros de validação:** o ACM pede um CNAME por nome do certificado. O bootstrap antigo usava `one(...)` porque cada certificado tinha um nome só; agora o `for_each` percorre `domain_validation_options`, com uma entrada por nome.
- **Cognito:**
  - `user_pool_tier = "LITE"`: o plano grátis até 10 mil usuários ativos por mês. Ele tem o Hosted UI clássico (`managed_login_version = 1`), que basta aqui; o managed login v2 (com editor de marca) fica nas extensões.
  - Login por e-mail (`username_attributes`), cadastro aberto (`allow_admin_create_user_only = false`) com verificação de e-mail. O remetente padrão do Cognito tem limite diário baixo, o que basta para estudo.
  - `username_attributes` não pode ser mudado depois: mudar recria o pool (e apaga os usuários).
  - `deletion_protection = "INACTIVE"` para que o encerramento (Fase 9) consiga apagar o pool. Em empresa, seria `ACTIVE`.
- **App client público** (`generate_secret = false`): o painel roda no navegador e não consegue guardar segredo. A proteção do fluxo é o PKCE, que o `oidc-client-ts` faz sozinho.
- **Saídas usadas pelas próximas fases:** a camada `platform` (Fase 6) lê este state para montar o ConfigMap `shortener-oidc`, e o Ingress (Fase 7) usa o `certificate_arn`. Os nomes dos outputs são contrato: não mude.

- [ ] **Passo 1: crie** `infra/bootstrap/modules/account-baseline/variables.tf`

```hcl
variable "environment" {
  type        = string
  description = "staging ou prod"
}

variable "hosts" {
  type = object({
    short = string # links curtos (redirect)
    api   = string # API REST
    app   = string # painel React
  })
}

variable "cloudflare_zone_id" {
  type = string
}
```

- [ ] **Passo 2: crie** `infra/bootstrap/modules/account-baseline/main.tf`

```hcl
terraform {
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
    random     = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

data "aws_region" "current" {}

# ---------- Certificado TLS (3 hosts) ----------
resource "aws_acm_certificate" "this" {
  domain_name               = var.hosts.short
  subject_alternative_names = [var.hosts.api, var.hosts.app]
  validation_method         = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_dns_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name    = dvo.resource_record_name
      type    = dvo.resource_record_type
      content = dvo.resource_record_value
    }
  }
  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(each.value.name, ".")
  type    = each.value.type
  content = trimsuffix(each.value.content, ".")
  ttl     = 60
  proxied = false
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn = aws_acm_certificate.this.arn
  depends_on      = [cloudflare_dns_record.acm_validation]
}

# ---------- Cognito ----------
resource "aws_cognito_user_pool" "this" {
  name                     = "shortener-${var.environment}"
  user_pool_tier           = "LITE"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "INACTIVE"

  admin_create_user_config {
    allow_admin_create_user_only = false # auto-cadastro pelo Hosted UI
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "random_string" "domain_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_cognito_user_pool_domain" "this" {
  domain                = "shortener-${var.environment}-${random_string.domain_suffix.result}" # único na região
  user_pool_id          = aws_cognito_user_pool.this.id
  managed_login_version = 1 # Hosted UI clássico
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "shortener-web"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = false # cliente público (SPA + PKCE)
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["https://${var.hosts.app}/callback"]
  logout_urls                          = ["https://${var.hosts.app}/"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH"]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 1
  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
}

locals {
  oidc_issuer = "https://${aws_cognito_user_pool.this.endpoint}" # https://cognito-idp.us-east-1.amazonaws.com/<pool_id>
  hosted_ui   = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}
```

O `explicit_auth_flows` só com `ALLOW_REFRESH_TOKEN_AUTH` é proposital: o login acontece no Hosted UI (fluxo `code`), e o app nunca recebe senha. O refresh token é o que permite a renovação silenciosa do painel.

- [ ] **Passo 3: crie** `infra/bootstrap/modules/account-baseline/outputs.tf`

```hcl
output "certificate_arn" {
  value = aws_acm_certificate_validation.this.certificate_arn
}

output "oidc_issuer" {
  value = local.oidc_issuer
}

output "oidc_jwks_url" {
  value = "${local.oidc_issuer}/.well-known/jwks.json"
}

output "oidc_authority" {
  value = local.oidc_issuer # o oidc-client-ts descobre os endpoints em <authority>/.well-known/openid-configuration
}

output "oidc_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "oidc_logout_url" {
  value = "${local.hosted_ui}/logout"
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "hosts" {
  value = var.hosts
}
```

`certificate_arn` sai do recurso de validação, não do certificado: assim, quem lê o output só recebe o ARN depois que o certificado está `Issued`.

Os nomes de recursos e atributos acima foram conferidos na documentação do provider `hashicorp/aws` v6 (`aws_cognito_user_pool_domain` → `managed_login_version`, `aws_cognito_user_pool` → `user_pool_tier`, `aws_cognito_user_pool_client` → `token_validity_units`) e do `cloudflare/cloudflare` v5 (`cloudflare_dns_record` → `content`). Se o `terraform validate` reclamar de algum, a fonte da verdade é a página do recurso no Terraform Registry, na versão que o seu `.terraform.lock.hcl` fixou.

**Pronto quando:** o módulo existe; ele é exercitado na próxima tarefa.

---

## Tarefa 5.8: bootstrap de staging e prod (`infra/bootstrap/staging/` e `prod/`)

**Arquivos:** criar `infra/bootstrap/staging/main.tf`, `infra/bootstrap/staging/terraform.tfvars`, `infra/bootstrap/prod/main.tf` e `infra/bootstrap/prod/terraform.tfvars`.

**Conceitos:**
- **Raiz × módulo:** a raiz configura providers, backend e a conta; o módulo descreve os recursos. Staging e prod são duas raízes finas sobre o mesmo módulo.
- **A raiz reexporta os outputs do módulo.** Quem lê o state com `terraform_remote_state` (a camada `platform` na Fase 6) só enxerga os outputs da raiz.
- Hosts por ambiente:

| | staging | prod |
|---|---|---|
| `short` | `shortener-staging.fabricioroglio.com` | `shortener.fabricioroglio.com` |
| `api` | `api.shortener-staging.fabricioroglio.com` | `api.shortener.fabricioroglio.com` |
| `app` | `app.shortener-staging.fabricioroglio.com` | `app.shortener.fabricioroglio.com` |

- [ ] **Passo 1: crie** `infra/bootstrap/staging/main.tf`

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
    random     = { source = "hashicorp/random", version = "~> 3.0" }
  }

  backend "s3" {
    bucket       = "shortener-tfstate-<SHARED_ACCOUNT_ID>"
    key          = "bootstrap/staging.tfstate"
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

provider "cloudflare" {} # lê o token de CLOUDFLARE_API_TOKEN

variable "cloudflare_zone_id" {
  type = string
}

module "baseline" {
  source             = "../modules/account-baseline"
  environment        = "staging"
  cloudflare_zone_id = var.cloudflare_zone_id
  hosts = {
    short = "shortener-staging.fabricioroglio.com"
    api   = "api.shortener-staging.fabricioroglio.com"
    app   = "app.shortener-staging.fabricioroglio.com"
  }
}

output "certificate_arn" {
  value = module.baseline.certificate_arn
}
output "oidc_issuer" {
  value = module.baseline.oidc_issuer
}
output "oidc_jwks_url" {
  value = module.baseline.oidc_jwks_url
}
output "oidc_authority" {
  value = module.baseline.oidc_authority
}
output "oidc_client_id" {
  value = module.baseline.oidc_client_id
}
output "oidc_logout_url" {
  value = module.baseline.oidc_logout_url
}
output "cognito_user_pool_id" {
  value = module.baseline.cognito_user_pool_id
}
output "hosts" {
  value = module.baseline.hosts
}
```

Aqui o backend já nasce no S3: o bucket existe desde a Tarefa 5.6.

- [ ] **Passo 2: crie** `infra/bootstrap/staging/terraform.tfvars` (não tem segredo, vai para o Git)

```hcl
cloudflare_zone_id = "<ZONE_ID>"
```

- [ ] **Passo 3: aplique staging**

```bash
cd ~/Documents/projects/shortener-deploy/infra/bootstrap/staging
terraform init
terraform plan     # certificado + 3 registros DNS + validação + user pool + random + domínio + client
terraform apply    # a validação do ACM leva de 1 a 5 minutos
terraform output
```

- [ ] **Passo 4: crie a raiz de prod.** Copie a pasta e troque só o que é do ambiente:

```bash
cd ..
mkdir prod && cp staging/main.tf staging/terraform.tfvars prod/
```

Em `prod/main.tf`, troque:
- `key = "bootstrap/prod.tfstate"`
- `profile = "shortener-prod"` e `allowed_account_ids = ["<PROD_ACCOUNT_ID>"]` no provider (o backend continua com `profile = "shortener-shared"`)
- `Environment = "prod"` nas tags
- `environment = "prod"` e os hosts `shortener.fabricioroglio.com`, `api.shortener.fabricioroglio.com` e `app.shortener.fabricioroglio.com` no módulo

```bash
cd prod
terraform init && terraform apply
terraform output
```

- [ ] **Passo 5: confira os certificados**

```bash
for env in staging prod; do
  aws acm list-certificates --profile "shortener-$env" \
    --query 'CertificateSummaryList[].{dominio:DomainName,status:Status,sans:SubjectAlternativeNameSummaries}'
done
```

Os dois aparecem com status `ISSUED` e 3 nomes cada. Na Cloudflare, aparecem 6 registros CNAME `_xxxx...` (3 por ambiente).

- [ ] **Passo 6: abra o Hosted UI de staging**

```bash
cd ../staging
LOGOUT=$(terraform output -raw oidc_logout_url)
CLIENT=$(terraform output -raw oidc_client_id)
open "${LOGOUT%/logout}/login?client_id=${CLIENT}&response_type=code&scope=openid&redirect_uri=https%3A%2F%2Fapp.shortener-staging.fabricioroglio.com%2Fcallback"
```

A tela de login do Cognito abre, com o link "Sign up". Se quiser, cadastre-se: o código de verificação chega por e-mail. Depois do login, o navegador vai para `https://app.shortener-staging.fabricioroglio.com/callback?code=...` e dá erro de DNS, o que é esperado: o painel só existe a partir da Fase 7. O usuário fica no pool e serve nas próximas fases.

- [ ] **Passo 7: confira os endpoints OIDC**

```bash
curl -s "$(terraform output -raw oidc_issuer)/.well-known/openid-configuration" | jq '{issuer, authorization_endpoint, jwks_uri}'
curl -s "$(terraform output -raw oidc_jwks_url)" | jq '.keys | length'   # normalmente 2 chaves RS256
```

- [ ] **Passo 8: commit pela rotina de PR** (na raiz do `shortener-deploy`)

```bash
cd ~/Documents/projects/shortener-deploy
git status                      # confira: nada de terraform.tfstate, .terraform/ ou private.auto.tfvars
git switch -c infra/organization-bootstrap
git add infra
git commit -m "infra: organização, contas, SCPs, SSO, state na shared e bootstrap de staging e prod"
git push -u origin HEAD
gh pr create --fill
gh pr merge --squash --delete-branch
git switch main && git pull
```

Confira se os `.terraform.lock.hcl` das 4 raízes entraram no commit: eles **devem** ser versionados, porque fixam as versões dos providers. O deploy repo ainda não tem CI (ele nasce na Fase 6), então o PR passa direto.

**Pronto quando:** os dois certificados estão `ISSUED`, o Hosted UI de staging abre, os `terraform output` de staging e prod mostram os 8 outputs, e tudo está na `main` do `shortener-deploy`.

---

## Rotina de início de sessão (use daqui em diante)

```bash
aws sso login --sso-session shortener          # um login (com MFA) vale para os 4 profiles por 8h
export CLOUDFLARE_API_TOKEN=$(security find-generic-password -s shortener-cloudflare-token -w)  # do Keychain (Tarefa 5.5)
export TF_VAR_cloudflare_api_token="$CLOUDFLARE_API_TOKEN"
```

Não exporte `AWS_PROFILE` globalmente: cada raiz do Terraform já diz qual profile usa, e os scripts da Fase 6 recebem o ambiente e escolhem o profile. Para comandos avulsos, passe `--profile shortener-<conta>`.

## Checkpoint da Fase 5

- [ ] Root da management com MFA; você entra no dia a dia pelo SSO, com MFA
- [ ] Budget de US$ 20 na management cobrindo a organização, com alertas por e-mail
- [ ] Organização com as OUs `Infrastructure` e `Workloads`, as contas `shared`, `staging` e `prod`, e as 3 SCPs anexadas
- [ ] Contas-membro sem credenciais de root (centralized root access)
- [ ] 4 profiles SSO funcionando, e você viu uma SCP negar uma chamada fora de `us-east-1`
- [ ] State de `organization` e `bootstrap/*` no bucket da `shared`, versionado e com lock
- [ ] Certificados de staging e prod emitidos com 3 nomes cada
- [ ] Cognito de staging e prod com Hosted UI abrindo
- [ ] Você sabe explicar por que ACM e Cognito ficam no bootstrap e por que a management não roda workload
