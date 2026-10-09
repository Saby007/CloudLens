variable "environment_name" {
  description = "azd environment name; also names the resource group and Entra app registrations."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,63}$", var.environment_name))
    error_message = "environment_name must be 1-64 lowercase letters, digits or hyphens."
  }
}

variable "location" {
  description = "Azure region for the cluster, network, registry and storage."
  type        = string
  default     = "centralindia"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]+$", var.location))
    error_message = "location must be an Azure location code such as centralindia."
  }
}

variable "foundry_location" {
  description = "Azure region for the Foundry account (ai profile)."
  type        = string
  default     = "eastus2"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]+$", var.foundry_location))
    error_message = "foundry_location must be an Azure location code such as eastus2."
  }
}

variable "profile" {
  description = "core: network, cluster, registry, logging and identities. data: adds export storage and the processor identity. ai: adds the private Foundry account."
  type        = string
  default     = "core"

  validation {
    condition     = contains(["core", "data", "ai"], var.profile)
    error_message = "profile must be core, data or ai."
  }
}

variable "provisioned_profile" {
  description = "Profile of the previous provision (APP_PROVISIONED_PROFILE). Lowering the profile would delete the data or AI resources, so it is refused."
  type        = string
  default     = ""

  validation {
    condition = var.provisioned_profile == "" || !contains(["core", "data", "ai"], var.provisioned_profile) || !contains(["core", "data", "ai"], var.profile) || (
      index(["core", "data", "ai"], var.profile) >= index(["core", "data", "ai"], var.provisioned_profile)
    )
    error_message = "APP_PROFILE cannot be lowered below the provisioned profile (APP_PROVISIONED_PROFILE): Terraform would delete the export storage or the Foundry account. To remove them on purpose, first run: azd env set APP_PROVISIONED_PROFILE \"\"."
  }
}

variable "resource_group_name" {
  description = "Resource group to create. Defaults to rg-<environment_name>."
  type        = string
  default     = ""
}

variable "principal_id" {
  description = "Object ID of the principal azd deploys as; granted cluster-admin so azd can apply the Kubernetes manifests."
  type        = string
  default     = ""
}

variable "vnet_address_prefix" {
  type    = string
  default = "10.42.0.0/23"

  validation {
    condition     = can(cidrnetmask(var.vnet_address_prefix))
    error_message = "vnet_address_prefix must be an IPv4 CIDR block."
  }
}

variable "aks_subnet_prefix" {
  description = "Node subnet. Pods use the separate overlay range, so this only needs one address per node."
  type        = string
  default     = "10.42.0.0/24"

  validation {
    condition     = can(cidrnetmask(var.aks_subnet_prefix))
    error_message = "aks_subnet_prefix must be an IPv4 CIDR block."
  }
}

variable "private_endpoint_subnet_prefix" {
  type    = string
  default = "10.42.1.0/27"

  validation {
    condition     = can(cidrnetmask(var.private_endpoint_subnet_prefix))
    error_message = "private_endpoint_subnet_prefix must be an IPv4 CIDR block."
  }
}

variable "aks_pod_cidr" {
  description = "Azure CNI Overlay pod range. Not routable from the VNet, but must not overlap it or the service range."
  type        = string
  default     = "10.244.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.aks_pod_cidr))
    error_message = "aks_pod_cidr must be an IPv4 CIDR block."
  }
}

variable "aks_service_cidr" {
  description = "Kubernetes service range; the cluster DNS service uses its tenth address."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.aks_service_cidr))
    error_message = "aks_service_cidr must be an IPv4 CIDR block."
  }
}

variable "aks_sku_tier" {
  description = "Standard adds the financially backed API server uptime SLA; use Free only for dev/test."
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.aks_sku_tier)
    error_message = "aks_sku_tier must be Free, Standard or Premium."
  }
}

variable "aks_kubernetes_version" {
  description = "Leave empty for the region's default version; the stable auto-upgrade channel keeps it current."
  type        = string
  default     = ""
}

variable "aks_system_vm_size" {
  description = "System node pool size. Needs a local temp disk of at least 64 GiB for the ephemeral OS disk (a 'd' size such as Standard_D2ds_v5)."
  type        = string
  default     = "Standard_D2ds_v5"

  validation {
    condition     = can(regex("^Standard_[A-Z]+[0-9]+[a-z]*d[a-z]*_v[0-9]+$", var.aks_system_vm_size))
    error_message = "aks_system_vm_size must be a size with a local temp disk, for example Standard_D2ds_v5 or Standard_D4ds_v5."
  }
}

