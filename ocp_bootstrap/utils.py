import logging
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional


def setup_logging(cluster_name: str, work_dir: Path) -> logging.Logger:
    logger = logging.getLogger("ocp-bootstrap")
    if logger.handlers:
        return logger  # already configured (e.g., re-invoked in same process)

    logger.setLevel(logging.DEBUG)

    formatter = logging.Formatter(
        "%(asctime)s [%(levelname)-7s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    )

    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(formatter)
    logger.addHandler(ch)

    log_file = work_dir / f"{cluster_name}-bootstrap.log"
    fh = logging.FileHandler(log_file)
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(formatter)
    logger.addHandler(fh)

    return logger


def run_cmd(
    cmd: List[str],
    cwd: Optional[Path] = None,
    logger: Optional[logging.Logger] = None,
    env: Optional[Dict] = None,
) -> subprocess.CompletedProcess:
    """Run a subprocess with logging. Raises RuntimeError on non-zero exit."""
    cmd_str = " ".join(str(c) for c in cmd)
    if logger:
        logger.info(f"Running: {cmd_str}")

    merged_env = {**os.environ, **(env or {})}

    result = subprocess.run(
        cmd, cwd=cwd, capture_output=True, text=True, env=merged_env
    )

    if logger:
        if result.stdout.strip():
            for line in result.stdout.strip().split("\n"):
                logger.debug(f"  stdout: {line}")
        if result.stderr.strip():
            for line in result.stderr.strip().split("\n"):
                logger.debug(f"  stderr: {line}")

    if result.returncode != 0:
        if logger:
            logger.error(f"Command failed (rc={result.returncode}): {cmd_str}")
            logger.error(f"stderr: {result.stderr}")
        raise RuntimeError(f"Command failed: {cmd_str}\n{result.stderr}")

    return result


def validate_prerequisites(
    profile: Dict, args, logger: logging.Logger
) -> None:
    """Fail fast if required binaries are missing before any provisioning work starts."""
    missing = []
    checks = []

    if not getattr(args, "skip_ignition", False):
        checks.append(
            ("openshift-install", profile.get("openshift_install_bin", "openshift-install-4.20"))
        )
    if not getattr(args, "skip_terraform", False):
        checks.append(("terraform", profile.get("terraform_bin", "terraform")))

    need_oc = (
        not getattr(args, "skip_csr", False) and not getattr(args, "skip_terraform", False)
    ) or bool(profile.get("argocd_hub_api_url"))
    if need_oc:
        checks.append(("oc", "oc"))

    for label, binary in checks:
        if not shutil.which(binary):
            missing.append(f"  {label}: '{binary}' not found in PATH")

    if missing:
        logger.error("Pre-flight check failed — missing required binaries:")
        for m in missing:
            logger.error(m)
        sys.exit(1)

    if not getattr(args, "skip_terraform", False):
        have_creds = os.environ.get("AWS_ACCESS_KEY_ID") or os.environ.get("AWS_PROFILE")
        if not have_creds:
            logger.warning(
                "No AWS credentials in environment (AWS_ACCESS_KEY_ID or AWS_PROFILE). "
                "Terraform will fail to reach AWS unless credentials are configured."
            )
        if not profile.get("aws_region"):
            logger.warning("aws_region not set in the site/cluster config")

    logger.info("Pre-flight check passed (all required binaries found)")
