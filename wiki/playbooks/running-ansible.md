---
type: Runbook
title: Running the Ansible Playbooks
description: The three ways to get an Ansible control environment for this repo — the uv-managed project, a system Ansible install, and the macOS system-Python interpreter override.
resource: /pyproject.toml
tags: [ansible, uv, python, tooling, control-machine]
timestamp: 2026-09-10T00:00:00Z
---

Every playbook in `ansible/` runs from a **control machine** — your workstation,
not a cluster node — which needs Ansible plus the Python libraries the
`kubernetes.core` and PostgreSQL modules import. There are three supported ways
to get that, and they are interchangeable: pick one and use it for every command
in the other runbooks. Where a runbook shows `ansible-playbook …`, the uv form is
the same command with `uv run` in front of it.

## Option 1: the uv-managed project (recommended)

The repo root is a [uv](https://docs.astral.sh/uv/) project. `pyproject.toml`
declares the control-machine dependencies and `uv.lock` pins exact versions, so
every operator gets the same Ansible:

| Dependency | Why it's needed |
| --- | --- |
| `ansible` | The playbook runner itself. |
| `ansible-lint` | Linting roles and playbooks. |
| `kubernetes` | Imported by the `kubernetes.core` modules and lookups. |
| `psycopg2-binary` | Imported by the PostgreSQL modules the database roles use. |

`uv run` creates and syncs the virtualenv on demand, so no setup step and no
activation is required:

```bash
uv run ansible-playbook -i <inventory> kubernetes.yml
```

It finds the project by walking up from the working directory, so this works
unchanged from `ansible/`, which is where most playbooks are run from.

To get a shell where plain `ansible-playbook` works, activate the environment
instead. `uv sync` creates `.venv/` and installs the locked dependencies into it:

```bash
uv sync
source .venv/bin/activate          # bash/zsh
source .venv/bin/activate.fish     # fish
```

Use `deactivate` to leave it. Re-run `uv sync` after pulling changes to
`pyproject.toml` or `uv.lock`.

## Option 2: a system Ansible install

A system-wide Ansible — Homebrew, `pipx`, or a distribution package — works
fine, and is what most of the runbooks' bare `ansible-playbook` examples assume.
Install the two Python libraries above into the same interpreter Ansible runs
under, or the `kubernetes.core` and PostgreSQL tasks fail with import errors.

## Option 3: the macOS system Python

Installing the Python libraries into Homebrew's Python can be awkward on macOS,
so an alternative is to install them into the Python that ships with the OS and
point Ansible at that interpreter:

```bash
/usr/bin/pip3 install psycopg2 kubernetes

ansible-playbook -i <inventory> -e 'ansible_python_interpreter=/usr/bin/python3' \
  --tags=configure-services kubernetes.yml
```

This is the workaround Option 1 exists to avoid — the uv environment carries
both libraries and its own interpreter, so no `ansible_python_interpreter`
override is needed.

## Galaxy content is installed the same way regardless

`ansible/requirements.yml` lists the Galaxy content the playbooks need — the
`community.general`, `kubernetes.core`, and `ansible.posix` collections, plus the
`adfinis-sygroup.grub` and `CyVerse-Ansible.docker` roles:

```bash
ansible-galaxy install -r requirements.yml
# or, under uv:
uv run ansible-galaxy install -r requirements.yml
```

Run it from `ansible/`. Both collections and roles install under `~/.ansible/`,
**outside** the virtualenv, so they are shared across all three options and only
need installing once per machine.

The `ansible` PyPI package is the full distribution, not just `ansible-core`, so
the uv environment already ships every collection the playbooks import —
including `community.crypto` and `community.postgresql`, which
`ansible/requirements.yml` does not list. Under Option 1 the `ansible-galaxy`
run is therefore only needed for the two **roles**. Under an `ansible-core`-only
install, the missing collections have to be added by hand.

## Other tools are still your responsibility

uv manages the Python side only. The non-Python tools the playbooks shell out to
— `kubectl`, `kustomize`, `helm`, `skaffold`, `k0sctl`, `golang-migrate`, `psql`,
`gpg`, `openssl` — are not in `pyproject.toml` and must be installed separately.
Individual runbooks list the ones they need; see
[Local Single-Node Deployment](/playbooks/local-single-node-deployment.md) for
the fullest list.

# Citations

[1] `pyproject.toml` — the uv project definition: `requires-python` and the four control-machine dependencies.

[2] `uv.lock` — the pinned dependency versions `uv sync` and `uv run` resolve to.

[3] `ansible/requirements.yml` — the Galaxy collections and roles the playbooks require.

[4] `ansible/README.md` — required collections, required local tools, and the per-subsystem playbook reference.

[5] `docs/production-release.md` — the release procedure's control-machine setup section, source of the macOS system-Python workaround.
