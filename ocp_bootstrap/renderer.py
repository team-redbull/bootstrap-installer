import logging
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict

from jinja2 import Environment, FileSystemLoader

from .constants import SCRIPT_DIR, TEMPLATES_DIR


def build_template_context(
    cluster_name: str,
    profile: Dict[str, Any],
    ip_info: Dict[str, Any],
    segment: str,
    vlan_id: str,
    cluster_dir: Path,
) -> Dict[str, Any]:
    """Merge all data into a single Jinja2 template context."""

    # Pull secret: site profile path → config/pull-secret.json → PULL_SECRET env var
    pull_secret_path = Path(
        profile.get("pull_secret_path", str(SCRIPT_DIR / "config" / "pull-secret.json"))
    )
    if pull_secret_path.exists():
        pull_secret = pull_secret_path.read_text().strip()
    else:
        pull_secret = os.environ.get("PULL_SECRET", "{}")
        if pull_secret == "{}":
            print(f"WARNING: No pull secret found at {pull_secret_path} or PULL_SECRET env var")

    # SSH key: site profile path → ~/.ssh/id_rsa.pub → SSH_PUBLIC_KEY env var
    ssh_key = ""
    ssh_key_path = Path(
        profile.get("ssh_public_key_path", str(Path.home() / ".ssh" / "id_rsa.pub"))
    )
    if ssh_key_path.exists():
        ssh_key = ssh_key_path.read_text().strip()
    elif os.environ.get("SSH_PUBLIC_KEY"):
        ssh_key = os.environ["SSH_PUBLIC_KEY"]

    # Additional trust bundle: site profile path → config/additional-trust-bundle.pem
    additional_trust_bundle = ""
    trust_bundle_path = Path(
        profile.get(
            "additional_trust_bundle_path",
            str(SCRIPT_DIR / "config" / "additional-trust-bundle.pem"),
        )
    )
    if trust_bundle_path.exists():
        additional_trust_bundle = trust_bundle_path.read_text().strip()

    vpc_id = profile.get("vpc_id")
    if not vpc_id:
        raise ValueError(
            "vpc_id is required in the site/cluster config "
            "(the existing VPC the subnet is created in, e.g. vpc_id: vpc-0abc123)"
        )

    return {
        "cluster_name": cluster_name,
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        **profile,
        **ip_info,
        "segment": segment,
        "vlan_id": vlan_id,
        "vpc_id": vpc_id,
        "ignition_dir": str(cluster_dir / "ignition"),
        "pull_secret": pull_secret,
        "ssh_key": ssh_key,
        "additional_trust_bundle": additional_trust_bundle,
        # Networking defaults — override in site profile if needed
        "cluster_network_cidr": profile.get("cluster_network_cidr", "10.132.0.0/14"),
        "cluster_network_host_prefix": profile.get("cluster_network_host_prefix", 23),
        "service_network_cidr": profile.get("service_network_cidr", "172.31.0.0/16"),
    }


def render_templates(
    ctx: Dict[str, Any],
    cluster_dir: Path,
    logger: logging.Logger,
) -> Dict[str, Path]:
    """Render all Jinja2 templates and write output files."""
    env = Environment(
        loader=FileSystemLoader(str(TEMPLATES_DIR)),
        keep_trailing_newline=True,
    )
    outputs = {}

    # install-config.yaml
    install_config_dir = cluster_dir / "install"
    install_config_dir.mkdir(parents=True, exist_ok=True)
    out_path = install_config_dir / "install-config.yaml"
    out_path.write_text(env.get_template("install-config.yaml.j2").render(ctx))
    outputs["install-config"] = out_path
    logger.info(f"Rendered install-config.yaml -> {out_path}")

    backup = cluster_dir / "install-config.yaml.backup"
    shutil.copy2(out_path, backup)
    logger.debug(f"Backup install-config -> {backup}")

    # terraform.tfvars
    out_path = cluster_dir / "terraform.tfvars"
    out_path.write_text(env.get_template("terraform.tfvars.j2").render(ctx))
    outputs["terraform.tfvars"] = out_path
    logger.info(f"Rendered terraform.tfvars -> {out_path}")

    # v4InternalSubnet manifest (injected after create manifests)
    out_path = cluster_dir / "v4-internal-subnet.yaml"
    out_path.write_text(env.get_template("v4-internal-subnet.yaml.j2").render(ctx))
    outputs["v4-internal-subnet"] = out_path
    logger.info(f"Rendered v4-internal-subnet.yaml -> {out_path}")

    return outputs
