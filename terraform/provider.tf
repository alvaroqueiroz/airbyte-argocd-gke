provider "google" {
  project = var.project_id
  region  = var.region
}
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.0"
    }
    helm = {
      source = "hashicorp/helm"
      version = "1.2.3"
    }
  }
}
