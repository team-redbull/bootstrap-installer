from pathlib import Path

# Project root = one level above this package directory
SCRIPT_DIR = Path(__file__).parent.parent.resolve()

TEMPLATES_DIR = SCRIPT_DIR / "templates"
SITES_DIR = SCRIPT_DIR / "config" / "sites"
CLUSTERS_DIR = SCRIPT_DIR / "config" / "clusters"
DEFAULTS_FILE = SCRIPT_DIR / "config" / "defaults.yaml"
DEFAULT_WORK_DIR = SCRIPT_DIR / "clusters"
TERRAFORM_DIR = SCRIPT_DIR / "aws"
