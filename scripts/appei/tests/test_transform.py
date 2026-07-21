import pytest

from appei import transform


def make_tool() -> dict:
    return {
        "id": "tool-uuid",
        "name": "cat",
        "version": "1.0",
        "permission": "own",
        "is_public": True,
        "implementation": {
            "implementor": "someone",
            "implementor_email": "someone@example.org",
            "test": {"input_files": [], "output_files": []},
        },
        "container": {
            "id": "container-uuid",
            "memory_limit": 4,
            "interactive_apps": {"id": "ia-uuid", "image": "img"},
            "image": {"id": "image-uuid", "name": "quay.io/cat", "tag": "latest"},
            "container_ports": [{"id": "port-uuid", "container_port": 80}],
        },
    }


def make_app() -> dict:
    return {
        "id": "app-uuid",
        "name": "cat app",
        "version": "1.0",
        "system_id": "de",
        "description": "concatenate",
        "tools": [make_tool()],
        "groups": [
            {
                "id": "group-uuid",
                "name": "params",
                "step_number": 1,
                "parameters": [
                    {"id": "param-uuid", "type": "Text", "label": "a text param"}
                ],
            }
        ],
    }


class TestCleanToolForImport:
    def test_removes_instance_specific_fields(self):
        cleaned = transform.clean_tool_for_import(make_tool())
        assert "permission" not in cleaned
        assert "is_public" not in cleaned
        assert "id" not in cleaned["container"]["interactive_apps"]
        assert "id" not in cleaned["container"]["image"]
        assert all("id" not in p for p in cleaned["container"]["container_ports"])

    def test_keeps_everything_else(self):
        cleaned = transform.clean_tool_for_import(make_tool())
        assert cleaned["name"] == "cat"
        assert cleaned["container"]["image"]["name"] == "quay.io/cat"
        assert cleaned["implementation"]["test"] == {
            "input_files": [],
            "output_files": [],
        }

    def test_does_not_mutate_input(self):
        tool = make_tool()
        transform.clean_tool_for_import(tool)
        assert tool == make_tool()

    def test_tolerates_missing_container(self):
        cleaned = transform.clean_tool_for_import({"name": "bare", "version": "1"})
        assert cleaned == {"name": "bare", "version": "1"}


class TestCleanAppForImport:
    @pytest.mark.parametrize("key", sorted(transform.APP_IMPORT_DROP_KEYS))
    def test_drops_top_level_key(self, key):
        app = make_app()
        app[key] = "anything"
        assert key not in transform.clean_app_for_import(app)

    def test_returns_cleaned_copy_without_mutating_input(self):
        app = make_app()
        cleaned = transform.clean_app_for_import(app)
        assert cleaned is not app
        assert app == make_app()
        assert cleaned["name"] == "cat app"

    def test_strips_tool_details_kept_only_for_tool_import(self):
        cleaned = transform.clean_app_for_import(make_app())
        tool = cleaned["tools"][0]
        assert "test" not in tool["implementation"]
        assert "interactive_apps" not in tool["container"]
        assert "container_ports" not in tool["container"]
        assert "id" not in tool["container"]
        assert "id" not in tool["container"]["image"]

    def test_drops_source_app_and_version_ids(self):
        # Keeping the source UUID collides with seeded apps (e.g. DE Word
        # Count) that exist on the target under the same primary key.
        app = make_app()
        app["version_id"] = "src-version-uuid"
        cleaned = transform.clean_app_for_import(app)
        assert "id" not in cleaned
        assert "version_id" not in cleaned

    def test_tool_container_is_reduced_to_allowed_keys(self):
        # The app create request only accepts the container's Settings keys
        # plus image; anything else is rejected as a disallowed key.
        app = make_app()
        container = app["tools"][0]["container"]
        container["entrypoint"] = "/bin/cat"
        container["container_volumes_from"] = [{"name": "data"}]
        container["container_devices"] = [{"host_path": "/dev/x"}]
        container["container_volumes"] = [{"host_path": "/tmp"}]
        cleaned = transform.clean_app_for_import(app)["tools"][0]["container"]
        assert "container_volumes_from" not in cleaned
        assert "container_devices" not in cleaned
        assert "container_volumes" not in cleaned
        assert cleaned["memory_limit"] == 4
        assert cleaned["entrypoint"] == "/bin/cat"
        assert cleaned["image"] == {"name": "quay.io/cat", "tag": "latest"}

    def test_strips_group_and_parameter_ids(self):
        cleaned = transform.clean_app_for_import(make_app())
        group = cleaned["groups"][0]
        assert "step_number" not in group
        assert all("id" not in p for p in group["parameters"])


def clean_parameter(param: dict) -> dict:
    app = make_app()
    app["groups"][0]["parameters"] = [param]
    return transform.clean_app_for_import(app)["groups"][0]["parameters"][0]


