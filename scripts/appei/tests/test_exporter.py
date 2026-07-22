import pytest

from appei.client import TerrainError
from appei.exporter import export_app


class FakeClient:
    def __init__(self):
        self.tool_requests = []

    def admin_app_details(self, system_id, app_id):
        return {
            "id": app_id,
            "system_id": system_id,
            "name": "cat app",
            "tools": [{"id": "tool-uuid", "name": "cat"}],
        }

    def app(self, system_id, app_id):
        return {
            "id": app_id,
            "label": "cat app label",
            "groups": [{"name": "params", "parameters": []}],
        }

    def admin_tool(self, tool_id):
        self.tool_requests.append(tool_id)
        return {
            "id": tool_id,
            "container": {"image": {"name": "quay.io/cat"}},
            "implementation": {"test": {"input_files": []}},
        }


class TestExportApp:
    def test_merges_details_job_view_and_tool_details(self):
        exported = export_app(FakeClient(), "de", "app-uuid")
        assert exported["name"] == "cat app"
        assert exported["label"] == "cat app label"
        assert exported["groups"] == [{"name": "params", "parameters": []}]
        tool = exported["tools"][0]
        assert tool["name"] == "cat"
        assert tool["container"]["image"]["name"] == "quay.io/cat"
        assert tool["implementation"]["test"] == {"input_files": []}

    def test_fetches_each_tool_by_id(self):
        client = FakeClient()
        export_app(client, "de", "app-uuid")
        assert client.tool_requests == ["tool-uuid"]


class PrivateAppClient(FakeClient):
    """Denies the job view until the app has been shared with adminuser."""

    def __init__(self, make_jwt, share_error=None, unshare_error=None):
        super().__init__()
        self.access_token = make_jwt({"preferred_username": "adminuser"})
        self.share_error = share_error
        self.unshare_error = unshare_error
        self.shared = False
        self.share_requests = []
        self.unshare_requests = []

    def app(self, system_id, app_id):
        if not self.shared:
            raise TerrainError(
                "GET",
                f"https://de.example.org/terrain/apps/{system_id}/{app_id}",
                403,
                "insufficient privileges",
            )
        return super().app(system_id, app_id)

    def admin_share_apps(self, sharing):
        self.share_requests.append(sharing)
        app_request = sharing[0]["apps"][0]
        if self.share_error is not None:
            return {
                "sharing": [
                    {
                        "subject": sharing[0]["subject"],
                        "apps": [
                            {
                                **app_request,
                                "app_name": "cat app",
                                "success": False,
                                "error": {"reason": self.share_error},
                            }
                        ],
                    }
                ]
            }
        self.shared = True
        return {
            "sharing": [
                {
                    "subject": sharing[0]["subject"],
                    "apps": [{**app_request, "app_name": "cat app", "success": True}],
                }
            ]
        }

    def admin_unshare_apps(self, unsharing):
        self.unshare_requests.append(unsharing)
        if self.unshare_error is not None:
            raise self.unshare_error
        self.shared = False
        return {"unsharing": []}


class TestPrivateAppExport:
    def test_self_shares_read_and_retries_on_403(self, make_jwt):
        client = PrivateAppClient(make_jwt)
        exported = export_app(client, "de", "app-uuid", log=lambda _: None)
        assert exported["groups"] == [{"name": "params", "parameters": []}]
        assert client.share_requests == [
            [
                {
                    "subject": {"source_id": "ldap", "id": "adminuser"},
                    "apps": [
                        {"system_id": "de", "app_id": "app-uuid", "permission": "read"}
                    ],
                }
            ]
        ]

    def test_unshares_after_export(self, make_jwt):
        client = PrivateAppClient(make_jwt)
        export_app(client, "de", "app-uuid", log=lambda _: None)
        assert client.unshare_requests == [
            [
                {
                    "subject": {"source_id": "ldap", "id": "adminuser"},
                    "apps": [{"system_id": "de", "app_id": "app-uuid"}],
                }
            ]
        ]

    def test_logs_the_temporary_share(self, make_jwt):
        messages = []
        export_app(PrivateAppClient(make_jwt), "de", "app-uuid", log=messages.append)
        assert any("sharing" in message for message in messages)

    def test_failed_share_raises_with_reason(self, make_jwt):
        client = PrivateAppClient(make_jwt, share_error="app not found")
        with pytest.raises(ValueError, match="app not found"):
            export_app(client, "de", "app-uuid", log=lambda _: None)
        assert client.unshare_requests == []

    def test_unshare_failure_logs_warning_but_export_succeeds(self, make_jwt):
        unshare_error = TerrainError("POST", "url", 500, "boom")
        client = PrivateAppClient(make_jwt, unshare_error=unshare_error)
        messages = []
        exported = export_app(client, "de", "app-uuid", log=messages.append)
        assert exported["name"] == "cat app"
        assert any("could not remove" in message for message in messages)

    def test_non_403_error_propagates_without_sharing(self, make_jwt):
        client = PrivateAppClient(make_jwt)

        def broken_app(system_id, app_id):
            raise TerrainError("GET", "url", 500, "server error")

        client.app = broken_app
        with pytest.raises(TerrainError, match="server error"):
            export_app(client, "de", "app-uuid", log=lambda _: None)
        assert client.share_requests == []
