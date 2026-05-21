"""Install context: parsed configurator output, invocation paths, and a
mutable `state` dict for objects that live across phases (e.g., the
archinstall config handler and mirror list handler)."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class InstallContext:
    config_path: Path
    creds_path: Path
    full_name: str
    email: str
    encrypt: bool

    user_configuration: dict
    user_credentials: dict

    target: Path = Path("/mnt")
    omarchy_path: Path = Path("/usr/share/omarchy")
    state_dir: Path = Path("/run/omarchy-install")
    log_path: Path = Path("/var/log/omarchy-install.log")
    target_log_path: Path = Path("/mnt/var/log/omarchy-install.log")

    # Mutable per-run state shared across phases (e.g., 'arch_config_handler',
    # 'mirror_handler'). Phases populate as needed; later phases read.
    state: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_env(cls) -> "InstallContext":
        config_str = os.environ.get("OMARCHY_INSTALL_CONFIG")
        creds_str = os.environ.get("OMARCHY_INSTALL_CREDS")
        if not config_str or not creds_str:
            raise RuntimeError("OMARCHY_INSTALL_CONFIG and OMARCHY_INSTALL_CREDS must be set")

        config_path = Path(config_str)
        creds_path = Path(creds_str)
        user_configuration = json.loads(config_path.read_text())
        ctx = cls(
            config_path=config_path,
            creds_path=creds_path,
            full_name=_read_text(os.environ.get("OMARCHY_INSTALL_FULL_NAME_FILE")),
            email=_read_text(os.environ.get("OMARCHY_INSTALL_EMAIL_FILE")),
            encrypt=_read_text(os.environ.get("OMARCHY_INSTALL_ENCRYPT_FILE")).lower() in ("true", "yes", "1"),
            user_configuration=user_configuration,
            user_credentials=json.loads(creds_path.read_text()),
        )
        disk_config = user_configuration.get("disk_config", {})
        if (
            disk_config.get("config_type") == "pre_mounted_config"
            and disk_config.get("mountpoint")
        ):
            ctx.target = Path(disk_config["mountpoint"])
        return ctx

    @property
    def username(self) -> str:
        return self.user_credentials["users"][0]["username"]

    @property
    def mode(self) -> str:
        cfg_type = self.user_configuration.get("disk_config", {}).get("config_type")
        return "protected" if cfg_type == "pre_mounted_config" else "full_disk"

    @property
    def is_protected(self) -> bool:
        return self.mode == "protected"


def _read_text(path: str | None) -> str:
    if not path:
        return ""
    p = Path(path)
    if not p.exists():
        return ""
    return p.read_text().strip()
