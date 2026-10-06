# OCI Free Tier Configuration

A guide to provisioning an Always Free Ampere A1 VM on Oracle Cloud with Terraform - VCN, public subnet, internet gateway, route table, security list, the A1 instance itself, a private Object Storage bucket capped at the 20 GB free allowance, a second bucket for remote Terraform state, and optionally DNS labels, IPv6, and a reserved public IP.

---

## 1. Why Terraform for this

- **State tracking**: Terraform remembers exactly what it created (`terraform.tfstate`) and can tell you what's changed or drifted, so you always know what's actually deployed.
- **Idempotent by default**: `terraform apply` only changes what's different from the last run - safe to run repeatedly without worrying about duplicating resources.
- **One place to see everything**: a handful of `.tf` files describe the whole stack, with resources referencing each other directly instead of you tracking OCIDs by hand.
- **Trade-off**: less control over retry behavior - Ampere A1 capacity errors ("Out of capacity") aren't retried automatically by Terraform (more on this in section 14).

## 2. Install Terraform and set up the OCI provider

**Linux (Ubuntu/Debian):**

```bash
sudo apt update && sudo apt install -y gnupg software-properties-common
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
```

**macOS (Homebrew):**

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

Use HashiCorp's own tap rather than plain `brew install terraform`. Since the license change, Homebrew's core `terraform` formula is frozen at 1.5.7 and gets no new releases. Upgrade later with `brew upgrade hashicorp/tap/terraform`.

**Windows (winget):**

```powershell
winget install HashiCorp.Terraform
```