variable "aks_system_min_nodes" {
  type    = number
  default = 2

  validation {
    condition     = var.aks_system_min_nodes >= 1 && var.aks_system_min_nodes <= 10
    error_message = "aks_system_min_nodes must be between 1 and 10."
  }
}

variable "aks_system_max_nodes" {
  type    = number
  default = 3

  validation {
    condition     = var.aks_system_max_nodes >= 1 && var.aks_system_max_nodes <= 20
    error_message = "aks_system_max_nodes must be between 1 and 20."
  }
}

variable "aks_user_vm_size" {
  description = "Application node pool size. Needs a local temp disk of at least 64 GiB for the ephemeral OS disk."
  type        = string
  default     = "Standard_D4ds_v5"

  validation {
    condition     = can(regex("^Standard_[A-Z]+[0-9]+[a-z]*d[a-z]*_v[0-9]+$", var.aks_user_vm_size))
    error_message = "aks_user_vm_size must be a size with a local temp disk, for example Standard_D4ds_v5."
  }
}

variable "aks_user_min_nodes" {
  type    = number
  default = 2

  validation {
    condition     = var.aks_user_min_nodes >= 1 && var.aks_user_min_nodes <= 20
    error_message = "aks_user_min_nodes must be between 1 and 20."
  }
}

variable "aks_user_max_nodes" {
  type    = number
  default = 5

  validation {
    condition     = var.aks_user_max_nodes >= 1 && var.aks_user_max_nodes <= 50
    error_message = "aks_user_max_nodes must be between 1 and 50."
  }
}

variable "aks_zones" {
  description = "Comma-separated availability zones for the node pools and ingress IP, or none in regions without zones."
  type        = string
  default     = "1,2,3"

  validation {
    condition     = lower(trimspace(var.aks_zones)) == "none" || can(regex("^([1-3](,[1-3]){0,2})?$", replace(var.aks_zones, " ", "")))
    error_message = "aks_zones must be none or a comma-separated list of zones 1-3."
  }
}

variable "aks_api_authorized_ip_ranges" {
  description = "Optional comma-separated CIDR ranges allowed to reach the Kubernetes API server of a cluster with a public API server. Include the machine that runs azd. A private cluster has no public address to limit."
  type        = string
  default     = ""
}

variable "aks_private_cluster" {
  description = "true (default): the Kubernetes API server has only a private address inside the virtual network, so kubectl, the cluster bootstrap and azd deploy must run from a machine that can reach it (the deploy host this configuration can create, or a connected network). false: the API server keeps a public address, protected by Entra ID and Azure RBAC."
  type        = bool
  default     = true

  validation {
    condition     = !var.aks_private_cluster || trimspace(var.aks_api_authorized_ip_ranges) == ""
    error_message = "aks_api_authorized_ip_ranges limits a public API server; a private cluster has none. Clear APP_AKS_API_AUTHORIZED_IP_RANGES, or keep the public API server with APP_AKS_PRIVATE_CLUSTER=false."
  }
}

variable "private_registry" {
  description = "true (default): the container registry is Premium with a private endpoint and no public access, so images are pushed and pulled over the virtual network only. Cloud-side builds (az acr build, azd's remote build) cannot reach it; images are built on the deploy host. false: a Basic registry with public access."
  type        = bool
  default     = true
}

variable "aks_outbound_type" {
  description = "How the cluster reaches the internet. natGateway (default): a NAT gateway with one static public IP, outbound only, and no public load balancer. loadBalancer: the cluster's standard load balancer with managed outbound IPs (see aks_outbound_ip_count and the SNAT settings)."
  type        = string
  default     = "natGateway"

  validation {
    condition     = contains(["natGateway", "loadBalancer"], var.aks_outbound_type)
    error_message = "aks_outbound_type (APP_AKS_OUTBOUND_TYPE) must be natGateway or loadBalancer."
  }
}

variable "deploy_host_enabled" {
  description = "Create the deploy host: a Linux VM with no public address, in this virtual network, reached through Azure Bastion, that has the tools to deploy a private cluster and registry. Only created when the cluster or the registry is private; turn it off when you deploy from a network you already connect to this one."
  type        = bool
  default     = true
}

