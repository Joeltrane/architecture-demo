## Define the EKS cluster control plane
resource "aws_eks_cluster" "main" {
  name     = var.cluster-name
  role_arn = aws_iam_role.eks.arn

  ## Define which VPC to associate this EKS cluster control plane with.
  vpc_config {
    security_group_ids      = [aws_security_group.eks.id, aws_security_group.main-node.id]
    subnet_ids              = [aws_subnet.a.id, aws_subnet.b.id, aws_subnet.c.id]
    endpoint_private_access = var.endpoint_private_access ## Exposes the kubernetes control plain API endpoint to the internal VPC network.
    endpoint_public_access  = var.endpoint_public_access ## Exposes the kubernetes control plain API endpoint to the internet.
  }

  depends_on = [
    aws_iam_role_policy_attachment.main-cluster-AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.main-cluster-AmazonEKSServicePolicy,
  ]
}

## Define the node group and associate it with the EKS cluster control plane defined above.
resource "aws_eks_node_group" "eks" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = var.cluster-name
  node_role_arn   = aws_iam_role.main-node.arn
  subnet_ids      = [aws_subnet.a.id, aws_subnet.b.id, aws_subnet.c.id]

  ## Define how this EKS cluster should autoscale. Set all unanimously to one value to pin the cluster size.
  scaling_config {
    desired_size = var.eks_desired_size
    max_size     = var.eks_max_size
    min_size     = var.eks_min_size
  }

  ## Define which ssh keys, if any to allow access to the EKS cluster's autoscaling nodes; and a security group to control access.
  remote_access {
    ec2_ssh_key = var.ec2_ssh_key
    source_security_group_ids = [aws_security_group.eks.id]
  }

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.main-node-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.main-node-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.main-node-AmazonEC2ContainerRegistryReadOnly,
  ]
}


## Obtain the EKS cluster authentication token and store it as an object.
data "aws_eks_cluster_auth" "main" {
  name = aws_eks_cluster.main.name
}

## Define the Kubernetes provider and associate it with the EKS cluster defined above.
provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.main.token
  load_config_file       = false #The load_config_file = false assignment is critical, so the provider does not start looking for a config file on our file system.
}

## Define a kubernetes cluster-role object as expressed in Terraform syntax.
## This cluster-role allows Application Load Balancers to server as a kubernetes ingress controller.
## This configuration is useful for administration activities.
resource "kubernetes_cluster_role" "alb-ingress" {
  metadata {
    name = "alb-ingress-controller"
    labels = {
      "app.kubernetes.io/name" = "alb-ingress-controller"
    }
  }

  rule {
    api_groups = ["", "extensions"]
    resources  = ["configmaps", "endpoints", "events", "ingresses", "ingresses/status", "services"]
    verbs      = ["create", "get", "list", "update", "watch", "patch"]
  }

  rule {
    api_groups = ["", "extensions"]
    resources  = ["nodes", "pods", "secrets", "services", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }
}


resource "kubernetes_cluster_role_binding" "alb-ingress" {
  metadata {
    name = "alb-ingress-controller"
    labels = {
      "app.kubernetes.io/name" = "alb-ingress-controller"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "alb-ingress-controller"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "alb-ingress-controller"
    namespace = "kube-system"
  }
}


## This resource creates a kubernetes service-account object, as expressed in terraform syntax.
resource "kubernetes_service_account" "alb-ingress" {
  metadata {
    name = "alb-ingress-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name" = "alb-ingress-controller"
    }
  }

  automount_service_account_token = true
}


## This resource creates a kubernetes deployment object, as expressed in terraform syntax.
## this deployment creates the container that the Application Load Balancer makes connections to in order to access running applications.
resource "kubernetes_deployment" "alb-ingress" {
  metadata {
    name = "alb-ingress-controller"
    labels = {
      "app.kubernetes.io/name" = "alb-ingress-controller"
    }
    namespace = "kube-system"
  }

  spec {
    selector {
      match_labels = {
        "app.kubernetes.io/name" = "alb-ingress-controller"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "alb-ingress-controller"
        }
      }
      spec {
        volume {
          name = kubernetes_service_account.alb-ingress.default_secret_name
          secret {
            secret_name = kubernetes_service_account.alb-ingress.default_secret_name
          }
        }
        container {
          # This is where you change the version when Amazon comes out with a new version of the ingress controller
          image = "docker.io/amazon/aws-alb-ingress-controller:v1.1.4"
          name  = "alb-ingress-controller"
          args = ["--ingress-class=alb",
            "--cluster-name=${aws_eks_cluster.main.name}",
            "--aws-vpc-id=${aws_vpc.eks.id}",
            "--aws-region=${var.region}"]
          volume_mount {
            name       = kubernetes_service_account.alb-ingress.default_secret_name
            mount_path = "/var/run/secrets/kubernetes.io/serviceaccount"
            read_only  = true
          }
        }
        service_account_name = "alb-ingress-controller"
      }
    }
  }

  depends_on = [
    aws_eks_node_group.eks
  ]
}

## This resource creates a kubernetes ingress object, as expressed in terraform syntax.
## This maps connections coming from the Application Load Balancer to Services running in the EKS cluster.
resource "kubernetes_ingress" "main" {
  metadata {
    name = "main-ingress"
    annotations = {
      "alb.ingress.kubernetes.io/scheme" = "internet-facing"
      "kubernetes.io/ingress.class" = "alb"
      "alb.ingress.kubernetes.io/subnets" = "${aws_subnet.a.id}, ${aws_subnet.b.id}, ${aws_subnet.c.id}"
      "alb.ingress.kubernetes.io/certificate-arn" = "${aws_acm_certificate.cert.arn}"
      "alb.ingress.kubernetes.io/listen-ports" = <<JSON
[
  {"HTTP": 80},
  {"HTTPS": 443}
]
JSON
      "alb.ingress.kubernetes.io/actions.ssl-redirect" = <<JSON
{
  "Type": "redirect",
  "RedirectConfig": {
    "Protocol": "HTTPS",
    "Port": "443",
    "StatusCode": "HTTP_301"
  }
}
JSON
    }
  }

  spec {
    rule {
      host = "app.${var.domain_name}"
      http {
        path {
          backend {
            service_name = "ssl-redirect"
            service_port = "use-annotation"
          }
          path = "/*"
        }
        path {
          backend {
            service_name = "app-service1"
            service_port = 80
          }
          path = "/service1"
        }
        path {
          backend {
            service_name = "app-service2"
            service_port = 80
          }
          path = "/service2"
        }
      }
    }

    rule {
      host = "api.${var.domain_name}"
      http {
        path {
          backend {
            service_name = "ssl-redirect"
            service_port = "use-annotation"
          }
          path = "/*"
        }
        path {
          backend {
            service_name = "api-service1"
            service_port = 80
          }
          path = "/service3"
        }
        path {
          backend {
            service_name = "api-service2"
            service_port = 80
          }
          path = "/graphq4"
        }
      }
    }
  }
}