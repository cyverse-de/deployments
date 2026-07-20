# infrastructure

* [cert-manager](/infrastructure/cert-manager.md) - How cert-manager is installed via Helm and which ClusterIssuers the deployment creates for self-signed and Let's Encrypt certificates.
* [HTCondor](/infrastructure/condor.md) - The HTCondor pool that runs DE batch analyses — inventory groups, the condor.yml install playbook, node configuration, and the uninstall playbook.
* [GoCD](/infrastructure/gocd.md) - The GoCD continuous-deployment server and agents installed on hosts outside the cluster by gocd.yml, including agent tooling and kubeconfig distribution.
* [GPU Workers](/infrastructure/gpu-workers.md) - How GPU worker nodes get NVIDIA drivers, a container-toolkit runtime, and device-plugin labeling so VICE analyses can schedule onto them.
* [Grouper](/infrastructure/grouper.md) - How the grouper_init role deploys Grouper in-cluster — config secret, one-time database and folder initialization via a gsh pod, and the grouper-loader and grouper-ws workloads.
* [HAProxy](/infrastructure/haproxy.md) - The two HAProxy deployments in a DE install — the baseline de_proxy node and the ui_haproxy configuration fronting the DE UI — plus the Kubernetes API load balancer.
* [Harbor](/infrastructure/harbor.md) - How the Harbor container registry is deployed via its Helm chart in kubernetes.yml, including TLS, Gateway/Ingress exposure, and its external PostgreSQL databases.
* [Ingress and Gateway Routing](/infrastructure/ingress.md) - Traefik (Gateway API) is the primary edge for DE traffic, with ingress-nginx available for Ingress-based exposure; the kubernetes_ingress role defines the DE, portal, and VICE gateways and routes.
* [iRODS and Data Store](/infrastructure/irods.md) - How the DE connects to iRODS — verifying connectivity, data-info failures, service account rotation, the iRODS CSI driver, and file transfer troubleshooting.
* [Jaeger](/infrastructure/jaeger.md) - Optional distributed-tracing backend — collector and query deployments backed by Elasticsearch-compatible storage, installed only when the jaeger tag is named explicitly.
* [Keycloak](/infrastructure/keycloak.md) - Keycloak administration for the DE — deployment, health checks, client secret rotation, admin users, impersonation, and diagnosing authentication failures.
* [Kubernetes Cluster](/infrastructure/kubernetes-cluster.md) - How the k0s cluster is provisioned — node preparation, firewall, API load balancer, k0sctl apply, and the kubernetes.yml orchestration and tags.
* [OpenLDAP](/infrastructure/ldap.md) - How OpenLDAP is installed for the DE by the ldap_slapd.yml playbook, and the base entities, groups, and service accounts it defines.
* [Longhorn](/infrastructure/longhorn.md) - The opt-in longhorn role that installs Longhorn replicated block storage via Helm — default StorageClass, replica sizing, and backup-target handling. Superseded by OpenEBS.
* [NATS](/infrastructure/nats.md) - How NATS is installed via its Helm chart by the nats role, and how to download its TLS certs and creds from cluster secrets.
* [OpenEBS](/infrastructure/openebs.md) - How OpenEBS cluster storage is deployed by the opt-in openebs role in kubernetes.yml, and the kustomize/kubectl versions it requires.
* [OpenSearch](/infrastructure/opensearch.md) - The single-node in-cluster OpenSearch StatefulSet backing the DE data-search pipeline, deployed by the opensearch role via kubernetes.yml or the standalone opensearch.yml playbook.
* [PostgreSQL](/infrastructure/postgresql.md) - How PostgreSQL is installed and the DE databases are initialized by the install-postgres and setup-databases passes of kubernetes.yml, plus day-to-day operations such as backups, manual migrations, and diagnostics.
* [RabbitMQ](/infrastructure/rabbitmq.md) - How RabbitMQ is installed and configured for the DE services by the rabbitmq.yml and rabbitmq_configure.yml playbooks.
