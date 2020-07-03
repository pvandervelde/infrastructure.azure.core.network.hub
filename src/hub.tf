terraform {
    backend "local" {
    }
}

provider "azurerm" {
  alias  = "production"

  features {}

  subscription_id = var.subscription_production

  version = "~>2.12.0"
}

provider "azurerm" {
    #alias = "target"

    features {}

    subscription_id = var.environment == "production" ? var.subscription_production : var.subscription_test

    version = "~>2.12.0"
}


#
# LOCALS
#

locals {
  location_map = {
    australiacentral = "auc",
    australiacentral2 = "auc2",
    australiaeast = "aue",
    australiasoutheast = "ause",
    brazilsouth = "brs",
    canadacentral = "cac",
    canadaeast = "cae",
    centralindia = "inc",
    centralus = "usc",
    eastasia = "ase",
    eastus = "use",
    eastus2 = "use2",
    francecentral = "frc",
    francesouth = "frs",
    germanynorth = "den",
    germanywestcentral = "dewc",
    japaneast = "jpe",
    japanwest = "jpw",
    koreacentral = "krc",
    koreasouth = "kre",
    northcentralus = "usnc",
    northeurope = "eun",
    norwayeast = "noe",
    norwaywest = "now",
    southafricanorth = "zan",
    southafricawest = "zaw",
    southcentralus = "ussc",
    southeastasia = "asse",
    southindia = "ins",
    switzerlandnorth = "chn",
    switzerlandwest = "chw",
    uaecentral = "aec",
    uaenorth = "aen",
    uksouth = "uks",
    ukwest = "ukw",
    westcentralus = "uswc",
    westeurope = "euw",
    westindia = "inw",
    westus = "usw",
    westus2 = "usw2",
  }
}

locals {
  environment_short = substr(var.environment, 0, 1)
  location_short = lookup(local.location_map, var.location, "aue")
}

# Name prefixes
locals {
  name_prefix = "${local.environment_short}-${local.location_short}"
  name_prefix_tf = "${local.name_prefix}-tf-${var.category}"
}

locals {
  common_tags = {
    category    = "${var.category}"
    environment = "${var.environment}"
    location    = "${var.location}"
    source      = "${var.meta_source}"
    version     = "${var.meta_version}"
  }

  extra_tags = {
  }
}

# Network security rules
locals {
  default_nsg_rule = {
    direction                                  = "Inbound"
    access                                     = "Allow"
    protocol                                   = "Tcp"
    description                                = null
    source_port_range                          = null
    source_port_ranges                         = null
    destination_port_range                     = null
    destination_port_ranges                    = null
    source_address_prefix                      = null
    source_address_prefixes                    = null
    source_application_security_group_ids      = null
    destination_address_prefix                 = null
    destination_address_prefixes               = null
    destination_application_security_group_ids = null
  }
  default_mgmt_nsg_rules = [
    {
      name                       = "allow-load-balancer"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "AzureLoadBalancer"
      destination_address_prefix = "*"
    },
    {
      name                       = "deny-other"
      access                     = "Deny"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "VirtualNetwork"
      destination_address_prefix = "VirtualNetwork"
    }
  ]

  merged_mgmt_nsg_rules = flatten([
    for nsg in var.management_nsg_rules : merge(local.default_nsg_rule, nsg)
  ])

  merged_dmz_nsg_rules = flatten([
    for nsg in var.dmz_nsg_rules : merge(local.default_nsg_rule, nsg)
  ])

  nat_rules = { for idx, rule in var.firewall_nat_rules : rule.name => {
    idx : idx,
    rule : rule,
  } }

  network_rules = { for idx, rule in var.firewall_network_rules : rule.name => {
    idx : idx,
    rule : rule,
  } }

  application_rules = { for idx, rule in var.firewall_application_rules : rule.name => {
    idx : idx,
    rule : rule,
  } }
}

