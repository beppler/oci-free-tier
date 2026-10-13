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
  type    = string
  default = "~/.oci/api_key.pem"
}

variable "compartment_id" {
  type = string
}

variable "availability_domain" {
  type    = string
  default = "tWkk:SA-SAOPAULO-1-AD-1"
}

variable "region" {
  type    = string
  default = "sa-saopaulo-1"
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

variable "bucket_name" {
  type    = string
  default = "bucket-free"
}

variable "state_bucket_name" {
  type    = string
  default = "bucket-free-state"
}

variable "object_storage_quota_gb" {
  type    = number
  default = 20
}

variable "enforce_object_storage_quota" {
  type    = bool
  default = true
}

variable "bucket_vm_access" {
  type    = bool
  default = true
}

variable "bucket_client_access" {
  type    = bool
  default = true
}

variable "bucket_client_user_name" {
  type    = string
  default = "bucket-free-client"
}

variable "bucket_client_email" {
  type    = string
  default = null
}
