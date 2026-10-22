output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

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