variable "deploy_host_subnet_prefix" {
  description = "Subnet for the deploy host, inside the virtual network, /28 or larger."
  type        = string
  default     = "10.42.1.96/27"

  validation {
    condition     = can(cidrnetmask(var.deploy_host_subnet_prefix)) && tonumber(split("/", var.deploy_host_subnet_prefix)[1]) <= 28
    error_message = "deploy_host_subnet_prefix must be an IPv4 CIDR block of /28 or larger."
  }
}

variable "bastion_subnet_prefix" {
  description = "AzureBastionSubnet for the deploy host's Azure Bastion, inside the virtual network; Azure requires /26 or larger."
  type        = string
  default     = "10.42.1.128/26"

  validation {
    condition     = can(cidrnetmask(var.bastion_subnet_prefix)) && tonumber(split("/", var.bastion_subnet_prefix)[1]) <= 26
    error_message = "bastion_subnet_prefix must be an IPv4 CIDR block of /26 or larger."
  }
}

variable "deploy_host_vm_size" {
  description = "Size of the deploy host. It builds the container images, so it needs a few cores."
  type        = string
  default     = "Standard_D4s_v5"
}

variable "deploy_host_shutdown_time" {
  description = "UTC time (HHmm) at which the deploy host shuts itself down every day, to stop its compute charge. It starts again with az vm start. Empty disables it."
  type        = string
  default     = "1800"

  validation {
    condition     = var.deploy_host_shutdown_time == "" || can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.deploy_host_shutdown_time))
    error_message = "deploy_host_shutdown_time must be HHmm, for example 1800, or empty."
  }
}

variable "auth_mode" {
  description = "MEGHKOSHA_AUTH_MODE: entra (default) or operator, the Dev-only mode without sign-in, in which HTTPS is never open to the whole internet."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "entra", "operator"], var.auth_mode)
    error_message = "auth_mode (MEGHKOSHA_AUTH_MODE) must be entra or operator, lowercase."
  }
}

variable "web_allowed_ip_ranges" {
  description = "Optional comma-separated IPv4 addresses or CIDR ranges (/8 or narrower) that may reach a public ingress over HTTPS. Empty allows the internet, except in operator mode, where HTTPS then stays closed. A private ingress has no public address, so it takes none."
  type        = string
  default     = ""

  validation {
    condition = alltrue([
      for range in compact([for item in split(",", var.web_allowed_ip_ranges) : trimspace(item)]) :
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}(/([89]|[12][0-9]|3[0-2]))?$", range)) &&
      try(cidrhost(strcontains(range, "/") ? range : "${range}/32", 0) == split("/", range)[0], false)
    ])
    error_message = "web_allowed_ip_ranges must list IPv4 addresses or CIDR ranges from /8 to /32 written with their network address, for example 203.0.113.7 or 198.51.100.0/24."
  }

  validation {
    condition     = var.ingress_visibility == "public" || trimspace(var.web_allowed_ip_ranges) == ""
    error_message = "web_allowed_ip_ranges limits who can reach a public ingress; the private ingress has no public address. Clear APP_WEB_ALLOWED_IP_RANGES, or keep the internet-facing ingress with APP_INGRESS_VISIBILITY=public."
  }
}

variable "aks_outbound_ip_count" {
  description = "Managed outbound public IPs. Each adds 64,000 SNAT ports for the nodes to share, so more IPs allow more nodes."
  type        = number
  default     = 1

  validation {
    condition     = var.aks_outbound_ip_count >= 1 && var.aks_outbound_ip_count <= 100
    error_message = "aks_outbound_ip_count must be between 1 and 100."
  }
}

variable "aks_outbound_ports_per_node" {
  description = "SNAT ports each node gets for outbound connections. Every node, including the extra node an upgrade adds to each pool, takes this many from the outbound IPs' 64,000 each."
  type        = number
  default     = 6400

  validation {
    condition     = var.aks_outbound_ports_per_node >= 1024 && var.aks_outbound_ports_per_node <= 64000 && var.aks_outbound_ports_per_node % 8 == 0
    error_message = "aks_outbound_ports_per_node must be a multiple of 8 between 1024 and 64000."
  }
}

variable "aks_outbound_idle_timeout_minutes" {
  description = "Minutes an idle outbound connection keeps its SNAT port. Azure's default is 30; the app closes idle connections after 30 seconds."
  type        = number
  default     = 4

  validation {
    condition     = var.aks_outbound_idle_timeout_minutes >= 4 && var.aks_outbound_idle_timeout_minutes <= 120
    error_message = "aks_outbound_idle_timeout_minutes must be between 4 and 120."
  }
}

