# Kustomizations

## Keycloak

The [Keycloak kustomization](keycloak) contains a base and a couple of example overlays to help you create an overlay
for your own Discovery Environment deployment.

## OpenEBS

OpenEBS, the cluster's storage provider, is now deployed by the `openebs` Ansible role
(`ansible/roles/openebs`) rather than from a standalone kustomization here.
