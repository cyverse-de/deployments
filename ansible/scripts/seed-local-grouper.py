#!/usr/bin/env python3
"""Seed a local Grouper with a dataset shaped like production's.

A freshly deployed local DE has one DE group (users:de-users) and two LDAP
subjects, which is enough to prove the Grouper importer runs and nothing about
whether it is correct. This creates the shapes that actually exercise it:
every group type, owners, a two-level nesting chain, a member reachable by two
paths, and the privilege vocabulary including GrouperAll.

Groups are created through iplant-groups rather than written into the Grouper
database, so they are formed exactly the way the DE forms them.

Idempotent: existing users, folders, groups, members and privileges are left
alone, so this can be re-run after a partial failure or alongside hand-made
changes.

    export LDAP_ROOT_PW=...            # ldap_root_pw from the local inventory
    KUBECONFIG=~/.kube/local-admin.conf ./seed-local-grouper.py

The importer can then be exercised against it:

    kubectl -n de create job --from=cronjob/grouper-import gi-1
    kubectl -n de logs job/gi-1
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

USERS = [
    ("jdoe", "Jane", "Doe", "Example University", "Genomics", 40010),
    ("msmith", "Morgan", "Smith", "Example University", "Imaging", 40011),
    ("rpatel", "Riya", "Patel", "Example University", "Genomics", 40012),
    ("lchen", "Lee", "Chen", "Other Institute", "Imaging", 40013),
]

# Hashed form of a throwaway password. These accounts exist to be group members
# on a development cluster; nothing authenticates as them.
USER_PW_HASH = "{SSHA}KCn+ZNsfcqVOMwMUSeajUfU2mCQrnq3P"


def sh(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def ldif(base_dn):
    out = []
    for uid, given, sn, org, dept, uidnum in USERS:
        out.append(f"""dn: uid={uid},ou=People,{base_dn}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: {uid}
