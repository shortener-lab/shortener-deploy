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

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 } # ALB público vai aqui
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
