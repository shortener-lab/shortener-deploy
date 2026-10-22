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
