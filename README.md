# ocp-bootstrap

Automated OpenShift 4.20 UPI cluster provisioning on vSphere for disconnected (airgap) environments.

Replaces a multi-hour manual process with a single command: cluster config YAML in → running cluster out.

---

## What It Does

```
Cluster YAML
     │
     ▼
Three-layer config merge          VLAN Manager (optional)
defaults.yaml                          │
  + sites/<site>.yaml    ──────────────┤
  + clusters/<name>.yaml              segment / VLAN ID
     │                                 │
     ▼                                 ▼
  IP Calculation    ──────────>   Template Rendering
  (.1-.3 infra                   install-config.yaml
   .4-.6 control plane           terraform.tfvars
   .7    bootstrap               v4-internal-subnet.yaml
   .254  gateway)
     │
     ├──> openshift-install   (manifests → inject v4InternalSubnet → ignition)
     │
     ├──> Wildcard DNS API    (*.apps → all 3 infra IPs)
     │
     ├──> Terraform           (provision VMs + api/api-int DNS via exec provisioner)
     │
     ├──> CSR approval loop   (auto-approve until all nodes Ready)
     │
     └──> ArgoCD registration (optional — register spoke into hub ArgoCD)
```

**DNS topology — no VIPs, no load balancer required:**

| Record                       | Resolves to                                     |
| ---------------------------- | ----------------------------------------------- |
| `api.<cluster>.<domain>`     | All 3 control plane IPs (round-robin A records) |
| `api-int.<cluster>.<domain>` | All 3 control plane IPs (round-robin A records) |
| `*.apps.<cluster>.<domain>`  | All 3 infra node IPs (round-robin A records)    |

---

## Prerequisites

| Tool                     | Purpose                                            |
| ------------------------ | -------------------------------------------------- |
| Python 3.10+             | Run this tool                                      |
| `openshift-install-4.20` | Generate manifests and ignition configs            |
| `terraform` ≥ 1.0        | Provision vSphere VMs                              |
| `oc` CLI                 | CSR approval loop; ArgoCD hub cluster registration |

The tool validates all required binaries at startup before any provisioning work begins.

---

## Installation

### 1. Clone and install Python dependencies

```bash
git clone <repo-url>
cd bootstrap-installer
git lfs pull          # download pre-committed binaries from utils_bin/
pip install -r requirements.txt
```

Python packages required (`requirements.txt`):

| Package    | Version  | Purpose                        |
| ---------- | -------- | ------------------------------ |
| `PyYAML`   | ≥ 6.0    | Config file parsing            |
| `Jinja2`   | ≥ 3.1    | Template rendering             |
| `requests` | ≥ 2.31   | DNS API + VLAN Manager calls   |

### 2. Install binaries

Pre-built binaries for the target Linux environment are committed under `utils_bin/` (tracked with Git LFS):

| File                                    | Binary       | Version      |
| --------------------------------------- | ------------ | ------------ |
| `utils_bin/argocd-linux-amd64`          | `argocd` CLI | see filename |
| `utils_bin/terraform_*_linux_amd64.zip` | `terraform`  | see filename |

Copy or symlink these to a directory on your `PATH` on the machine running the bootstrap tool (typically the bastion host):

```bash
# ArgoCD CLI
cp utils_bin/argocd-linux-amd64 /usr/local/bin/argocd
chmod +x /usr/local/bin/argocd

# Terraform — extract the zip
unzip utils_bin/terraform_*_linux_amd64.zip -d /usr/local/bin/
chmod +x /usr/local/bin/terraform
```

`openshift-install` and `oc` must be obtained separately from your Red Hat mirror and placed on `PATH`.

### 3. Terraform providers

Terraform providers (`vmware/vsphere`, `community-terraform-providers/ignition`, `hashicorp/null`) are **pre-downloaded** into `vsphere/providers/` and committed to this repo. No internet access is needed — `terraform init` will use the committed local providers automatically.

---

## Configuration

The tool uses a **three-layer merge** — each layer overrides the one above it:

```
config/defaults.yaml                   ← global defaults (sizing, offsets, tool paths)
  └── config/sites/<site>.yaml         ← per-site (vcenter, vSphere topology, DNS servers)
        └── config/clusters/<name>.yaml  ← per-cluster (name, segment, port group)
```

### 1. Global defaults — `config/defaults.yaml`

Shared across all sites. Update this file with your environment's actual values before first use. Key values:

