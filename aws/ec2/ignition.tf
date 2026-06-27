locals {
  ignition_encoded = "data:text/plain;charset=utf-8;base64,${base64encode(var.ignition)}"

  # Render user-data per node: bootstrap gets an S3 stub, everything else
  # merges the role's pointer config with a per-node /etc/hostname.
  user_data = {
    for fqdn in keys(var.hostnames_ip_addresses) :
    fqdn => var.is_bootstrap ? data.ignition_config.bootstrap[fqdn].rendered : data.ignition_config.node[fqdn].rendered
  }
}

# --- master / infra / compute: merge base + hostname -------------------------
data "ignition_file" "hostname" {
  for_each = var.is_bootstrap ? {} : var.hostnames_ip_addresses

  path = "/etc/hostname"
  mode = 420

  content {
    content = element(split(".", each.key), 0)
  }
}

data "ignition_config" "node" {
  for_each = var.is_bootstrap ? {} : var.hostnames_ip_addresses

  merge {
    source = local.ignition_encoded
  }

  files = [
    data.ignition_file.hostname[each.key].rendered,
  ]
}

# --- bootstrap: stub that replaces config from S3 (16 KB user-data limit) -----
data "ignition_config" "bootstrap" {
  for_each = var.is_bootstrap ? var.hostnames_ip_addresses : {}

  replace {
    source = var.bootstrap_s3_url
  }
}
