# --- AWS / network ----------------------------------------------------------
variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC the cluster subnet is created in."
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR for the cluster subnet Terraform creates (the 'segment')."
}

variable "availability_zone" {
  type        = string
  description = "AZ for the cluster subnet."
}

variable "route_table_id" {
  type        = string
  default     = ""
  description = "Optional existing route table to associate the subnet with (should provide outbound internet via NAT for image pulls). If empty, the VPC's main route table applies."
}

variable "rhcos_ami" {
  type        = string
  description = "RHCOS AMI id for the chosen OCP version + region."
}

variable "ssh_key_name" {
  type        = string
  default     = ""
  description = "Optional EC2 key pair name for SSH access."
}

variable "allowed_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the API (6443) and ingress (80/443/22)."
}

# --- Cluster identity --------------------------------------------------------
variable "cluster_id" {
  type        = string
  description = "Cluster name (also used as the Name/tag prefix)."
}

variable "base_domain" {
  type = string
}

variable "cluster_domain" {
  type        = string
  description = "<cluster_id>.<base_domain>. A private Route53 zone is created for this."
}

# --- Ignition ----------------------------------------------------------------
variable "bootstrap_ignition_path" {
  type = string
}

variable "control_plane_ignition_path" {
  type = string
}

variable "compute_ignition_path" {
  type = string
}

variable "infra_ignition_path" {
  type = string
}

# --- Node IPs ----------------------------------------------------------------
variable "bootstrap_ip" {
  type = string
}

variable "control_plane_ips" {
  type = list(string)
}

variable "infra_ips" {
  type = list(string)
}

variable "compute_ips" {
  type    = list(string)
  default = []
}

# --- Sizing ------------------------------------------------------------------
variable "bootstrap_instance_type" {
  type    = string
  default = "m5.large"
}

variable "bootstrap_disk_size" {
  type    = number
  default = 120
}

variable "control_plane_count" {
  type = number
}

variable "control_plane_instance_type" {
  type    = string
  default = "m5.2xlarge"
}

variable "control_plane_disk_size" {
  type    = number
  default = 120
}

variable "infra_count" {
  type = number
}

variable "infra_instance_type" {
  type    = string
  default = "m5.2xlarge"
}

variable "infra_disk_size" {
  type    = number
  default = 120
}

variable "compute_count" {
  type    = number
  default = 0
}

variable "compute_instance_type" {
  type    = string
  default = "m5.xlarge"
}

variable "compute_disk_size" {
  type    = number
  default = 120
}