class TestParameterDefaults:
    def test_flag_gets_default_value_and_name(self):
        param = clean_parameter({"type": "Flag"})
        assert param["defaultValue"] is False
        assert param["name"] == {
            "checked": {"option": "", "value": ""},
            "unchecked": {"option": "", "value": ""},
        }

    def test_flag_keeps_existing_values(self):
        param = clean_parameter({"type": "Flag", "defaultValue": True, "name": "-v"})
        assert param["defaultValue"] is True
        assert param["name"] == "-v"

    def test_text_selection_gets_defaults(self):
        param = clean_parameter({"type": "TextSelection"})
        assert param["arguments"] == []
        assert param["defaultValue"] == ""
        assert param["required"] is False
        assert param["omit_if_blank"] is False

    @pytest.mark.parametrize(
        "ptype",
        ["MultiFileOutput", "FileInput", "FolderInput", "FileOutput", "FolderOutput"],
    )
    def test_file_parameter_defaults_overwrite(self, ptype):
        param = clean_parameter(
            {"type": ptype, "defaultValue": "old", "required": True}
        )
        assert param["defaultValue"] == ""
        assert param["required"] is False
        assert param["omit_if_blank"] is False
        assert param["file_parameters"] == {
            "is_implicit": False,
            "data_source": "file",
            "format": "Unspecified",
            "file_info_type": "File",
        }

    def test_multi_file_selector_defaults(self):
        param = clean_parameter({"type": "MultiFileSelector"})
        assert param["defaultValue"] == []
        assert param["file_parameters"]["repeat_option_flag"] is False

    def test_other_types_lose_file_parameters(self):
        param = clean_parameter({"type": "Text", "file_parameters": {"format": "x"}})
        assert "file_parameters" not in param


class TestCreateAppSubmission:
    def test_copies_top_level_fields_and_flattens_documentation(self):
        app = make_app()
        app["documentation"] = {"documentation": "docs body", "id": "doc-uuid"}
        app["references"] = ["https://example.org"]
        submission = transform.create_app_submission(app)
        assert submission["avus"] == []
        assert submission["name"] == "cat app"
        assert submission["system_id"] == "de"
        assert submission["references"] == ["https://example.org"]
        assert submission["documentation"] == "docs body"

    def test_skips_absent_optional_fields(self):
        submission = transform.create_app_submission(make_app())
        assert "integration_date" not in submission

    def test_does_not_copy_source_ids_into_submission(self):
        # The importer fills in the target-side app ID after creation; the
        # source IDs mean nothing on the target instance.
        app = make_app()
        app["version_id"] = "src-version-uuid"
        submission = transform.create_app_submission(app)
        assert "id" not in submission
        assert "version_id" not in submission

    def test_missing_documentation_defaults_to_empty_string(self):
        # The apps service refuses to publish without a documentation field.
        submission = transform.create_app_submission(make_app())
        assert submission["documentation"] == ""

    def test_documentation_object_without_body_defaults_to_empty_string(self):
        app = make_app()
        app["documentation"] = {"id": "doc-uuid"}
        assert transform.create_app_submission(app)["documentation"] == ""


class TestListingHelpers:
    listing = [
        {"id": "one", "name": "cat app", "version": "1.0"},
        {"id": "two", "name": "cat app", "version": "2.0"},
    ]

    @pytest.mark.parametrize(
        ("name", "version", "expected"),
        [
            ("cat app", "1.0", True),
            ("cat app", "3.0", False),
            ("dog app", "1.0", False),
        ],
    )
    def test_is_in_listing(self, name, version, expected):
        item = {"name": name, "version": version}
        assert transform.is_in_listing(item, self.listing) is expected

    def test_id_from_listing(self):
        item = {"name": "cat app", "version": "2.0"}
        assert transform.id_from_listing(item, self.listing) == "two"

    def test_id_from_listing_missing(self):
        item = {"name": "dog app", "version": "1.0"}
        assert transform.id_from_listing(item, self.listing) is None

    def test_listing_entry_without_version_does_not_match_versioned_item(self):
        item = {"name": "cat app", "version": "1.0"}
        assert transform.id_from_listing(item, [{"id": "x", "name": "cat app"}]) is None


class TestMergeApp:
    def test_deep_merges_dicts(self):
        base = {"a": 1, "nested": {"x": 1}}
        extra = {"b": 2, "nested": {"y": 2}}
        assert transform.merge(base, extra) == {
            "a": 1,
            "b": 2,
            "nested": {"x": 1, "y": 2},
        }

    def test_does_not_mutate_base(self):
        base = {"nested": {"x": 1}}
        transform.merge(base, {"nested": {"y": 2}})
        assert base == {"nested": {"x": 1}}
