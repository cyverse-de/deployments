---
name: resolving-the-kubeconfig
description: Use when a CyVerse DE deployments command needs to know which cluster to act on — before running any ansible-playbook, kubectl, or skaffold that targets a cluster (deploys, subsystem installs, full kubernetes.yml runs). Resolves the kubeconfig value and decides when to ask the user.
---

# Resolving the Kubeconfig

## Overview

Many `deployments` operations act on a Kubernetes cluster and read the Ansible
`kubeconfig` var to decide **which** cluster. Its role default
(`roles/common/defaults/main.yml`) reads the `KUBECONFIG` env var, falling back
to `~/.kube/config`:

```yaml
kubeconfig: "{{ lookup('env', 'KUBECONFIG') | default(lookup('env','HOME') ~ '/.kube/config', true) }}"
```

But an inventory's group_vars may **pin `kubeconfig` explicitly**, and a
group_vars value **wins over the env-derived default**. So `KUBECONFIG` alone
does not guarantee the cluster you'll hit — resolve the value deliberately
before running anything that mutates a cluster.

## When to Use

- Before any command that targets a cluster: `deploy_it.yml`, `kubernetes.yml`,
  a subsystem install, or a direct `kubectl`/`skaffold` against the DE.
- Any skill that deploys or mutates cluster state should resolve the kubeconfig
  through this procedure first.
- NOT needed for build-only work (`build_it.yml` / `build_release.yml` don't
  touch a cluster).

## The Three Sources

| | Source | How to observe it |
| --- | --- | --- |
| **S** | A kubeconfig agreed earlier in **this session** | Conversation context |
| **G** | `kubeconfig` pinned in the inventory **group_vars** | Grep the `-i` inventory's group_vars for a `kubeconfig:` line |
| **E** | The `KUBECONFIG` **environment** variable | `printenv KUBECONFIG` |

## Resolution

| Situation | Do this |
| --- | --- |
| **S** is set | Use S — a session-agreed value wins over G and E. |
| S unset, exactly one of **G** / **E** set | Use whichever is set. |
| S unset, **both G and E** set | They may disagree (and G silently wins in Ansible). **Ask** which to use. |
| S unset, **neither** G nor E set (only the `~/.kube/config` fallback) | **Ask** for the kubeconfig — do not act against the default. |

Whenever you ask, also ask **whether the chosen value should apply to the rest
of the session**; if so, treat it as **S** for later commands. **Do not write
the kubeconfig to memory** — it changes across sessions.

When S is set but the environment doesn't yet reflect it (e.g. `KUBECONFIG`
points elsewhere), make the `kubeconfig` var actually resolve to S before
running — e.g. `export KUBECONFIG=<agreed path>`.

## Guardrail

If the resolved kubeconfig targets **production**, get **explicit approval**
before running any mutating command — never default to prod.

## Common Mistakes

- **Trusting `KUBECONFIG` when group_vars pins `kubeconfig`.** The group_vars
  value wins; the export is silently ignored. Check G before assuming E applies.
- **Proceeding on the `~/.kube/config` fallback.** If nothing selects a cluster,
  ask — don't let a mutating command land on whatever `~/.kube/config` happens
  to be.
- **Persisting the value.** Keep the resolved kubeconfig as session state only;
  never save it to memory.
