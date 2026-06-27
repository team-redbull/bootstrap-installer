import argparse
import logging
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict

import yaml

from .argocd import register_cluster_in_argocd
from .constants import DEFAULT_WORK_DIR, CLUSTERS_DIR, TERRAFORM_DIR
from .csr import approve_csrs
from .installer import create_ignition_configs, create_manifests, inject_v4_internal_subnet
from .network import calculate_ips
from .renderer import build_template_context, render_templates
from .site import load_site_profile
from .terraform import run_terraform, run_terraform_destroy
from .utils import setup_logging, validate_prerequisites


@dataclass
class ClusterCtx:
    """All resolved state for a single cluster bootstrap run."""
    name: str
    site: str
    profile: Dict[str, Any]
    cluster_dir: Path
    install_dir: Path
    ignition_dir: Path
    tfstate_path: Path
    logger: logging.Logger
    segment: str = ""
    vlan_id: str = "0"
    ip_info: Dict = field(default_factory=dict)
    template_ctx: Dict = field(default_factory=dict)
    template_outputs: Dict = field(default_factory=dict)

    @property
    def kubeconfig(self) -> Path:
        return self.cluster_dir / "auth" / "kubeconfig"

    @property
    def terraform_bin(self) -> str:
        return self.profile.get("terraform_bin", "terraform")

    @property
    def terraform_dir(self) -> str:
        return self.profile.get("terraform_dir", str(TERRAFORM_DIR))

    @property
    def plugin_dir(self) -> str | None:
        return self.profile.get("terraform_plugin_dir") or None


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Bootstrap OpenShift 4.20 UPI on AWS EC2")
    p.add_argument("--config", required=True, help="Cluster YAML (config/clusters/<name>.yaml)")
    p.add_argument("--work-dir", default=str(DEFAULT_WORK_DIR), help=f"Output directory (default: {DEFAULT_WORK_DIR})")
    p.add_argument("--destroy", action="store_true", help="Destroy the cluster (terraform destroy)")
    p.add_argument("--skip-terraform", action="store_true", help="Skip terraform (generate configs only)")
    p.add_argument("--skip-csr", action="store_true", help="Skip CSR approval loop")
    p.add_argument("--skip-ignition", action="store_true", help="Skip openshift-install (use existing ignition)")
    p.add_argument("--skip-argocd", action="store_true", help="Skip ArgoCD hub registration")
    p.add_argument("--csr-timeout", type=int, default=45, help="CSR approval timeout in minutes (default: 45)")
    return p.parse_args()


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

def _die(msg: str) -> None:
    print(f"ERROR: {msg}")
    sys.exit(1)


def _validate_name(name: str) -> None:
    if len(name) > 27:
        _die(f"Cluster name '{name}' exceeds 27 characters")
    if not all(c.isalnum() or c == "-" for c in name):
        _die(f"Cluster name '{name}': only alphanumeric + hyphens allowed")
    if name.startswith("-") or name.endswith("-"):
        _die(f"Cluster name '{name}': cannot start or end with a hyphen")


def _build_context(args) -> ClusterCtx:
    config_path = Path(args.config)
    if not config_path.exists():
        available = [f.stem for f in CLUSTERS_DIR.glob("*.yaml")] if CLUSTERS_DIR.exists() else []
        _die(f"Config not found: {config_path}" + (f"  Available: {available}" if available else ""))

    cluster_cfg = yaml.safe_load(config_path.read_text()) or {}
    name = cluster_cfg.get("cluster_name")
    site = cluster_cfg.get("site")
    if not name:
        _die("'cluster_name' is required in the cluster config")
    if not site:
        _die("'site' is required in the cluster config")
    _validate_name(name)

    cluster_dir = Path(args.work_dir) / name
    cluster_dir.mkdir(parents=True, exist_ok=True)
    logger = setup_logging(name, cluster_dir)

    profile = load_site_profile(site)
    profile.update({k: v for k, v in cluster_cfg.items() if k not in ("cluster_name", "site")})
    logger.info(f"=== Bootstrap: {name} | site: {site} | dir: {cluster_dir} ===")

    return ClusterCtx(
        name=name, site=site, profile=profile,
        cluster_dir=cluster_dir,
        install_dir=cluster_dir / "install",
        ignition_dir=cluster_dir / "ignition",
        tfstate_path=cluster_dir / "terraform.tfstate",
        logger=logger,
        segment=cluster_cfg.get("segment") or "",
        vlan_id=str(cluster_cfg.get("vlan_id", "0")),
    )


# ---------------------------------------------------------------------------
# Phases  (add a new phase: write _run_X, add one line to main)
# ---------------------------------------------------------------------------