variable "aks_maintenance_day" {
  description = "Weekly UTC day for cluster and node image auto-upgrades."
  type        = string
  default     = "Sunday"

  validation {
    condition     = contains(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], var.aks_maintenance_day)
    error_message = "aks_maintenance_day must be a day of the week, for example Sunday."
  }
}

variable "aks_maintenance_start_time" {
  description = "UTC start time (HH:mm) of the four-hour weekly maintenance window."
  type        = string
  default     = "02:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.aks_maintenance_start_time))
    error_message = "aks_maintenance_start_time must use HH:mm."
  }
}

variable "ingress_dns_label" {
  description = "Public ingress only: the DNS label in <label>.<region>.cloudapp.azure.com. Defaults to cloudlens-<resource token>, which also names the private host when no custom_domain is set."
  type        = string
  default     = ""

  validation {
    condition     = var.ingress_dns_label == "" || can(regex("^[a-z][a-z0-9-]{1,61}[a-z0-9]$", var.ingress_dns_label))
    error_message = "ingress_dns_label must be 3-63 lowercase letters, digits or hyphens, start with a letter and not end with a hyphen."
  }
}

variable "ingress_visibility" {
  description = "private (default): the app has no public address. It is served from a private IP in the virtual network and, optionally, through a Private Link Service that private endpoints in other networks connect to. public: an internet-facing address."
  type        = string
  default     = "private"

  validation {
    condition     = contains(["private", "public"], var.ingress_visibility)
    error_message = "ingress_visibility (APP_INGRESS_VISIBILITY) must be private or public, lowercase."
  }
}

variable "ingress_subnet_prefix" {
  description = "Private ingress: subnet that holds the internal load balancer's address (its fifth address, the first Azure leaves usable). Inside the virtual network, /28 or larger."
  type        = string
  default     = "10.42.1.32/27"

  validation {
    condition     = can(cidrnetmask(var.ingress_subnet_prefix)) && tonumber(split("/", var.ingress_subnet_prefix)[1]) <= 28
    error_message = "ingress_subnet_prefix must be an IPv4 CIDR block of /28 or larger."
  }
}

variable "private_link_subnet_prefix" {
  description = "Private ingress: subnet for the Private Link Service's NAT addresses (Azure requires its Private Link service network policies to be off). Inside the virtual network, /28 or larger."
  type        = string
  default     = "10.42.1.64/27"

  validation {
    condition     = can(cidrnetmask(var.private_link_subnet_prefix)) && tonumber(split("/", var.private_link_subnet_prefix)[1]) <= 28
    error_message = "private_link_subnet_prefix must be an IPv4 CIDR block of /28 or larger."
  }
}

variable "private_link_enabled" {
  description = "Private ingress: publish the app through a Private Link Service, so a private endpoint in any virtual network (peered or not) can reach it. Off keeps only the private IP, reachable from this network and anything peered or connected to it."
  type        = bool
  default     = true
}

variable "private_link_allowed_subscriptions" {
  description = "Comma-separated subscription IDs, besides the deployment subscription, whose private endpoints may connect to the Private Link Service without manual approval."
  type        = string
  default     = ""

  validation {
    condition = alltrue([
      for id in compact([for item in split(",", var.private_link_allowed_subscriptions) : trimspace(item)]) :
      can(regex("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$", id))
    ])
    error_message = "private_link_allowed_subscriptions must be a comma-separated list of subscription IDs (GUIDs)."
  }
}

variable "custom_domain" {
  description = "Optional host name for the app. Public ingress: point a CNAME at the cloudapp.azure.com name first. Private ingress: a private DNS zone of this name, pointing at the private IP, is created for the virtual network; without one the host is <ingress label>.internal."
  type        = string
  default     = ""

  validation {
    condition     = var.custom_domain == "" || can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", lower(var.custom_domain)))
    error_message = "custom_domain must be a host name such as cloudlens.contoso.com."
  }
}

