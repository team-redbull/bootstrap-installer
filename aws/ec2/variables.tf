variable "hostnames_ip_addresses" {
  type        = map(string)
  description = "Map of node FQDN -> private IP (offset within the subnet)."
}

variable "ignition" {
  type        = string
  description = "Base ignition config for this role (master/worker pointer .ign, or bootstrap.ign)."
}

variable "is_bootstrap" {
  type        = bool
  default     = false
  description = "When true, user-data is a stub that fetches the full config from S3."
}

variable "bootstrap_s3_url" {
  type        = string
  default     = ""
  description = "s3:// URL of bootstrap.ign (used only when is_bootstrap = true)."
}

variable "instance_profile" {
  type        = string
  default     = ""
  description = "IAM instance profile name (bootstrap only, for s3:GetObject)."
}

variable "ami" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "disk_size" {
  type = number
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "ssh_key_name" {
  type    = string
  default = ""
}