# Diagnostics
locals {
  diag_vnet_logs = [
    "VMProtectionAlerts",
  ]
  diag_vnet_metrics = [
    "AllMetrics",
  ]
  diag_nsg_logs = [
    "NetworkSecurityGroupEvent",
    "NetworkSecurityGroupRuleCounter",
  ]
  diag_pip_logs = [
    "DDoSProtectionNotifications",
    "DDoSMitigationFlowLogs",
    "DDoSMitigationReports",
  ]
  diag_pip_metrics = [
    "AllMetrics",
  ]
  diag_fw_logs = [
    "AzureFirewallApplicationRule",
    "AzureFirewallNetworkRule",
  ]
  diag_fw_metrics = [
    "AllMetrics",
  ]

  diag_all_logs = setunion(
    local.diag_vnet_logs,
    local.diag_nsg_logs,
    local.diag_pip_logs,
  local.diag_fw_logs)
  diag_all_metrics = setunion(
    local.diag_vnet_metrics,
    local.diag_pip_metrics,
  local.diag_fw_metrics)

  parsed_diag = {
    log_analytics_id   = "e1c46677-b6e1-4c5a-8983-bfecd30e5061"
    metric             = local.diag_all_metrics
    log                = local.diag_all_logs
    }
}

data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "log_analytics_workspace" {
  name                = "p-aue-tf-analytics-law-logs"
  resource_group_name = "p-aue-tf-analytics-rg"
  provider = azurerm.production
}

data "azurerm_network_watcher" "networkwatcher" {
  name = "NetworkWatcher_${local.location_short}"
  resource_group_name = "NetworkWatcherRG"
  provider = azurerm.production
}

#
# Resource group
#

