# ocp-bootstrap (AWS)

Automated OpenShift 4.20 **UPI** cluster provisioning on **AWS EC2**.

Replaces a multi-hour manual process with a single command: cluster config YAML in → running cluster out.

> This is the **`aws-integration`** branch. It deliberately does **not** use `openshift-install`'s native `aws` platform — the cluster runs `platform: none` on plain EC2 instances (no cloud controller, no VIPs, DNS round-robin), keeping the same bare-metal-like behaviour as the disconnected vSphere variant on `main`.

---

## What It Does

```text
Cluster YAML
     │
     ▼
Three-layer config merge
defaults.yaml
  + sites/<site>.yaml          (aws_region, vpc_id, AZ, RHCOS AMI, base_domain)
  + clusters/<name>.yaml       (name, segment = subnet CIDR)
     │
     ▼
  IP Calculation               (offsets within the subnet — avoid AWS-reserved .0–.3)
   .10-.12 infra
   .20-.22 control plane
   .30     bootstrap
     │
     ├──> openshift-install   (manifests → inject v4InternalSubnet → ignition)
     │
     ├──> Terraform           (private subnet + SG + S3/IAM for bootstrap ignition +
     │                         EC2 instances + private Route53 records)
     │
     ├──> CSR approval loop   (auto-approve until all nodes Ready)
     │
     └──> ArgoCD registration (optional — register spoke into hub ArgoCD)
```

**Private cluster, no VIPs, no load balancer.** Instances get private IPs only. The Terraform Route53 module creates round-robin A records in a **VPC-private** hosted zone (no public DNS):

| Record                       | Resolves to                                    |
| ---------------------------- | ---------------------------------------------- |
| `api.<cluster>.<domain>`     | All control-plane IPs (round-robin A records)  |
| `api-int.<cluster>.<domain>` | All control-plane IPs (round-robin A records)  |
| `*.apps.<cluster>.<domain>`  | All infra node IPs (round-robin A records)     |

---

## Prerequisites

| Tool                     | Purpose                                            |
| ------------------------ | -------------------------------------------------- |
| Python 3.10+             | Run this tool                                      |
| `openshift-install-4.20` | Generate manifests and ignition configs            |
| `terraform` ≥ 1.3        | Provision EC2 + Route53                             |
| `oc` CLI                 | CSR approval loop; ArgoCD hub cluster registration |

The tool validates required binaries at startup before any provisioning work begins.

**In AWS, you must already have:**

- A **VPC** (`vpc_id`) with DNS resolution/hostnames enabled and **outbound internet (NAT)** on the cluster subnet's route table — the cluster is private but connected, so nodes need NAT to pull images.
- An **RHCOS AMI** id for OpenShift 4.20 in your region (`openshift-install coreos print-stream-json` lists them).
- **AWS credentials** in the environment.

> The cluster is **private** — Terraform creates a VPC-private Route53 zone for `<cluster>.<base_domain>`. No public hosted zone is required, and instances get no public IPs. Reach the cluster from inside the VPC / VPN.

---

## Installation

```bash
git clone <repo-url>
cd bootstrap-installer
git lfs pull          # fetch pre-downloaded Terraform providers (aws/providers/) + binaries
pip install -r requirements.txt
```

`openshift-install` and `oc` must be obtained from your Red Hat mirror/console and placed on `PATH`. Terraform providers (`hashicorp/aws`, `community-terraform-providers/ignition`) are **pre-downloaded** into `aws/providers/` (committed via Git LFS for `linux_amd64` + `darwin_arm64`); `terraform init` uses that local filesystem mirror — no registry access needed. To refresh them after a version bump:

```bash
terraform -chdir=aws providers mirror -platform=linux_amd64 -platform=darwin_arm64 ./providers
git add aws/providers aws/.terraform.lock.hcl
```

Set AWS credentials (standard AWS SDK resolution):

```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
# or: export AWS_PROFILE="my-profile"
```

---

## Configuration

A **three-layer merge** — each layer overrides the one above it:

```text
config/defaults.yaml                   ← global defaults (sizing, offsets, tool paths)
  └── config/sites/<site>.yaml         ← per-site (region, vpc_id, AZ, AMI, base_domain)
        └── config/clusters/<name>.yaml  ← per-cluster (name, segment)
```

### 1. Global defaults — `config/defaults.yaml`

Shared across all sites. Key values:

```yaml
# IP layout — offsets start at .10 to avoid AWS-reserved addresses (.0–.3 and the last)
infra_ip_offsets: [10, 11, 12]
control_plane_ip_offsets: [20, 21, 22]
bootstrap_ip_offset: 30
compute_ip_offsets: []                 # empty = no compute nodes; e.g. [40, 41, 42]

# Instance sizing
control_plane_instance_type: m5.2xlarge
infra_instance_type: m5.2xlarge
compute_instance_type: m5.xlarge
bootstrap_instance_type: m5.large
```

