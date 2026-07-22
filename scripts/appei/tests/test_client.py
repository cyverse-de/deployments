import pytest

from appei.client import TerrainClient, TerrainError


class FakeResponse:
    def __init__(self, status_code=200, payload=None, text=""):
        self.status_code = status_code
        self._payload = payload if payload is not None else {}
        self.text = text or "error body"

    @property
    def ok(self):
        return self.status_code < 400

    def json(self):
        return self._payload


class FakeSession:
    def __init__(self, responses=None):
        self.responses = list(responses or [FakeResponse()])
        self.requests = []

    def request(self, method, url, **kwargs):
        self.requests.append((method, url, kwargs))
        return self.responses.pop(0)


def make_client(**kwargs):
    session = kwargs.pop("session", FakeSession(**kwargs))
    return TerrainClient("de.example.org", access_token="tok", session=session), session


class TestRequestShape:
    def test_admin_tool_url_and_bearer_header(self):
        client, session = make_client()
        client.admin_tool("tool-uuid")
        method, url, kwargs = session.requests[0]
        assert method == "GET"
        assert url == "https://de.example.org/terrain/admin/tools/tool-uuid"
        assert kwargs["headers"]["Authorization"] == "Bearer tok"
        assert kwargs["timeout"] == client.timeout

    def test_import_tools_posts_wrapped_list(self):
        client, session = make_client(
            responses=[FakeResponse(payload={"tool_ids": ["new-uuid"]})]
        )
        result = client.import_tools([{"name": "cat"}])
        method, url, kwargs = session.requests[0]
        assert method == "POST"
        assert url == "https://de.example.org/terrain/admin/tools"
        assert kwargs["json"] == {"tools": [{"name": "cat"}]}
        assert result == {"tool_ids": ["new-uuid"]}

    def test_list_admin_apps_passes_search(self):
        client, session = make_client(responses=[FakeResponse(payload={"apps": []})])
        assert client.list_admin_apps(search="cat") == []
        _, url, kwargs = session.requests[0]
        assert url == "https://de.example.org/terrain/admin/apps"
        assert kwargs["params"] == {"search": "cat"}

    def test_admin_share_apps_posts_wrapped_list(self):
        sharing = [
            {
                "subject": {"source_id": "ldap", "id": "adminuser"},
                "apps": [
                    {"system_id": "de", "app_id": "app-uuid", "permission": "read"}
                ],
            }
        ]
        client, session = make_client(responses=[FakeResponse(payload={"sharing": []})])
        result = client.admin_share_apps(sharing)
        method, url, kwargs = session.requests[0]
        assert method == "POST"
        assert url == "https://de.example.org/terrain/admin/apps/sharing"
        assert kwargs["json"] == {"sharing": sharing}
        assert result == {"sharing": []}

    def test_admin_unshare_apps_posts_wrapped_list(self):
        unsharing = [
            {
                "subject": {"source_id": "ldap", "id": "adminuser"},
                "apps": [{"system_id": "de", "app_id": "app-uuid"}],
            }
        ]
        client, session = make_client(
            responses=[FakeResponse(payload={"unsharing": []})]
        )
        result = client.admin_unshare_apps(unsharing)
        method, url, kwargs = session.requests[0]
        assert method == "POST"
        assert url == "https://de.example.org/terrain/admin/apps/unsharing"
        assert kwargs["json"] == {"unsharing": unsharing}
        assert result == {"unsharing": []}

    def test_publish_app_uses_admin_route(self):
        # The non-admin publish route rejects apps whose tools the caller
        # doesn't own (e.g. seeded tools with no permission rows).
        client, session = make_client()
        client.publish_app("de", {"id": "app-uuid", "name": "cat app"})
        method, url, kwargs = session.requests[0]
        assert method == "POST"
        assert url == "https://de.example.org/terrain/admin/apps/de/app-uuid/publish"
        assert kwargs["json"] == {"id": "app-uuid", "name": "cat app"}

    def test_get_token_uses_basic_auth_not_bearer(self):
        session = FakeSession([FakeResponse(payload={"access_token": "fresh"})])
        client = TerrainClient("de.example.org", session=session)
        token = client.get_token("admin", "hunter2")
        method, url, kwargs = session.requests[0]
        assert method == "GET"
        assert url == "https://de.example.org/terrain/token/keycloak"
        assert kwargs["auth"] == ("admin", "hunter2")
        assert "Authorization" not in kwargs["headers"]
        assert token == {"access_token": "fresh"}


class TestErrors:
    def test_error_response_raises_terrain_error_with_body(self):
        client, _ = make_client(
            responses=[FakeResponse(status_code=400, text="bad app json")]
        )
        with pytest.raises(TerrainError, match="bad app json") as excinfo:
            client.create_app("de", {"name": "cat app"})
        assert excinfo.value.status_code == 400
