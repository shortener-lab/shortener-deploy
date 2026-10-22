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
  name              = local.name
  kafka_versions    = [var.kafka_version]
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
