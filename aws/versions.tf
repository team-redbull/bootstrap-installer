terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    ignition = {
      source  = "community-terraform-providers/ignition"
      version = ">= 2.1"
    }
  }
}
