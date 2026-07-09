_This repository has been archived and is now maintained in a Git repository hosted by CyVerse._

# deployments

Tools for deploying the CyVerse Discovery Environment (DE)

## Ansible Playbooks

The [Ansible playbooks](ansible) are primarily used to deploy subsystems used by the DE. Some examples of things that
are deployed using Ansible playbooks are OpenLDAP and Kubernetes.

## Kustomizations

The [Kustomizations](kustomize) are used to deploy third-party software that the DE relies on in Kubernetes,
currently Keycloak. OpenEBS is now deployed by the `openebs` Ansible role.
