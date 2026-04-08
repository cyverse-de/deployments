_This repository has been archived and is now being maintained in a Git repository maintained by CyVerse._

# deployments

Tools for deploying the CyVerse Discovery Environment (DE)

## Ansible Playbooks

The [Ansible playbooks](ansible) are primarily used to deploy subsystems used by the DE. Some examples of things that
are deployed using Ansible playbooks are OpenLDAP and Kubernetes.

## Kustomizations

The [Kustomizations](kustomize) are currently used to deploy software that is used by the DE in Kubernetes. The only
example we have of this at this time is Keycloak, but Kustomizations of other software components will be added in the
future.