```yaml
# IP layout
gateway_offset: 254
infra_ip_offsets: [1, 2, 3]
control_plane_ip_offsets: [4, 5, 6]
bootstrap_ip_offset: 7
compute_ip_offsets: []         # empty = no compute nodes; e.g. [8, 9, 10] to add 3

# VM sizing
control_plane_num_cpus: 8
control_plane_memory: 24576   # MB
infra_num_cpus: 8
infra_memory: 32768           # MB

# Mirror registry (one entry per source; override per site/cluster if needed)
image_mirrors:
  - source: quay.io/openshift-release-dev/ocp-release
    mirror: mirror.registry.example.local:5000/openshift/release
  - source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
    mirror: mirror.registry.example.local:5000/openshift/release
  - source: registry.redhat.io
    mirror: mirror.registry.example.local:5000

# APIs
wildcard_dns_api_url: http://dns-api.example.local:8080/api/wildcard
vlan_manager_url: http://vlan-manager.example.local:8000
```

### 2. Site profile — `config/sites/<site>.yaml`

Contains only what differs per physical site — vSphere topology and local network. Everything else (mirrors, APIs, sizing) is inherited from `defaults.yaml`. See `config/sites/site-a.yaml` as a reference:

```yaml
site_name: site-a

# vSphere
vcenter: vcenter.site-a.example.local
vcenter_user: administrator@vsphere.local
vcenter_password_env: VSPHERE_PASSWORD   # reads $VSPHERE_PASSWORD at runtime
datacenter: DC-SiteA
vsphere_cluster: Cluster-Prod-01
vsphere_datastore_cluster: DSC-Prod-SiteA
vsphere_dvs_name: DVS-Prod-SiteA
vsphere_folder: /DC-SiteA/vm/OCP-Clusters
vm_template: rhcos-420

# DNS / network
base_domain: ocp.example.local
search_domain: example.local
dns_servers:
  - 10.100.0.10
  - 10.100.0.11

# Override image_mirrors, wildcard_dns_api_url, or vlan_manager_url here
# only if this site uses different endpoints than the defaults.
```

### 3. Cluster config — `config/clusters/<cluster>.yaml`

One file per cluster. See `config/clusters/example-cluster.yaml` for a full reference:

```yaml
cluster_name: my-cluster-01
site: site-a

# Set segment+vlan_id directly, or omit both to auto-allocate via VLAN Manager
segment: 10.0.5.0/24
vlan_id: 105

# vSphere port group for this cluster's VMs
vm_network: VLAN105-OCP

# Optional: compute nodes (workers — infra nodes handle all workloads by default)
# compute_ip_offsets: [8, 9, 10]   # 3 compute nodes at .8, .9, .10

# Optional: ArgoCD hub registration (see section below)
# argocd_hub_api_url: https://api.hub-cluster.example.com:6443
# argocd_hub_token: <sa-token>

# Any key from defaults.yaml or the site profile can be overridden here
# openshift_install_bin: /usr/local/bin/openshift-install-4.21
```

### Sensitive files (never committed)

Place these in `config/` before running:

| File                                  | Description                              |
| ------------------------------------- | ---------------------------------------- |
| `config/pull-secret.json`             | Red Hat / mirror registry pull secret    |
| `config/additional-trust-bundle.pem`  | CA certificate for your mirror registry  |

Set the vCenter password as an environment variable (name must match `vcenter_password_env` in the site profile):

```bash
export VSPHERE_PASSWORD="your-vcenter-password"
```

---

## Usage

```bash
# Full bootstrap — ignition + DNS + Terraform + CSR approval (+ ArgoCD if configured)
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml

# Generate configs only, no Terraform (dry-run / review)
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --skip-terraform

# Re-run Terraform only (ignition already exists)
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --skip-ignition --skip-dns

# Use a custom output directory
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --work-dir /tmp/ocp-dry-run

# Destroy a previously provisioned cluster
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --destroy

# Extend the CSR approval window to 60 minutes
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --csr-timeout 60

# Skip ArgoCD registration even if configured in the cluster YAML
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --skip-argocd
```

Run `python3 bootstrap.py --help` for the full reference.

---

## ArgoCD Hub Registration

When `argocd_hub_api_url` is set in the cluster config, the bootstrap tool automatically registers the newly provisioned spoke cluster into ArgoCD on the hub after the cluster is Available. No `argocd` CLI is required.

**How it works:**

