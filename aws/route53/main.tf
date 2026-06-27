# Private hosted zone only — the cluster is internal. No load balancer: each
# name is a multi-value A record (DNS round-robin), mirroring the vSphere flow.

resource "aws_route53_record" "api" {
  zone_id = var.private_zone_id
  name    = "api.${var.cluster_domain}"
  type    = "A"
  ttl     = var.ttl
  records = var.api_ips
}

resource "aws_route53_record" "api_int" {
  zone_id = var.private_zone_id
  name    = "api-int.${var.cluster_domain}"
  type    = "A"
  ttl     = var.ttl
  records = var.api_ips
}

resource "aws_route53_record" "apps" {
  zone_id = var.private_zone_id
  name    = "*.apps.${var.cluster_domain}"
  type    = "A"
  ttl     = var.ttl
  records = var.apps_ips
}

resource "aws_route53_record" "node" {
  for_each = var.node_records

  zone_id = var.private_zone_id
  name    = each.key
  type    = "A"
  ttl     = var.ttl
  records = [each.value]
}
