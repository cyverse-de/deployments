# Ansible Playbooks

## Required Ansible Collections

- community.general
- kubernetes.core

## Database Initialization

The following databases are created by the `postgresql_init.yml` playbook:

| Database      | Owner    | Auto Init    | Auto Migrate |
| ------------- | -------- | ------------ | ------------ |
| de            | de       | no           | no           |
| notifications | de       | no           | no           |
| metadata      | de       | no           | no           |
| de_releases   | de       | no           | no           |
| grouper       | grouper  | yes          | ?            |
| qms           | de       | configurable | configurable |
| unleash       | de       | yes          | ?            |
| keycloak      | keycloak | yes          | ?            |

The owner users are configurable through the `dbms_connection_user` and `grouper_connection_user` group_vars.

Migrations are run for the `de`, `metadata`, `notifications`, and `de_releases` databases. The `grouper` database is
handled by its own playbook since it's fairly complicated. The `qms` database is created here, but populated by the
`qms` service. `unleash` is not yet initialized by this playbook.

## Kubernetes

The k0s distribution of Kubernetes is used by the DE, with the `k0sctl` tool providing the ability to bring up and tear
down clusters according to a YAML configuration file. We're using stacked control nodes, which means that each control
node also acts as a etcd member node. Control nodes do not run workloads and do not show up in the `kubectl get nodes`
command output.

## OpenLDAP

The DE uses OpenLDAP using an RFC2307 schema as its user directory by default. If you don't have an existing LDAP
directory, the [OpenLDAP playbooks](ldap) can be used to create a new one. Note: the DE has not been tested with other
LDAP schemas.

## RabbitMQ

The DE and CyVerse Data Store both use RabbitMQ as a message bus. The DE uses it for notifications, and the data store
uses it to push updates to ElasticSearch for indexing. The [RabbitMQ playbooks](rabbitmq) will install RabbitMQ on a
single node.

## HTCondor

The DE uses HTCondor to run non-interactive analyses. Several DE specific components are required for this to work, so
the recommended approach is to create a new HTCondor cluster that is dedicated to the DE. This can be done using the
[HTCondor playbooks](condor).

## Cert-Manager

The DE uses cert-manager to generate and rotate self-signed TLS certs for use with NATS.

## NATS

The DE uses NATS in the backend to communicate between some services. By default, NATS is installed in clustered mode
with 5 nodes. You should be able to connect to any node to communicate with other services using NATS. The
[NATS playbooks](nats) will install `helm` inside the cluster and use it to set up and run NATS.

**NOTE** Make sure the `KUBECONFIG` environment variable is set to the correct value in your local shell.

## GoCD

We use GoCD for continuous deployment. It's deployed outside of a kubernetes cluster to simplify the automation of cluster maintainance.

| Playbook            | Description                               | Example                                         |
| ------------------- | ----------------------------------------- | ----------------------------------------------- |
| gocd.yml            | Installs GoCD cluster                     | `ansible-playbook -i <inventory> -K gocd.yml`   |
| gocd_k3s_config.yml | Installs kubeconfig onto GoCD agent nodes | `ansible -i <inventory> -K gocd_k3s_config.yml` |

## Grouper

Grouper is installed inside the same cluster as the Discovery Environment, but the process is different enough from the rest of the services that it needs its own playbook and roles.

| Playbook    | Description                           | Example                                       |
| ----------- | ------------------------------------- | --------------------------------------------- |
| grouper.yml | Installs Grouper into the k3s cluster | `ansible-playbook -i <inventory> grouper.yml` |

## Keycloak

Keycloak is used for authentication/authorization and is installed inside the same cluster as the Discovery Environment.

| Playbook     | Description                            | Example                                        |
| ------------ | -------------------------------------- | ---------------------------------------------- |
| keycloak.yml | Installs keycloak into the k3s cluster | `ansible-playbook -i <inventory> keycloak.yml` |

## Services

The Discovery Environment services are installed and upgraded through `kubernetes.yml`, selected by tag. The `deploy-service` role runs `skaffold deploy` for each service.

Deploying all of the configurations and all of the services:

```bash
ansible-playbook -i <inventory> --tags configure-services,deploy-all-services kubernetes.yml
```

Deploying just the service configurations:

```bash
ansible-playbook -i <inventory> --tags configure-services kubernetes.yml
```

Deploying a single service, without the configurations (set `project` to the service name):

```bash
ansible-playbook -i <inventory> --tags deploy-single-service -e project=<service> kubernetes.yml
```

Deploying all of the services, without the configurations:

```bash
ansible-playbook -i <inventory> --tags deploy-all-services kubernetes.yml
```

For CI/CD, the standalone `deploy_service.yml` playbook deploys a single service. Set `project` to the service name and `KUBECONFIG` in the environment:

```bash
ansible-playbook -i <inventory> -e project=<service> deploy_service.yml
```

# Common Tasks

## Add a Node to the Kubernetes Cluster

``` bash
ansible-playbook -i <inventory> --ask-become-pass --tags add-nodes --limit <node-name> kubernetes.yaml
```
