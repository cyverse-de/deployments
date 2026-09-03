# playbooks

* [DE Administration Procedures](/playbooks/admin-procedures.md) - User-facing admin tasks via the Terrain admin API and Sonora admin panel — subscriptions, VICE access, workshops, DOI requests, alerts, and app moderation.
* [Copying Apps Between DE Instances](/playbooks/app-export-import.md) - Using the appei tool to export an app and its tools from one DE as a JSON bundle and import them into another via the Terrain API, and the de_apps role that imports a default set into a new deployment.
* [Argo Installation and Workflow Resources](/playbooks/argo-resources.md) - How the argo role installs Argo Workflows/Events and how argo_resources.yml loads the secrets that batch workflows mount.
* [Batch Analyses Troubleshooting](/playbooks/batch-analyses-troubleshooting.md) - Diagnosing stuck, failed, or orphaned batch analyses executed via Argo Workflows, including the AMQP status pipeline and output transfer.
* [Bootstrapping a Portal Admin](/playbooks/bootstrap-portal-admin.md) - How bootstrap_portal_admin.yml creates a login-capable portal admin across LDAP, the portal database, iRODS, and the DE.
* [Building and Deploying Services](/playbooks/build-and-deploy.md) - How service container images are built from source with build_it.yml and build_release.yml, and deployed with deploy_it.yml.
* [Certificate Management](/playbooks/certificate-management.md) - TLS certificate inventory for the DE, how certs are issued and renewed, and what to do when one has expired or is about to.
* [Continuous Integration Builds](/playbooks/ci-to-qa.md) - The tag-triggered CI path that builds a service image on GitHub Actions and commits the updated build descriptor back to the deployments repo.
* [Rewriting App Community Tags](/playbooks/community-tags.md) - Running the community-tags migration, which changes the community tag on an app from the community's name to its ID.
* [Deploying TLS Certificates](/playbooks/deploy-tls-certs.md) - How the tls_certs_main.yml playbook copies the combined TLS certificate to the proxy nodes for HAProxy.
* [Deploying a Full DE Environment](/playbooks/full-deployment.md) - How to deploy a complete Discovery Environment with kubernetes.yml, from kubeconfig generation through database setup and service rollout.
* [Importing Groups from Grouper](/playbooks/grouper-import.md) - Running the grouper-import tool to copy DE group data out of Grouper into the permissions schema, and keeping it in step during the migration.
* [Local Single-Node Deployment](/playbooks/local-single-node-deployment.md) - How to stand up a full DE from scratch on a freshly installed single-node k0s cluster with local.yml, using an in-cluster PostgreSQL and RabbitMQ, sslip.io hostnames on a pinned Traefik ClusterIP, a locally trusted CA, and a reused QA iRODS zone.
* [Longhorn Teardown](/playbooks/longhorn-teardown.md) - The all-or-nothing procedure for deleting a Longhorn install from a cluster, and how to recover if the default BackupTarget was deleted prematurely.
* [Miscellaneous Utility Playbooks](/playbooks/misc-utility-playbooks.md) - A catalog of the small standalone playbooks - security mitigations, k3s-era cleanup, host surveys, database copies, config pushes, app imports, and GoCD kubeconfig transfer.
* [Node OS Updates and Rolling Reboots](/playbooks/node-maintenance.md) - OS package updates with update_nodes.yml and drained, rolling reboots of cluster nodes with reboot_nodes.yml.
* [Merging the Notifications Database into DE](/playbooks/notifications-db-merge.md) - How notifications_db_merge.yml moves the standalone notifications database into the DE database's public schema, remapping user and notification-type identifiers on the way.
* [General Operations Runbook](/playbooks/ops-runbook.md) - Day-to-day DE cluster operations — health checks, restarts, scaling, rollbacks, config pushes, log access, and node maintenance.
* [Permissions Performance Testing](/playbooks/permissions-performance-testing.md) - Building a synthetic production-scale dataset in the permissions schema and measuring the group-expansion query paths against it.
* [Portal Exim Mail Relay](/playbooks/portal-exim.md) - How portal-exim.yml deploys an exim4 SMTP relay into the portal namespace for outbound portal mail.
* [Production Release Procedure](/playbooks/production-release.md) - The end-to-end production release run — maintenance mode, quiescing Data Store consumers, config and database updates, service deploys, and node updates.
* [VICE Image Caching](/playbooks/vice-image-cache.md) - The two mechanisms for pre-pulling VICE images onto worker nodes - the kube-fledged image_cache role and the legacy vice-cache Job playbook.
* [VICE Troubleshooting](/playbooks/vice-troubleshooting.md) - Diagnosing stuck or broken VICE interactive apps — loading-page stalls, scheduling and image pull failures, readiness problems, and orphaned resources.
