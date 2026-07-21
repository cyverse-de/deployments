import base64
import json

import pytest


@pytest.fixture
def make_jwt():
    """Build an unsigned JWT-shaped token with the given payload claims."""

    def _make(payload: dict) -> str:
        def encode(part: dict) -> str:
            raw = json.dumps(part).encode()
            return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

        return f"{encode({'alg': 'RS256'})}.{encode(payload)}.fakesignature"

    return _make
