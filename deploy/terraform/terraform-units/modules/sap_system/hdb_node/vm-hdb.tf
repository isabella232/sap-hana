/*-----------------------------------------------------------------------------8
|                                                                              |
|                                 HANA - VMs                                   |
|                                                                              |
+--------------------------------------4--------------------------------------*/

# NICS ============================================================================================================

/*-----------------------------------------------------------------------------8
HANA DB Linux Server private IP range: .10 -
+--------------------------------------4--------------------------------------*/

# Creates the admin traffic NIC and private IP address for database nodes
resource "azurerm_network_interface" "nics-dbnodes-admin" {
  count                         = local.enable_deployment ? length(local.hdb_vms) : 0
  name                          = format("%s%s", local.hdb_vms[count.index].name, local.resource_suffixes.admin-nic)
  location                      = var.resource-group[0].location
  resource_group_name           = var.resource-group[0].name
  enable_accelerated_networking = true

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = local.sub_admin_exists ? data.azurerm_subnet.sap-admin[0].id : azurerm_subnet.sap-admin[0].id
    private_ip_address            = lookup(local.hdb_vms[count.index], "admin_nic_ip", false) != false ? local.hdb_vms[count.index].admin_nic_ip : cidrhost(length(local.sub_db_arm_id) > 0 ? data.azurerm_subnet.sap-admin[0].address_prefixes[0] : azurerm_subnet.sap-admin[0].address_prefixes[0], tonumber(count.index) + 10)
    private_ip_address_allocation = "static"
  }
}

# Creates the DB traffic NIC and private IP address for database nodes
resource "azurerm_network_interface" "nics-dbnodes-db" {
  count                         = local.enable_deployment ? length(local.hdb_vms) : 0
  name                          = format("%s%s", local.hdb_vms[count.index].name, local.resource_suffixes.db-nic)
  location                      = var.resource-group[0].location
  resource_group_name           = var.resource-group[0].name
  enable_accelerated_networking = true

  ip_configuration {
    primary                       = true
    name                          = "ipconfig1"
    subnet_id                     = local.sub_db_exists ? data.azurerm_subnet.sap-db[0].id : azurerm_subnet.sap-db[0].id
    private_ip_address            = try(local.hdb_vms[count.index].db_nic_ip, false) == false ? cidrhost(length(local.sub_db_arm_id) > 0 ? data.azurerm_subnet.sap-db[0].address_prefixes[0] : azurerm_subnet.sap-db[0].address_prefixes[0], tonumber(count.index) + 10) : local.hdb_vms[count.index].db_nic_ip
    private_ip_address_allocation = "static"
  }
}

# LOAD BALANCER ===================================================================================================

/*-----------------------------------------------------------------------------8
Load balancer front IP address range: .4 - .9
+--------------------------------------4--------------------------------------*/

resource "azurerm_lb" "hdb" {
  count               = local.enable_deployment ? 1 : 0
  name                = format("%s%s", local.prefix, local.resource_suffixes.db-alb)
  resource_group_name = var.resource-group[0].name
  location            = var.resource-group[0].location
  sku                 = local.zonal_deployment ? "Standard" : "Basic"

  frontend_ip_configuration {
    name                          = format("%s%s", local.prefix, local.resource_suffixes.db-alb-feip)
    subnet_id                     = local.sub_db_exists ? data.azurerm_subnet.sap-db[0].id : azurerm_subnet.sap-db[0].id
    private_ip_address_allocation = "Static"
    private_ip_address            = try(local.hana_database.loadbalancer.frontend_ip, (local.sub_db_exists ? cidrhost(data.azurerm_subnet.sap-db[0].address_prefixes[0], tonumber(count.index) + 4) : cidrhost(azurerm_subnet.sap-db[0].address_prefixes[0], tonumber(count.index) + 4)))
  }
}

resource "azurerm_lb_backend_address_pool" "hdb" {
  count               = local.enable_deployment ? 1 : 0
  name                = format("%s%s", local.prefix, local.resource_suffixes.db-alb-bepool)
  resource_group_name = var.resource-group[0].name
  loadbalancer_id     = azurerm_lb.hdb[count.index].id
}

resource "azurerm_lb_probe" "hdb" {
  count               = local.enable_deployment ? 1 : 0
  resource_group_name = var.resource-group[0].name
  loadbalancer_id     = azurerm_lb.hdb[count.index].id
  name                = format("%s%s", local.prefix, local.resource_suffixes.db-alb-hp)
  port                = "625${local.hana_database.instance.instance_number}"
  protocol            = "Tcp"
  interval_in_seconds = 5
  number_of_probes    = 2
}

# TODO:
# Current behavior, it will try to add all VMs in the cluster into the backend pool, which would not work since we do not have availability sets created yet.
# In a scale-out scenario, we need to rewrite this code according to the scale-out + HA reference architecture.
resource "azurerm_network_interface_backend_address_pool_association" "hdb" {
  count                   = local.enable_deployment ? length(local.hdb_vms) : 0
  network_interface_id    = azurerm_network_interface.nics-dbnodes-db[count.index].id
  ip_configuration_name   = azurerm_network_interface.nics-dbnodes-db[count.index].ip_configuration[0].name
  backend_address_pool_id = azurerm_lb_backend_address_pool.hdb[0].id
}

