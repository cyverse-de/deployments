"""Import an exported app/tool bundle into a DE instance."""

import copy
from typing import Callable

from appei import transform
from appei.client import TerrainClient

# ARK identifier of the AVU that marks an app as beta in the DE.
BETA_AVU_ATTR = "n2t.net/ark:/99152/h1459"

Log = Callable[[str], None]


def import_bundle(
    client: TerrainClient,
    bundle: dict,
    log: Log = print,
    publish: bool = False,
    feature: bool = False,
    public_tools: bool = False,
) -> str:
    """Import the bundle's tools and app, privately unless told otherwise.

    With publish=True the app is made public and its beta AVU dropped;
    feature=True additionally blesses it as a featured app and implies
    publish. public_tools=True creates the tools through the admin route,
    which makes them public DE-wide; it is required for tools using the
    admin-only container fields.

    Tools and the app are matched by name+version against the target's
    listings, so re-running an import is safe: existing resources are reused
    and their target-side IDs substituted for the source-side ones.
    """
    publish = publish or feature
    for key in ("name", "version", "system_id"):
        if key not in bundle:
            raise ValueError(f"import bundle is missing required field {key!r}")

    data = copy.deepcopy(bundle)
    system_id = data["system_id"]
    app_name = data["name"]
    app_version = data["version"]

    tool_listing = client.list_admin_tools()
    app_listing = client.list_admin_apps(search=app_name)
    private_listing = client.list_apps(search=app_name)

    for tool in data.get("tools", []):
        existing_id = transform.id_from_listing(tool, tool_listing)
        if existing_id is not None:
            log(
                f"Tool {tool['name']} {tool['version']} already exists as {existing_id}"
            )
            tool["id"] = existing_id
            continue
        tool["id"] = _create_tool(client, tool, public_tools, log)
        log(f"Imported tool {tool['name']} {tool['version']} as {tool['id']}")

    # The admin listing covers private apps too, so a match there says nothing
    # about visibility; check the flag, or an existing private app is reported
    # as public and --publish silently skips publishing it.
    public_listing = [app for app in app_listing if app.get("is_public")]
    public_id = transform.id_from_listing(data, public_listing)
    if public_id is not None:
        log(f"App {app_name} {app_version} is already public as {public_id}")
        _remove_beta_avu(client, public_id, log)
        return public_id

    app_id = transform.id_from_listing(data, private_listing)
    if app_id is None:
        log(f"Importing app {app_name} {app_version}...")
        app_id = client.create_app(system_id, transform.clean_app_for_import(data))[
            "id"
        ]
        log(f"Imported app {app_name} {app_version} as private app {app_id}")
    else:
        log(f"App {app_name} {app_version} already exists privately as {app_id}")

    if not publish:
        return app_id

    submission = transform.create_app_submission(data)
    submission["id"] = app_id
    if not submission["documentation"]:
        log(
            f"App {app_name} {app_version} has no documentation in the bundle; "
            "publishing with empty documentation since the DE requires the "
            "field to make an app public"
        )
    log(f"Publishing app {app_name} {app_version}...")
    client.publish_app(system_id, submission)
    if feature:
        log(f"Marking app {app_name} {app_version} as featured...")
        client.bless_app(system_id, app_id)
    _remove_beta_avu(client, app_id, log)
    log(f"Done importing app {app_name} {app_version}")
    return app_id


def _create_tool(
    client: TerrainClient, tool: dict, public_tools: bool, log: Log
) -> str:
    """Create one tool, private by default, and return its new ID."""
    name, version = tool["name"], tool["version"]
    blocking = transform.blocking_admin_only_keys(tool)
    if not public_tools:
        if blocking:
            raise ValueError(
                f"tool {name} {version} uses {', '.join(blocking)}, which the "
                "private tool route rejects; re-run with --public-tool to "
                "import it as a public tool"
            )
        log(f"Importing tool {name} {version}...")
        return client.create_private_tool(
            transform.clean_tool_for_private_import(tool)
        )["id"]

    reason = f" (it uses {', '.join(blocking)})" if blocking else ""
    log(f"Warning: importing tool {name} {version} as a PUBLIC tool{reason}")
    result = client.import_tools([transform.clean_tool_for_import(tool)])
    return result["tool_ids"][0]


def _remove_beta_avu(client: TerrainClient, app_id: str, log: Log) -> None:
    avus = client.app_metadata(app_id)["avus"]
    kept = [
        avu
        for avu in avus
        if not (avu["attr"] == BETA_AVU_ATTR and avu["value"] == "beta")
    ]
    if len(kept) == len(avus):
        log("App has no beta AVU; leaving metadata untouched")
        return
    log("Removing the beta status from the imported app...")
    client.set_app_metadata(app_id, kept)