1. Creates an `argocd-manager` ServiceAccount in `kube-system` on the spoke cluster
2. Creates a static (non-expiring) SA token Secret tied to that ServiceAccount
3. Binds `argocd-manager` to the `cluster-admin` ClusterRole
4. Applies an ArgoCD cluster Secret to the hub cluster's ArgoCD namespace

The cluster Secret uses the `argocd.argoproj.io/secret-type: cluster` label — ArgoCD watches for these and automatically adds the cluster to its inventory (no project name needed; projects are separate from cluster registration).

**Cluster config fields:**

```yaml
# Required
argocd_hub_api_url: https://api.hub-cluster.example.com:6443

# Token — use one of:
argocd_hub_token: <sa-token-plain-text>      # plain text in YAML (fine for private/disconnected repos)
argocd_hub_token_env: HUB_CLUSTER_SA_TOKEN   # env var name (alternative)

# Optional
argocd_namespace: argocd          # default: argocd
argocd_insecure_skip_tls: false   # default: false
```

The hub token must belong to a ServiceAccount with permission to create Secrets in the ArgoCD namespace (typically a `cluster-admin` SA on the hub).

**Skip flag:** `--skip-argocd` skips this step even if configured.

---

## Project Structure

```
bootstrap-installer/
├── bootstrap.py                      # Entrypoint
├── requirements.txt
├── clusters/                         # Cluster output (default work dir — git-tracked)
│   └── <cluster-name>/
│       ├── auth/                     # kubeconfig, kubeadmin-password (gitignored)
│       ├── ignition/                 # bootstrap.ign, master.ign, worker.ign
│       ├── terraform.tfstate         # Per-cluster Terraform state (tracked)
│       ├── terraform.tfvars          # Generated Terraform variables
│       ├── install-config.yaml.backup
│       ├── cluster-context.yaml      # Full rendered context
│       └── <name>-bootstrap.log      # Execution log (gitignored)
├── config/
│   ├── defaults.yaml                 # Global defaults (committed)
│   ├── sites/
│   │   └── <site>.yaml               # Site profile — create one per site
│   └── clusters/
│       ├── example-cluster.yaml      # Reference example
│       └── <cluster>.yaml            # Your cluster configs (one per cluster)
├── ocp_bootstrap/                    # Python package
│   ├── cli.py                        # Argument parsing + orchestration
│   ├── constants.py                  # Path constants (auto-resolved from repo root)
│   ├── network.py                    # VLAN allocation + IP calculation
│   ├── renderer.py                   # Jinja2 template rendering
│   ├── site.py                       # Three-layer config merge
│   ├── installer.py                  # openshift-install wrapper
│   ├── terraform.py                  # Terraform init/plan/apply/destroy
│   ├── dns.py                        # Wildcard DNS API call
│   ├── csr.py                        # CSR approval loop
│   ├── argocd.py                     # ArgoCD hub cluster registration
│   └── utils.py                      # Logging, run_cmd, validate_prerequisites
├── templates/
│   ├── install-config.yaml.j2        # OpenShift install config
│   ├── terraform.tfvars.j2           # Terraform input variables
│   └── v4-internal-subnet.yaml.j2   # OVN v4InternalSubnet manifest
└── vsphere/                          # Terraform root module
    ├── main.tf                       # VMs, folder, resource pool, DNS modules
    ├── variables.tf
    ├── versions.tf
    ├── .terraform.lock.hcl           # Committed — pins provider versions
    ├── providers/                    # Pre-downloaded provider zips (committed)
    │   └── registry.terraform.io/
    │       ├── vmware/vsphere/
    │       ├── community-terraform-providers/ignition/
    │       └── hashicorp/null/
    ├── vm/                           # Reusable VM module (bootstrap, control plane, infra, compute)
    ├── dns_a_record/                 # Node A + PTR record module
    └── api_a_record/                 # api / api-int A record module
```

---

## IP Allocation

From a `/24` segment (e.g. `10.0.5.0/24`) the default offsets produce:

| IP                   | Role                                         |
| -------------------- | -------------------------------------------- |
| 10.0.5.1 - 10.0.5.3 | Infra nodes (`*.apps` ingress)                |
| 10.0.5.4 - 10.0.5.6 | Control plane (`api` / `api-int`)             |
| 10.0.5.7             | Bootstrap (temporary, removed after install) |
| 10.0.5.8+            | Compute nodes (optional, empty by default)   |
| 10.0.5.254           | Gateway                                      |

Override `infra_ip_offsets`, `control_plane_ip_offsets`, `bootstrap_ip_offset`, `compute_ip_offsets`, and `gateway_offset` in `defaults.yaml` or the site profile to change the layout.