### 2. Site profile — `config/sites/<site>.yaml`

Per-site AWS topology. See `config/sites/aws-site.yaml`:

```yaml
site_name: aws-site

aws_region: us-east-1
vpc_id: vpc-0abc123...          # existing VPC
availability_zone: us-east-1a
rhcos_ami: ami-0abc123...       # RHCOS 4.20 AMI for this region
aws_ssh_key_name: my-keypair    # optional EC2 key pair
allowed_cidrs:                  # who may reach api (6443) / ingress (80/443) / ssh
  - 10.0.0.0/8
# route_table_id: rtb-...       # optional; otherwise a route table to the VPC's IGW is created

base_domain: ocp.example.com    # parent domain; a private zone for <cluster>.<base_domain> is created
```

AWS credentials are **not** config keys — the Terraform AWS provider reads them from the environment.

### 3. Cluster config — `config/clusters/<cluster>.yaml`

One file per cluster. See `config/clusters/example-cluster.yaml`:

```yaml
cluster_name: my-cluster-01
site: aws-site

# segment = the subnet CIDR Terraform creates in the VPC.
# Must be free within the VPC and not overlap other subnets.
segment: 10.0.5.0/24

# Optional: compute nodes (infra nodes handle all workloads by default)
# compute_ip_offsets: [40, 41, 42]

# Optional: ArgoCD hub registration (see section below)
# argocd_hub_api_url: https://api.hub-cluster.example.com:6443
# argocd_hub_token: <sa-token>

# Any key from defaults.yaml or the site profile can be overridden here
# control_plane_instance_type: m5.4xlarge
```

### Sensitive files (never committed)

| File                      | Description                          |
| ------------------------- | ------------------------------------ |
| `config/pull-secret.json` | Real Red Hat / Quay pull secret      |

(SSH public key is read from `~/.ssh/id_rsa.pub` by default; override with `ssh_public_key_path`.)

---

## Usage

```bash
# Full bootstrap — ignition + Terraform + CSR approval (+ ArgoCD if configured)
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml

# Generate configs only, no Terraform (dry-run / review)
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --skip-terraform

# Re-run Terraform only (ignition already exists)
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --skip-ignition

# Use a custom output directory
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --work-dir /tmp/ocp-dry-run

# Destroy a previously provisioned cluster
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --destroy

# Extend the CSR approval window to 60 minutes
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --csr-timeout 60

# Skip ArgoCD registration even if configured in the cluster YAML
python3 bootstrap.py --config config/clusters/my-cluster-01.yaml --skip-argocd
```

Run `python3 bootstrap.py --help` for the full reference. Terraform prompts for approval before it applies; review the plan (subnet, security group, S3 bucket/object, IAM profile, instances with their `private_ip`, both Route53 zones) and type `yes` to proceed.

### How the bootstrap ignition is delivered

`bootstrap.ign` is ~300 KB, but EC2 user-data is capped at 16 KB. Terraform uploads `bootstrap.ign` to a private **S3 bucket** and gives the bootstrap instance an **IAM instance profile** with `s3:GetObject`; the instance's user-data is a tiny stub that `replace`s its config from `s3://…`. `master.ign`/`worker.ign` are small pointer configs (they fetch from `api-int:22623`) and are passed inline as user-data. The S3 bucket has `force_destroy = true`, so `--destroy` cleans it up.

---

## ArgoCD Hub Registration

When `argocd_hub_api_url` is set in the cluster config, the bootstrap tool automatically registers the newly provisioned spoke cluster into ArgoCD on the hub after the cluster is Available. No `argocd` CLI is required.

**How it works:**

1. Creates an `argocd-manager` ServiceAccount in `kube-system` on the spoke cluster
2. Creates a static (non-expiring) SA token Secret tied to that ServiceAccount
3. Binds `argocd-manager` to the `cluster-admin` ClusterRole
4. Applies an ArgoCD cluster Secret to the hub cluster's ArgoCD namespace

**Cluster config fields:**

```yaml
# Required
argocd_hub_api_url: https://api.hub-cluster.example.com:6443

# Token — use one of:
argocd_hub_token: <sa-token-plain-text>      # plain text in YAML
argocd_hub_token_env: HUB_CLUSTER_SA_TOKEN   # env var name (alternative)

# Optional
argocd_namespace: argocd          # default: argocd
argocd_insecure_skip_tls: false   # default: false
```

