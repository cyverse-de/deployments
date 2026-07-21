import copy

import pytest

from appei.importer import BETA_AVU_ATTR, import_bundle

TOOL = {
    "id": "src-tool-uuid",
    "name": "cat",
    "version": "1.0",
    "permission": "own",
    "container": {"image": {"id": "img-uuid", "name": "quay.io/cat"}},
}

BUNDLE = {
    "id": "src-app-uuid",
    "name": "cat app",
    "version": "1.0",
    "version_id": "src-version-uuid",
    "system_id": "de",
    "description": "concatenate",
    "tools": [TOOL],
    "groups": [],
    "documentation": {"documentation": "docs body"},
}


class FakeClient:
    def __init__(
        self,
        tool_listing=(),
        app_listing=(),
        private_listing=(),
        avus=(),
    ):
        self._tool_listing = list(tool_listing)
        self._app_listing = list(app_listing)
        self._private_listing = list(private_listing)
        self._avus = list(avus)
        self.calls = []

    def list_admin_tools(self):
        return self._tool_listing

    def list_admin_apps(self, search=None):
        return self._app_listing

    def list_apps(self, search=None):
        return self._private_listing

    def import_tools(self, tools):
        self.calls.append(("import_tools", copy.deepcopy(tools)))
        return {"tool_ids": ["new-tool-uuid"]}

    def create_app(self, system_id, app):
        self.calls.append(("create_app", system_id, copy.deepcopy(app)))
        return {"id": "new-app-uuid", "name": app["name"]}

    def publish_app(self, system_id, submission):
        self.calls.append(("publish_app", system_id, copy.deepcopy(submission)))

    def bless_app(self, system_id, app_id):
        self.calls.append(("bless_app", system_id, app_id))

    def app_metadata(self, app_id):
        return {"avus": self._avus}

    def set_app_metadata(self, app_id, avus):
        self.calls.append(("set_app_metadata", app_id, copy.deepcopy(avus)))

    def named_calls(self, name):
        return [c for c in self.calls if c[0] == name]


def quiet(_msg):
    pass


class TestFreshImport:
    def test_imports_tool_then_app_with_rewritten_tool_id(self):
        client = FakeClient()
        app_id = import_bundle(client, BUNDLE, log=quiet)
        assert app_id == "new-app-uuid"

        (_, imported_tools) = client.named_calls("import_tools")[0]
        assert imported_tools[0]["name"] == "cat"
        assert "permission" not in imported_tools[0]

        (_, system_id, created) = client.named_calls("create_app")[0]
        assert system_id == "de"
        assert created["tools"][0]["id"] == "new-tool-uuid"
        assert "documentation" not in created

    def test_default_import_stays_private(self):
        client = FakeClient()
        app_id = import_bundle(client, BUNDLE, log=quiet)
        assert app_id == "new-app-uuid"
        assert client.named_calls("publish_app") == []
        assert client.named_calls("bless_app") == []
        assert client.named_calls("set_app_metadata") == []

    def test_publish_flag_publishes_without_blessing(self):
        client = FakeClient()
        import_bundle(client, BUNDLE, log=quiet, publish=True)
        (_, _, submission) = client.named_calls("publish_app")[0]
        assert submission["id"] == "new-app-uuid"
        assert submission["documentation"] == "docs body"
        assert client.named_calls("bless_app") == []

    def test_feature_flag_implies_publish_and_blesses(self):
        client = FakeClient()
        import_bundle(client, BUNDLE, log=quiet, feature=True)
        (_, _, submission) = client.named_calls("publish_app")[0]
        assert submission["id"] == "new-app-uuid"
        assert client.named_calls("bless_app") == [("bless_app", "de", "new-app-uuid")]

    def test_undocumented_app_publishes_with_empty_documentation(self):
        bundle = {key: value for key, value in BUNDLE.items() if key != "documentation"}
        client = FakeClient()
        messages = []
        import_bundle(client, bundle, log=messages.append, publish=True)
        (_, _, submission) = client.named_calls("publish_app")[0]
        assert submission["documentation"] == ""
        assert any("documentation" in message for message in messages)

    def test_does_not_mutate_input_bundle(self):
        original = copy.deepcopy(BUNDLE)
        import_bundle(FakeClient(), BUNDLE, log=quiet)
        assert BUNDLE == original


class TestExistingResources:
    def test_existing_tool_is_reused_not_reimported(self):
        client = FakeClient(
            tool_listing=[{"id": "target-tool-uuid", "name": "cat", "version": "1.0"}]
        )
        import_bundle(client, BUNDLE, log=quiet)
        assert client.named_calls("import_tools") == []
        (_, _, created) = client.named_calls("create_app")[0]
        assert created["tools"][0]["id"] == "target-tool-uuid"

    def test_public_app_skips_create_publish_and_bless(self):
        client = FakeClient(
            app_listing=[{"id": "pub-app-uuid", "name": "cat app", "version": "1.0"}]
        )
        app_id = import_bundle(client, BUNDLE, log=quiet)
        assert app_id == "pub-app-uuid"
        assert client.named_calls("create_app") == []
        assert client.named_calls("publish_app") == []
        assert client.named_calls("bless_app") == []

    def test_private_app_is_published_without_recreating(self):
        client = FakeClient(
            private_listing=[
                {"id": "priv-app-uuid", "name": "cat app", "version": "1.0"}
            ]
        )
        app_id = import_bundle(client, BUNDLE, log=quiet, publish=True)
        assert app_id == "priv-app-uuid"
        assert client.named_calls("create_app") == []
        (_, _, submission) = client.named_calls("publish_app")[0]
        assert submission["id"] == "priv-app-uuid"

    def test_existing_private_app_stays_private_by_default(self):
        client = FakeClient(
            private_listing=[
                {"id": "priv-app-uuid", "name": "cat app", "version": "1.0"}
            ]
        )
        app_id = import_bundle(client, BUNDLE, log=quiet)
        assert app_id == "priv-app-uuid"
        assert client.named_calls("create_app") == []
        assert client.named_calls("publish_app") == []


class TestBetaAvu:
    beta = {"attr": BETA_AVU_ATTR, "value": "beta", "unit": ""}
    other = {"attr": "something", "value": "else", "unit": ""}

    def test_removes_beta_avu_after_publishing(self):
        client = FakeClient(avus=[self.beta, self.other])
        import_bundle(client, BUNDLE, log=quiet, publish=True)
        assert client.named_calls("set_app_metadata") == [
            ("set_app_metadata", "new-app-uuid", [self.other])
        ]

    def test_leaves_metadata_alone_without_beta_avu(self):
        client = FakeClient(avus=[self.other])
        import_bundle(client, BUNDLE, log=quiet, publish=True)
        assert client.named_calls("set_app_metadata") == []


class TestValidation:
    @pytest.mark.parametrize("key", ["name", "version", "system_id"])
    def test_rejects_bundle_missing_required_field(self, key):
        bundle = copy.deepcopy(BUNDLE)
        del bundle[key]
        with pytest.raises(ValueError, match=key):
            import_bundle(FakeClient(), bundle, log=quiet)
