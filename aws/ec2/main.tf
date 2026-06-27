resource "aws_instance" "node" {
  for_each = var.hostnames_ip_addresses

  ami                    = var.ami
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  private_ip             = each.value
  vpc_security_group_ids = [var.security_group_id]
  key_name               = var.ssh_key_name != "" ? var.ssh_key_name : null
  iam_instance_profile   = var.instance_profile != "" ? var.instance_profile : null
  user_data              = local.user_data[each.key]

  root_block_device {
    volume_size = var.disk_size
    volume_type = "gp3"
  }

  tags = {
    Name = element(split(".", each.key), 0)
  }

  # Ignition is consumed only at first boot; don't recreate on later changes.
  lifecycle {
    ignore_changes = [user_data, ami]
  }
}

output "private_ips" {
  value = { for k, inst in aws_instance.node : k => inst.private_ip }
}

output "instance_ids" {
  value = { for k, inst in aws_instance.node : k => inst.id }
}