The hub token must belong to a ServiceAccount with permission to create Secrets in the ArgoCD namespace. **Skip flag:** `--skip-argocd`.

---

## Project Structure

```text
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
│   │   └── aws-site.yaml             # Site profile — one per site
│   └── clusters/
│       ├── example-cluster.yaml      # Reference example
│       └── <cluster>.yaml            # Your cluster configs (one per cluster)
├── ocp_bootstrap/                    # Python package
│   ├── cli.py                        # Argument parsing + orchestration
│   ├── constants.py                  # Path constants (auto-resolved from repo root)
│   ├── network.py                    # IP calculation from offsets
│   ├── renderer.py                   # Jinja2 template rendering
│   ├── site.py                       # Three-layer config merge
│   ├── installer.py                  # openshift-install wrapper
│   ├── terraform.py                  # Terraform init/plan/apply/destroy
│   ├── csr.py                        # CSR approval loop
│   ├── argocd.py                     # ArgoCD hub cluster registration
│   └── utils.py                      # Logging, run_cmd, validate_prerequisites
├── templates/
│   ├── install-config.yaml.j2        # OpenShift install config (platform: none)
│   ├── terraform.tfvars.j2           # Terraform input variables (AWS)
│   └── v4-internal-subnet.yaml.j2    # OVN v4InternalSubnet manifest
└── aws/                              # Terraform root module
    ├── main.tf                       # subnet, SG, S3/IAM, private zone, module calls
    ├── variables.tf
    ├── versions.tf
    ├── .terraform.lock.hcl           # committed — pins provider versions/hashes
    ├── providers/                    # pre-downloaded provider zips (committed via Git LFS)
    ├── ec2/                          # EC2 instance module (all node roles) + ignition
    └── route53/                      # api / api-int / *.apps / per-node records (private zone)
```

---

## IP Allocation

From a subnet CIDR (e.g. `10.0.5.0/24`) the default offsets produce:

| IP                   | Role                                          |
| -------------------- | --------------------------------------------- |
| 10.0.5.10 – 10.0.5.12 | Infra nodes (`*.apps` ingress)               |
| 10.0.5.20 – 10.0.5.22 | Control plane (`api` / `api-int`)            |
| 10.0.5.30             | Bootstrap (temporary, removed after install)  |
| 10.0.5.40+            | Compute nodes (optional, empty by default)    |

> **AWS reserves the first four addresses (.0–.3) and the last of every subnet.** Keep offsets at `.4` or higher (defaults start at `.10`). `.1` is always the subnet router.

Override `infra_ip_offsets`, `control_plane_ip_offsets`, `bootstrap_ip_offset`, and `compute_ip_offsets` in `defaults.yaml` or the site profile to change the layout.

---

## Cluster State & Multi-Cluster Operations

Cluster artifacts are written to `clusters/<cluster-name>/` inside this repo (the default work dir). Terraform state, ignition configs, and rendered configs survive across machines via `git push`/`git clone`. Credentials (`auth/`) and logs are gitignored.

**Per-cluster Terraform state isolation:** each cluster's `terraform.tfstate` lives at `clusters/<name>/terraform.tfstate`. All Terraform commands pass `-state=<cluster-specific-path>`, so destroying one cluster never affects others.

```bash
# Create cluster A and cluster B independently
python3 bootstrap.py --config config/clusters/cluster-a.yaml
python3 bootstrap.py --config config/clusters/cluster-b.yaml

# Destroy only cluster B — cluster A is untouched
python3 bootstrap.py --config config/clusters/cluster-b.yaml --destroy
```

---

## Notes & Limitations

- **`platform: none` on AWS** means there is no AWS cloud controller and no EBS CSI auto-wiring. Persistent storage (StorageClasses, dynamic PVs) is out of scope and must be set up separately.
- **Private cluster** — instances have private IPs only and DNS is a VPC-private zone. Reach `api`/console from inside the VPC or over a VPN/transit; `allowed_cidrs` scopes who may hit the API/ingress.
- **Outbound internet** — the subnet's route table must reach a NAT gateway so nodes can pull images (connected, not airgapped).
- **VPC DNS** must be enabled so masters/workers can resolve `api-int` from the private hosted zone at boot.

---

## After Bootstrap

```bash
export KUBECONFIG=clusters/my-cluster-01/auth/kubeconfig
oc get nodes
oc get clusteroperators
```

Once all nodes are `Ready` and all cluster operators are `Available`, proceed with Day-2: install the OpenShift GitOps operator and point ArgoCD at your GitOps repository.

If `argocd_hub_api_url` was set, the cluster is already registered in your hub ArgoCD — check Settings → Clusters in the ArgoCD UI.
