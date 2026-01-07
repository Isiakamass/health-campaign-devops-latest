###############################################################################
# Terraform Backend Configuration (USES existing S3 + DynamoDB)
###############################################################################
terraform {
  backend "s3" {
    bucket         = "icfsl-health-demo-tfstate"
    key            = "terraform-setup/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "icfsl-health-demo-tfstate"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.46.0, < 6.0.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.20.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.9.0"
    }
  }

  required_version = ">= 1.3.0"
}

###############################################################################
# Local Variables
###############################################################################
locals {
  az_to_find          = var.availability_zones[0]
  az_index_in_network = index(var.network_availability_zones, local.az_to_find)
}

###############################################################################
# Networking
###############################################################################
module "network" {
  source             = "../modules/kubernetes/aws/network"
  vpc_cidr_block     = var.vpc_cidr_block
  cluster_name       = var.cluster_name
  availability_zones = var.network_availability_zones
}

###############################################################################
# PostgreSQL Database (RDS)
###############################################################################
module "db" {
  source                       = "../modules/db/aws"
  subnet_ids                   = module.network.private_subnets
  vpc_security_group_ids       = [module.network.rds_db_sg_id]
  availability_zone            = element(var.availability_zones, 0)
  instance_class               = "db.t4g.medium"
  engine_version               = "15.8"
  storage_type                 = "gp3"
  storage_gb                   = "20"
  backup_retention_days        = "7"
  administrator_login          = var.db_username
  administrator_login_password = var.db_password
  identifier                   = "${var.cluster_name}-db"
  db_name                      = var.db_name
  environment                  = var.cluster_name
}

###############################################################################
# EKS Cluster
###############################################################################
module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version
  vpc_id          = module.network.vpc_id

  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  authentication_mode = "API_AND_CONFIG_MAP"

  subnet_ids = concat(
    module.network.private_subnets,
    module.network.public_subnets
  )

  cluster_addons = {
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
  }

  tags = {
    Name               = var.cluster_name
    KubernetesCluster  = var.cluster_name
  }
}

###############################################################################
# Managed Node Group
###############################################################################
module "eks_managed_node_group" {
  depends_on = [module.eks]

  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 20.0"

  name            = var.cluster_name
  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  subnet_ids = [
    module.network.private_subnets[local.az_index_in_network]
  ]

  min_size     = var.min_worker_nodes
  max_size     = var.max_worker_nodes
  desired_size = var.desired_worker_nodes

  instance_types = var.instance_types
  capacity_type  = "SPOT"
}

###############################################################################
# Kubernetes Providers
###############################################################################
data "aws_eks_cluster" "cluster" {
  depends_on = [module.eks_managed_node_group]
  name       = var.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  depends_on = [module.eks_managed_node_group]
  name       = var.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(
    data.aws_eks_cluster.cluster.certificate_authority[0].data
  )
  token = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(
      data.aws_eks_cluster.cluster.certificate_authority[0].data
    )
    token = data.aws_eks_cluster_auth.cluster.token
  }
}

###############################################################################
# ⚠ WARNING: DO NOT CREATE BACKEND RESOURCES IN THIS STACK
# The following resources must never exist in the main Terraform stack.
# They are commented out to prevent DynamoDB / S3 creation errors.
###############################################################################

# resource "aws_s3_bucket" "terraform_state" {
#   bucket = "icfsl-health-demo-tfstate"
# }

# resource "aws_dynamodb_table" "terraform_state_lock" {
#   name         = "icfsl-health-demo-tfstate"
#   billing_mode = "PAY_PER_REQUEST"
#   hash_key     = "LockID"
#
#   attribute {
#     name = "LockID"
#     type = "S"
#   }
# }
