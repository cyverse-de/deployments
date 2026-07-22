"""Export an app and its tools as one importable JSON bundle."""

from collections.abc import Callable

from appei import tokens, transform
from appei.client import TerrainClient, TerrainError


def export_app(
    client: TerrainClient,
    system_id: str,
    app_id: str,
    log: Callable[[str], None] = print,
) -> dict:
    """Merge the admin details, job view, and full tool details for an app."""
    app = transform.merge(
        client.admin_app_details(system_id, app_id),
        _job_view(client, system_id, app_id, log),
    )
    app["tools"] = [
        transform.merge(tool, client.admin_tool(tool["id"]))
        for tool in app.get("tools", [])
    ]
    return app


def _job_view(
    client: TerrainClient, system_id: str, app_id: str, log: Callable[[str], None]
) -> dict:
    """Fetch the app's job view, self-sharing read access if it's private.

    The job-view endpoint checks the caller's own app permissions, which admin
    group membership doesn't grant, so a private app 403s even for admins. The
    admin sharing endpoint can grant read on any app; use it temporarily and
    undo the grant afterward.
    """
    try:
        return client.app(system_id, app_id)
    except TerrainError as err:
        if err.status_code != 403:
            raise
    username = tokens.username_from_token(client.access_token)
    log(
        f"no read permission on app {app_id} (it is probably private); "
        f"temporarily sharing it with {username} to export it"
    )
    subject = {"source_id": "ldap", "id": username}
    response = client.admin_share_apps(
        [
            {
                "subject": subject,
                "apps": [
                    {"system_id": system_id, "app_id": app_id, "permission": "read"}
                ],
            }
        ]
    )
    _check_share_response(response, app_id)
    try:
        return client.app(system_id, app_id)
    finally:
        try:
            client.admin_unshare_apps(
                [
                    {
                        "subject": subject,
                        "apps": [{"system_id": system_id, "app_id": app_id}],
                    }
                ]
            )
        except TerrainError as err:
            log(
                f"warning: could not remove the temporary share of app {app_id} "
                f"from {username}: {err}"
            )


def _check_share_response(response: dict, app_id: str) -> None:
    """The sharing endpoint returns 200 with per-app success flags; check them."""
    for subject_result in response.get("sharing", []):
        for app_result in subject_result.get("apps", []):
            if not app_result.get("success", False):
                reason = app_result.get("error", {}).get("reason", "unknown reason")
                raise ValueError(f"could not share app {app_id} for export: {reason}")