mail: {uid}@example.org
sn: {sn}
givenName: {given}
cn: {given} {sn}
title: Researcher
o: {org}
departmentNumber: {dept}
uidNumber: {uidnum}
gidNumber: 10000
homeDirectory: /home/{uid}
userPassword: {USER_PW_HASH}
""")
    return "\n".join(out)


def seed_ldap(ns, base_dn, root_pw):
    """Load the users into OpenLDAP.

    Through a pod rather than from the control machine: the openldap image has
    no shell and the workstation is not assumed to have ldap-utils. ldapadd
    exits 68 (ENTRY_ALREADY_EXISTS) on a re-run, which is success here.
    """
    print("== ldap users")
    manifest = sh("kubectl", "create", "configmap", "-n", ns, "grouper-seed-users",
                  f"--from-literal=users.ldif={ldif(base_dn)}",
                  "--dry-run=client", "-o", "yaml").stdout
    applied = subprocess.run(["kubectl", "apply", "-n", ns, "-f", "-"],
                             input=manifest, capture_output=True, text=True)
    if applied.returncode:
        sys.exit(f"could not create the seed configmap: {applied.stderr}")

    # The password goes through a Secret and secretKeyRef, piped over stdin,
    # so it never appears on a workstation command line or in the pod spec.
    secret = json.dumps({"apiVersion": "v1", "kind": "Secret",
                         "metadata": {"name": "grouper-seed-ldap-pw", "namespace": ns},
                         "stringData": {"password": root_pw}})
    applied = subprocess.run(["kubectl", "apply", "-n", ns, "-f", "-"],
                             input=secret, capture_output=True, text=True)
    if applied.returncode:
        sys.exit(f"could not create the seed secret: {applied.stderr}")

    overrides = json.dumps({"spec": {"containers": [{
        "name": "ldapload", "image": "alpine:3.20",
        "command": ["sh", "-c",
                    "apk add -q openldap-clients >/dev/null 2>&1 && "
                    f'ldapadd -c -x -H ldap://openldap:389 -D "cn=Manager,{base_dn}" '
                    '-w "$LDAP_ROOT_PW" -f /seed/users.ldif'],
        "env": [{"name": "LDAP_ROOT_PW", "valueFrom": {
            "secretKeyRef": {"name": "grouper-seed-ldap-pw", "key": "password"}}}],
        "volumeMounts": [{"name": "seed", "mountPath": "/seed"}]}],
        "volumes": [{"name": "seed", "configMap": {"name": "grouper-seed-users"}}]}})
    r = subprocess.run(
        ["kubectl", "run", "grouper-seed-ldapload", "-n", ns, "--rm", "-i",
         "--restart=Never", "--image=alpine:3.20", "--quiet",
         f"--overrides={overrides}"],
        capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.strip():
            print(f"  {line.strip()}")
    subprocess.run(["kubectl", "delete", "configmap", "-n", ns,
                    "grouper-seed-users", "--ignore-not-found"],
                   capture_output=True)
    subprocess.run(["kubectl", "delete", "secret", "-n", ns,
                    "grouper-seed-ldap-pw", "--ignore-not-found"],
                   capture_output=True)


class Groups:
    """The iplant-groups API, over a port-forward."""

    def __init__(self, ns, admin, port):
        self.base = f"http://127.0.0.1:{port}"
        self.admin = admin
        self.pf = subprocess.Popen(
            ["kubectl", "port-forward", "-n", ns, "svc/iplant-groups", f"{port}:80"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(30):
            time.sleep(1)
            try:
                urllib.request.urlopen(f"{self.base}/", timeout=2).read()
                return
            except Exception:
                continue
        self.close()
        sys.exit("iplant-groups did not answer through the port-forward")

    def close(self):
        self.pf.terminate()

    def call(self, method, path, body=None):
        url = f"{self.base}{path}{'&' if '?' in path else '?'}user={self.admin}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        if data:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            return {"__error__": e.code, "__body__": e.read()[:200].decode(errors="replace")}

    @staticmethod
    def enc(name):
        return urllib.parse.quote(name, safe="")

    def folder(self, name):
        if "__error__" not in self.call("GET", f"/folders/{self.enc(name)}"):
            print(f"  folder {name} (exists)")
            return
        r = self.call("POST", "/folders/", {"name": name, "description": "seeded"})
        print(f"  folder {name}" if "__error__" not in r else f"  !! folder {name}: {r['__body__']}")

    def group(self, name, description):
        existing = self.call("GET", f"/groups/{self.enc(name)}")
        if "__error__" not in existing:
            print(f"  group  {name} (exists)")
            return existing["id"]
        r = self.call("POST", "/groups/",
                      {"name": name, "type": "group", "description": description})
        if "__error__" in r:
            print(f"  !! group {name}: {r['__body__']}")
            return None
        print(f"  group  {name}")
        return r["id"]

    def members(self, group, ids):
        ids = [i for i in ids if i]
        if not ids:
            return
        r = self.call("POST", f"/groups/{self.enc(group)}/members/", {"members": ids})
        if "__error__" in r:
            print(f"  !! member {group}: {r['__body__']}")
            return
        ok = sum(1 for x in r.get("results", []) if x.get("success"))
        print(f"  member {group} += {ok}/{len(ids)}")

    def privilege(self, group, subject, priv):
        # The API takes the singular names; Grouper stores the plurals the
        # importer reads (read -> readers, optin -> optins, view -> viewers,
        # admin -> admins).
        r = self.call("PUT", f"/groups/{self.enc(group)}/privileges/{self.enc(subject)}/{priv}/")
        print(f"  priv   {group} {subject}:{priv}"
              if "__error__" not in r else f"  !! priv {group} {subject}:{priv}: {r['__body__']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--namespace", default="de")
    ap.add_argument("--ldap-namespace", default="openldap")
    ap.add_argument("--base-dn", default="dc=de,dc=localhost")
    ap.add_argument("--env-prefix", default="iplant:de:de",
                    help="the Grouper folder the DE's groups live under")
    ap.add_argument("--admin", default="de_grouper")
    ap.add_argument("--port", type=int, default=18081)
    ap.add_argument("--skip-ldap", action="store_true")
    args = ap.parse_args()

    root_pw = os.environ.get("LDAP_ROOT_PW")
    if not root_pw and not args.skip_ldap:
        sys.exit("Set LDAP_ROOT_PW (ldap_root_pw in the local inventory), or pass --skip-ldap.")

    if not args.skip_ldap:
        seed_ldap(args.ldap_namespace, args.base_dn, root_pw)

    e = args.env_prefix
    g = Groups(args.namespace, args.admin, args.port)
    try:
        # Grouper will not create a group whose parent stem is absent, and a
        # fresh local DE has only <env>:users. Parents before children.
        print("== folders")
        for f in [f"{e}:users:jdoe", f"{e}:users:jdoe:collaborator-lists",
                  f"{e}:users:msmith", f"{e}:users:msmith:collaborator-lists",
                  f"{e}:users:rpatel", f"{e}:users:rpatel:collaborator-lists",
                  f"{e}:teams", f"{e}:teams:jdoe", f"{e}:teams:msmith",
                  f"{e}:communities"]:
            g.folder(f)

        print("== groups")
        ids = {}
        for name, desc in [
            (f"{e}:users:jdoe:collaborator-lists:default", "Jane's default list"),
            # Collaborator lists are usually but not always named "default";
            # production has counterexamples, so the parser must not assume it.
            (f"{e}:users:jdoe:collaborator-lists:Genomics Lab", "Genomics lab members"),
            (f"{e}:users:msmith:collaborator-lists:default", "Morgan's default list"),
            (f"{e}:users:rpatel:collaborator-lists:Thesis Readers", "Committee"),
            (f"{e}:teams:jdoe:Field Team", "Field sampling team"),
            (f"{e}:teams:msmith:Imaging Ops", "Imaging operations"),
            (f"{e}:communities:Genomics", "Genomics community"),
            (f"{e}:communities:Imaging", "Imaging community"),
        ]:
            ids[name] = g.group(name, desc)

        print("== membership")
        g.members(f"{e}:users:jdoe:collaborator-lists:default", ["msmith", "rpatel"])
        g.members(f"{e}:users:jdoe:collaborator-lists:Genomics Lab", ["rpatel"])
        g.members(f"{e}:users:msmith:collaborator-lists:default", ["lchen"])
        g.members(f"{e}:users:rpatel:collaborator-lists:Thesis Readers", ["jdoe", "lchen"])
        g.members(f"{e}:teams:jdoe:Field Team", ["msmith"])
        g.members(f"{e}:teams:msmith:Imaging Ops", ["lchen"])
        g.members(f"{e}:communities:Genomics", ["jdoe"])
        g.members(f"{e}:communities:Imaging", ["msmith", "lchen"])
        g.members(f"{e}:users:de-users", [u[0] for u in USERS])

        # Two levels deep on purpose: Field Team -> Genomics Lab -> msmith's
        # default puts lchen in Field Team at depth 2, so an expansion that
        # only follows one hop drops them and still looks plausible.
        print("== nesting")
        g.members(f"{e}:users:jdoe:collaborator-lists:Genomics Lab",
                  [ids.get(f"{e}:users:msmith:collaborator-lists:default")])
        g.members(f"{e}:teams:jdoe:Field Team",
                  [ids.get(f"{e}:users:jdoe:collaborator-lists:Genomics Lab")])
        # lchen is already a direct member of Imaging, so this gives that pair
        # a second path -- which is what makes grouper_memberships_v return it
        # twice, and what the importer has to dedupe.
        g.members(f"{e}:communities:Imaging",
                  [ids.get(f"{e}:users:msmith:collaborator-lists:default")])

        print("== privileges")
        # GrouperAll is the public/joinable marker: read+optin on a community,
        # view on a team.
        g.privilege(f"{e}:communities:Genomics", "GrouperAll", "read")
        g.privilege(f"{e}:communities:Genomics", "GrouperAll", "optin")
        g.privilege(f"{e}:teams:jdoe:Field Team", "GrouperAll", "view")
        # A real user-held read grant, which must survive as a permission.
        g.privilege(f"{e}:users:jdoe:collaborator-lists:Genomics Lab", "lchen", "read")
        g.privilege(f"{e}:communities:Imaging", "msmith", "admin")
    finally:
        g.close()

    print("\nSeeded. Run the importer with:")
    print(f"  kubectl -n {args.namespace} create job --from=cronjob/grouper-import gi-1")


if __name__ == "__main__":
    main()
