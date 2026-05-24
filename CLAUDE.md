# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Automated OpenShift 4.20 UPI cluster provisioner for disconnected (airgap) vSphere environments. A single command takes a cluster YAML and produces a running OCP cluster — no internet access required at runtime.

## Running the Tool

```bash
pip install -r requirements.txt

# Full bootstrap
python3 bootstrap.py --config config/clusters/<name>.yaml

# Generate configs only (no VMs, useful for reviewing)
python3 bootstrap.py --config config/clusters/<name>.yaml --skip-terraform

# Rerun Terraform only (ignition already exists)
python3 bootstrap.py --config config/clusters/<name>.yaml --skip-ignition --skip-dns

# Destroy a cluster
python3 bootstrap.py --config config/clusters/<name>.yaml --destroy
```

Required env var (name defined in site profile as `vcenter_password_env`):
```bash
export VSPHERE_PASSWORD="..."
```

## Architecture

### Execution flow (`ocp_bootstrap/cli.py`)

`main()` builds a `ClusterCtx` dataclass then calls these phases in order:

1. **`_run_network`** — allocates a VLAN via HTTP API (if `segment` not set) and calculates all IPs from offsets
2. **`_run_templates`** — renders Jinja2 templates into the cluster output dir
3. **`_run_ignition`** — calls `openshift-install` to generate manifests, injects the `v4InternalSubnet` CR, then generates ignition configs
4. **`_run_dns`** — calls the wildcard DNS API to create `*.apps` records
5. **`_run_terraform`** — runs `terraform init/apply` to provision VMs; then calls `_run_csr` and `_run_argocd`

Each phase is a standalone `_run_X` function. To add a phase: write `_run_X`, add one call in `main()`.

### Config merge (`ocp_bootstrap/site.py`)

Three-layer merge (each overrides the one above):
```
config/defaults.yaml
  + config/sites/<site>.yaml
    + config/clusters/<cluster>.yaml   (all keys except cluster_name/site)
```
Keys ending in `_env` are resolved to environment variables at load time (e.g., `vcenter_password_env: VSPHERE_PASSWORD` → reads `$VSPHERE_PASSWORD`).

### Key modules

| Module | Responsibility |
|---|---|
| `cli.py` | Arg parsing, `ClusterCtx` dataclass, phase orchestration |
| `constants.py` | All path constants (auto-resolved from repo root) |
| `network.py` | VLAN Manager API call + IP calculation from offsets |
| `renderer.py` | Jinja2 context building + template rendering |
| `site.py` | Three-layer config merge + `_env` key resolution |
| `installer.py` | `openshift-install` wrapper (manifests → inject → ignition) |
| `terraform.py` | `terraform init/plan/apply/destroy` with per-cluster state |
| `dns.py` | Wildcard DNS API (`*.apps` records) |
| `csr.py` | CSR approval polling loop |
| `argocd.py` | ArgoCD hub cluster registration via kube API (no CLI needed) |
| `utils.py` | `run_cmd()`, `setup_logging()`, `validate_prerequisites()` |

### Terraform (`vsphere/`)

Root module with three child modules: `vm/` (all node types), `dns_a_record/` (node A+PTR records), `api_a_record/` (api/api-int records). Per-cluster state is isolated via `-state=clusters/<name>/terraform.tfstate`. Providers are committed in `vsphere/providers/` — no registry access needed. At runtime, `terraform.py` writes a temporary `filesystem_mirror` CLI config and sets `TF_CLI_CONFIG_FILE`.

### Cluster output (`clusters/<name>/`)

Each cluster writes its artifacts here. Terraform state and rendered configs are git-tracked; `auth/` (kubeconfig) and `*.log` files are gitignored.

## Important Constraints

- **Binary validation runs before any provisioning.** `validate_prerequisites()` checks `openshift-install`, `terraform`, and `oc` (only what's actually needed based on flags) and exits immediately if any are missing.
- **Cluster name limit:** 27 chars, alphanumeric + hyphens only, no leading/trailing hyphen.
- **Terraform state is per-cluster** — destroying one cluster never affects others.
- **`compute_ip_offsets: []`** by default means no compute nodes; infra nodes handle all workloads.
- **No VIPs, no load balancer** — DNS round-robin across all control plane IPs for `api`/`api-int`, and all infra IPs for `*.apps`.
- **Sensitive files not committed:** `config/pull-secret.json`, `config/additional-trust-bundle.pem`.
