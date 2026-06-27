# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Automated OpenShift 4.20 **UPI** cluster provisioner for **AWS EC2** (connected environment). It deliberately does **not** use `openshift-install`'s native `aws` platform — the cluster runs `platform: none` on plain EC2 instances (no cloud controller, no VIPs, DNS round-robin), keeping the same bare-metal-like behaviour as the disconnected vSphere variant this was forked from. A single command takes a cluster YAML and produces a running OCP cluster.

> The `main` branch targets disconnected vSphere; this (`aws-integration`) branch targets AWS EC2.

## Running the Tool

```bash
pip install -r requirements.txt

# Full bootstrap
python3 bootstrap.py --config config/clusters/<name>.yaml

# Generate configs only (no EC2, useful for reviewing)
python3 bootstrap.py --config config/clusters/<name>.yaml --skip-terraform

# Rerun Terraform only (ignition already exists)
python3 bootstrap.py --config config/clusters/<name>.yaml --skip-ignition

# Destroy a cluster
python3 bootstrap.py --config config/clusters/<name>.yaml --destroy
```

AWS credentials come from the environment (standard AWS SDK resolution):
```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
# or: export AWS_PROFILE="..."
```

## Architecture

### Execution flow (`ocp_bootstrap/cli.py`)

`main()` builds a `ClusterCtx` dataclass then calls these phases in order:

1. **`_run_network`** — requires `segment` (the subnet CIDR) and calculates all IPs from offsets
2. **`_run_templates`** — renders Jinja2 templates into the cluster output dir
3. **`_run_ignition`** — calls `openshift-install` to generate manifests, injects the `v4InternalSubnet` CR, then generates ignition configs
4. **`_run_terraform`** — runs `terraform init/apply` to provision EC2 instances + Route53 records; then calls `_run_csr` and `_run_argocd`

Each phase is a standalone `_run_X` function. To add a phase: write `_run_X`, add one call in `main()`. (DNS is created by Terraform's Route53 module, so there is no separate DNS phase.)

### Config merge (`ocp_bootstrap/site.py`)

Three-layer merge (each overrides the one above):
```
config/defaults.yaml
  + config/sites/<site>.yaml
    + config/clusters/<cluster>.yaml   (all keys except cluster_name/site)
```
Keys ending in `_env` are resolved to environment variables at load time (e.g., `argocd_hub_token_env: HUB_CLUSTER_SA_TOKEN` → reads `$HUB_CLUSTER_SA_TOKEN`). AWS credentials are not config keys — the Terraform AWS provider reads them from the standard environment (`AWS_ACCESS_KEY_ID` / `AWS_PROFILE`).

### Key modules

| Module | Responsibility |
|---|---|
| `cli.py` | Arg parsing, `ClusterCtx` dataclass, phase orchestration |
| `constants.py` | All path constants (auto-resolved from repo root) |
| `network.py` | IP calculation from offsets (CIDR-agnostic) |
| `renderer.py` | Jinja2 context building + template rendering |
| `site.py` | Three-layer config merge + `_env` key resolution |
| `installer.py` | `openshift-install` wrapper (manifests → inject → ignition) |
| `terraform.py` | `terraform init/plan/apply/destroy` with per-cluster state |
| `csr.py` | CSR approval polling loop |
| `argocd.py` | ArgoCD hub cluster registration via kube API (no CLI needed) |
| `utils.py` | `run_cmd()`, `setup_logging()`, `validate_prerequisites()` |

### Terraform (`aws/`)

Root module with two child modules: `ec2/` (all node types — `aws_instance` per node with a fixed `private_ip` from the offsets, ignition via user-data) and `route53/` (api/api-int/`*.apps`/per-node records in a **VPC-private** hosted zone). The cluster is **private**: the subnet has `map_public_ip_on_launch = false`, instances get private IPs only, and there is no public DNS. The root creates the subnet (the `segment`) inside an existing VPC, a security group, the private hosted zone, and — because EC2 user-data is capped at 16 KB while `bootstrap.ign` is ~300 KB — an **S3 bucket** holding `bootstrap.ign` plus an **IAM instance profile** so the bootstrap node can fetch it (its user-data is a tiny stub that `replace`s config from `s3://…`). Nodes reach the internet for image pulls via the VPC's existing NAT (an optional `route_table_id` associates the subnet with a NAT route table; otherwise the VPC main route table applies).

Provider binaries (`hashicorp/aws`, `community-terraform-providers/ignition`) are **pre-downloaded** into `aws/providers/` (committed via Git LFS, `linux_amd64` + `darwin_arm64`). `terraform_plugin_dir: ./providers` in `defaults.yaml` makes `terraform.py` write a `filesystem_mirror` CLI config and set `TF_CLI_CONFIG_FILE`, so `terraform init` never hits the registry. Per-cluster state is isolated via `-state=clusters/<name>/terraform.tfstate`. To refresh providers: `terraform -chdir=aws providers mirror -platform=linux_amd64 -platform=darwin_arm64 ./providers`.

### Cluster output (`clusters/<name>/`)

Each cluster writes its artifacts here. Terraform state and rendered configs are git-tracked; `auth/` (kubeconfig) and `*.log` files are gitignored.

## Important Constraints

- **Binary validation runs before any provisioning.** `validate_prerequisites()` checks `openshift-install`, `terraform`, and `oc` (only what's actually needed based on flags) and exits immediately if any are missing.
- **Cluster name limit:** 27 chars, alphanumeric + hyphens only, no leading/trailing hyphen.
- **Terraform state is per-cluster** — destroying one cluster never affects others.
- **`compute_ip_offsets: []`** by default means no compute nodes; infra nodes handle all workloads.
- **No VIPs, no load balancer** — DNS round-robin across all control plane IPs for `api`/`api-int`, and all infra IPs for `*.apps`.
- **AWS reserves the first four addresses (.0–.3) and the last of every subnet** — IP offsets start at `.10` to avoid them. Don't lower them below `.4`.
- **`segment` is required** (the subnet CIDR Terraform creates in the VPC) — there is no auto-allocation.
- **`platform: none` means no AWS cloud integration** — no cloud controller, no EBS CSI auto-wiring. Persistent storage is out of scope.
- **Private cluster** — instances have private IPs only; DNS is a VPC-private Route53 zone. Reach the cluster from inside the VPC / VPN.
- **Existing prerequisites in AWS:** a VPC (`vpc_id`) with DNS resolution/hostnames enabled and outbound internet (NAT) on the subnet's route table so nodes can pull images (connected, not airgapped).
- **Sensitive files not committed:** `config/pull-secret.json` (real Red Hat pull secret).
