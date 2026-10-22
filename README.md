# OCI Free Tier Configuration

A guide to provisioning an Always Free Ampere A1 VM on Oracle Cloud with OpenTofu - VCN, public subnet, internet gateway, route table, security list, the A1 instance itself, DNS labels, and reserved (fixed) public IPv4 and IPv6 addresses.

---

## 1. Why OpenTofu for this

- **State tracking**: OpenTofu remembers exactly what it created (`terraform.tfstate`) and can tell you what's changed or drifted, so you always know what's actually deployed.
- **Idempotent by default**: `tofu apply` only changes what's different from the last run - safe to run repeatedly without worrying about duplicating resources.
- **One place to see everything**: a handful of `.tf` files describe the whole stack, with resources referencing each other directly instead of you tracking OCIDs by hand.
- **Trade-off**: less control over retry behavior - Ampere A1 capacity errors ("Out of capacity") aren't retried automatically by OpenTofu (more on this in section 13).

## 2. Install OpenTofu and set up the OCI provider

[OpenTofu](https://opentofu.org) is the open-source, MPL-licensed fork of Terraform. It reads the same `.tf` files, `terraform.tfvars`, and `terraform.tfstate`, so those keep their usual names. The CLI command is `tofu`. This guide needs **OpenTofu 1.10 or newer**, which `providers.tf` enforces through `required_version`.

**Linux (Ubuntu/Debian):**

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
chmod +x install-opentofu.sh
./install-opentofu.sh --install-method deb
rm -f install-opentofu.sh
```

The installer adds OpenTofu's signed apt repository, so `sudo apt update && sudo apt upgrade` keeps it current.

**macOS (Homebrew):**

```bash
brew install opentofu
```

OpenTofu is in Homebrew core, so no tap is needed. Upgrade later with `brew upgrade opentofu`.

**Windows (winget):**

```powershell
winget install --exact --id=OpenTofu.Tofu
```

Verify it installed correctly in a new terminal window (winget updates `PATH`, but existing terminal sessions won't see it until reopened):

```bash
tofu -version
```

If you already ran this configuration with Terraform, read section 11.1 before running any `tofu` command against your existing state.

Next, set up authentication - OpenTofu uses its own API key rather than reusing anything from the OCI CLI.

A Windows-specific note for later sections: both `private_key_path` and `ssh_public_key_path` are resolved through `pathexpand()` (section 5), so `~/...` works unchanged in `terraform.tfvars` on either OS - no backslash/forward-slash concerns to worry about for either value. Everything else in this guide - the `.tf` files themselves and the `tofu init/plan/apply/destroy` commands - works identically on Windows.

OpenTofu needs its own OCI API credentials, independent of anything the OCI CLI has configured - set that up next.

## 3. Set up OCI API authentication (standalone, not via the OCI CLI)

OpenTofu's OCI provider authenticates with an **API signing key** - a public/private RSA key pair, where the public key is uploaded to your OCI user account and the private key stays on your machine. This is the same underlying mechanism the OCI CLI uses, but here we generate and wire it up directly for OpenTofu rather than relying on `oci setup config`. The key files go in `~/.oci/`, the conventional location, but OpenTofu reads the key file directly and never reads `~/.oci/config`.

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

### 3.3. Collect the four values OpenTofu needs

- **Tenancy OCID** - profile icon → **Tenancy: [name]**, copy the OCID shown there
- **User OCID** - profile icon → **My profile**, copy the OCID shown there
- **Fingerprint** - from step 2 above
- **Private key path** - `~/.oci/api_key.pem` is the default, so you only need to set `private_key_path` if you saved the key somewhere else

Keep these somewhere safe (a password manager, not committed to git) - they go into `terraform.tfvars` in section 10.

## 4. Project structure

```text
/
├── providers.tf           # provider pin, credentials, path handling
├── variables.tf           # every input and its default
├── network.tf             # VCN, IGW, route table, security list, subnet
├── compute.tf             # image lookup, A1 instance, reserved IPs
├── outputs.tf             # what apply prints when it finishes
├── .gitattributes         # normalizes line endings to LF
├── terraform.tfstate      # know current state - keep this out of git
└── terraform.tfvars       # your actual values - keep this out of git
```

Sections 5-9 below describe what each file contains and why, rather than reproducing it. The files themselves are in this repository and are the authoritative version - read them alongside the descriptions when you want the exact HCL.

## 5. `providers.tf`

Pins the provider and normalizes the two filesystem paths OpenTofu needs.

- **`terraform.required_version`** - requires OpenTofu 1.10 or newer.
- **`terraform.required_providers`** - pins `oracle/oci` to `~> 7.0`. The 5.x line predates the `lifetime` argument on `oci_core_ipv6`, so reserved IPv6 (section 8) won't work on it.
- **`locals`** - runs both `var.private_key_path` and `var.ssh_public_key_path` through `pathexpand()`, which resolves a leading `~` to the real home directory at apply time on Linux *and* Windows. This is why `~/...` paths in `terraform.tfvars` need no OS-specific quoting.
- **`provider "oci"`** - wires tenancy, user, fingerprint, private key, and region straight from variables.

The provider block is fully self-contained: it never reads `~/.oci/config`, so it behaves identically whether or not the OCI CLI is installed or configured on the machine.

## 6. `variables.tf`

Every input the configuration takes. Four have no default and must be supplied in `terraform.tfvars`; the rest are tuned for the Always Free tier and only need changing if you want something different.

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
| `instance_display_name` | string | `vm-ampere-free` | Instance name, `hostname_label`, and reserved-IP name prefix |
| `ocpus` | number | `2` | OCPUs - the Always Free ceiling |
| `memory_in_gbs` | number | `12` | RAM - the Always Free ceiling |
| `boot_volume_size_gb` | number | `50` | Boot volume size |
| `ssh_public_key_path` | string | `~/.ssh/id_ed25519.pub` | SSH public key injected into the instance; `~` is expanded |

`ocpus` and `memory_in_gbs` sit exactly on the Always Free cap of 2 OCPU / 12 GB **per tenancy**. Raising either one, or running a second A1 instance alongside this one, takes you off the free tier.

## 7. `network.tf`

Creates the VCN, internet gateway, route table, security list, and public subnet, all dual-stack (IPv4 and IPv6). Names, the CIDR, and the DNS labels are written directly in the file rather than exposed as variables.

- **`oci_core_vcn.this`** - the VCN `vcn-free-public` at `10.0.0.0/24`, with `is_ipv6enabled` (OCI assigns it a /56) and DNS label `vcnfree`.
- **`oci_core_internet_gateway.this`** - an enabled IGW named `vcn-free-public-igw`.
- **`oci_core_route_table.this`** - default routes `0.0.0.0/0` and `::/0` to the IGW.
- **`oci_core_security_list.this`** - egress open to everything (`0.0.0.0/0` and `::/0`). Ingress opens SSH/HTTP/HTTPS (22, 80, 443) over TCP from both, plus ping: protocol `1` / `type = 8` for IPv4 and protocol `58` (ICMPv6) / `type = 128` for IPv6.
- **`oci_core_subnet.this`** - the public subnet `subnet-free-public` (DNS label `subnetfree`) that reuses the full VCN CIDR. Its IPv6 range is carved out with `cidrsubnet(oci_core_vcn.this.ipv6cidr_blocks[0], 8, 0)`, giving the first /64 of the VCN's /56.

The TCP ingress rules are generated with `setproduct()` from the two source CIDRs and a `[22, 80, 443]` port list, so opening another port is a one-line change to that list rather than a new hand-written block. If you add rules by hand in the console instead, `plan` will keep proposing to remove them - see section 12.

## 8. `compute.tf`

Creates the A1 instance and its reserved public IPs. IPv4 and IPv6 reservation use entirely different OCI resources - see the note at the end of this section.

- **`data.oci_core_images.ubuntu_aarch64`** - looks up the newest Canonical Ubuntu 24.04 image built for `VM.Standard.A1.Flex` (aarch64), sorted by creation time descending, and takes `images[0]`.
- **`oci_core_instance.this`** - the VM itself: shape `VM.Standard.A1.Flex` sized by `ocpus`/`memory_in_gbs`, booting the image above at `boot_volume_size_gb`. Its VNIC gets a public IPv4 and a `hostname_label`; your SSH public key is injected through `metadata.ssh_authorized_keys`.
- **`data.oci_core_vnic_attachments.instance_vnics`** - finds the instance's VNIC, needed by both reserved IPs.
- **`data.oci_core_private_ips.instance_private_ip`** - resolves that VNIC's private IP to the private-IP OCID that a reserved public IPv4 has to attach to.
- **`oci_core_public_ip.reserved_ipv4`** - a `RESERVED` public IPv4. Ephemeral public IPs already survive stop/start in OCI; a reserved one also survives the instance being terminated and recreated, and can be moved to a new one.
- **`oci_core_ipv6.reserved_ipv6`** - a `RESERVED` IPv6 address on that VNIC.

Two details in this file are easy to break:

**`assign_ipv6ip` is deliberately `false`.** The instance's IPv6 address is created by `oci_core_ipv6` instead; auto-assigning one too would give the VNIC a second, ephemeral IPv6.

**The `lifecycle.ignore_changes` block is load-bearing.** It ignores:

- `metadata` - the exact bytes `file()` reads (a trailing newline, for instance) rarely match byte-for-byte what OCI stored on an already-running or imported instance
- `source_details[0].source_id` - the image data source always resolves to the *newest* matching image, which won't match whatever image the instance actually booted from

Without it, OpenTofu proposes destroying and recreating a live instance every time Canonical publishes a new 24.04 image.

**Why IPv6 needs its own resource:** OCI's IPv4 and IPv6 reservation are unrelated mechanisms. `oci_core_public_ip` (IPv4) creates a separate public IP *object* that attaches to an existing private IP - the private IP itself never changes. `oci_core_ipv6`, by contrast, *is* the address itself, directly on the VNIC - there's no separate "public IPv6 object" layered on top. That's why the instance's `assign_ipv6ip` is off: creating `oci_core_ipv6` with `lifetime = "RESERVED"` is what actually gets your instance its IPv6 address, rather than layering a reservation on top of an auto-assigned ephemeral one.

## 9. `outputs.tf`

What `tofu apply` prints when it finishes (and what `tofu output` replays later).

| Output | Value |
| --- | --- |
| `instance_public_ip` | The reserved public IPv4 |
| `instance_private_ip` | The instance's private IP inside the subnet |
| `instance_public_ipv6` | The reserved IPv6 address |
| `fqdn` | `<instance>.subnetfree.vcnfree.oraclevcn.com`, the instance's name inside the VCN |

## 10. `terraform.tfvars`

```hcl
tenancy_ocid         = "ocid1.tenancy.oc1..your-tenancy-ocid"
user_ocid            = "ocid1.user.oc1..your-user-ocid"
fingerprint          = "xx:xx:xx:xx:...your-key-fingerprint"
compartment_id       = "ocid1.tenancy.oc1..your-real-ocid"
availability_domain  = "tWkk:SA-SAOPAULO-1-AD-1"
region               = "sa-saopaulo-1"
```

Add `terraform.tfvars` to `.gitignore` - it now holds your private key path and account identifiers alongside everything else.

## 11. Running it

```bash
tofu init    # downloads the OCI provider
tofu plan    # shows exactly what will be created - review before applying
tofu apply   # creates everything; type "yes" to confirm
```

To tear it all down later:

```bash
tofu destroy
```

OpenTofu figures out the correct dependency order automatically (subnet → IGW → route table → security list → VCN, in reverse of creation).

### 11.1. Migrating existing Terraform state to OpenTofu

If you already deployed this stack with Terraform, OpenTofu can take over the existing local `terraform.tfstate`. Back it up first, because once `tofu apply` writes the state, you shouldn't go back to Terraform with it:

```bash
cp terraform.tfstate terraform.tfstate.pre-tofu
rm -rf .terraform    # provider binaries downloaded by Terraform
tofu init
tofu plan
```

If you kept an older `.terraform.lock.hcl` that lists `registry.terraform.io/oracle/oci`, delete it before `tofu init`. The one in this repository already targets OpenTofu's registry.

`tofu plan` should report **No changes**. That's the real compatibility check, because OpenTofu doesn't document compatibility with state written by the newest Terraform releases (1.12 and later). If `plan` complains about the provider address instead, point the state at OpenTofu's registry and run `plan` again:

```bash
tofu state replace-provider registry.terraform.io/oracle/oci registry.opentofu.org/oracle/oci
```

The committed `.terraform.lock.hcl` already pins `registry.opentofu.org/oracle/oci` with hashes for Linux, macOS (Apple silicon), and Windows. If you bump the provider, refresh the hashes for all three:

```bash
tofu providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=windows_amd64
```

## 12. Adopting an already-existing VM instead of creating a new one

If you already created the VCN/subnet/instance some other way (e.g. by hand in the console, or with separate scripts) **before** running `tofu apply` for the first time, don't just run `apply` - OpenTofu has no record of those resources yet, so `plan` will propose creating everything from scratch. Applying that as-is risks a duplicate instance, a `hostname_label` conflict in the subnet, or - since Always Free Ampere A1 is capped at 2 OCPU/12GB **total** - pushing you over the free-tier quota if your existing VM is already using it.

Instead, **import** the existing resources into OpenTofu's state so it manages what's already there rather than creating new copies:

```bash
tofu import oci_core_vcn.this [existing-vcn-ocid]
tofu import oci_core_internet_gateway.this [existing-igw-ocid]
tofu import oci_core_route_table.this [existing-route-table-ocid]
tofu import oci_core_security_list.this [existing-security-list-ocid]
tofu import oci_core_subnet.this [existing-subnet-ocid]
tofu import oci_core_instance.this [existing-instance-ocid]
tofu import oci_core_public_ip.reserved_ipv4 [existing-reserved-ip-ocid]      # only if you already have a reserved IP
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

**Skip the `oci_core_public_ip` import** if you haven't reserved an IPv4 yet - OpenTofu will create one fresh on `apply` instead. Importing is only for adopting one that already exists (e.g. if you ran a reservation step outside OpenTofu earlier); if you skip it while one already exists, `plan` will propose creating a second reserved IP.

**Not sure whether your current IP is actually reserved?** The `oci network public-ip list` command above only searches `--scope REGION`, which is where *reserved* IPs live - an ephemeral IP won't show up there at all, so an empty result doesn't necessarily mean nothing exists. Check the ephemeral scope too before concluding there's nothing to import:

```bash
oci network public-ip list --compartment-id [compartment-ocid] --scope AVAILABILITY_DOMAIN --availability-domain [your_availability_domain] --query 'data[].{IP:"ip-address", Lifetime:lifetime, OCID:id}' --output table
```

If your instance's IP shows up here with `Lifetime: EPHEMERAL`, there's genuinely nothing reserved to import - proceed as above and let OpenTofu create one. Don't rely on the console's IP lifetime label alone to decide; it can be stale (e.g. after a VNIC change), so treat this CLI query as the authoritative check. One thing worth knowing before applying in that case: reserving an already-running ephemeral IP through OpenTofu doesn't guarantee you keep the *same* address - OCI may assign a different one when the new reserved object is created, so double check any DNS records or bookmarks pointing at the old IP afterward.

**After each import, run `tofu plan`.** It will show a diff between the real, already-deployed resource and what your `.tf` files currently describe (a `plan` after import never proposes destroying/recreating on its own — it just shows drift). Adjust the values in your `.tf`/`terraform.tfvars` files — not the actual infrastructure — until `plan` reports no changes for that resource. That confirms OpenTofu's config now accurately matches what's really running.

A few things likely to need adjusting after import:

- The VCN/subnet CIDR, names, and DNS labels in `network.tf` — match whatever you actually used
- `ocpus` / `memory_in_gbs` / `boot_volume_size_gb` — match the instance's real shape config
- The security list's rule set — if you added custom rules by hand (like the ICMP ones), the generated `network.tf` needs to include them too, or `plan` will keep showing a diff trying to remove them

The image data source (`data.oci_core_images.ubuntu_aarch64`) never needs importing — it's a lookup, not a managed resource. Note that it always resolves to the *newest* matching image, which is exactly why the `lifecycle.ignore_changes` block in section 8's `compute.tf` exists — without it, OpenTofu would try to replace your instance the moment a newer Ubuntu 24.04 aarch64 image gets published.

## 13. The "Out of capacity" problem

Ampere A1 is in high demand, and `tofu apply` fails immediately on `Out of capacity` errors - it does **not** retry automatically. A couple of ways to handle it:

**Simplest - wrap `tofu apply` in a shell loop:**

```bash
until tofu apply -auto-approve; do
  echo "Apply failed (likely capacity) - retrying in 60s..."
  sleep 60
done
```

**Or scope retries to just the instance**, once network resources already exist:

```bash
until tofu apply -auto-approve -target=oci_core_instance.this; do
  sleep 60
done
tofu apply -auto-approve   # picks up the rest (reserved IP, etc.)
```

## 14. State file - a word of caution

`terraform.tfstate` will contain sensitive details about your infrastructure (OCIDs, IPs, etc.) in plain text. Keep it out of git (`echo "*.tfstate*" >> .gitignore`). The state lives only on the machine you run OpenTofu from, so back it up somewhere safe: losing it means OpenTofu no longer knows what it created, and you'd have to re-import everything (section 12).
