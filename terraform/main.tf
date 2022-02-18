data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${module.gke.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  }
}

module "gcp-network" {
  source       = "terraform-google-modules/network/google"
  project_id   = var.project_id
  network_name = var.network

  subnets = [
    {
      subnet_name   = var.subnetwork
      subnet_ip     = "10.0.0.0/17"
      subnet_region = var.region
    },
  ]

  secondary_ranges = {
    (var.subnetwork) = [
      {
        range_name    = var.ip_range_pods_name
        ip_cidr_range = "192.168.0.0/18"
      },
      {
        range_name    = var.ip_range_services_name
        ip_cidr_range = "192.168.64.0/18"
      }
    ]
  }

  firewall_rules = [
    {
      name      = "allow-airbyte-webserver-access"
      direction = "INGRESS"
      ranges    = ["0.0.0.0/0"]
      allow = [{
        protocol = "tcp"
        ports    = ["80", "443", "8080"]
      }]
      log_config = {
        metadata = "INCLUDE_ALL_METADATA"
      }
    }
  ]
}

module "gke" {
  source                     = "terraform-google-modules/kubernetes-engine/google"
  project_id                 = var.project_id
  name                       = var.cluster_name
  regional                   = true
  region                     = var.region
  network                    = module.gcp-network.network_name
  subnetwork                 = module.gcp-network.subnets_names[0]
  ip_range_pods              = var.ip_range_pods_name
  ip_range_services          = var.ip_range_services_name
  create_service_account     = true
  horizontal_pod_autoscaling = true
}

resource "null_resource" "connnect_to_gke_cluster" {
  provisioner "local-exec" {
    command = "gcloud container clusters get-credentials ${module.gke.name} --region ${var.region} --project ${var.project_id}"
  }
  depends_on = [module.gke]
}

# first apply should end here

module "argocd" {
  source     = "./argocd"
  depends_on = [module.gke, resource.null_resource.connnect_to_gke_cluster]
  ingress_annotations = {
    "kubernetes.io/ingress.class"                    = "nginx"
    "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"
    "nginx.ingress.kubernetes.io/ssl-passthrough"    = "true"
    "nginx.ingress.kubernetes.io/backend-protocol"   = "HTTPS"
    "kubernetes.io/tls-acme"                         = "true"
    "cert-manager.io/cluster-issuer"                 = "lets-encrypt"
  }
  server_insecure = true
  repositories = [
    # {
    #   url      = var.airbyte_manifests_repo
    #   username = "username"
    #   password = "password"
    # },
    # {
    #     url          = var.airbyte_manifests_repo
    #     access_token = "access_token"
    # },
    {
        url  = "https://charts.bitnami.com/bitnami"
        type = "helm"
    }]
}

# second apply must end here

module "argocd_application_git" {
  source = "./argocd_application"

  argocd_namespace    = module.argocd.namespace
  destination_server  = "https://kubernetes.default.svc"
  project             = "default"
  name                = "airbyte"
  namespace           = "airbyte-namespace"
  repo_url            = var.airbyte_manifests_repo
  path                = "kube/manifests"
  target_revision     = "HEAD"
  automated_self_heal = true
  automated_prune     = true
  directory_recursive = true
}

# third apply for the entire file