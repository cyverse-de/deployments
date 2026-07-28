"""Thin HTTP client for the Terrain endpoints appei uses."""

import requests


class TerrainError(Exception):
    """A Terrain request failed; carries the HTTP status and response body."""

    def __init__(self, method: str, url: str, status_code: int, body: str):
        self.status_code = status_code
        super().__init__(f"{method} {url} returned {status_code}: {body}")


class TerrainClient:
    def __init__(
        self,
        server: str,
        access_token: str | None = None,
        session: requests.Session | None = None,
        timeout: float = 60,
    ):
        self.base_url = f"https://{server}/terrain"
        self.access_token = access_token
        self.session = session if session is not None else requests.Session()
        self.timeout = timeout

    def _request(self, method: str, path: str, authenticated: bool = True, **kwargs):
        url = f"{self.base_url}/{path}"
        headers = {}
        if authenticated:
            headers["Authorization"] = f"Bearer {self.access_token}"
        res = self.session.request(
            method, url, headers=headers, timeout=self.timeout, **kwargs
        )
        if not res.ok:
            raise TerrainError(method, url, res.status_code, res.text)
        return res

    def get_token(self, username: str, password: str) -> dict:
        """Exchange username/password for a Keycloak access token."""
        res = self._request(
            "GET", "token/keycloak", authenticated=False, auth=(username, password)
        )
        return res.json()

    def admin_app_details(self, system_id: str, app_id: str) -> dict:
        return self._request("GET", f"admin/apps/{system_id}/{app_id}/details").json()

    def app(self, system_id: str, app_id: str) -> dict:
        return self._request("GET", f"apps/{system_id}/{app_id}").json()

    def admin_tool(self, tool_id: str) -> dict:
        return self._request("GET", f"admin/tools/{tool_id}").json()

    def list_admin_tools(self) -> list[dict]:
        return self._request("GET", "admin/tools").json()["tools"]

    def list_admin_apps(self, search: str | None = None) -> list[dict]:
        params = {"search": search} if search is not None else {}
        return self._request("GET", "admin/apps", params=params).json()["apps"]

    def list_apps(self, search: str | None = None) -> list[dict]:
        params = {"search": search} if search is not None else {}
        return self._request("GET", "apps", params=params).json()["apps"]

    def admin_share_apps(self, sharing: list[dict]) -> dict:
        return self._request(
            "POST", "admin/apps/sharing", json={"sharing": sharing}
        ).json()

    def admin_unshare_apps(self, unsharing: list[dict]) -> dict:
        return self._request(
            "POST", "admin/apps/unsharing", json={"unsharing": unsharing}
        ).json()

    def shred_apps(self, app_ids: list[dict]) -> None:
        """Permanently remove apps from the database.

        Uses the admin shredder, which deletes the rows outright; the
        non-admin `apps/shredder` route only sets the deleted flag.
        root_deletion_request is required to shred a public app and is
        ignored for private ones.
        """
        self._request(
            "POST",
            "admin/apps/shredder",
            json={"app_ids": app_ids, "root_deletion_request": True},
        )

    def import_tools(self, tools: list[dict]) -> dict:
        """Add tools DE-wide, which makes them public. See create_private_tool."""
        return self._request("POST", "admin/tools", json={"tools": tools}).json()

    def create_private_tool(self, tool: dict) -> dict:
        """Add a single tool owned by, and private to, the requesting user.

        Terrain forces restricted, network_mode and the resource limits to
        configured defaults here, and rejects the admin-only container fields.
        """
        return self._request("POST", "tools", json=tool).json()

    def delete_tool(self, tool_id: str) -> None:
        """Delete a tool, which Terrain refuses while any app still uses it.

        A soft-deleted app still counts as a user of its tool, so the app has
        to be shredded before its tool can go.
        """
        self._request("DELETE", f"admin/tools/{tool_id}")

    def create_app(self, system_id: str, app: dict) -> dict:
        return self._request("POST", f"apps/{system_id}", json=app).json()

    def publish_app(self, system_id: str, submission: dict) -> None:
        # Use the admin route: the non-admin one refuses to publish an app
        # whose tools the caller doesn't own, e.g. seeded tools with no
        # permission rows in the permissions service.
        self._request(
            "POST",
            f"admin/apps/{system_id}/{submission['id']}/publish",
            json=submission,
        )

    def bless_app(self, system_id: str, app_id: str) -> None:
        self._request("POST", f"admin/apps/{system_id}/{app_id}/blessing")

    def app_metadata(self, app_id: str) -> dict:
        return self._request("GET", f"admin/apps/{app_id}/metadata").json()

    def set_app_metadata(self, app_id: str, avus: list[dict]) -> None:
        self._request("PUT", f"admin/apps/{app_id}/metadata", json={"avus": avus})
