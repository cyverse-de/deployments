# Ansible Playbooks

For an overview of the required repositories, CI builds, and the production deployment process, see [docs/index.md](docs/index.md). For building service images from source, see [BUILD_DEPLOY.md](BUILD_DEPLOY.md).

## Required Ansible Collections

- community.crypto
- community.general
- kubernetes.core
- ansible.posix

These (and the required roles) can be installed with `ansible-galaxy install -r requirements.yml`.

## Database Initialization

Databases are created and migrated by the `postgresql_init` role, which runs in `kubernetes.yml` under the
`setup-databases` tag:

```bash
ansible-playbook -i <inventory> --tags setup-databases kubernetes.yml
```

| Database                  | Owner                   | Enabled by      | Migrations |
| ------------------------- | ----------------------- | --------------- | ---------- |
| de                        | `dbms_connection_user`  | always          | yes        |
| notifications             | `dbms_connection_user`  | always          | yes        |
| metadata                  | `dbms_connection_user`  | always          | yes        |
| grouper                   | `grouper_connection_user` | `grouper` var | no — Grouper initializes its own schema |
| qms                       | `dbms_connection_user`  | `qms` var       | yes        |
| unleash                   | `dbms_connection_user`  | `unleash` var   | no — Unleash initializes its own schema |
| keycloak                  | `keycloak_db_username`  | `keycloak` var  | no — Keycloak manages its own schema |
| harbor_core, harbor_clair | `harbor_database_user`  | `harbor` var    | no         |
| portal                    | `portal_db_user`        | `portal` var    | yes        |

The `create_user`, `create_dbs`, `install_exts`, and `migrate` variables control whether database users, the databases
themselves, extensions, and migrations are handled on a given run. These, the per-service enable flags, and the owner
user names are normally set in the private inventory's group_vars.

## Kubernetes

The k0s distribution of Kubernetes is used by the DE, with the `k0sctl` tool providing the ability to bring up and tear
down clusters according to a YAML configuration file. We're using stacked control nodes, which means that each control
node also acts as an etcd member node. Control nodes do not run workloads and do not show up in the `kubectl get nodes`
command output.

## OpenLDAP

The DE uses OpenLDAP with an RFC 2307 schema as its user directory by default. If you don't have an existing LDAP
directory, the `ldap_slapd.yml` playbook can be used to create a new one; see [docs/ldap.md](docs/ldap.md). Note: the
DE has not been tested with other LDAP schemas.

## RabbitMQ

The DE and CyVerse Data Store both use RabbitMQ as a message bus. The DE uses it for notifications, and the data store
uses it to push updates to ElasticSearch for indexing. The `rabbitmq.yml` playbook will install and configure RabbitMQ
on a single node; see [docs/rabbitmq.md](docs/rabbitmq.md).

## HTCondor

The DE uses HTCondor to run non-interactive analyses. Several DE specific components are required for this to work, so
the recommended approach is to create a new HTCondor cluster that is dedicated to the DE. This can be done using the
`condor.yml` playbook.

## Cert-Manager

The DE uses cert-manager to generate and rotate self-signed TLS certs for use with NATS.

## NATS

The DE uses NATS in the backend to communicate between some services. By default, NATS is installed in clustered mode
with 4 replicas. You should be able to connect to any node to communicate with other services using NATS. The `nats`
role installs NATS via its Helm chart and runs in `kubernetes.yml` under the `nats` tag; see
[docs/nats.md](docs/nats.md) for retrieving the client/server TLS files.

**NOTE** Make sure the `KUBECONFIG` environment variable is set to the correct value in your local shell.

## GoCD

We use GoCD for continuous deployment. It's deployed outside of the Kubernetes cluster to simplify the automation of cluster maintenance.

| Playbook              | Description                                              | Example                                                  |
| --------------------- | -------------------------------------------------------- | -------------------------------------------------------- |
| gocd.yml              | Installs the GoCD server and agents (includes the below) | `ansible-playbook -i <inventory> -K gocd.yml`            |
| gocd_kubeconfig.yaml  | Installs the kubeconfig onto GoCD agent nodes            | `ansible-playbook -i <inventory> -K gocd_kubeconfig.yaml` |

## Grouper

Grouper is installed inside the same cluster as the Discovery Environment, but the process is different enough from
the rest of the services that it has its own role. The `grouper_init` role runs in `kubernetes.yml` under the
`grouper` tag:

```bash
ansible-playbook -i <inventory> --tags grouper kubernetes.yml
```

## Keycloak

Keycloak is used for authentication/authorization and is installed inside the same cluster as the Discovery
Environment. The `keycloak_install` role runs in `kubernetes.yml`, and only when the `keycloak` tag is passed
explicitly:

```bash
ansible-playbook -i <inventory> --tags keycloak kubernetes.yml
```

## Services

Each Discovery Environment service has a self-contained role under `roles/services/<service>/` that carries everything needed to configure, build, and deploy it:

| Path | Purpose |
| --- | --- |
| `templates/` | The service's configuration template (if it needs one), rendered into a per-service `<service>-configs` secret at deploy time |
| `files/skaffold.yaml`, `files/k8s/` | The canonical skaffold config and Kubernetes manifests for the service |
| `files/<service>.json` | The build descriptor recording the exact image (git ref + digest) to deploy |
| `tasks/main.yml` | Creates the config secret and deploys the service (via the `deploy-service` role) |
| `tasks/build.yml` | Builds the service image from source (via the `build-service` role) |

A shared `configs` secret holding environment-style settings used by many services is managed separately by the `service_configurations` role under the `configure-services` tag.

### Deploying services

Set `KUBECONFIG` to the target cluster before deploying. `deploy_it.yml` deploys services selected by tag, where each service's tag matches its role name:

```bash
# one service
ansible-playbook -i <inventory> deploy_it.yml --tags terrain

# several services
ansible-playbook -i <inventory> deploy_it.yml --tags terrain,sonora
```

The same roles are wired into `kubernetes.yml` for full-environment runs:

```bash
# the shared configs secret plus all of the services
ansible-playbook -i <inventory> --tags configure-services,deploy-all-services kubernetes.yml

# just the shared configs secret
ansible-playbook -i <inventory> --tags configure-services kubernetes.yml

# all of the services
ansible-playbook -i <inventory> --tags deploy-all-services kubernetes.yml
```

### Building services

For cloning the source repositories (`clone_sources.yml`), building images (`build_it.yml`), rebuilding a release (`build_release.yml`), and the full build/deploy workflow, see [BUILD_DEPLOY.md](BUILD_DEPLOY.md).

# Common Tasks

## Add a Node to the Kubernetes Cluster

``` bash
ansible-playbook -i <inventory> --ask-become-pass --tags add-nodes --limit <node-name> kubernetes.yml
```
