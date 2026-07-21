"""Per-server access-token cache under the user's config directory."""

import base64
import binascii
import json
import os
from pathlib import Path


class TokenError(Exception):
    """No cached token for a server; the user needs to run `appei login`."""


def token_path(server: str) -> Path:
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", "") or Path.home() / ".config")
    return config_home / "cyverse" / "discoenv" / "appei" / server


def save_token(server: str, token_data: dict) -> Path:
    path = token_path(server)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(token_data), encoding="utf-8")
    path.chmod(0o600)
    return path


def load_token(server: str) -> dict:
    path = token_path(server)
    if not path.is_file():
        raise TokenError(
            f"no cached token for {server} at {path}; run `appei login --server {server}` first"
        )
    return json.loads(path.read_text(encoding="utf-8"))


def username_from_token(access_token: str) -> str:
    """Read preferred_username from a JWT's payload, without verifying it."""
    try:
        payload_b64 = access_token.split(".")[1]
        padded = payload_b64 + "=" * (-len(payload_b64) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded))
        return payload["preferred_username"]
    except (IndexError, KeyError, ValueError, binascii.Error) as exc:
        raise TokenError(
            f"could not read a username from the cached access token ({exc}); "
            "it may be malformed — try `appei login` again"
        ) from exc


def delete_token(server: str) -> bool:
    """Remove the cached token; report whether one existed."""
    path = token_path(server)
    if not path.is_file():
        return False
    path.unlink()
    return True
