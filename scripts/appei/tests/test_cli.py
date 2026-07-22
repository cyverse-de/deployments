import json

import pytest

from appei import cli, tokens
from appei.client import TerrainError


@pytest.fixture(autouse=True)
def config_home(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path))
    monkeypatch.delenv("APPEI_PASSWORD", raising=False)
    return tmp_path


class FakeClient:
    instances = []

    def __init__(self, server, access_token=None, session=None):
        self.server = server
        self.access_token = access_token
        self.login_attempts = []
        self.published = []
        self.blessed = []
        FakeClient.instances.append(self)

    def get_token(self, username, password):
        self.login_attempts.append((username, password))
        return {"access_token": "fresh-token"}

    def list_admin_apps(self, search=None):
        return [{"id": "app-uuid", "system_id": "de", "name": "cat app"}]

    def admin_app_details(self, system_id, app_id):
        return {
            "id": app_id,
            "system_id": system_id,
            "name": "cat app",
            "version": "1.0",
            "tools": [{"id": "tool-uuid", "name": "cat", "version": "1.0"}],
        }

    def app(self, system_id, app_id):
        return {"id": app_id, "groups": []}

    def admin_tool(self, tool_id):
        return {"id": tool_id, "container": {"image": {"name": "quay.io/cat"}}}

    def list_admin_tools(self):
        return []

    def list_apps(self, search=None):
        return []

    def import_tools(self, tools):
        return {"tool_ids": ["new-tool-uuid"]}

    def create_app(self, system_id, app):
        return {"id": "new-app-uuid"}

    def publish_app(self, system_id, submission):
        self.published.append((system_id, submission["id"]))

    def bless_app(self, system_id, app_id):
        self.blessed.append((system_id, app_id))

    def app_metadata(self, app_id):
        return {"avus": []}

    def set_app_metadata(self, app_id, avus):
        pass


@pytest.fixture(autouse=True)
def fake_client(monkeypatch):
    FakeClient.instances = []
    monkeypatch.setattr(cli, "TerrainClient", FakeClient)
    return FakeClient


class TestLogin:
    def test_saves_token_from_flag_password(self):
        rc = cli.main(
            [
                "login",
                "--server",
                "de.example.org",
                "--username",
                "admin",
                "--password",
                "hunter2",
            ]
        )
        assert rc == 0
        assert tokens.load_token("de.example.org") == {"access_token": "fresh-token"}
        assert FakeClient.instances[0].login_attempts == [("admin", "hunter2")]

    def test_falls_back_to_env_password(self, monkeypatch):
        monkeypatch.setenv("APPEI_PASSWORD", "from-env")
        rc = cli.main(["login", "--server", "de.example.org", "--username", "admin"])
        assert rc == 0
        assert FakeClient.instances[0].login_attempts == [("admin", "from-env")]


class TestLogout:
    def test_deletes_cached_token(self):
        tokens.save_token("de.example.org", {"access_token": "old"})
        assert cli.main(["logout", "--server", "de.example.org"]) == 0
        with pytest.raises(tokens.TokenError):
            tokens.load_token("de.example.org")

    def test_ok_when_no_token_cached(self):
        assert cli.main(["logout", "--server", "de.example.org"]) == 0


class TestList:
    def test_prints_apps_table(self, capsys):
        tokens.save_token("de.example.org", {"access_token": "tok"})
        assert cli.main(["list", "--server", "de.example.org"]) == 0
        out = capsys.readouterr().out
        assert "app-uuid" in out
        assert "cat app" in out

    def test_requires_login(self, capsys):
        assert cli.main(["list", "--server", "de.example.org"]) == 1
        assert "appei login" in capsys.readouterr().err


class TestExport:
    def test_writes_bundle_to_output_file(self, tmp_path):
        tokens.save_token("de.example.org", {"access_token": "tok"})
        out_file = tmp_path / "cat-app.json"
        rc = cli.main(
            [
                "export",
                "--server",
                "de.example.org",
                "--id",
                "app-uuid",
                "--output",
                str(out_file),
            ]
        )
        assert rc == 0
        bundle = json.loads(out_file.read_text())
        assert bundle["name"] == "cat app"
        assert bundle["tools"][0]["container"]["image"]["name"] == "quay.io/cat"

    def test_prints_bundle_without_output_flag(self, capsys):
        tokens.save_token("de.example.org", {"access_token": "tok"})
        rc = cli.main(["export", "--server", "de.example.org", "--id", "app-uuid"])
        assert rc == 0
        assert json.loads(capsys.readouterr().out)["name"] == "cat app"


class TestImport:
    def write_bundle(self, tmp_path):
        tokens.save_token("de.example.org", {"access_token": "tok"})
        bundle = {
            "name": "cat app",
            "version": "1.0",
            "system_id": "de",
            "tools": [],
        }
        in_file = tmp_path / "bundle.json"
        in_file.write_text(json.dumps(bundle))
        return str(in_file)

    def test_imports_bundle_from_file(self, tmp_path, capsys):
        in_file = self.write_bundle(tmp_path)
        rc = cli.main(["import", "--server", "de.example.org", "--input", in_file])
        assert rc == 0
        assert "new-app-uuid" in capsys.readouterr().out

    def test_default_import_is_private(self, tmp_path):
        in_file = self.write_bundle(tmp_path)
        cli.main(["import", "--server", "de.example.org", "--input", in_file])
        client = FakeClient.instances[-1]
        assert client.published == []
        assert client.blessed == []

    def test_publish_flag_publishes_without_featuring(self, tmp_path):
        in_file = self.write_bundle(tmp_path)
        cli.main(
            ["import", "--server", "de.example.org", "--input", in_file, "--publish"]
        )
        client = FakeClient.instances[-1]
        assert client.published == [("de", "new-app-uuid")]
        assert client.blessed == []

    def test_feature_flag_publishes_and_features(self, tmp_path):
        in_file = self.write_bundle(tmp_path)
        cli.main(
            ["import", "--server", "de.example.org", "--input", in_file, "--feature"]
        )
        client = FakeClient.instances[-1]
        assert client.published == [("de", "new-app-uuid")]
        assert client.blessed == [("de", "new-app-uuid")]


class TestErrorHandling:
    def test_terrain_error_reported_on_stderr(self, monkeypatch, capsys):
        tokens.save_token("de.example.org", {"access_token": "tok"})

        def boom(self, search=None):
            raise TerrainError("GET", "https://x", 401, "token expired")

        monkeypatch.setattr(FakeClient, "list_admin_apps", boom)
        assert cli.main(["list", "--server", "de.example.org"]) == 1
        assert "token expired" in capsys.readouterr().err
