//////
// vSphere variables
//////

variable "vsphere_server" {
  type        = string
  description = "vSphere server hostname or IP."
}

variable "vsphere_user" {
  type        = string
  description = "vSphere server user."
}

variable "vsphere_password" {
  type        = string
  description = "vSphere server password."
}

variable "vsphere_cluster" {
  type        = string
  description = "vSphere compute cluster name."
}

variable "vsphere_datacenter" {
  type        = string
  description = "vSphere datacenter name."
}

variable "vsphere_datastore_cluster" {
  type        = string
  description = "vSphere datastore cluster name."
}

variable "vsphere_dvs_name" {
  type        = string
  description = "Distributed virtual switch name."
}

variable "vsphere_folder" {
  type        = string
  description = "vSphere VM folder path (cluster folder will be created inside this)."
}

variable "vsphere_required_tag_category" {
  type        = string
  default     = ""
  description = "Tag category name that the compute cluster must have. Empty = no check."
}

variable "vsphere_required_tag_name" {
  type        = string
  default     = ""
  description = "Tag name within vsphere_required_tag_category the cluster must carry. Empty = no check."
}

variable "vm_network" {
  type        = string
  description = "vSphere port group name for the cluster network."
}

variable "vm_template" {
  type        = string
  description = "RHCOS VM template name."
}

variable "vm_dns_addresses" {
  type    = list(string)
  default = ["1.1.1.1", "9.9.9.9"]
}

/////////
// OpenShift cluster variables
/////////

variable "cluster_id" {
  type        = string
  description = "Cluster name (max 27 chars, alphanumeric/hyphen)."
}

variable "base_domain" {
  type        = string
  description = "Base DNS domain (e.g. example.com)."
}

variable "cluster_domain" {
  type        = string
  description = "Full cluster domain (e.g. mce-prod-01.example.com)."
}

variable "machine_cidr" {
  type        = string
  description = "Machine network CIDR (e.g. 10.0.5.0/24)."
}

variable "gateway_ip" {
  type        = string
  description = "Gateway IP address for the cluster network."
}

/////////
// Bootstrap machine variables
/////////

variable "bootstrap_ignition_path" {
  type    = string
  default = "./bootstrap.ign"
}

variable "bootstrap_ip" {
  type    = string
  default = ""
}

variable "bootstrap_disk_size" {
  type    = number
  default = 100
}

///////////
// Control plane variables
///////////

variable "control_plane_ignition_path" {
  type    = string
  default = "./master.ign"
}

variable "control_plane_count" {
  type    = number
  default = 3
}

variable "control_plane_ips" {
  type    = list(string)
  default = []
}

variable "control_plane_memory" {
  type    = number
  default = 16384
}

variable "control_plane_num_cpus" {
  type    = number
  default = 4
}

variable "control_plane_disk_size" {
  type    = number
  default = 120
}

//////////
// Compute (worker) variables
//////////

variable "compute_ignition_path" {
  type    = string
  default = "./worker.ign"
}

variable "compute_count" {
  type    = number
  default = 3
}

variable "compute_ips" {
  type    = list(string)
  default = []
}

variable "compute_memory" {
  type    = number
  default = 8192
}

variable "compute_num_cpus" {
  type    = number
  default = 4
}

variable "compute_disk_size" {
  type    = number
  default = 120
}

//////////
// Infra node variables
//////////

variable "infra_ignition_path" {
  type    = string
  default = "./worker.ign"
}

variable "infra_count" {
  type    = number
  default = 3
}

variable "infra_ips" {
  type    = list(string)
  default = []
}

variable "infra_memory" {
  type    = number
  default = 16384
}

variable "infra_num_cpus" {
  type    = number
  default = 4
}

variable "infra_disk_size" {
  type    = number
  default = 120
}