variable "tls_cluster_issuer" {
  description = "Certificate source for the web host. Empty chooses by ingress_visibility: letsencrypt for public, private-ca for private. letsencrypt and letsencrypt-staging validate over the public internet, so they need a public ingress (staging avoids production rate limits). private-ca is a CA that cert-manager creates in the cluster; browsers must trust it. byo expects you to create the web-tls secret in the cloudlens namespace yourself, for example from your enterprise CA."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "letsencrypt", "letsencrypt-staging", "private-ca", "byo"], var.tls_cluster_issuer)
    error_message = "tls_cluster_issuer must be letsencrypt, letsencrypt-staging, private-ca or byo; empty chooses by ingress visibility."
  }

  validation {
    condition     = var.ingress_visibility == "public" || !contains(["letsencrypt", "letsencrypt-staging"], var.tls_cluster_issuer)
    error_message = "Let's Encrypt validates the host over the public internet, which a private ingress does not accept. Use private-ca or byo, clear the setting (azd env set APP_TLS_CLUSTER_ISSUER \"\"), or keep the internet-facing ingress with APP_INGRESS_VISIBILITY=public."
  }
}

variable "log_retention_days" {
  type    = number
  default = 30

  validation {
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 730
    error_message = "log_retention_days must be between 30 and 730."
  }
}

variable "storage_sku" {
  type    = string
  default = "Standard_LRS"

  validation {
    condition     = contains(["Standard_LRS", "Standard_ZRS"], var.storage_sku)
    error_message = "storage_sku must be Standard_LRS or Standard_ZRS."
  }
}

variable "allow_native_export_trusted_services" {
  description = "Explicitly approved trusted-services exception so Cost Management can write native exports; never bypasses an Azure Policy denial."
  type        = bool
  default     = false
}

variable "daily_export_retention_days" {
  description = "Days to keep daily month-to-date FOCUS snapshots under cost-exports/focus-daily/."
  type        = number
  default     = 60

  validation {
    condition     = var.daily_export_retention_days >= 7 && var.daily_export_retention_days <= 365
    error_message = "daily_export_retention_days must be between 7 and 365."
  }
}

variable "closed_month_retention_days" {
  description = "Days to keep closed-month FOCUS exports under cost-exports/focus/. Must cover the longest 6-month history window."
  type        = number
  default     = 214

  validation {
    condition     = var.closed_month_retention_days >= 190 && var.closed_month_retention_days <= 3650
    error_message = "closed_month_retention_days must be between 190 and 3650."
  }
}

variable "export_parallel_months" {
  description = "Months each subscription may export at once. Keep 1 until Azure is confirmed to run one export's months in parallel."
  type        = number
  default     = 1

  validation {
    condition     = var.export_parallel_months >= 1 && var.export_parallel_months <= 6
    error_message = "export_parallel_months must be between 1 and 6."
  }
}

variable "enable_processor" {
  description = "Runs the scheduled export processor CronJob (data or ai profile)."
  type        = bool
  default     = false
}

variable "processor_schedule" {
  description = "Processor cadence (UTC cron). Each tick advances monthly pulls and starts daily pulls once their UTC time has passed."
  type        = string
  default     = "*/5 * * * *"

  validation {
    condition     = length(split(" ", trimspace(var.processor_schedule))) == 5
    error_message = "processor_schedule must be a five-field cron expression."
  }
}

variable "foundry_project_name" {
  type    = string
  default = "cost-agent-project"

  validation {
    condition     = length(var.foundry_project_name) >= 2 && length(var.foundry_project_name) <= 32
    error_message = "foundry_project_name must be 2-32 characters."
  }
}

variable "model_deployments" {
  description = "Approved Foundry model deployments (ai profile)."
  type = list(object({
    name         = string
    modelFormat  = string
    modelName    = string
    modelVersion = string
    sku          = string
    capacity     = number
  }))
  default = []

  validation {
    condition     = alltrue([for model in var.model_deployments : contains(["Standard", "GlobalStandard", "DataZoneStandard"], model.sku) && model.capacity >= 1])
    error_message = "Each model deployment needs a Standard, GlobalStandard or DataZoneStandard sku and a capacity of at least 1."
  }

  validation {
    condition     = length(distinct([for model in var.model_deployments : lower(model.name)])) == length(var.model_deployments)
    error_message = "Model deployment names must be unique."
  }
}

variable "enable_ai_runtime" {
  description = "Keep false until the Foundry agent and model invocation are verified end to end."
  type        = bool
  default     = false
}

variable "enable_chat_runtime" {
  description = "Enable grounded chat through the app-local Model Router without enabling the separate hosted-agent narrator."
  type        = bool
  default     = false
}

variable "agent_name" {
  type    = string
  default = "cost-agent"
}

variable "model_router_deployment_name" {
  type    = string
  default = ""
}
