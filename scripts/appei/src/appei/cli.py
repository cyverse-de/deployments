"""Command-line interface: appei login/logout/list/export/import."""

import argparse
import getpass
import json
import os
import sys
from pathlib import Path

from tabulate import tabulate

from appei import exporter, importer, tokens
from appei.client import TerrainClient, TerrainError


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (tokens.TokenError, TerrainError, ValueError, OSError) as exc:
        print(f"appei: {exc}", file=sys.stderr)
        return 1


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="appei", description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    login = subparsers.add_parser(
        "login", help="get a Terrain token and cache it for the server"
    )
    login.add_argument("--server", required=True, help="FQDN of the DE server")
    login.add_argument("--username", required=True, help="admin username")
    login.add_argument(
        "--password",
        help="admin password (default: $APPEI_PASSWORD, else an interactive prompt)",
    )
    login.set_defaults(func=_run_login)

    logout = subparsers.add_parser("logout", help="delete the cached token")
    logout.add_argument("--server", required=True, help="FQDN of the DE server")
    logout.set_defaults(func=_run_logout)

    listing = subparsers.add_parser("list", help="list public apps on the server")
    listing.add_argument("--server", required=True, help="FQDN of the DE server")
    listing.set_defaults(func=_run_list)

    export = subparsers.add_parser(
        "export", help="export an app and its tools as a JSON bundle"
    )
    export.add_argument("--server", required=True, help="FQDN of the DE server")
    export.add_argument("-i", "--id", required=True, help="ID of the app to export")
    export.add_argument(
        "-s", "--system-id", default="de", help="execution system ID (default: de)"
    )
    export.add_argument(
        "-o", "--output", help="file to write the bundle to (default: stdout)"
    )
    export.set_defaults(func=_run_export)

    imp = subparsers.add_parser(
        "import", help="import an exported JSON bundle into the server"
    )
    imp.add_argument("--server", required=True, help="FQDN of the DE server")
    imp.add_argument(
        "-i", "--input", required=True, help="file containing an exported bundle"
    )
    imp.add_argument(
        "--publish",
        action="store_true",
        help="publish the imported app so it is public (default: keep it private)",
    )
    imp.add_argument(
        "--feature",
        action="store_true",
        help="publish the imported app and mark it as featured (implies --publish)",
    )
    imp.set_defaults(func=_run_import)

    return parser


def _client(server: str) -> TerrainClient:
    token_data = tokens.load_token(server)
    return TerrainClient(server, access_token=token_data["access_token"])


def _run_login(args: argparse.Namespace) -> int:
    password = (
        args.password
        or os.environ.get("APPEI_PASSWORD")
        or getpass.getpass(f"Password for {args.username}@{args.server}: ")
    )
    token_data = TerrainClient(args.server).get_token(args.username, password)
    path = tokens.save_token(args.server, token_data)
    print(f"Access token written to {path}")
    return 0


def _run_logout(args: argparse.Namespace) -> int:
    if tokens.delete_token(args.server):
        print(f"Deleted cached token for {args.server}")
    else:
        print(f"No cached token for {args.server}, no logout necessary")
    return 0


def _run_list(args: argparse.Namespace) -> int:
    apps = _client(args.server).list_admin_apps()
    rows = [[app["id"], app["system_id"], app["name"]] for app in apps]
    print(tabulate(rows, headers=["ID", "System ID", "Name"]))
    return 0


def _run_export(args: argparse.Namespace) -> int:
    # Log to stderr so a bundle written to stdout stays valid JSON.
    bundle = exporter.export_app(
        _client(args.server),
        args.system_id,
        args.id,
        log=lambda message: print(message, file=sys.stderr),
    )
    rendered = json.dumps(bundle, sort_keys=True, indent=2)
    if args.output:
        path = Path(os.path.expandvars(args.output)).expanduser()
        path.write_text(rendered + "\n", encoding="utf-8")
        print(f"Wrote app bundle to {path}", file=sys.stderr)
    else:
        print(rendered)
    return 0


def _run_import(args: argparse.Namespace) -> int:
    bundle = json.loads(Path(args.input).read_text(encoding="utf-8"))
    app_id = importer.import_bundle(
        _client(args.server), bundle, publish=args.publish, feature=args.feature
    )
    print(f"Imported app is available as {app_id}")
    return 0
