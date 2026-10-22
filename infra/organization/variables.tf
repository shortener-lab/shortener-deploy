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
