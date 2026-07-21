# playbooks

* [DE Administration Procedures](/playbooks/admin-procedures.md) - User-facing admin tasks via the Terrain admin API and Sonora admin panel — subscriptions, VICE access, workshops, DOI requests, alerts, and app moderation.
* [Copying Apps Between DE Instances](/playbooks/app-export-import.md) - Using the appei tool to export an app and its tools from one DE as a JSON bundle and import them into another via the Terrain API.
* [Argo Installation and Workflow Resources](/playbooks/argo-resources.md) - How the argo role installs Argo Workflows/Events and how argo_resources.yml loads the secrets that batch workflows mount.
* [Batch Analyses Troubleshooting](/playbooks/batch-analyses-troubleshooting.md) - Diagnosing stuck, failed, or orphaned batch analyses executed via Argo Workflows, including the AMQP status pipeline and output transfer.
* [Bootstrapping a Portal Admin](/playbooks/bootstrap-portal-admin.md) - How bootstrap_portal_admin.yml creates a login-capable portal admin across LDAP, the portal database, iRODS, and the DE.
* [Building and Deploying Services](/playbooks/build-and-deploy.md) - How service container images are built from source with build_it.yml and build_release.yml, and deployed with deploy_it.yml.
* [Certificate Management](/playbooks/certificate-management.md) - TLS certificate inventory for the DE, how certs are issued and renewed, and what to do when one has expired or is about to.
* [Continuous Integration to QA](/playbooks/ci-to-qa.md) - The tag-triggered CI path that builds service images on GitHub Actions, publishes build descriptors to de-releases, and deploys to QA via GoCD.
* [Deploying TLS Certificates](/playbooks/deploy-tls-certs.md) - How the tls_certs_main.yml playbook copies the combined TLS certificate to the proxy nodes for HAProxy.
* [Deploying a Full DE Environment](/playbooks/full-deployment.md) - How to deploy a complete Discovery Environment with kubernetes.yml, from kubeconfig generation through database setup and service rollout.
* [Longhorn Teardown](/playbooks/longhorn-teardown.md) - The all-or-nothing procedure for deleting a Longhorn install from a cluster, and how to recover if the default BackupTarget was deleted prematurely.
* [Miscellaneous Utility Playbooks](/playbooks/misc-utility-playbooks.md) - A catalog of the small standalone playbooks - security mitigations, k3s-era cleanup, host surveys, database copies, config pushes, and GoCD kubeconfig transfer.
* [Node OS Updates and Rolling Reboots](/playbooks/node-maintenance.md) - OS package updates with update_nodes.yml and drained, rolling reboots of cluster nodes with reboot_nodes.yml.
* [General Operations Runbook](/playbooks/ops-runbook.md) - Day-to-day DE cluster operations — health checks, restarts, scaling, rollbacks, config pushes, log access, and node maintenance.
* [Portal Exim Mail Relay](/playbooks/portal-exim.md) - How portal-exim.yml deploys an exim4 SMTP relay into the portal namespace for outbound portal mail.
* [VICE Image Caching](/playbooks/vice-image-cache.md) - The two mechanisms for pre-pulling VICE images onto worker nodes - the kube-fledged image_cache role and the legacy vice-cache Job playbook.
* [VICE Troubleshooting](/playbooks/vice-troubleshooting.md) - Diagnosing stuck or broken VICE interactive apps — loading-page stalls, scheduling and image pull failures, readiness problems, and orphaned resources.
