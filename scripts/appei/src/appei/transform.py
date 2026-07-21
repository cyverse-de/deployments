"""Pure transformations between Terrain's read and import JSON shapes.

Terrain's create-request schemas are the read schemas with instance-specific
IDs removed, so exports become importable by stripping those IDs and filling
in parameter fields the read output omits.
"""

import copy
from typing import Any

from deepmerge import always_merger

# Read-only/listing fields Terrain's app create request does not accept,
# plus the source-instance IDs: the create request honors a provided id, and
# reusing the source UUID collides with seeded apps (e.g. DE Word Count) that
# already exist on the target under the same primary key.
APP_IMPORT_DROP_KEYS = frozenset(
    {
        "app_type",
        "beta",
        "can_favor",
        "can_rate",
        "can_run",
        "categories",
        "deleted",
        "disabled",
        "documentation",
        "edited_date",
        "hierarchies",
        "id",
        "integrator_email",
        "integrator_name",
        "isBlessed",
        "is_favorite",
        "is_public",
        "job_stats",
        "label",
        "limitChecks",
        "overall_job_type",
        "permission",
        "pipeline_eligibility",
        "rating",
        "requirements",
        "step_count",
        "suggested_categories",
        "version_id",
        "versions",
    }
)

# Container keys the app create request accepts for a tool: the container
# Settings fields plus image (schema ToolListingImage in common-swagger-api).
# Everything else (devices, volumes, ports, interactive_apps) is rejected as
# a disallowed key.
APP_TOOL_CONTAINER_KEEP_KEYS = frozenset(
    {
        "cpu_shares",
        "entrypoint",
        "gpu_models",
        "image",
        "max_cpu_cores",
        "max_gpus",
        "memory_limit",
        "min_cpu_cores",
        "min_disk_space",
        "min_gpus",
        "min_memory_limit",
        "name",
        "network_mode",
        "pids_limit",
        "skip_tmp_mount",
        "uid",
        "working_directory",
    }
)

# Top-level fields the publish request wants copied from the exported app.
# The app ID is filled in by the importer once the target assigns one; the
# source instance's id/version_id are meaningless on the target.
SUBMISSION_KEYS = (
    "integration_date",
    "description",
    "name",
    "system_id",
    "references",
    "edited_date",
)


def merge(base: dict, extra: dict) -> dict:
    """Deep-merge extra into a copy of base, leaving both inputs untouched."""
    return always_merger.merge(copy.deepcopy(base), copy.deepcopy(extra))


def clean_tool_for_import(tool: dict) -> dict:
    """Return a copy of a ToolDetails response shaped for POST /admin/tools."""
    cleaned = copy.deepcopy(tool)
    cleaned.pop("permission", None)
    cleaned.pop("is_public", None)
    container = cleaned.get("container", {})
    container.get("interactive_apps", {}).pop("id", None)
    container.get("image", {}).pop("id", None)
    for key in (
        "container_ports",
        "container_devices",
        "container_volumes",
        "container_volumes_from",
    ):
        for entry in container.get(key) or []:
            entry.pop("id", None)
    return cleaned


def clean_app_for_import(app: dict) -> dict:
    """Return a copy of an exported app shaped for POST /apps/{system-id}."""
    cleaned = copy.deepcopy(app)
    for key in APP_IMPORT_DROP_KEYS:
        cleaned.pop(key, None)
    for tool in cleaned.get("tools", []):
        tool.get("implementation", {}).pop("test", None)
        if "container" in tool:
            tool["container"] = {
                key: value
                for key, value in tool["container"].items()
                if key in APP_TOOL_CONTAINER_KEEP_KEYS
            }
            tool["container"].get("image", {}).pop("id", None)
    for group in cleaned.get("groups", []):
        group.pop("id", None)
        group.pop("step_number", None)
        for param in group.get("parameters", []):
            param.pop("id", None)
            _apply_parameter_defaults(param)
    return cleaned


def _apply_parameter_defaults(param: dict) -> None:
    # The export output omits fields the create request requires; fill them
    # the same way Sonora does when it builds these parameters.
    match param["type"]:
        case "Flag":
            param.setdefault("defaultValue", False)
            param.setdefault(
                "name",
                {
                    "checked": {"option": "", "value": ""},
                    "unchecked": {"option": "", "value": ""},
                },
            )
        case "TextSelection":
            param.setdefault("arguments", [])
            param.setdefault("defaultValue", "")
            param.setdefault("required", False)
            param.setdefault("omit_if_blank", False)
        case (
            "MultiFileOutput"
            | "FileInput"
            | "FolderInput"
            | "FileOutput"
            | "FolderOutput"
        ):
            param["defaultValue"] = ""
            param["required"] = False
            param["omit_if_blank"] = False
            param["file_parameters"] = {
                "is_implicit": False,
                "data_source": "file",
                "format": "Unspecified",
                "file_info_type": "File",
            }
        case "MultiFileSelector":
            param["defaultValue"] = []
            param["required"] = False
            param["omit_if_blank"] = False
            param["file_parameters"] = {
                "data_source": "file",
                "file_info_type": "File",
                "format": "Unspecified",
                "is_implicit": False,
                "repeat_option_flag": False,
            }
        case _:
            param.pop("file_parameters", None)


def create_app_submission(app: dict) -> dict:
    """Build the publish-request body from an exported app."""
    submission: dict[str, Any] = {"avus": []}
    for key in SUBMISSION_KEYS:
        if key in app:
            submission[key] = app[key]
    # The apps service refuses to publish an app with no documentation at
    # all, but accepts an empty string, so always send the field.
    submission["documentation"] = (
        app.get("documentation", {}).get("documentation") or ""
    )
    return submission


def is_in_listing(item: dict, listing: list[dict]) -> bool:
    """Report whether an app/tool with the same name and version is listed."""
    return id_from_listing(item, listing) is not None


def id_from_listing(item: dict, listing: list[dict]) -> str | None:
    """Find the listed ID of the entry matching item's name and version."""
    for listed in listing:
        if listed["name"] == item["name"] and listed.get("version") == item.get(
            "version"
        ):
            return listed["id"]
    return None
