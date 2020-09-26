locals {
  environment          = lower(try(var.infrastructure.environment, ""))
  location             = try(var.infrastructure.region, "")
  codename             = lower(try(var.infrastructure.codename, ""))
  management_vnet_name = try(var.infrastructure.vnets.management.name, "MGMT")
}