def _run_destroy(ctx: ClusterCtx) -> None:
    tfvars = ctx.cluster_dir / "terraform.tfvars"
    if not tfvars.exists():
        ctx.logger.error(f"No terraform.tfvars at {tfvars}. Run bootstrap first.")
        sys.exit(1)
    run_terraform_destroy(terraform_bin=ctx.terraform_bin, terraform_dir=ctx.terraform_dir,
                          tfvars_path=tfvars, tfstate_path=ctx.tfstate_path,
                          plugin_dir=ctx.plugin_dir, logger=ctx.logger)


def _run_network(ctx: ClusterCtx) -> None:
    if not ctx.segment:
        ctx.logger.error(
            "'segment' is required in the cluster config — it is the subnet CIDR "
            "Terraform creates in the VPC (e.g. segment: 10.0.5.0/24)"
        )
        sys.exit(1)
    ctx.ip_info = calculate_ips(ctx.segment, ctx.profile, ctx.logger)


def _run_templates(ctx: ClusterCtx) -> None:
    ctx.template_ctx = build_template_context(
        cluster_name=ctx.name, profile=ctx.profile, ip_info=ctx.ip_info,
        segment=ctx.segment, vlan_id=ctx.vlan_id, cluster_dir=ctx.cluster_dir,
    )
    ctx.template_outputs = render_templates(ctx.template_ctx, ctx.cluster_dir, ctx.logger)


def _run_ignition(ctx: ClusterCtx, args) -> None:
    if args.skip_ignition:
        ctx.logger.info("Skipping ignition (--skip-ignition)")
        return
    install_bin = ctx.profile.get("openshift_install_bin", "openshift-install-4.20")
    create_manifests(install_bin, ctx.install_dir, ctx.logger)
    inject_v4_internal_subnet(ctx.template_outputs["v4-internal-subnet"], ctx.install_dir, ctx.logger)
    create_ignition_configs(install_bin, ctx.install_dir, ctx.ignition_dir, ctx.logger)


def _run_csr(ctx: ClusterCtx, args) -> None:
    if args.skip_csr:
        ctx.logger.info("Skipping CSR approval (--skip-csr)")
        return
    approve_csrs(ctx.kubeconfig, ctx.logger, timeout_minutes=args.csr_timeout)


def _run_argocd(ctx: ClusterCtx, args) -> None:
    if args.skip_argocd or not ctx.profile.get("argocd_hub_api_url"):
        if args.skip_argocd:
            ctx.logger.info("Skipping ArgoCD registration (--skip-argocd)")
        return
    register_cluster_in_argocd(ctx.name, ctx.kubeconfig, ctx.profile, ctx.logger)


def _run_terraform(ctx: ClusterCtx, args) -> None:
    if args.skip_terraform:
        ctx.logger.info("Skipping terraform (--skip-terraform)")
        return
    run_terraform(terraform_bin=ctx.terraform_bin, terraform_dir=ctx.terraform_dir,
                  tfvars_path=ctx.template_outputs["terraform.tfvars"],
                  tfstate_path=ctx.tfstate_path, plugin_dir=ctx.plugin_dir, logger=ctx.logger)
    _run_csr(ctx, args)
    _run_argocd(ctx, args)


def _save_context(ctx: ClusterCtx) -> None:
    ctx_file = ctx.cluster_dir / "cluster-context.yaml"
    dump = {k: v for k, v in ctx.template_ctx.items() if isinstance(v, (str, int, float, list, dict, bool))}
    ctx_file.write_text(yaml.dump(dump, default_flow_style=False))

    compute = ", ".join(ctx.ip_info.get("compute_ips", [])) or "(none)"
    ctx.logger.info(f"""
{'='*70}
  CLUSTER BOOTSTRAP COMPLETE: {ctx.name}
{'='*70}

  Site:          {ctx.profile.get('site_name', ctx.site)}
  Segment:       {ctx.segment}
  Control Plane: {', '.join(ctx.ip_info.get('control_plane_ips', []))}
  Infra Nodes:   {', '.join(ctx.ip_info.get('infra_ips', []))}
  Compute Nodes: {compute}

  Kubeconfig:    {ctx.cluster_dir}/auth/kubeconfig
  Context file:  {ctx_file}

  export KUBECONFIG={ctx.cluster_dir}/auth/kubeconfig
{'='*70}""")


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

def main() -> None:
    args = parse_args()
    ctx = _build_context(args)
    validate_prerequisites(ctx.profile, args, ctx.logger)

    if args.destroy:
        _run_destroy(ctx)
        return

    _run_network(ctx)
    _run_templates(ctx)
    _run_ignition(ctx, args)
    _run_terraform(ctx, args)
    _save_context(ctx)