Verify it installed correctly in a new terminal window (winget updates `PATH`, but existing terminal sessions won't see it until reopened):

```bash
terraform -version
```

Next, set up authentication - Terraform uses its own API key rather than reusing anything from the OCI CLI.

A Windows-specific note for later sections: both `private_key_path` and `ssh_public_key_path` are resolved through `pathexpand()` (section 5), so `~/...` works unchanged in `terraform.tfvars` on either OS - no backslash/forward-slash concerns to worry about for either value. Everything else in this guide - the `.tf` files themselves and the `terraform init/plan/apply/destroy` commands - works identically on Windows.

Terraform needs its own OCI API credentials, independent of anything the OCI CLI has configured - set that up next.

## 3. Set up OCI API authentication (standalone, not via the OCI CLI)

Terraform's OCI provider authenticates with an **API signing key** - a public/private RSA key pair, where the public key is uploaded to your OCI user account and the private key stays on your machine. This is the same underlying mechanism the OCI CLI uses, but here we generate and wire it up directly for Terraform rather than relying on `oci setup config`. The key files go in `~/.oci/`, the conventional location, but Terraform reads the key file directly and never reads `~/.oci/config`.

### 3.1. Generate the key pair

**Linux / macOS:**

```bash
mkdir -p ~/.oci
openssl genrsa -out ~/.oci/api_key.pem 2048
openssl rsa -pubout -in ~/.oci/api_key.pem -out ~/.oci/api_key_public.pem
echo "OCI_API_KEY" >> ~/.oci/api_key.pem
chmod 600 ~/.oci/api_key.pem
```

**Windows (PowerShell 7.1+), no OpenSSL needed** — uses .NET's built-in RSA classes:

```powershell
mkdir "$env:USERPROFILE\.oci" -Force
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
$privateKeyPem = $rsa.ExportRSAPrivateKeyPem()
$publicKeyPem  = $rsa.ExportSubjectPublicKeyInfoPem()
Set-Content -Path "$env:USERPROFILE\.oci\api_key.pem" -Value ($privateKeyPem + "`nOCI_API_KEY`n") -NoNewline
Set-Content -Path "$env:USERPROFILE\.oci\api_key_public.pem" -Value $publicKeyPem -NoNewline
```

Check `$PSVersionTable.PSVersion` first — this needs PowerShell 7.1+ (`pwsh.exe`), not the built-in Windows PowerShell 5.1, which lacks the `Pem` export methods. Install with `winget install Microsoft.PowerShell` if needed. The output format matches what OpenSSL produces (PKCS#1 private key, standard SPKI public key), so OCI accepts it the same way.

Both versions append an `OCI_API_KEY` line after the end of the private key. This is the label OCI puts on keys downloaded from the console, so secret scanners can recognize the file as an OCI API key. OCI tools ignore the extra line when reading the key; without it, the OCI CLI prints a warning suggesting you add it.

### 3.2. Upload the public key to your OCI user account

1. Console → click your **profile icon** (top right) → **My profile**
2. Under **Resources**, click **API keys** → **Add API Key**
3. Choose **Paste public key**, paste the contents of `api_key_public.pem`
4. Click **Add** - OCI shows a **configuration file preview** with your `user`, `tenancy`, `region`, and **fingerprint** values. Copy the **fingerprint** shown here; you'll need it below.

### 3.3. Collect the four values Terraform needs

- **Tenancy OCID** - profile icon → **Tenancy: [name]**, copy the OCID shown there
- **User OCID** - profile icon → **My profile**, copy the OCID shown there
- **Fingerprint** - from step 2 above
- **Private key path** - `~/.oci/api_key.pem` is the default, so you only need to set `private_key_path` if you saved the key somewhere else

Keep these somewhere safe (a password manager, not committed to git) - they go into `terraform.tfvars` in section 11.

## 4. Project structure

```text
/
├── providers.tf           # provider pin, credentials, path handling
├── variables.tf           # every input and its default
├── network.tf             # VCN, IGW, route table, security list, subnet
├── compute.tf             # image lookup, A1 instance, reserved IPs
├── storage.tf             # Object Storage buckets (data + state), 20 GB quota, VM + client access
├── outputs.tf             # what apply prints when it finishes
├── .gitattributes         # normalizes line endings to LF
├── terraform.tfstate      # know current state - keep this out of git (until moved to the state bucket, section 15)
├── backend.tf             # optional, you create it in section 15 - remote state in the state bucket
├── backend.hcl            # optional, section 15 - backend credentials, keep this out of git
└── terraform.tfvars       # your actual values - keep this out of git
```

Sections 5-10 below describe what each file contains and why, rather than reproducing it. The files themselves are in this repository and are the authoritative version - read them alongside the descriptions when you want the exact HCL.

## 5. `providers.tf`

Pins the provider and normalizes the two filesystem paths Terraform needs.

- **`terraform.required_providers`** - pins `oracle/oci` to `~> 7.0`. The 5.x line predates the `lifetime` argument on `oci_core_ipv6`, so reserved IPv6 (section 8) won't work on it.
- **`locals`** - runs both `var.private_key_path` and `var.ssh_public_key_path` through `pathexpand()`, which resolves a leading `~` to the real home directory at apply time on Linux *and* Windows. This is why `~/...` paths in `terraform.tfvars` need no OS-specific quoting.
- **`provider "oci"`** - wires tenancy, user, fingerprint, private key, and region straight from variables.

The provider block is fully self-contained: it never reads `~/.oci/config`, so it behaves identically whether or not the OCI CLI is installed or configured on the machine.

## 6. `variables.tf`

Every input the configuration takes. Six have no default and must be supplied in `terraform.tfvars`; the rest are tuned for the Always Free tier and only need changing if you want something different.

**Required - no defaults:**

| Variable | Type | Purpose |
| --- | --- | --- |
| `tenancy_ocid` | string | Tenancy OCID (section 3) |
| `user_ocid` | string | User OCID (section 3) |
| `fingerprint` | string | API key fingerprint (section 3) |
| `compartment_id` | string | Compartment the resources are created in |

**Optional - with defaults:**

| Variable | Type | Default | Purpose |
| --- | --- | --- | --- |
| `private_key_path` | string | `~/.oci/api_key.pem` | Path to the API signing private key; `~` is expanded |
| `availability_domain` | string | `tWkk:SA-SAOPAULO-1-AD-1` | Target Availability Domain |
| `region` | string | `sa-saopaulo-1` | Target Region |
| `vcn_cidr` | string | `10.0.0.0/24` | VCN CIDR; the subnet reuses it verbatim |
| `vcn_name` | string | `vcn-free-public` | VCN display name; also prefixes the IGW/route table/security list names |
| `subnet_name` | string | `subnet-free-public` | Subnet display name |
| `enable_ipv6` | bool | `true` | Adds IPv6 to the VCN, subnet, routes, and security rules |
| `vcn_dns_label` | string | `vcnfree` | VCN DNS label; empty string disables DNS |
| `subnet_dns_label` | string | `subnetfree` | Subnet DNS label; empty string disables DNS |
| `instance_display_name` | string | `vm-ampere-free` | Instance name, `hostname_label`, and reserved-IP name prefix |
| `ocpus` | number | `2` | OCPUs - the Always Free ceiling |
| `memory_in_gbs` | number | `12` | RAM - the Always Free ceiling |
| `boot_volume_size_gb` | number | `50` | Boot volume size |
| `ssh_public_key_path` | string | `~/.ssh/id_rsa.pub` | SSH public key injected into the instance; `~` is expanded |
| `reserve_public_ip` | bool | `true` | Reserve the public IPv4 (and IPv6) instead of letting OCI assign ephemeral ones |
| `bucket_name` | string | `bucket-free` | Object Storage bucket name |
| `state_bucket_name` | string | `bucket-free-state` | Bucket that holds the remote Terraform state (section 15) |
| `object_storage_quota_gb` | number | `20` | Object Storage quota in GB - the Always Free ceiling |
| `enforce_object_storage_quota` | bool | `true` | Create the tenancy quota policy that enforces `object_storage_quota_gb` (needs tenancy admin) |
| `bucket_vm_access` | bool | `true` | Let the VM use the bucket through instance principal (dynamic group + policy) |
| `bucket_client_access` | bool | `true` | Create the dedicated bucket-only user, group, policy, and API key for other clients |
| `bucket_client_user_name` | string | `bucket-free-client` | That user's name; also prefixes its group and policy names |
| `bucket_client_email` | string | `null` | Email for that user; needed only in tenancies whose identity domain requires one |
| `bucket_client_public_key_path` | string | `~/.oci/bucket_client_api_key_public.pem` | Public key uploaded as the user's API key; `~` is expanded |

`ocpus` and `memory_in_gbs` sit exactly on the Always Free cap of 2 OCPU / 12 GB **per tenancy**. Raising either one, or running a second A1 instance alongside this one, takes you off the free tier.

## 7. `network.tf`

Creates the VCN, internet gateway, route table, security list, and public subnet. IPv6 support is threaded through all five via `dynamic` blocks keyed on `var.enable_ipv6`, so flipping that one variable adds or removes the whole IPv6 path.

- **`oci_core_vcn.this`** - the VCN, at `var.vcn_cidr`, with `is_ipv6enabled` following `enable_ipv6`. A blank `vcn_dns_label` is converted to `null` so DNS can be turned off cleanly.
- **`oci_core_internet_gateway.this`** - an enabled IGW named `<vcn_name>-igw`.
- **`oci_core_route_table.this`** - a default route `0.0.0.0/0` to the IGW, plus a `::/0` rule added dynamically when IPv6 is on.
- **`oci_core_security_list.this`** - egress open to everything (`0.0.0.0/0`, plus `::/0` when enabled). Ingress opens SSH/HTTP/HTTPS (22, 80, 443) over TCP and ICMP echo for ping, and the same set is emitted again for IPv6 - protocol `58` (ICMPv6) with `type = 128` instead of protocol `1` / `type = 8`.
- **`oci_core_subnet.this`** - a public subnet (`prohibit_public_ip_on_vnic = false`) that reuses the full VCN CIDR. Its IPv6 range is carved out with `cidrsubnet(oci_core_vcn.this.ipv6cidr_blocks[0], 8, 0)`, giving the first /64 of the VCN's assigned /56.

The TCP ingress rules are generated from a `{ ssh = 22, http = 80, https = 443 }` map, so opening another port is a one-line change to that map rather than a new hand-written block. If you add rules by hand in the console instead, `plan` will keep proposing to remove them - see section 13.

## 8. `compute.tf`

Creates the A1 instance and, optionally, its reserved public IPs. IPv4 and IPv6 reservation use entirely different OCI resources - see the note at the end of this section.

- **`data.oci_core_images.ubuntu_aarch64`** - looks up the newest Canonical Ubuntu 24.04 image built for `VM.Standard.A1.Flex` (aarch64), sorted by creation time descending, and takes `images[0]`.
- **`oci_core_instance.this`** - the VM itself: shape `VM.Standard.A1.Flex` sized by `ocpus`/`memory_in_gbs`, booting the image above at `boot_volume_size_gb`. Its VNIC gets a public IPv4 and a `hostname_label`; your SSH public key is injected through `metadata.ssh_authorized_keys`.
- **`data.oci_core_private_ips.instance_private_ip`** - resolves the instance's private IP to the private-IP OCID that a reserved public IPv4 has to attach to.
- **`oci_core_public_ip.reserved_ipv4`** - created only when `reserve_public_ip` is true; a `RESERVED` public IPv4 that survives stop/start.
- **`data.oci_core_vnic_attachments.instance_vnics`** - finds the instance's VNIC, needed by the IPv6 resource below.
- **`oci_core_ipv6.reserved_ipv6`** - created only when `enable_ipv6` *and* `reserve_public_ip` are both true; a `RESERVED` IPv6 address on that VNIC.

Two details in this file are easy to break:

**`assign_ipv6ip` is deliberately `var.enable_ipv6 && !var.reserve_public_ip`.** The instance auto-assigns an ephemeral IPv6 only when you are *not* reserving one; the reserved path creates the address through `oci_core_ipv6` instead. The two are mutually exclusive, not additive.

**The `lifecycle.ignore_changes` block is load-bearing.** It ignores:

- `metadata` - the exact bytes `file()` reads (a trailing newline, for instance) rarely match byte-for-byte what OCI stored on an already-running or imported instance
- `source_details[0].source_id` - the image data source always resolves to the *newest* matching image, which won't match whatever image the instance actually booted from

Without it, Terraform proposes destroying and recreating a live instance every time Canonical publishes a new 24.04 image.

**Why IPv6 needs its own resource:** OCI's IPv4 and IPv6 reservation are unrelated mechanisms. `oci_core_public_ip` (IPv4) creates a separate public IP *object* that attaches to an existing private IP - the private IP itself never changes. `oci_core_ipv6`, by contrast, *is* the address itself, directly on the VNIC - there's no separate "public IPv6 object" layered on top. That's why the instance's `assign_ipv6ip` is turned off when reserving: creating `oci_core_ipv6` with `lifetime = "RESERVED"` is what actually gets your instance its IPv6 address in that case, rather than layering a reservation on top of an auto-assigned ephemeral one.

## 9. `storage.tf`

Creates a private Object Storage bucket for your data and a second one for Terraform state, caps usage at the Always Free allowance, lets the VM use the bucket without API keys stored on it, and creates a dedicated bucket-only user for other clients.

The key thing to understand is that **the 20 GB is not allocated to anything.** A bucket has no size; it grows with whatever you put in it. Always Free covers the first 20 GB stored in the tenancy (Standard, Infrequent Access, and Archive combined), and anything beyond that is billed. So the data bucket can use practically all 20 GB, the state bucket takes a few KB of it, and the quota stops you from going over.

- **`data.oci_objectstorage_namespace.this`** - looks up the tenancy's Object Storage namespace. Every bucket name and URL is scoped by this namespace.
- **`oci_objectstorage_bucket.this`** - the bucket. It has `NoPublicAccess` (nothing is reachable without authentication) and the `Standard` tier. `versioning` is `Disabled` on purpose, because old object versions would silently count toward the 20 GB.
- **`oci_objectstorage_bucket.state`** - holds `terraform.tfstate` once you switch to the remote backend (section 15). It's private and `Standard` like the data bucket, but `versioning` is `Enabled`: every state write keeps the previous version, so a bad apply can be rolled back. State files are a few KB, so the extra versions barely touch the 20 GB. Neither the VM nor the bucket client user gets access to it.
- **`oci_limits_quota.object_storage`** - a quota policy, `set object-storage quota storage-bytes to <bytes> in tenancy`, with the byte count computed from `object_storage_quota_gb`. Once the limit is reached, uploads fail instead of being billed. The quota is regional, so it covers this `region`. Quota policies must be created in the **root compartment**, and creating one needs tenancy-admin rights. If your API user doesn't have those rights, set `enforce_object_storage_quota = false` and keep an eye on usage in the console.
- **`oci_identity_dynamic_group.vm`** - a dynamic group whose matching rule is exactly this instance's OCID. It lives in the root compartment, like all dynamic groups.
- **`oci_identity_policy.vm_bucket`** - allows that dynamic group to `read buckets` and `manage objects`, restricted by `target.bucket.name` to this one bucket.

The dynamic group and policy are created only when `bucket_vm_access` is true. From your own machine you need nothing extra, because your API key already has access. On the VM, install the OCI CLI (for example, `pip install oci-cli`) and authenticate as the instance itself:

```bash
oci os object put  --auth instance_principal -bn bucket-free --file ./backup.tar.gz
oci os object list --auth instance_principal -bn bucket-free
```

Newly created dynamic groups and policies can take a few minutes to take effect, so an early `NotAuthorizedOrNotFound` error usually just means you need to wait.

**Access from other clients** (other machines, people, backup tools) uses a dedicated user instead of your admin key. These resources are created only when `bucket_client_access` is true:

- **`oci_identity_user.bucket_client`** - the user, `bucket_client_user_name`, created in the root compartment. Some tenancies that use identity domains reject new users without an email address; if yours does, set `bucket_client_email`.
- **`oci_identity_user_capabilities_management.bucket_client`** - limits the user to API keys and Customer Secret Keys, with no console password, auth tokens, or SMTP credentials.
- **`oci_identity_group.bucket_client`** and **`oci_identity_user_group_membership.bucket_client`** - a group containing the user, which is what the policy grants access to.
- **`oci_identity_policy.bucket_client`** - the same two bucket-only statements the VM gets.
- **`oci_identity_api_key.bucket_client`** - uploads the public key found at `bucket_client_public_key_path`. Only the public key goes to OCI, so nothing secret ends up in `terraform.tfstate`.

Generate the key pair **before** running `plan`, because `plan` fails if the public key file doesn't exist.

**Linux / macOS:**

```bash
mkdir -p ~/.oci
openssl genrsa -out ~/.oci/bucket_client_api_key.pem 2048
openssl rsa -pubout -in ~/.oci/bucket_client_api_key.pem -out ~/.oci/bucket_client_api_key_public.pem
echo "OCI_API_KEY" >> ~/.oci/bucket_client_api_key.pem
chmod 600 ~/.oci/bucket_client_api_key.pem
```

**Windows (PowerShell 7.1+)** - the same .NET approach as section 3:

```powershell
mkdir "$env:USERPROFILE\.oci" -Force
$rsa = [System.Security.Cryptography.RSA]::Create(2048)
Set-Content -Path "$env:USERPROFILE\.oci\bucket_client_api_key.pem" -Value ($rsa.ExportRSAPrivateKeyPem() + "`nOCI_API_KEY`n") -NoNewline
Set-Content -Path "$env:USERPROFILE\.oci\bucket_client_api_key_public.pem" -Value $rsa.ExportSubjectPublicKeyInfoPem() -NoNewline
```

Then copy the private key to each client and point an OCI config profile at it, using the `bucket_client_user_ocid` and `bucket_client_key_fingerprint` outputs:

```ini
[bucket-client]
user        = <bucket_client_user_ocid>
fingerprint = <bucket_client_key_fingerprint>
tenancy     = <tenancy_ocid>
region      = <region>
key_file    = ~/.oci/bucket_client_api_key.pem
```

The profile goes in the OCI CLI's config file: `~/.oci/config` on Linux and macOS, `%USERPROFILE%\.oci\config` on Windows. Put it next to any profile you already have there. With that profile, the OCI CLI and SDKs work with `--profile bucket-client`:

```bash
# Upload, list, download, delete single objects
oci os object put    --profile bucket-client -bn bucket-free --file ./backup.tar.gz
oci os object put    --profile bucket-client -bn bucket-free --file ./backup.tar.gz --name backups/2026-09-28.tar.gz
oci os object list   --profile bucket-client -bn bucket-free --prefix backups/
oci os object get    --profile bucket-client -bn bucket-free --name backups/2026-09-28.tar.gz --file ./restore.tar.gz
oci os object delete --profile bucket-client -bn bucket-free --name backups/2026-09-28.tar.gz

# Whole directories
oci os object bulk-upload   --profile bucket-client -bn bucket-free --src-dir ./photos --prefix photos/
oci os object bulk-download --profile bucket-client -bn bucket-free --download-dir ./restore --prefix photos/
oci os object sync          --profile bucket-client -bn bucket-free --src-dir ./photos --prefix photos/

# Bucket details (approximate size and object count)
oci os bucket get --profile bucket-client -bn bucket-free --fields approximateSize --fields approximateCount
```

To avoid repeating `--profile`, set `OCI_CLI_PROFILE=bucket-client` in the shell (PowerShell: `$env:OCI_CLI_PROFILE = "bucket-client"`). The policy gives this user access to this one bucket only, so `oci os bucket list` returns `NotAuthorizedOrNotFound`. That's expected; always address the bucket directly with `-bn`.

rclone can use the same profile through its native Oracle backend. Add this to `rclone.conf` (`rclone config file` shows where it is):

```ini
[oci-bucket]
type           = oracleobjectstorage
provider       = user_principal_auth
namespace      = <object_storage_namespace>
compartment    = <compartment_id>
region         = <region>
config_file    = ~/.oci/config
config_profile = bucket-client
```

Then, for example: `rclone sync ./photos oci-bucket:bucket-free/photos` or `rclone ls oci-bucket:bucket-free`.

Some tools speak only S3, for example restic, most NAS backup apps, and `aws s3`. For those, create a **Customer Secret Key** by hand for this user: Identity → Users → `bucket-free-client` → **Customer secret keys**. Then point the tool at the `bucket_s3_endpoint` output. This key is deliberately *not* managed by Terraform, because its secret would be stored in plaintext in the state file. The policy above already covers it, and a user can have at most two of these keys.

## 10. `outputs.tf`

What `terraform apply` prints when it finishes (and what `terraform output` replays later).

| Output | Value |
| --- | --- |
| `instance_public_ip` | The reserved IPv4 when `reserve_public_ip` is true, otherwise the instance's ephemeral public IP |
| `instance_private_ip` | The instance's private IP inside the subnet |
| `instance_public_ipv6` | The reserved IPv6 address; or `"IPv6 not enabled"`; or a reminder to check the VNIC in the console when the address is ephemeral |
| `object_storage_namespace` | The tenancy's Object Storage namespace |
| `bucket_name` | The bucket's name |
| `state_bucket_name` | The state bucket's name, for `backend.tf` |
| `bucket_s3_endpoint` | `https://<namespace>.compat.objectstorage.<region>.oraclecloud.com`, for S3-compatible tools |
| `bucket_client_user_ocid` | The bucket client user's OCID, or `"bucket client access not enabled"` |
| `bucket_client_key_fingerprint` | Fingerprint of that user's API key, for the client's OCI config profile |
| `fqdn` | `<instance>.<subnet_dns_label>.<vcn_dns_label>.oraclevcn.com`, or `"DNS labels not set"` if either label is blank |

The IPv6 and FQDN outputs are conditional expressions rather than plain references, because the resources behind them may not exist at all depending on `enable_ipv6` and the DNS labels.

## 11. `terraform.tfvars`

```hcl
tenancy_ocid         = "ocid1.tenancy.oc1..your-tenancy-ocid"
user_ocid            = "ocid1.user.oc1..your-user-ocid"
fingerprint          = "xx:xx:xx:xx:...your-key-fingerprint"
compartment_id       = "ocid1.tenancy.oc1..your-real-ocid"
availability_domain  = "tWkk:SA-SAOPAULO-1-AD-1"
region               = "sa-saopaulo-1"
```

Add `terraform.tfvars` to `.gitignore` - it now holds your private key path and account identifiers alongside everything else.

## 12. Running it

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

## 13. Adopting an already-existing VM instead of creating a new one

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
terraform import oci_objectstorage_bucket.this n/[namespace]/b/[bucket-name]       # only if the bucket already exists
terraform import oci_objectstorage_bucket.state n/[namespace]/b/[state-bucket-name] # only if the state bucket already exists
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

oci os ns get

oci os bucket list --compartment-id [compartment-ocid] --query 'data[].{Name:name, Created:"time-created"}' --output table
```

The internet gateway, route table, security list, and subnet commands all need `--vcn-id`, so grab the VCN's OCID from the first command before running the rest.

**The bucket is the one exception to importing by OCID.** Its import ID is `n/[namespace]/b/[bucket-name]`, built from the output of the last two commands: `oci os ns get` prints the namespace, and `oci os bucket list` shows the bucket names. Set `bucket_name` to match the existing bucket before importing. `access_type`, `storage_tier`, and `versioning` are fixed in `storage.tf`, so check how the existing bucket differs from them before you `apply`:

- **`access_type`** - a mismatch is changed in place.
- **`storage_tier`** - can't be changed after a bucket is created. If the existing bucket isn't `Standard`, `plan` shows it as **must be replaced**, which would delete the bucket and everything in it. Don't apply that. Change `storage_tier` in `storage.tf` to match the bucket instead.
- **`versioning`** - a bucket that has ever had versioning enabled can only be `Suspended`, never `Disabled` again, so applying `Disabled` fails. For such a bucket, set `versioning = "Suspended"` in `storage.tf`. This stops new versions from being kept, but the previous versions already stored remain and still count toward the 20 GB until you delete them.

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

## 14. The "Out of capacity" problem

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

## 15. State file - a word of caution

`terraform.tfstate` will contain sensitive details about your infrastructure (OCIDs, IPs, etc.) in plain text. Keep it out of git (`echo "*.tfstate*" >> .gitignore`). To run Terraform from more than one machine, or simply not lose the state with your laptop, move it into the `bucket-free-state` bucket that `storage.tf` creates.

The bucket has to exist before Terraform can store state in it, so this is a two-step process: run `terraform apply` once with local state as usual (sections 12-13), then switch backends. This uses Terraform's native `oci` backend, which needs **Terraform 1.12 or newer** (`terraform -version`) and also handles state locking.

Create `backend.tf` next to the other `.tf` files:

```hcl
terraform {
  backend "oci" {
    bucket = "bucket-free-state"
    key    = "terraform.tfstate"
  }
}
```

Backend blocks can't read variables, so the remaining settings go in `backend.hcl`, which is in `.gitignore`. Use the same values as `terraform.tfvars`, plus the `object_storage_namespace` output:

```hcl
namespace        = "<object_storage_namespace>"
region           = "sa-saopaulo-1"
tenancy_ocid     = "ocid1.tenancy.oc1..your-tenancy-ocid"
user_ocid        = "ocid1.user.oc1..your-user-ocid"
fingerprint      = "xx:xx:xx:xx:...your-key-fingerprint"
private_key_path = "/home/you/.oci/api_key.pem"
```

Write `private_key_path` as a full path, since `pathexpand()` (section 5) isn't available in backend settings. On Windows, use forward slashes, for example `C:/Users/you/.oci/api_key.pem`.

Then migrate the existing state into the bucket:

```bash
terraform init -backend-config=backend.hcl -migrate-state
```

Answer `yes` when Terraform asks to copy the state. Run `terraform plan` afterwards: it should report no changes. Once it does, delete the local `terraform.tfstate` and `terraform.tfstate.backup`. On any other machine, copy `backend.tf` and `backend.hcl` and run `terraform init -backend-config=backend.hcl`.

To roll back to an earlier state, list the versions with `oci os object list-object-versions -bn bucket-free-state --prefix terraform.tfstate` and download one with `oci os object get --version-id <id>`.

**Before `terraform destroy`**, move the state back to local first. Otherwise destroy removes everything else and then fails on the state bucket, which still holds the state:

```bash
# delete or rename backend.tf, then:
terraform init -migrate-state
terraform destroy
```

Even with local state, destroy can only delete `bucket-free-state` once it's empty, including old object versions. Empty it in the console first (Buckets → `bucket-free-state` → Objects, with **Show deleted objects** on).
