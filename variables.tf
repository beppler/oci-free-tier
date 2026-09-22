variable "tenancy_ocid" {
  type = string
}

variable "user_ocid" {
  type = string
}

variable "fingerprint" {
  type = string
}

variable "private_key_path" {
  type = string
}

variable "compartment_id" {
  type = string
}

variable "region" {
  type    = string
}

variable "availability_domain" {
  type = string
}

variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

variable "vcn_name" {
  type    = string
  default = "vcn-free-public"
}

variable "subnet_name" {
  type    = string
  default = "subnet-free-public"
}

variable "enable_ipv6" {
  type    = bool
  default = true
}

variable "vcn_dns_label" {
  type    = string
  default = "vcnfree"
}

variable "subnet_dns_label" {
  type    = string
  default = "subnetfree"
}

variable "instance_display_name" {
  type    = string
  default = "vm-ampere-free"
}

variable "ocpus" {
  type    = number
  default = 2
}

variable "memory_in_gbs" {
  type    = number
  default = 12
}

variable "boot_volume_size_gb" {
  type    = number
  default = 50
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "reserve_public_ip" {
  type    = bool
  default = true
}
