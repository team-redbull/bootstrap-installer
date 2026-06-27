locals {
  bootstrap_fqdn      = "${var.cluster_id}-bootstrap.${var.cluster_domain}"
  control_plane_fqdns = [for idx in range(var.control_plane_count) : "${var.cluster_id}-control-plane-${format("%02d", idx + 1)}.${var.cluster_domain}"]
  infra_fqdns         = [for idx in range(var.infra_count) : "${var.cluster_id}-infra-${format("%02d", idx + 1)}.${var.cluster_domain}"]
  compute_fqdns       = [for idx in range(var.compute_count) : "${var.cluster_id}-compute-${format("%02d", idx + 1)}.${var.cluster_domain}"]

  bucket_name  = "${lower(var.cluster_id)}-bootstrap-ign-${data.aws_caller_identity.current.account_id}"
  bootstrap_s3 = "s3://${aws_s3_bucket.bootstrap.id}/bootstrap.ign"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      "ocp-cluster" = var.cluster_id
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "this" {
  id = var.vpc_id
}

# --- Subnet (private — instances get private IPs only) -----------------------
resource "aws_subnet" "ocp" {
  vpc_id                  = var.vpc_id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.cluster_id}-subnet"
  }
}

# Optional: associate the subnet with an existing route table. That table must
# provide outbound internet (e.g. via a NAT gateway) so nodes can pull images —
# this is a connected environment. If omitted, the VPC's main route table applies.
resource "aws_route_table_association" "ocp" {
  count          = var.route_table_id != "" ? 1 : 0
  subnet_id      = aws_subnet.ocp.id
  route_table_id = var.route_table_id
}

# --- Security group ----------------------------------------------------------
resource "aws_security_group" "ocp" {
  name        = "${var.cluster_id}-sg"
  description = "OpenShift UPI cluster ${var.cluster_id}"
  vpc_id      = var.vpc_id

  # Internal access (from within the VPC / VPN): API, ingress, SSH
  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }
  ingress {
    description = "HTTPS ingress"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }
  ingress {
    description = "HTTP ingress"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  # Intra-cluster: all traffic between cluster nodes (includes 22623 MCS, etcd, kubelet, OVN)
  ingress {
    description = "Node to node"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_id}-sg"
  }
}

# --- Bootstrap ignition over S3 (user-data is capped at 16 KB) ---------------
resource "aws_s3_bucket" "bootstrap" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = {
    Name = "${var.cluster_id}-bootstrap-ignition"
  }
}

resource "aws_s3_object" "bootstrap" {
  bucket  = aws_s3_bucket.bootstrap.id
  key     = "bootstrap.ign"
  content = file(var.bootstrap_ignition_path)
}

resource "aws_iam_role" "bootstrap" {
  name = "${var.cluster_id}-bootstrap"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "bootstrap_s3" {
  name = "${var.cluster_id}-bootstrap-s3"
  role = aws_iam_role.bootstrap.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.bootstrap.arn}/bootstrap.ign"
    }]
  })
}

resource "aws_iam_instance_profile" "bootstrap" {
  name = "${var.cluster_id}-bootstrap"
  role = aws_iam_role.bootstrap.name
}

# --- Private hosted zone (internal resolution of api-int etc.) ---------------
resource "aws_route53_zone" "private" {
  name = var.cluster_domain

  vpc {
    vpc_id = var.vpc_id
  }

  tags = {
    Name = "${var.cluster_id}-private"
  }
}

# --- Instances ---------------------------------------------------------------
module "bootstrap" {
  source = "./ec2"

  hostnames_ip_addresses = { (local.bootstrap_fqdn) = var.bootstrap_ip }
  ignition               = file(var.bootstrap_ignition_path)
  is_bootstrap           = true
  bootstrap_s3_url       = local.bootstrap_s3
  instance_profile       = aws_iam_instance_profile.bootstrap.name

  ami               = var.rhcos_ami
  instance_type     = var.bootstrap_instance_type
  disk_size         = var.bootstrap_disk_size
  subnet_id         = aws_subnet.ocp.id
  security_group_id = aws_security_group.ocp.id
  ssh_key_name      = var.ssh_key_name

  depends_on = [aws_s3_object.bootstrap]
}

module "control_plane" {
  source = "./ec2"

  hostnames_ip_addresses = zipmap(local.control_plane_fqdns, var.control_plane_ips)
  ignition               = file(var.control_plane_ignition_path)

  ami               = var.rhcos_ami
  instance_type     = var.control_plane_instance_type
  disk_size         = var.control_plane_disk_size
  subnet_id         = aws_subnet.ocp.id
  security_group_id = aws_security_group.ocp.id
  ssh_key_name      = var.ssh_key_name
}

module "infra" {
  source = "./ec2"

  hostnames_ip_addresses = zipmap(local.infra_fqdns, var.infra_ips)
  ignition               = file(var.infra_ignition_path)

  ami               = var.rhcos_ami
  instance_type     = var.infra_instance_type
  disk_size         = var.infra_disk_size
  subnet_id         = aws_subnet.ocp.id
  security_group_id = aws_security_group.ocp.id
  ssh_key_name      = var.ssh_key_name
}

module "compute" {
  source = "./ec2"

  hostnames_ip_addresses = zipmap(local.compute_fqdns, var.compute_ips)
  ignition               = file(var.compute_ignition_path)

  ami               = var.rhcos_ami
  instance_type     = var.compute_instance_type
  disk_size         = var.compute_disk_size
  subnet_id         = aws_subnet.ocp.id
  security_group_id = aws_security_group.ocp.id
  ssh_key_name      = var.ssh_key_name
}

# --- DNS (private zone only, round-robin, no load balancer) ------------------
module "dns" {
  source = "./route53"

  cluster_domain  = var.cluster_domain
  private_zone_id = aws_route53_zone.private.zone_id

  # api / api-int -> all control-plane private IPs
  api_ips = var.control_plane_ips

  # *.apps -> all infra private IPs
  apps_ips = var.infra_ips

  # per-node A records
  node_records = merge(
    module.bootstrap.private_ips,
    module.control_plane.private_ips,
    module.infra.private_ips,
    module.compute.private_ips,
  )
}
