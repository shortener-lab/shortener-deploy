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
