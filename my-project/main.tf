
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "aws_caller_identity" "current" {}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source = "/home/cyber/repos/eks-project/modules/eks"
  cluster_name                   = local.name
  cluster_endpoint_public_access = true

  cluster_addons = {
    coredns = {
      preserve    = true
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

 # aws-auth configmap
  manage_aws_auth_configmap = true
    aws_auth_users = [
    {
      userarn  = var.userarn
      username = var.username
      groups   = ["system:masters"]
    },
 
  ]


  # EKS Managed Node Group(s)
  eks_managed_node_group_defaults = {
    ami_type       = "AL2_x86_64"
    instance_types = ["t2.micro"]

    attach_cluster_primary_security_group = true
    
  }

  eks_managed_node_groups = {
    prod = {
      min_size     = 1
      max_size     = 10
      desired_size = 1

      instance_types = ["t2.micro"]
      capacity_type  = "ON_DEMAND"
         tags = {
        ExtraTag = "prod-cluster"
      }
    }
  }
     
    }


#   aws_auth_users = [
#     {
#       userarn  = "arn:aws:iam::66666666666:user/user1"
#       username = "user1"
#       groups   = ["system:masters"]
#     },
#     {
#       userarn  = "arn:aws:iam::66666666666:user/user2"
#       username = "user2"
#       groups   = ["system:masters"]
#     },
#   ]

# }


###############################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "app.terraform.io/heder24/vpc/aws"
  version = "1.0.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]


  private_subnet_names = ["Private Subnet One", "Private Subnet Two"]
  # public_subnet_names omitted to show default name generation for all three subnets
  database_subnet_names    = ["DB Subnet One"]
  elasticache_subnet_names = ["Elasticache Subnet One", "Elasticache Subnet Two"]
  redshift_subnet_names    = ["Redshift Subnet One", "Redshift Subnet Two", "Redshift Subnet Three"]
  intra_subnet_names       = []

  create_database_subnet_group  = false
  manage_default_network_acl    = false
  manage_default_route_table    = false
  manage_default_security_group = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway = true
  single_nat_gateway = true


  # VPC Flow Logs (Cloudwatch log group and IAM role will be created)
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60

}
################################################################################
# Public SG
################################################################################

module "public_sg" {
  source  = "app.terraform.io/heder24/public-security-groups/aws"
  version = "1.0.0"

  name   = var.public_sg
  vpc_id = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      description = "Allow HTTPS from public IPV4"
      from_port   = 443
      to_port     = 443
      protocol    = 6
      cidr_blocks = "0.0.0.0/0"

    },
    {
      description = "Allow HTTP from public IPV4"
      from_port   = 80
      to_port     = 80
      protocol    = 6
      cidr_blocks = "0.0.0.0/0"

    },

  ]

  ingress_with_ipv6_cidr_blocks = [
    {
      description      = "HTTPS from public IPV6"
      from_port        = 443
      to_port          = 443
      protocol         = 6
      ipv6_cidr_blocks = "::/0"
    },
    {
      description      = "HTTP from public IPV6"
      from_port        = 80
      to_port          = 80
      protocol         = 6
      ipv6_cidr_blocks = "::/0"
    },

  ]

  egress_with_cidr_blocks = [
    {
      description = "HTTPS to anywhere IPV4"
      from_port   = 443
      to_port     = 443
      protocol    = 6
      cidr_blocks = "0.0.0.0/0"
    },
    {
      description = "HTTP to anywhere IPV4"
      from_port   = 80
      to_port     = 80
      protocol    = 6
      cidr_blocks = "0.0.0.0/0"
    },
  ]

  egress_with_ipv6_cidr_blocks = [
    {
      description      = "HTTP to anywhere IPV4"
      from_port        = 80
      to_port          = 80
      protocol         = 6
      ipv6_cidr_blocks = "::/0"
    },
    {
      description      = "HTTPS to anywhere IPV4"
      from_port        = 443
      to_port          = 443
      protocol         = 6
      ipv6_cidr_blocks = "::/0"
    },

  ]

}


#########################################################################
#alb
#########################################################################

module "alb" {
  source  = "app.terraform.io/heder24/alb/aws"
  version = "1.0.0"

  name = local.name

  load_balancer_type = "application"

  vpc_id          = module.vpc.vpc_id
  subnets         = module.vpc.public_subnets
  security_groups = [module.public_sg.security_group_id]

  http_tcp_listeners = [

    {
      port        = 80
      protocol    = "HTTP"
      action_type = "forward"
    },
  ]

  target_groups = [
    {
      name_prefix                       = "prod"
      backend_protocol                  = "HTTP"
      backend_port                      = 80
      target_type                       = "instance"
      deregistration_delay              = 10
      load_balancing_cross_zone_enabled = false
      health_check = {
        enabled             = true
        interval            = 30
        path                = var.health_path
        port                = "traffic-port"
        healthy_threshold   = 3
        unhealthy_threshold = 3
        timeout             = 6
        protocol            = "HTTP"

      }
      tags = {
        InstanceTargetGroupTag = "prod"
      }
    },
  ]
  lb_tags = {
    MyLoadBalancer = "prod-lb"
  }

}


# module "waf" {
#   source = "/home/cyber/repos/eks-project/modules/waf"
#   name   = var.waf-name

#   scope         = "REGIONAL"
#   associate_alb = true
#   alb_arn       =  module.alb.lb_arn
#   managed_rules = [
#     { "name" : "AWSManagedRulesAmazonIpReputationList", "override_action" : "none", "priority" : 1, "vendor_name" : "AWS", "rule_action_override" : [] },
#     { "name" : "AWSManagedRulesCommonRuleSet", "override_action" : "none", "priority" : 2, "vendor_name" : "AWS", "rule_action_override" : [{ "name" = "SizeRestrictions_BODY", "action_to_use" = "allow" }] },
#     { "name" : "AWSManagedRulesSQLiRuleSet", "override_action" : "none", "priority" : 3, "vendor_name" : "AWS", "rule_action_override" : []  },
#     { "name" : "AWSManagedRulesKnownBadInputsRuleSet", "override_action" : "none", "priority" : 4, "vendor_name" : "AWS", "rule_action_override" : []  },
#     { "name" : "AWSManagedRulesLinuxRuleSet", "override_action" : "none", "priority" : 5, "vendor_name" : "AWS", "rule_action_override" : []  },
#     { "name" : "AWSManagedRulesUnixRuleSet", "override_action" : "none", "priority" : 6, "vendor_name" : "AWS", "rule_action_override" : []  },
#   ]

# }
# resource "aws_cloudwatch_log_group" "prod-logs" {
#   name = "aws-waf-logs-prod"
# }

# # resource "aws_wafv2_web_acl_logging_configuration" "prod-logs" {
# #   log_destination_configs = [aws_cloudwatch_log_group.prod-logs.arn]
# #   resource_arn            = aws_wafv2_web_acl.example.arn
# # }


# #################################################################
# # HELM
# #################################################################

#  resource "helm_release" "knote" {
#   name       = "knote"

#   repository = "/home/cyber/repos/eks-project/helm/knote"
#   chart      = "knote"

  
# }