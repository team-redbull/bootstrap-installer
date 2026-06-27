terraform {
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
