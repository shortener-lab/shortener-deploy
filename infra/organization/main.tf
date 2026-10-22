terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }

  backend "s3" {
    bucket       = "shortener-tfstate-319679463324"
    key          = "organization/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    profile      = "shortener-shared"
  }
}

provider "aws" {
  region              = "us-east-1"
  profile             = "shortener-mgmt"
  allowed_account_ids = ["725397330824"]
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