resource "azurerm_resource_group" "rg" {
  name = "${local.name_prefix_tf}-rg-${var.category}"
  location = var.location

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

#
# Storage account for flow logs
#

module "storage" {
  source  = "avinor/storage-account/azurerm"
  version = "2.2.0"

  name                = "${local.name_prefix_tf}"
  resource_group_name = "${local.name_prefix_tf}-rg-${var.category}-storage"
  location            = azurerm_resource_group.rg.location

  enable_advanced_threat_protection = true

  # TODO Not yet supported to use service endpoints together with flow logs. Not a trusted Microsoft service
  # See https://github.com/MicrosoftDocs/azure-docs/issues/5989
  # network_rules {
  #   ip_rules                   = ["127.0.0.1"]
  #   virtual_network_subnet_ids = ["${azurerm_subnet.firewall.id}"]
  # }

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

#
# DDos protection plan
#

resource "azurerm_network_ddos_protection_plan" "ddos_protection" {
  count = var.create_ddos_plan ? 1 : 0
  name  = "{local.name_prefix_tf}-ddos"
  location = var.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

#
# Hub network with subnets
#

resource "azurerm_virtual_network" "vnet" {
  address_space = [var.address_space]
  location = var.location
  name = "${local.name_prefix_tf}-vn"

  resource_group_name = azurerm_resource_group.rg.name

  tags = merge( local.common_tags, local.extra_tags, var.tags )

  dynamic "ddos_protection_plan" {
    for_each = var.create_ddos_plan ? [true] : []
    iterator = ddos
    content {
      id     = azurerm_network_ddos_protection_plan.ddos_protection.id
      enable = true
    }
  }
}

# Set the user principals who are allowed to peer vnets
resource "azurerm_role_assignment" "peering" {
  count = length(var.peering_assignment)
  principal_id = var.peering_assignment[count.index]
  role_definition_name = "Network Contributor"
  scope = azurerm_virtual_network.vnet.id
}

resource "azurerm_monitor_diagnostic_setting" "vnet" {
  count                          = 1
  name                           = "${local.name_prefix_tf}-mds-vnet"
  target_resource_id             = azurerm_virtual_network.vnet.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.log_analytics_workspace.id

  dynamic "log" {
    for_each = setintersection(local.parsed_diag.log, local.diag_vnet_logs)
    content {
      category = log.value

      retention_policy {
        enabled = false
      }
    }
  }

  dynamic "metric" {
    for_each = setintersection(local.parsed_diag.metric, local.diag_vnet_metrics)
    content {
      category = metric.value

      retention_policy {
        enabled = false
      }
    }
  }
}

#
# Firewall subnet
#

resource "azurerm_subnet" "firewall" {
  address_prefixes = [ cidrsubnet(var.address_space, 2, 0) ]
  name = "AzureFirewallSubnet" #"${local.name_prefix_tf}-sn-firewall"
  resource_group_name = azurerm_resource_group.rg.name
  service_endpoints = var.service_endpoints
  virtual_network_name = azurerm_virtual_network.vnet.name
}

#
# Gateway subnet
#

resource "azurerm_subnet" "gateway" {
  address_prefixes = [ cidrsubnet(var.address_space, 2, 1) ]
  name = "GatewaySubnet"
  resource_group_name = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name

  service_endpoints = [
    "Microsoft.Storage",
  ]
}

#
# Management subnet
#

resource "azurerm_subnet" "mgmt" {
  address_prefixes = [ cidrsubnet(var.address_space, 2, 2) ]
  name = "${local.name_prefix_tf}-sn-management"
  resource_group_name = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name

  service_endpoints = [
    "Microsoft.Storage",
  ]
}

#
# DMZ subnet
#

resource "azurerm_subnet" "dmz" {
  address_prefixes = [ cidrsubnet(var.address_space, 2, 3) ]
  name = "${local.name_prefix_tf}-sn-dmz"
  resource_group_name = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name

  service_endpoints = [
    "Microsoft.Storage",
  ]
}

#
# Route table
#

resource "azurerm_route_table" "out" {
  name = "${local.name_prefix_tf}-rt-outbound"
  location = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

resource "azurerm_route" "fw" {
  name = "${local.name_prefix_tf}-r-firewall"
  resource_group_name = azurerm_resource_group.rg.name
  route_table_name = azurerm_route_table.out.name
  address_prefix = "0.0.0.0/0"
  next_hop_type = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.fw.ip_configuration.0.private_ip_address
}

resource "azurerm_subnet_route_table_association" "mgmt" {
  subnet_id = azurerm_subnet.mgmt.id
  route_table_id = azurerm_route_table.out.id
}

resource "azurerm_subnet_route_table_association" "dmz" {
  subnet_id = azurerm_subnet.dmz.id
  route_table_id = azurerm_route_table.out.id
}

#
# Network security groups
#

# Management subnet
resource "azurerm_network_security_group" "mgmt" {
  name = "${local.name_prefix_tf}-nsg-mgmt"
  location = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

resource "azurerm_network_watcher_flow_log" "mgmt" {
  network_watcher_name = data.azurerm_network_watcher.networkwatcher.id
  resource_group_name  = "NetworkWatcherRG"

  network_security_group_id = azurerm_network_security_group.mgmt.id
  storage_account_id        = module.storage.id
  enabled                   = true

  retention_policy {
    enabled = true
    days    = 7
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = data.azurerm_log_analytics_workspace.log_analytics_workspace.workspace_id
    workspace_region      = var.location
    workspace_resource_id = data.azurerm_log_analytics_workspace.log_analytics_workspace.id
    interval_in_minutes   = 10
  }
}

resource "azurerm_network_security_rule" "mgmt" {
  count = length(local.merged_mgmt_nsg_rules)
  resource_group_name = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.mgmt.name
  priority = 100 + 100 * count.index

  name = local.merged_mgmt_nsg_rules[count.index].name
  direction = local.merged_mgmt_nsg_rules[count.index].direction
  access = local.merged_mgmt_nsg_rules[count.index].access
  protocol = local.merged_mgmt_nsg_rules[count.index].protocol
  description = local.merged_mgmt_nsg_rules[count.index].description
  source_port_range = local.merged_mgmt_nsg_rules[count.index].source_port_range
  source_port_ranges = local.merged_mgmt_nsg_rules[count.index].source_port_ranges
  destination_port_range = local.merged_mgmt_nsg_rules[count.index].destination_port_range
  destination_port_ranges = local.merged_mgmt_nsg_rules[count.index].destination_port_ranges
  source_address_prefix = local.merged_mgmt_nsg_rules[count.index].source_address_prefix
  source_address_prefixes = local.merged_mgmt_nsg_rules[count.index].source_address_prefixes
  source_application_security_group_ids = local.merged_mgmt_nsg_rules[count.index].source_application_security_group_ids
  destination_address_prefix = local.merged_mgmt_nsg_rules[count.index].destination_address_prefix
  destination_address_prefixes = local.merged_mgmt_nsg_rules[count.index].destination_address_prefixes
  destination_application_security_group_ids = local.merged_mgmt_nsg_rules[count.index].destination_application_security_group_ids
}

resource "azurerm_monitor_diagnostic_setting" "mgmt" {
  count                          = 1
  name                           = "${local.name_prefix_tf}-mds-nsg-mgnt"
  target_resource_id             = azurerm_network_security_group.mgmt.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.log_analytics_workspace.id

  dynamic "log" {
    for_each = setintersection(local.parsed_diag.log, local.diag_nsg_logs)
    content {
      category = log.value

      retention_policy {
        enabled = false
      }
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "mgmt" {
  subnet_id = azurerm_subnet.mgmt.id
  network_security_group_id = azurerm_network_security_group.mgmt.id
}

# DMZ subnet
resource "azurerm_network_security_group" "dmz" {
  name = "${local.name_prefix_tf}-nsg-dmz"
  location = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

resource "azurerm_network_watcher_flow_log" "dmz" {
  network_watcher_name = data.azurerm_network_watcher.networkwatcher.id
  resource_group_name  = "NetworkWatcherRG"

  network_security_group_id = azurerm_network_security_group.dmz.id
  storage_account_id        = module.storage.id
  enabled                   = true

  retention_policy {
    enabled = true
    days    = 7
  }

  traffic_analytics {
    enabled               = true
    workspace_id          = data.azurerm_log_analytics_workspace.log_analytics_workspace.workspace_id
    workspace_region      = var.location
    workspace_resource_id = data.azurerm_log_analytics_workspace.log_analytics_workspace.id
    interval_in_minutes   = 10
  }
}

resource "azurerm_network_security_rule" "dmz" {
  count = length(local.merged_dmz_nsg_rules)
  resource_group_name = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.dmz.name
  priority = 100 + 100 * count.index

  name = local.merged_dmz_nsg_rules[count.index].name
  direction = local.merged_dmz_nsg_rules[count.index].direction
  access = local.merged_dmz_nsg_rules[count.index].access
  protocol = local.merged_dmz_nsg_rules[count.index].protocol
  description = local.merged_dmz_nsg_rules[count.index].description
  source_port_range = local.merged_dmz_nsg_rules[count.index].source_port_range
  source_port_ranges = local.merged_dmz_nsg_rules[count.index].source_port_ranges
  destination_port_range = local.merged_dmz_nsg_rules[count.index].destination_port_range
  destination_port_ranges = local.merged_dmz_nsg_rules[count.index].destination_port_ranges
  source_address_prefix = local.merged_dmz_nsg_rules[count.index].source_address_prefix
  source_address_prefixes = local.merged_dmz_nsg_rules[count.index].source_address_prefixes
  source_application_security_group_ids = local.merged_dmz_nsg_rules[count.index].source_application_security_group_ids
  destination_address_prefix = local.merged_dmz_nsg_rules[count.index].destination_address_prefix
  destination_address_prefixes = local.merged_dmz_nsg_rules[count.index].destination_address_prefixes
  destination_application_security_group_ids = local.merged_dmz_nsg_rules[count.index].destination_application_security_group_ids
}

resource "azurerm_monitor_diagnostic_setting" "dmz" {
  count                          = 1
  name                           = "${local.name_prefix_tf}-mds-nsg-dmz"
  target_resource_id             = azurerm_network_security_group.dmz.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.log_analytics_workspace.id

  dynamic "log" {
    for_each = setintersection(local.parsed_diag.log, local.diag_nsg_logs)
    content {
      category = log.value

      retention_policy {
        enabled = false
      }
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "dmz" {
  subnet_id = azurerm_subnet.dmz.id
  network_security_group_id = azurerm_network_security_group.dmz.id
}

#
# Private DNS
#

resource "azurerm_private_dns_zone" "main" {
  count = var.private_dns_zone != null ? 1 : 0
  name = var.private_dns_zone
  resource_group_name = azurerm_resource_group.rg.name

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

resource "azurerm_private_dns_zone_virtual_network_link" "main" {
  count = var.private_dns_zone != null ? 1 : 0
  name = "${local.name_prefix_tf}-dnsl-main"
  resource_group_name = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.main[0].name
  virtual_network_id = azurerm_virtual_network.vnet.id
  registration_enabled = true

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

resource "azurerm_role_assignment" "dns" {
  count = var.private_dns_zone != null ? length(var.peering_assignment) : 0
  scope = azurerm_private_dns_zone.main[0].id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id = var.peering_assignment[count.index]
}

#
# Firewall
#

resource "azurerm_public_ip_prefix" "fw" {
  name = "${local.name_prefix_tf}-pippre"
  location = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  prefix_length = var.public_ip_prefix_length

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

resource "random_string" "dns" {
  length = 6
  special = false
  upper = false
}

resource "azurerm_public_ip" "fw" {
  name = "${local.name_prefix_tf}-pip-fw"
  location = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  allocation_method = "Static"
  sku = "Standard"
  domain_name_label = format("%s%sfw%s", lower(replace(var.category, "/[[:^alnum:]]/", "")), lower(replace(var.public_ip_name, "/[[:^alnum:]]/", "")), random_string.dns.result)
  public_ip_prefix_id = azurerm_public_ip_prefix.fw.id

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

resource "azurerm_monitor_diagnostic_setting" "fw_pip" {
  name                           = "${local.name_prefix_tf}-mds-fw-pip"
  target_resource_id             = azurerm_public_ip.fw.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.log_analytics_workspace.id

  dynamic "log" {
    for_each = setintersection(local.parsed_diag.log, local.diag_pip_logs)
    content {
      category = log.value

      retention_policy {
        enabled = false
      }
    }
  }

  dynamic "metric" {
    for_each = setintersection(local.parsed_diag.metric, local.diag_pip_metrics)
    content {
      category = metric.value

      retention_policy {
        enabled = false
      }
    }
  }
}

resource "azurerm_firewall" "fw" {
  name = "${local.name_prefix_tf}-fw"
  location = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  zones = var.firewall_zones

  ip_configuration {
    name = var.public_ip_name
    subnet_id = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.fw.id
  }

  # Avoid changes when adding more public ips manually to firewall
  lifecycle {
    ignore_changes = [
      ip_configuration,
    ]
  }

  tags = merge( local.common_tags, local.extra_tags, var.tags )
}

resource "azurerm_monitor_diagnostic_setting" "fw" {
  count                          = 1
  name                           = "${local.name_prefix_tf}-mds-fw"
  target_resource_id             = azurerm_firewall.fw.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.log_analytics_workspace.id

  dynamic "log" {
    for_each = setintersection(local.parsed_diag.log, local.diag_fw_logs)
    content {
      category = log.value

      retention_policy {
        enabled = false
      }
    }
  }

  dynamic "metric" {
    for_each = setintersection(local.parsed_diag.metric, local.diag_fw_metrics)
    content {
      category = metric.value

      retention_policy {
        enabled = false
      }
    }
  }
}

resource "azurerm_firewall_application_rule_collection" "fw" {
  for_each = local.application_rules

  name = "${local.name_prefix_tf}-fwappr-${each.key}"
  azure_firewall_name = azurerm_firewall.fw.name
  resource_group_name = azurerm_resource_group.rg.name
  priority = 100 * (each.value.idx + 1)
  action = each.value.rule.action

  rule {
    name = each.key
    source_addresses = each.value.rule.source_addresses
    target_fqdns = each.value.rule.target_fqdns

    protocol {
      type = each.value.rule.protocol.type
      port = each.value.rule.protocol.port
    }
  }
}

resource "azurerm_firewall_network_rule_collection" "fw" {
  for_each = local.network_rules

  name = "${local.name_prefix_tf}-fwnwr-${each.key}"
  azure_firewall_name = azurerm_firewall.fw.name
  resource_group_name = azurerm_resource_group.rg.name
  priority = 100 * (each.value.idx + 1)
  action = each.value.rule.action

  rule {
    name = each.key
    source_addresses = each.value.rule.source_addresses
    destination_ports = each.value.rule.destination_ports
    destination_addresses = [for dest in each.value.rule.destination_addresses : contains(var.public_ip_name, dest) ? azurerm_public_ip.fw[dest].ip_address : dest]
    protocols = each.value.rule.protocols
  }
}

resource "azurerm_firewall_nat_rule_collection" "fw" {
  for_each = local.nat_rules

  name = "${local.name_prefix_tf}-fwnatr-${each.key}"
  azure_firewall_name = azurerm_firewall.fw.name
  resource_group_name = azurerm_resource_group.rg.name
  priority = 100 * (each.value.idx + 1)
  action = each.value.rule.action

  rule {
    name = each.key
    source_addresses = each.value.rule.source_addresses
    destination_ports = each.value.rule.destination_ports
    destination_addresses = [for dest in each.value.rule.destination_addresses : contains(var.public_ip_name, dest) ? azurerm_public_ip.fw[dest].ip_address : dest]
    protocols = each.value.rule.protocols
    translated_address = each.value.rule.translated_address
    translated_port = each.value.rule.translated_port
  }
}