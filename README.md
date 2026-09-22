# OCI Ampere A1 Free Tier VM

A guide to provisioning an Always Free Ampere A1 VM on Oracle Cloud with Terraform - VCN, public subnet, internet gateway, route table, security list, the A1 instance itself, and optionally DNS labels, IPv6, and a reserved public IP.

---

## 1. Why Terraform for this

- **State tracking**: Terraform remembers exactly what it created (`terraform.tfstate`) and can tell you what's changed or drifted, so you always know what's actually deployed.
- **Idempotent by default**: `terraform apply` only changes what's different from the last run - safe to run repeatedly without worrying about duplicating resources.
- **One place to see everything**: a handful of `.tf` files describe the whole stack, with resources referencing each other directly instead of you tracking OCIDs by hand.
- **Trade-off**: less control over retry behavior - Ampere A1 capacity errors ("Out of capacity") aren't retried automatically by Terraform (more on this in section 12).

## 2. Install Terraform and set up the OCI provider

**Linux (Ubuntu/Debian):**

```bash
sudo apt update && sudo apt install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
```

**Windows (winget):**

```powershell
winget install HashiCorp.Terraform
```

Verify it installed correctly in a new terminal window (winget updates `PATH`, but existing terminal sessions won't see it until reopened):

```powershell
terraform -version
```

Next, set up authentication - Terraform uses its own API key rather than reusing anything from the OCI CLI.

A Windows-specific note for later sections: both `private_key_path` and `ssh_public_key_path` are resolved through `pathexpand()` (section 5), so `~/...` works unchanged in `terraform.tfvars` on either OS - no backslash/forward-slash concerns to worry about for either value. Everything else in this guide - the `.tf` files themselves and the `terraform init/plan/apply/destroy` commands - works identically on Windows.

Terraform needs its own OCI API credentials, independent of anything the OCI CLI has configured - set that up next.

## 3. Set up OCI API authentication (standalone, not via the OCI CLI)

Terraform's OCI provider authenticates with an **API signing key** - a public/private RSA key pair, where the public key is uploaded to your OCI user account and the private key stays on your machine. This is the same underlying mechanism the OCI CLI uses, but here we generate and wire it up directly for Terraform rather than relying on `oci setup config` or anything in `~/.oci/`.

**1. Generate the key pair**

**Linux (Ubuntu/Debian):**

```bash
mkdir -p ~/.oci-terraform
openssl genrsa -out ~/.oci-terraform/oci_terraform_api_key.pem 2048
openssl rsa -pubout -in ~/.oci-terraform/oci_terraform_api_key.pem -out ~/.oci-terraform/oci_terraform_api_key_public.pem
chmod 600 ~/.oci-terraform/oci_terraform_api_key.pem
```

**Windows (PowerShell 7.1+), no OpenSSL needed** — uses .NET's built-in RSA classes:

```powershell
mkdir "$env:USERPROFILE\.oci-terraform" -Force
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$privateKeyPem = $rsa.ExportRSAPrivateKeyPem()
$publicKeyPem  = $rsa.ExportSubjectPublicKeyInfoPem()
Set-Content -Path "$env:USERPROFILE\.oci-terraform\oci_terraform_api_key.pem" -Value $privateKeyPem -NoNewline
Set-Content -Path "$env:USERPROFILE\.oci-terraform\oci_terraform_api_key_public.pem" -Value $publicKeyPem -NoNewline
```

Check `$PSVersionTable.PSVersion` first — this needs PowerShell 7.1+ (`pwsh.exe`), not the built-in Windows PowerShell 5.1, which lacks the `Pem` export methods. Install with `winget install Microsoft.PowerShell` if needed. The output format matches what OpenSSL produces (PKCS#1 private key, standard SPKI public key), so OCI accepts it the same way.

**2. Upload the public key to your OCI user account**

1. Console → click your **profile icon** (top right) → **My profile**
2. Under **Resources**, click **API keys** → **Add API Key**
3. Choose **Paste public key**, paste the contents of `oci_terraform_api_key_public.pem`
4. Click **Add** - OCI shows a **configuration file preview** with your `user`, `tenancy`, `region`, and **fingerprint** values. Copy the **fingerprint** shown here; you'll need it below.

**3. Collect the four values Terraform needs**

- **Tenancy OCID** - profile icon → **Tenancy: <name>**, copy the OCID shown there
- **User OCID** - profile icon → **My profile**, copy the OCID shown there
- **Fingerprint** - from step 2 above
- **Private key path** - wherever you saved `oci_terraform_api_key.pem`

Keep these somewhere safe (a password manager, not committed to git) - they go into `terraform.tfvars` in section 10.

## 4. Project structure

```text
oci-infrastructure/
├── providers.tf
├── variables.tf
├── network.tf
├── compute.tf
├── outputs.tf
└── terraform.tfvars       # your actual values - keep this out of git
```

## 5. `providers.tf`

```hcl
terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"   # 5.x predates the `lifetime` argument on oci_core_ipv6 (reserved IPv6)
    }
  }
}

locals {
  # pathexpand() resolves ~ to the actual home directory at apply time both on Linux and Windows
  private_key_path = pathexpand(var.private_key_path)
  ssh_public_key_path = pathexpand(var.ssh_public_key_path)
}

provider "oci" {
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = local.private_key_path
  region           = var.region
}
```

This is self-contained - it doesn't read `~/.oci/config` at all, so it works the same whether or not the OCI CLI is installed or configured on the machine.

## 6. `variables.tf`

```hcl
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
  default = "sa-saopaulo-1"
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
  default = false
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
  default = "~/.ssh/id_rsa.pub"
}

variable "reserve_public_ip" {
  type    = bool
  default = true
}
```

## 7. `network.tf`

This creates the VCN, internet gateway, route table, security list, and public subnet.

```hcl
resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_id
  cidr_block     = var.vcn_cidr
  display_name   = var.vcn_name
  dns_label      = var.vcn_dns_label != "" ? var.vcn_dns_label : null
  is_ipv6enabled = var.enable_ipv6
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  dynamic "route_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination       = "::/0"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_internet_gateway.this.id
    }
  }
}

resource "oci_core_security_list" "this" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.vcn_name}-seclist"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  dynamic "egress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      destination      = "::/0"
      destination_type = "CIDR_BLOCK"
      protocol         = "all"
    }
  }

  # TCP ports: SSH, HTTP, HTTPS - IPv4
  dynamic "ingress_security_rules" {
    for_each = { ssh = 22, http = 80, https = 443 }
    content {
      source   = "0.0.0.0/0"
      protocol = "6"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  # ICMP (ping) - IPv4
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1"
    icmp_options {
      type = 8
    }
  }

  # Same set again for IPv6, only if enabled
  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? { ssh = 22, http = 80, https = 443 } : {}
    content {
      source      = "::/0"
      source_type = "CIDR_BLOCK"
      protocol    = "6"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }
  dynamic "ingress_security_rules" {
    for_each = var.enable_ipv6 ? [1] : []
    content {
      source      = "::/0"
      source_type = "CIDR_BLOCK"
      protocol    = "58"
      icmp_options {
        type = 128
      }
    }
  }
}

resource "oci_core_subnet" "this" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.vcn_cidr
  ipv6cidr_block              = var.enable_ipv6 ? cidrsubnet(oci_core_vcn.this.ipv6cidr_blocks[0], 8, 0) : null
  display_name                = var.subnet_name
  dns_label                   = var.subnet_dns_label != "" ? var.subnet_dns_label : null
  route_table_id               = oci_core_route_table.this.id
  security_list_ids            = [oci_core_security_list.this.id]
  prohibit_public_ip_on_vnic   = false
}
```

## 8. `compute.tf`

This creates the A1 instance and, optionally, reserved public IPs (IPv4 and IPv6 use entirely different OCI resources for this - see the note after the code).

```hcl
data "oci_core_images" "ubuntu_aarch64" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "this" {
  compartment_id      = var.compartment_id
  availability_domain = var.availability_domain
  display_name         = var.instance_display_name
  shape                 = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_aarch64.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.this.id
    assign_public_ip = true
    hostname_label   = var.instance_display_name
    # Only auto-assign an ephemeral IPv6 here if we're NOT going to reserve one
    # below - reserving uses a separate oci_core_ipv6 resource instead.
    assign_ipv6ip    = var.enable_ipv6 && !var.reserve_public_ip
  }

  metadata = {
    ssh_authorized_keys = file(local.ssh_public_key_path)
  }

  # Prevents Terraform from destroying/recreating an already-running instance
  # over two things that commonly drift without meaning anything changed:
  # - metadata: file()'s exact bytes (e.g. trailing newline) rarely match
  #   what's actually stored, byte-for-byte, on an imported instance
  # - source_details[0].source_id: the image data source always resolves to
  #   the newest matching image, which won't match whatever image OCID the
  #   instance originally booted from
  lifecycle {
    ignore_changes = [
      metadata,
      source_details[0].source_id,
    ]
  }
}

# --- Reserved public IPv4 (stays fixed across stop/start) ---
resource "oci_core_public_ip" "reserved_ipv4" {
  count          = var.reserve_public_ip ? 1 : 0
  compartment_id = var.compartment_id
  lifetime       = "RESERVED"
  display_name   = "${var.instance_display_name}-reserved-ip"
  private_ip_id  = data.oci_core_private_ips.instance_private_ip.private_ips[0].id
}

data "oci_core_private_ips" "instance_private_ip" {
  ip_address = oci_core_instance.this.private_ip
  subnet_id  = oci_core_subnet.this.id
}

# --- Reserved IPv6 (separate resource type - IPv4/IPv6 reservation work differently in OCI) ---
data "oci_core_vnic_attachments" "instance_vnics" {
  compartment_id = var.compartment_id
  instance_id    = oci_core_instance.this.id
}

resource "oci_core_ipv6" "reserved_ipv6" {
  count           = (var.enable_ipv6 && var.reserve_public_ip) ? 1 : 0
  vnic_id         = data.oci_core_vnic_attachments.instance_vnics.vnic_attachments[0].vnic_id
  subnet_id       = oci_core_subnet.this.id
  display_name    = "${var.instance_display_name}-reserved-ipv6"
  lifetime        = "RESERVED"
}
```

**Why IPv6 needs its own block:** OCI's IPv4 and IPv6 reservation are unrelated mechanisms. `oci_core_public_ip` (IPv4) creates a separate public IP *object* that attaches to an existing private IP - the private IP itself never changes. `oci_core_ipv6`, by contrast, *is* the address itself, directly on the VNIC - there's no separate "public IPv6 object" layered on top. That's why the instance's `assign_ipv6ip` is turned off when reserving: creating `oci_core_ipv6` with `lifetime = "RESERVED"` is what actually gets your instance its IPv6 address in that case, rather than layering a reservation on top of an auto-assigned ephemeral one.

## 9. `outputs.tf`

```hcl
output "instance_public_ip" {
  value = var.reserve_public_ip ? oci_core_public_ip.reserved_ipv4[0].ip_address : oci_core_instance.this.public_ip
}

output "instance_private_ip" {
  value = oci_core_instance.this.private_ip
}

output "instance_public_ipv6" {
  value = (
    !var.enable_ipv6 ? "IPv6 not enabled" :
    var.reserve_public_ip ? oci_core_ipv6.reserved_ipv6[0].ip_address :
    "assigned (ephemeral) - check the instance's VNIC in the console for the address"
  )
}

output "fqdn" {
  value = (var.vcn_dns_label != "" && var.subnet_dns_label != "") ? "${var.instance_display_name}.${var.subnet_dns_label}.${var.vcn_dns_label}.oraclevcn.com" : "DNS labels not set"
}
```

## 10. `terraform.tfvars`

```hcl
tenancy_ocid         = "ocid1.tenancy.oc1..your-tenancy-ocid"
user_ocid            = "ocid1.user.oc1..your-user-ocid"
fingerprint          = "xx:xx:xx:xx:...your-key-fingerprint"
private_key_path     = "~/.oci-terraform/oci_api_key.pem"   # same on Linux and Windows - see local.private_key_path in providers.tf

compartment_id       = "ocid1.tenancy.oc1..your-real-ocid"
availability_domain  = "tWkk:SA-SAOPAULO-1-AD-1"
enable_ipv6          = false
```

Add `terraform.tfvars` to `.gitignore` - it now holds your private key path and account identifiers alongside everything else.

## 11. Running it

```bash
terraform init      # downloads the OCI provider
terraform plan       # shows exactly what will be created - review before applying
terraform apply       # creates everything; type "yes" to confirm
```

To tear it all down later:

```bash
terraform destroy
```

Terraform figures out the correct dependency order automatically (subnet → IGW → route table → security list → VCN, in reverse of creation).

## 12. Adopting an already-existing VM instead of creating a new one

If you already created the VCN/subnet/instance some other way (e.g. by hand in the console, or with separate scripts) **before** running `terraform apply` for the first time, don't just run `apply` - Terraform has no record of those resources yet, so `plan` will propose creating everything from scratch. Applying that as-is risks a duplicate instance, a `hostname_label` conflict in the subnet, or - since Always Free Ampere A1 is capped at 2 OCPU/12GB **total** - pushing you over the free-tier quota if your existing VM is already using it.

Instead, **import** the existing resources into Terraform's state so it manages what's already there rather than creating new copies:

```bash
terraform import oci_core_vcn.this [existing-vcn-ocid]
terraform import oci_core_internet_gateway.this [existing-igw-ocid]
terraform import oci_core_route_table.this [existing-route-table-ocid]
terraform import oci_core_security_list.this [existing-security-list-ocid]
terraform import oci_core_subnet.this [existing-subnet-ocid]
terraform import oci_core_instance.this [existing-instance-ocid]
terraform import oci_core_public_ip.reserved_ipv4[0] [existing-reserved-ip-ocid]   # only if you already have a reserved IP
```

Find each OCID either in the console (each resource's details page) or via the CLI, e.g.:

```bash
oci network vcn list --compartment-id [compartment-ocid] --query 'data[].{Name:"display-name", OCID:id}' --output table

oci network internet-gateway list --compartment-id [compartment-ocid] --vcn-id [vcn-ocid] --query 'data[].{Name:"display-name", OCID:id}' --output table

oci network route-table list --compartment-id [compartment-ocid] --vcn-id [vcn-ocid] --query 'data[].{Name:"display-name", OCID:id}' --output table

oci network security-list list --compartment-id [compartment-ocid] --vcn-id [vcn-ocid] --query 'data[].{Name:"display-name", OCID:id}' --output table

oci network subnet list --compartment-id [compartment-ocid] --vcn-id [vcn-ocid] --query "data[].{Name:\"display-name\", OCID:id}" --output table

oci compute instance list --compartment-id [compartment-ocid] --query 'data[].{Name:"display-name", OCID:id, State:"lifecycle-state"}' --output table

oci network public-ip list --compartment-id [compartment-ocid] --scope REGION --query 'data[].{IP:"ip-address", Lifetime:lifetime, OCID:id}' --output table
```

The internet gateway, route table, security list, and subnet commands all need `--vcn-id`, so grab the VCN's OCID from the first command before running the rest.

**Skip the `oci_core_public_ip` import** if you haven't reserved an IPv4 yet - leave `reserve_public_ip = true` and Terraform will create one fresh on `apply` instead. Importing is only for adopting one that already exists (e.g. if you ran a reservation step outside Terraform earlier); if you skip it while one already exists, `plan` will propose creating a second reserved IP.

**Not sure whether your current IP is actually reserved?** The `oci network public-ip list` command above only searches `--scope REGION`, which is where *reserved* IPs live - an ephemeral IP won't show up there at all, so an empty result doesn't necessarily mean nothing exists. Check the ephemeral scope too before concluding there's nothing to import:

```bash
oci network public-ip list --compartment-id [compartment-ocid] --scope AVAILABILITY_DOMAIN --availability-domain [your_availability_domain] --query 'data[].{IP:"ip-address", Lifetime:lifetime, OCID:id}' --output table
```

If your instance's IP shows up here with `Lifetime: EPHEMERAL`, there's genuinely nothing reserved to import - proceed as above and let Terraform create one. Don't rely on the console's IP lifetime label alone to decide; it can be stale (e.g. after a VNIC change), so treat this CLI query as the authoritative check. One thing worth knowing before applying in that case: reserving an already-running ephemeral IP through Terraform doesn't guarantee you keep the *same* address - OCI may assign a different one when the new reserved object is created, so double check any DNS records or bookmarks pointing at the old IP afterward.

**After each import, run `terraform plan`.** It will show a diff between the real, already-deployed resource and what your `.tf` files currently describe (a `plan` after import never proposes destroying/recreating on its own — it just shows drift). Adjust the values in your `.tf`/`terraform.tfvars` files — not the actual infrastructure — until `plan` reports no changes for that resource. That confirms Terraform's config now accurately matches what's really running.

A few things likely to need adjusting after import:

- `vcn_cidr`, `vcn_name`, `subnet_name` — match whatever you actually used
- `enable_ipv6` — set based on whether IPv6 was already added
- `ocpus` / `memory_in_gbs` / `boot_volume_size_gb` — match the instance's real shape config
- The security list's rule set — if you added custom rules by hand (like the ICMP ones), the generated `network.tf` needs to include them too, or `plan` will keep showing a diff trying to remove them

The image data source (`data.oci_core_images.ubuntu_aarch64`) never needs importing — it's a lookup, not a managed resource. Note that it always resolves to the *newest* matching image, which is exactly why the `lifecycle.ignore_changes` block in section 8's `compute.tf` exists — without it, Terraform would try to replace your instance the moment a newer Ubuntu 24.04 aarch64 image gets published.

## 13. The "Out of capacity" problem

Ampere A1 is in high demand, and `terraform apply` fails immediately on `Out of capacity` errors - it does **not** retry automatically. A couple of ways to handle it:

**Simplest - wrap `terraform apply` in a shell loop:**

```bash
until terraform apply -auto-approve; do
  echo "Apply failed (likely capacity) - retrying in 60s..."
  sleep 60
done
```

**Or scope retries to just the instance**, once network resources already exist:

```bash
until terraform apply -auto-approve -target=oci_core_instance.this; do
  sleep 60
done
terraform apply -auto-approve   # picks up the rest (reserved IP, etc.)
```

## 14. State file - a word of caution

`terraform.tfstate` will contain sensitive details about your infrastructure (OCIDs, IPs, etc.) in plain text. Keep it out of git (`echo "*.tfstate*" >> .gitignore`), and if you ever want to collaborate or run Terraform from multiple machines, look into OCI Object Storage as a remote backend rather than passing the local state file around.
