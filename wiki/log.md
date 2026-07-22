# Wiki Update Log

## 2026-07-22

* **Removal**: Deleted the discoenv-analyses service page — the service was retired from the repo (no deployed DE service consumed its NATS lookups). Removed it from [Certificate Management](/playbooks/certificate-management.md)'s NATS consumer and restart lists, dropped the cross-reference from [discoenv-users](/services/discoenv-users.md), and documented the new `discoenv_analyses_cleanup.yml` in [Miscellaneous Utility Playbooks](/playbooks/misc-utility-playbooks.md).
* **Update**: [Miscellaneous Utility Playbooks](/playbooks/misc-utility-playbooks.md) and [openldap-docker](/services/openldap-docker.md) — documented the new `openldap_community_group.yml` playbook that backfills the `community` group on already-deployed OpenLDAP instances (the seed LDIF only loads on a fresh volume).

## 2026-07-21

* **Update**: [openldap-docker](/services/openldap-docker.md) — seed.ldif.j2 now also seeds the `community` group that portal-conductor adds new portal users to; its absence made registration 500 with LDAP "No Such Object".
* **Update**: [portal2](/services/portal2.md) — documented the new `portal_disable_require_new_user_email_confirmation` var (default `false`) feeding `features.disableRequireNewUserEmailConfirmation` in the rendered config.
* **Update**: [Longhorn](/infrastructure/longhorn.md) — documented the new `longhorn_tolerations` default (vice/analysis NoSchedule taints) and how it feeds `global.tolerations` and `defaultSettings.taintToleration` so the CSI plugin registers on tainted analysis nodes.
* **Update**: [Copying Apps Between DE Instances](/playbooks/app-export-import.md) — documented the new appei behavior: private-app export via temporary admin self-share, imports staying private by default with `--publish`/`--feature` opt-ins, and empty-documentation publishing for undocumented apps.

## 2026-07-20

* **Creation**: Added [Copying Apps Between DE Instances](/playbooks/app-export-import.md) documenting the rebuilt uv-managed `scripts/appei` tool for exporting/importing apps and tools via the Terrain API.
* **Creation**: Populated the services section with a page per DE microservice role under `ansible/roles/services/` (49 pages, from [analyses](/services/analyses.md) to [vice-status-listener](/services/vice-status-listener.md)).
* **Creation**: Added infrastructure pages for [cert-manager](/infrastructure/cert-manager.md), [HTCondor](/infrastructure/condor.md), [GoCD](/infrastructure/gocd.md), [GPU Workers](/infrastructure/gpu-workers.md), [Grouper](/infrastructure/grouper.md), [Harbor](/infrastructure/harbor.md), [Ingress](/infrastructure/ingress.md), [Jaeger](/infrastructure/jaeger.md), [Kubernetes Cluster](/infrastructure/kubernetes-cluster.md), [Longhorn](/infrastructure/longhorn.md), and [OpenSearch](/infrastructure/opensearch.md).
* **Creation**: Added playbook pages for [Full Deployment](/playbooks/full-deployment.md), [CI to QA](/playbooks/ci-to-qa.md), [Bootstrap Portal Admin](/playbooks/bootstrap-portal-admin.md), [Node Maintenance](/playbooks/node-maintenance.md), [portal-exim](/playbooks/portal-exim.md), [VICE Image Cache](/playbooks/vice-image-cache.md), [Argo Resources](/playbooks/argo-resources.md), and [Misc Utility Playbooks](/playbooks/misc-utility-playbooks.md).
* **Migration**: Migrated the top-level ops guides: [Ops Runbook](/playbooks/ops-runbook.md), [Admin Procedures](/playbooks/admin-procedures.md), [Batch Analyses Troubleshooting](/playbooks/batch-analyses-troubleshooting.md), [VICE Troubleshooting](/playbooks/vice-troubleshooting.md), and [Certificate Management](/playbooks/certificate-management.md) from docs/; [Keycloak](/infrastructure/keycloak.md) and [iRODS](/infrastructure/irods.md) migrated as infrastructure pages.
* **Update**: Repointed `resource` fields on [RabbitMQ](/infrastructure/rabbitmq.md), [OpenLDAP](/infrastructure/ldap.md), [HAProxy](/infrastructure/haproxy.md), [NATS](/infrastructure/nats.md), [PostgreSQL](/infrastructure/postgresql.md), and [Deploying TLS Certificates](/playbooks/deploy-tls-certs.md) from the removed `ansible/docs/` paths to the current docs/ locations, folding in the newer doc content.
* **Update**: Documented the updating-the-wiki skill and CLAUDE.md-driven staleness check in [Maintaining This Wiki](/maintaining-the-wiki.md).
* **Creation**: Added [Maintaining This Wiki](/maintaining-the-wiki.md) and a Meta section in the root index.
* **Migration**: Migrated [RabbitMQ](/infrastructure/rabbitmq.md), [OpenLDAP](/infrastructure/ldap.md), and [HAProxy](/infrastructure/haproxy.md) from ansible/docs.
* **Migration**: Migrated [Deploying TLS Certificates](/playbooks/deploy-tls-certs.md) from ansible/docs/tls_certs.md.
* **Migration**: Split notes/storage.md into [OpenEBS](/infrastructure/openebs.md) and [Longhorn Teardown](/playbooks/longhorn-teardown.md).
* **Initialization**: Created the wiki bundle (OKF 0.1) with infrastructure, playbooks, and services sections.
* **Creation**: Seeded [PostgreSQL](/infrastructure/postgresql.md) and [NATS](/infrastructure/nats.md) from ansible/docs.
* **Creation**: Seeded [Building and Deploying Services](/playbooks/build-and-deploy.md) from ansible/BUILD_DEPLOY.md.
