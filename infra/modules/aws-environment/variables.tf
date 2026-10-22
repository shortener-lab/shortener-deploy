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
