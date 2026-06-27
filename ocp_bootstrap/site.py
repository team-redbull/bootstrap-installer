import os
import sys
from typing import Any, Dict

import yaml

from .constants import DEFAULTS_FILE, SITES_DIR


def load_site_profile(site: str) -> Dict[str, Any]:
    """
    Load the merged site profile:
      1. Start with config/defaults.yaml (global defaults)
      2. Override with config/sites/<site>.yaml (site-specific values)
      3. Resolve any *_env keys to their environment variable values
    """
    # 1. Global defaults
    profile: Dict[str, Any] = {}
    if DEFAULTS_FILE.exists():
        with open(DEFAULTS_FILE) as f:
            profile = yaml.safe_load(f) or {}
    else:
        print(f"WARNING: Global defaults file not found: {DEFAULTS_FILE}")

    # 2. Site-specific overrides (site values win over defaults)
    site_file = SITES_DIR / f"{site}.yaml"
    if not site_file.exists():
        print(f"ERROR: Site profile not found: {site_file}")
        print(f"Available sites: {[f.stem for f in SITES_DIR.glob('*.yaml')]}")
        sys.exit(1)

    with open(site_file) as f:
        site_data = yaml.safe_load(f) or {}

    profile.update(site_data)

    # 3. Resolve *_env keys (e.g. argocd_hub_token_env: HUB_CLUSTER_SA_TOKEN)
    for key, value in list(profile.items()):
        if key.endswith("_env"):
            env_var = value
            resolved = os.environ.get(env_var)
            if not resolved:
                print(f"WARNING: Environment variable {env_var} not set (referenced by {key})")
            base_key = key.removesuffix("_env")
            profile[base_key] = resolved or ""

    return profile
