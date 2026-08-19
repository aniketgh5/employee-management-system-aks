variable "subscription_id" {
  description = "Azure subscription ID where the AKS cluster will be created."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group name."
  type        = string
  default     = "aks-practice-rg"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "centralindia"
}

variable "cluster_name" {
  description = "AKS cluster name."
  type        = string
  default     = "aks-practice-cluster"
}

variable "dns_prefix" {
  description = "DNS prefix for the AKS API server."
  type        = string
  default     = "aks-practice"
}

variable "kubernetes_version" {
  description = "AKS Kubernetes version. Empty string lets Azure choose the default version."
  type        = string
  default     = null
}

variable "node_count" {
  description = "Number of nodes in the default node pool."
  type        = number
  default     = 1
}

variable "node_vm_size" {
  description = "VM size for practice cluster nodes."
  type        = string
  default     = "Standard_B2s"
}

