variable "cluster_domain" {
  type = string
}

variable "private_zone_id" {
  type = string
}

variable "api_ips" {
  type        = list(string)
  description = "Control-plane private IPs (api / api-int)."
}

variable "apps_ips" {
  type        = list(string)
  description = "Infra private IPs (*.apps)."
}

variable "node_records" {
  type        = map(string)
  description = "Map of node FQDN -> private IP for per-node A records."
}

variable "ttl" {
  type    = number
  default = 60
}