---

## Cluster State & Multi-Cluster Operations

Cluster artifacts are written to `clusters/<cluster-name>/` inside this repo (the default work dir). This means cluster state — Terraform state, ignition configs, rendered configs — survives across machines via `git push`/`git clone`.

Credentials (`auth/`) and logs are gitignored. Everything else is tracked.

**Per-cluster Terraform state isolation:** each cluster's `terraform.tfstate` lives at `clusters/<name>/terraform.tfstate`. All Terraform commands pass `-state=<cluster-specific-path>`, so destroying one cluster never affects others.

```bash
# Create cluster A and cluster B independently
python3 bootstrap.py --config config/clusters/cluster-a.yaml
python3 bootstrap.py --config config/clusters/cluster-b.yaml

# Destroy only cluster B — cluster A is untouched
python3 bootstrap.py --config config/clusters/cluster-b.yaml --destroy
```

---

## Airgap / Disconnected Operation

This repo is designed to run with **zero internet access** after cloning:

- **Terraform providers** are committed in `vsphere/providers/` as packed zips for `linux_amd64` (generated with `terraform providers mirror`)
- At runtime the bootstrap tool writes a temporary `filesystem_mirror` Terraform CLI config and sets `TF_CLI_CONFIG_FILE` — `terraform init` reads providers locally, no registry calls are made
- **Container image mirrors** are configured per site via `image_mirrors` in the site profile and rendered into `install-config.yaml`

To update providers when a new version is released (run on a connected machine, then commit):

```bash
cd vsphere/
terraform providers mirror -platform=linux_amd64 providers/
git add providers/ .terraform.lock.hcl
git commit -m "Update Terraform providers to <version>"
```

---

## Running with Docker (Recommended for Airgap)

Packaging as a container image bundles Python, all binaries, and Terraform providers into a single transferable artifact — no manual dependency installation on the bastion host.

### 1. Prepare OCP binaries (internet-connected machine)

The `openshift-install` and `oc` binaries are not committed to this repo. Download them from your mirror registry and place them in `bin/` at the repo root before building:

```
bin/
  openshift-install-4.20    ← from your mirror (linux/amd64)
  oc                        ← from OCP client tarball (linux/amd64)
```

### 2. Build the image

```bash
docker build -t ocp-bootstrap:4.20 .
```

### 3. Transfer to airgap environment

```bash
# Save on internet-connected machine
docker save ocp-bootstrap:4.20 | gzip > ocp-bootstrap-4.20.tar.gz

# Copy tar to airgap bastion host, then load it there
docker load < ocp-bootstrap-4.20.tar.gz
```

### 4. Run in the airgap environment

Mount `config/` (cluster YAMLs + secrets) and `clusters/` (output artifacts) as volumes so they persist outside the container:

```bash
docker run --rm \
  -e VSPHERE_PASSWORD="your-vcenter-password" \
  -v $(pwd)/config:/app/config \
  -v $(pwd)/clusters:/app/clusters \
  ocp-bootstrap:4.20 --config config/clusters/<name>.yaml
```

All `bootstrap.py` flags work as normal:

```bash
# Generate configs only (no VMs)
docker run --rm -e VSPHERE_PASSWORD="..." \
  -v $(pwd)/config:/app/config -v $(pwd)/clusters:/app/clusters \
  ocp-bootstrap:4.20 --config config/clusters/<name>.yaml --skip-terraform

# Destroy a cluster
docker run --rm -e VSPHERE_PASSWORD="..." \
  -v $(pwd)/config:/app/config -v $(pwd)/clusters:/app/clusters \
  ocp-bootstrap:4.20 --config config/clusters/<name>.yaml --destroy
```

Place `config/pull-secret.json` and `config/additional-trust-bundle.pem` on the bastion host before running — they are mounted in via the `config/` volume and are never baked into the image.

---

## After Bootstrap

```bash
export KUBECONFIG=clusters/my-cluster-01/auth/kubeconfig
oc get nodes
oc get clusteroperators
```

Once all nodes are `Ready` and all cluster operators are `Available`, proceed with Day2: install the OpenShift GitOps operator and point ArgoCD at your GitOps repository to manage infra labeling, LDAP, MCE, additional operators, and everything else.

If `argocd_hub_api_url` was set in the cluster config, the cluster is already registered in your hub ArgoCD — check Settings → Clusters in the ArgoCD UI.
