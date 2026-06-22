locals { 
  bootstrap_fqdns = "${var.cluster_id}-bootstrap.${var.cluster_domain}"
  control_plane_fqdns = [for idx in range(var.control_plane_count) : "${var.cluster_id}-control-plane-${format("%02d", idx+1)}.${var.cluster_domain}"]
  compute_fqdns = [for idx in range(var.compute_count) : "${var.cluster_id}-compute-${format("%02d", idx+1)}.${var.cluster_domain}"]
  infra_fqdns = [for idx in range(var.infra_count) : "${var.cluster_id}-infra-${format("%02d", idx+1)}.${var.cluster_domain}"]
  api_fqdns = formatlist("%s.%s", ["api", "api-int"], var.cluster_domain)
  mgmt_fqdns = concat([local.bootstrap_fqdns], local.control_plane_fqdns)
  mgmt_ips = concat([var.bootstrap_ip], var.control_plane_ips)
}

module "mgmt_dns_a_records" {
  source = "./dns_a_record"
  hostnames_ip_addresses = zipmap(local.mgmt_fqdns, local.mgmt_ips)
  cluster_domain = var.cluster_domain
}

module "compute_dns_a_record" {
  source = "./dns_a_record"
  hostnames_ip_addresses = zipmap(local.compute_fqdns, var.compute_ips)
  cluster_domain = var.cluster_domain
}

module "infra_dns_a_record" {
  source = "./dns_a_record"
  hostnames_ip_addresses = zipmap(local.infra_fqdns, var.infra_ips)
  cluster_domain = var.cluster_domain
}

module "api_dns_a_records" {
  source = "./api_a_record"
  ip_addresses = local.mgmt_ips
  cluster_domain = var.cluster_domain
}

provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = true
}

data "vsphere_tag_category" "required" {
  count = var.vsphere_required_tag_name != "" ? 1 : 0
  name  = var.vsphere_required_tag_category
}

data "vsphere_tag" "required" {
  count       = var.vsphere_required_tag_name != "" ? 1 : 0
  name        = var.vsphere_required_tag_name
  category_id = data.vsphere_tag_category.required[0].id
}

data "vsphere_datacenter" "dc" {
  name = var.vsphere_datacenter
}

data "vsphere_compute_cluster" "compute_cluster" {
  name = var.vsphere_cluster 
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore_cluster" "datastore_cluster" {
  name = var.vsphere_datastore_cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_distributed_virtual_switch" "dvs" {
  name = var.vsphere_dvs_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name = var.vm_network
  datacenter_id = data.vsphere_datacenter.dc.id
  distributed_virtual_switch_uuid = data.vsphere_distributed_virtual_switch.dvs.id
}

data "vsphere_virtual_machine" "template" {
  name = var.vm_template
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_folder" "folder" {
  path = "${var.vsphere_folder}/${var.cluster_id}"
  type = "vm"
  datacenter_id = data.vsphere_datacenter.dc.id  
}

resource "vsphere_resource_pool" "resources_pool" {
  name = var.cluster_id
  parent_resource_pool_id = data.vsphere_compute_cluster.compute_cluster.resource_pool_id

  lifecycle {
    precondition {
      condition = var.vsphere_required_tag_name == "" || contains(
        tolist(data.vsphere_compute_cluster.compute_cluster.tags),
        data.vsphere_tag.required[0].id
      )
      error_message = "Cluster '${var.vsphere_cluster}' does not have required tag '${var.vsphere_required_tag_name}' (category '${var.vsphere_required_tag_category}'). Provisioning aborted."
    }
  }
}

module "bootstrap" {
  source = "./vm"
  ignition = file(var.bootstrap_ignition_path)
  
  hostnames_ip_addresses = zipmap([local.bootstrap_fqdns], [var.bootstrap_ip])

  resource_pool_id = vsphere_resource_pool.resources_pool.id
  datastore_cluster_id = data.vsphere_datastore_cluster.datastore_cluster.id
  datacenter_id = data.vsphere_datacenter.dc.id
  network_id = data.vsphere_network.network.id
  folder_id = vsphere_folder.folder.path
  guest_id = data.vsphere_virtual_machine.template.guest_id
  template_uuid = data.vsphere_virtual_machine.template.id
  disk_thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned

  cluster_domain = var.cluster_domain
  base_domain = var.base_domain
  machine_cidr = var.machine_cidr
  gateway = var.gateway_ip

  num_cpus = 2
  memory = 8192
  disk_size = var.bootstrap_disk_size
  dns_addresses = var.vm_dns_addresses
}

module "control_plane_vm" {
  source = "./vm"
  count = var.control_plane_count
  ignition = file(var.control_plane_ignition_path)
  
  hostnames_ip_addresses = zipmap([local.control_plane_fqdns[count.index]], [var.control_plane_ips[count.index]])
  resource_pool_id = vsphere_resource_pool.resources_pool.id
  datacenter_id = data.vsphere_datacenter.dc.id
  datastore_cluster_id = data.vsphere_datastore_cluster.datastore_cluster.id
  network_id = data.vsphere_network.network.id
  folder_id = vsphere_folder.folder.path
  guest_id = data.vsphere_virtual_machine.template.guest_id
  template_uuid = data.vsphere_virtual_machine.template.id
  disk_thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned

  cluster_domain = var.cluster_domain
  base_domain = var.base_domain
  machine_cidr = var.machine_cidr
  gateway = var.gateway_ip

  num_cpus = var.control_plane_num_cpus
  memory = var.control_plane_memory
  disk_size = var.control_plane_disk_size
  dns_addresses = var.vm_dns_addresses
}

module "compute_vm" {
  source = "./vm"

  hostnames_ip_addresses = zipmap(local.compute_fqdns, var.compute_ips)

  ignition = file(var.compute_ignition_path)

  resource_pool_id = vsphere_resource_pool.resources_pool.id
  datastore_cluster_id = data.vsphere_datastore_cluster.datastore_cluster.id
  datacenter_id = data.vsphere_datacenter.dc.id
  network_id = data.vsphere_network.network.id
  folder_id = vsphere_folder.folder.path
  guest_id = data.vsphere_virtual_machine.template.guest_id
  template_uuid = data.vsphere_virtual_machine.template.id
  disk_thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned

  cluster_domain = var.cluster_domain
  base_domain = var.base_domain
  machine_cidr = var.machine_cidr
  gateway = var.gateway_ip

  num_cpus = var.compute_num_cpus
  memory = var.compute_memory
  disk_size = var.compute_disk_size
  dns_addresses = var.vm_dns_addresses
}

module "infra_vm" {
  source = "./vm"
  hostnames_ip_addresses = zipmap(local.infra_fqdns, var.infra_ips)

  ignition = file(var.infra_ignition_path)

  resource_pool_id = vsphere_resource_pool.resources_pool.id
  datastore_cluster_id = data.vsphere_datastore_cluster.datastore_cluster.id
  datacenter_id = data.vsphere_datacenter.dc.id
  network_id = data.vsphere_network.network.id
  folder_id = vsphere_folder.folder.path
  guest_id = data.vsphere_virtual_machine.template.guest_id
  template_uuid = data.vsphere_virtual_machine.template.id
  disk_thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned

  cluster_domain = var.cluster_domain
  base_domain = var.base_domain
  machine_cidr = var.machine_cidr
  gateway = var.gateway_ip

  num_cpus = var.infra_num_cpus
  memory = var.infra_memory
  disk_size = var.infra_disk_size
  dns_addresses = var.vm_dns_addresses
}