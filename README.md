# deployments

Tools for deploying the CyVerse Discovery Environment (DE)

## Ansible Playbooks

The [Ansible playbooks](ansible) are primarily used to deploy subsystems used by the DE. Some examples of things that
are deployed using Ansible playbooks are OpenLDAP and Kubernetes.

## Wiki

The [wiki](wiki/index.md) holds curated operational knowledge in
[Open Knowledge Format](https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md) (v0.1).
Validate it and regenerate its indexes with the [okf tool](scripts/okf); the skills under
[skills/](skills) describe how to read, write, and migrate wiki pages.

## Kustomizations

The [Kustomizations](kustomize) are used to deploy third-party software that the DE relies on in Kubernetes,
currently Keycloak. OpenEBS is now deployed by the `openebs` Ansible role.