resource "azurerm_lb_rule" "hdb" {
  count                          = local.enable_deployment ? length(local.loadbalancer_ports) : 0
  resource_group_name            = var.resource-group[0].name
  loadbalancer_id                = azurerm_lb.hdb[0].id
  name                           = format("%s%s%05d-%02d", local.prefix, local.resource_suffixes.db-alb-rule, local.loadbalancer_ports[count.index].port, count.index)
  protocol                       = "Tcp"
  frontend_port                  = local.loadbalancer_ports[count.index].port
  backend_port                   = local.loadbalancer_ports[count.index].port
  frontend_ip_configuration_name = format("%s%s", local.prefix, local.resource_suffixes.db-alb-feip)
  backend_address_pool_id        = azurerm_lb_backend_address_pool.hdb[0].id
  probe_id                       = azurerm_lb_probe.hdb[0].id
  enable_floating_ip             = true
}

// VIRTUAL MACHINES ================================================================================================

// Manages Linux Virtual Machine for HANA DB servers
resource "azurerm_linux_virtual_machine" "vm-dbnode" {
  count               = local.enable_deployment ? length(local.hdb_vms) : 0
  name                = local.hdb_vms[count.index].name
  computer_name       = local.hdb_vms[count.index].computername
  location            = var.resource-group[0].location
  resource_group_name = var.resource-group[0].name

  //If more than one servers are deployed into a single zone put them in an availability set and not a zone
  availability_set_id          = local.enable_ultradisk ? null : length(local.hdb_vms) == length(local.zones) ? null : length(local.zones) > 1 ? azurerm_availability_set.hdb[count.index % length(local.zones)].id : azurerm_availability_set.hdb[0].id
  proximity_placement_group_id = local.zonal_deployment ? var.ppg[count.index % length(local.zones)].id : var.ppg[0].id
  zone                         = local.enable_ultradisk ? local.zones[count.index % length(local.zones)] : length(local.hdb_vms) == length(local.zones) ? local.zones[count.index % length(local.zones)] : null

  network_interface_ids = [
    azurerm_network_interface.nics-dbnodes-admin[count.index].id,
    azurerm_network_interface.nics-dbnodes-db[count.index].id
  ]
  size                            = lookup(local.sizes, local.hdb_vms[count.index].size).compute.vm_size
  admin_username                  = local.hdb_vms[count.index].authentication.username
  admin_password                  = lookup(local.hdb_vms[count.index].authentication, "password", null)
  disable_password_authentication = local.hdb_vms[count.index].authentication.type != "password" ? true : false

  additional_capabilities {
    ultra_ssd_enabled = local.enable_ultradisk
  }

  dynamic "os_disk" {
    iterator = disk
    for_each = flatten([for storage_type in lookup(local.sizes, local.hdb_vms[count.index].size).storage : [for disk_count in range(storage_type.count) : { name = storage_type.name, id = disk_count, disk_type = storage_type.disk_type, size_gb = storage_type.size_gb, caching = storage_type.caching }] if storage_type.name == "os"])
    content {
      name                 = format("%s%s", local.hdb_vms[count.index].name, local.resource_suffixes.osdisk)
      caching              = disk.value.caching
      storage_account_type = disk.value.disk_type
      disk_size_gb         = disk.value.size_gb
    }
  }

  source_image_id = local.hdb_vms[count.index].os.source_image_id != "" ? local.hdb_vms[count.index].os.source_image_id : null

  # If source_image_id is not defined, deploy with source_image_reference
  dynamic "source_image_reference" {
    for_each = range(local.hdb_vms[count.index].os.source_image_id == "" ? 1 : 0)
    content {
      publisher = local.hdb_vms[count.index].os.publisher
      offer     = local.hdb_vms[count.index].os.offer
      sku       = local.hdb_vms[count.index].os.sku
      version   = "latest"
    }
  }

  admin_ssh_key {
    username   = local.hdb_vms[count.index].authentication.username
    public_key = file(var.sshkey.path_to_public_key)
  }

  boot_diagnostics {
    storage_account_uri = var.storage-bootdiag.primary_blob_endpoint
  }
}
// MANAGED DISKS ======================================================================================

// Creates managed data disk
resource "azurerm_managed_disk" "data-disk" {
  count                = local.enable_deployment ? length(local.data_disk_list) : 0
  name                 = local.data_disk_list[count.index].name
  location             = var.resource-group[0].location
  resource_group_name  = var.resource-group[0].name
  create_option        = "Empty"
  storage_account_type = local.data_disk_list[count.index].storage_account_type
  disk_size_gb         = local.data_disk_list[count.index].disk_size_gb
  disk_iops_read_write = local.data_disk_list[count.index].disk_iops_read_write
  disk_mbps_read_write = local.data_disk_list[count.index].disk_mbps_read_write
  zones                = [azurerm_linux_virtual_machine.vm-dbnode[floor(count.index / length(local.data-disk-per-dbnode))].zone]

}

// Manages attaching a Disk to a Virtual Machine
resource "azurerm_virtual_machine_data_disk_attachment" "vm-dbnode-data-disk" {
  count                     = local.enable_deployment ? length(local.data_disk_list) : 0
  managed_disk_id           = azurerm_managed_disk.data-disk[count.index].id
  virtual_machine_id        = azurerm_linux_virtual_machine.vm-dbnode[local.data_disk_list[count.index].vm_index].id
  caching                   = local.data_disk_list[count.index].caching
  write_accelerator_enabled = local.data_disk_list[count.index].write_accelerator_enabled
  lun                       = local.data_disk_list[count.index].lun
}
