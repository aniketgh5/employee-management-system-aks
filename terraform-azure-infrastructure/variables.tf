variable "subscription_id" {
  description = "Azure subscription ID where the infrastructure will be created."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name."
  type        = string
  default     = "employee-app-rg"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "centralindia"
}

variable "cluster_name" {
  description = "AKS cluster name."
  type        = string
  default     = "employee-app-aks"
}

variable "dns_prefix" {
  description = "DNS prefix for the AKS API server."
  type        = string
  default     = "employee-app"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version. null lets Azure choose the default version."
  type        = string
  default     = null
}

variable "node_count" {
  description = "Number of nodes in the default node pool."
  type        = number
  default     = 1
}

variable "node_vm_size" {
  description = "VM size for AKS nodes."
  type        = string
  default     = "Standard_B2s"
}


variable "environment" {
  description = "Environment tag applied to the infrastructure."
  type        = string
  default     = "dev"
}

variable "acr_name" {
  description = "Globally unique ACR name, containing 5-50 alphanumeric characters."
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.acr_name))
    error_message = "ACR name must contain 5-50 alphanumeric characters."
  }
}

variable "key_vault_name" {
  description = "Globally unique Key Vault name (3-24 letters, digits or hyphens)."
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.key_vault_name)) && !strcontains(var.key_vault_name, "--")
    error_message = "Key Vault name must be 3-24 characters, start with a letter, end with a letter/digit and contain no consecutive hyphens."
  }
}
