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
