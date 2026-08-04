# ========================================
# Terraform主配置文件
# ========================================
# 用途：部署方案B的4分片×2副本架构
# ========================================

# ========================================
# 1. GCP Provider配置
# ========================================

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# ========================================
# 2. VPC网络模块
# ========================================

module "vpc" {
  source = "./modules/vpc"

  project_id   = var.project_id
  region       = var.region
  network_name = var.network_name

  # 子网配置
  subnet_cidr = var.subnet_cidr

  # 防火墙规则
  allowed_ports = [
    8123,  # HTTP接口
    9000,  # Native接口
    9009,  # 副本间通信
    9181,  # Keeper客户端端口
    9444   # Keeper Raft端口
  ]
}

# ========================================
# 3. ClickHouse集群模块
# ========================================

module "clickhouse_cluster" {
  source = "./modules/clickhouse_cluster"

  project_id = var.project_id
  region     = var.region
  zone       = var.zone

  # 网络配置
  network    = module.vpc.network_self_link
  subnetwork = module.vpc.subnetwork_self_link

  # 集群配置
  cluster_name  = var.cluster_name
  shard_count   = var.shard_count
  replica_count = var.replica_count

  # VM规格（经济版）
  machine_type = var.machine_type

  # 存储配置
  disk_extreme_size_gb  = var.disk_extreme_size_gb
  disk_balanced_size_gb = var.disk_balanced_size_gb

  # 成本优化
  preemptible = var.use_preemptible

  # ClickHouse版本
  clickhouse_version = var.clickhouse_version

  # Keeper配置
  keeper_hosts = module.keepers.keeper_hosts
}

# ========================================
# 4. Keeper集群模块
# ========================================

module "keepers" {
  source = "./modules/keepers"

  project_id = var.project_id
  region     = var.region
  zone       = var.zone

  # 网络配置
  network    = module.vpc.network_self_link
  subnetwork = module.vpc.subnetwork_self_link

  # Keeper配置
  keeper_count  = var.keeper_count
  machine_type  = var.keeper_machine_type
  keeper_config = local.keeper_config

  # 成本优化
  preemptible = false  # Keeper不建议使用可抢占式VM
}

# ========================================
# 5. GCS存储桶模块
# ========================================

module "gcs_bucket" {
  source = "./modules/gcs_bucket"

  project_id = var.project_id
  region     = var.region

  # 存储桶配置
  bucket_name     = var.bucket_name
  location        = var.bucket_location
  storage_class   = var.storage_class
  force_destroy   = var.force_destroy_bucket

  # 生命周期管理
  lifecycle_rules = var.lifecycle_rules
}

# ========================================
# 6. 跳板机模块
# ========================================

resource "google_compute_instance" "bastion" {
  name         = "${var.cluster_name}-bastion"
  machine_type = var.bastion_machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-2204-lts"
      size  = 100
    }
  }

  network_interface {
    network    = module.vpc.network_self_link
    subnetwork = module.vpc.subnetwork_self_link
    access_config {}  # 公网IP
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  metadata_startup_script = file("${path.module}/scripts/install_bastion.sh")

  tags = ["bastion"]
}

# ========================================
# 7. 本地变量
# ========================================

locals {
  # Keeper配置
  keeper_config = {
    cluster_name = var.cluster_name
    keeper_count = var.keeper_count
  }
}

# ========================================
# 8. 输出
# ========================================

output "clickhouse_cluster_hosts" {
  description = "ClickHouse集群节点列表"
  value       = module.clickhouse_cluster.cluster_hosts
}

output "keeper_hosts" {
  description = "Keeper节点列表"
  value       = module.keepers.keeper_hosts
}

output "bastion_public_ip" {
  description = "跳板机公网IP"
  value       = google_compute_instance.bastion.network_interface[0].access_config[0].nat_ip
}

output "gcs_bucket_url" {
  description = "GCS存储桶URL"
  value       = module.gcs_bucket.bucket_url
}

output "connection_string" {
  description = "连接字符串示例"
  value       = "clickhouse-client --host=${google_compute_instance.bastion.network_interface[0].access_config[0].nat_ip} --port=8123"
}
