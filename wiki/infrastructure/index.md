# infrastructure

* [HAProxy](/infrastructure/haproxy.md) - The two HAProxy deployments in a DE install — the baseline de_proxy node and the ui_haproxy configuration fronting the DE UI — plus the Kubernetes API load balancer.
* [OpenLDAP](/infrastructure/ldap.md) - How OpenLDAP is installed for the DE by the ldap_slapd.yml playbook, and the base entities, groups, and service accounts it defines.
* [NATS](/infrastructure/nats.md) - How NATS is installed via its Helm chart by the nats role, and how to download its TLS certs and creds from cluster secrets.
* [OpenEBS](/infrastructure/openebs.md) - How OpenEBS cluster storage is deployed by the opt-in openebs role in kubernetes.yml, and the kustomize/kubectl versions it requires.
* [PostgreSQL](/infrastructure/postgresql.md) - How PostgreSQL is installed and the DE databases are initialized by the install-postgres and setup-databases passes of kubernetes.yml.
* [RabbitMQ](/infrastructure/rabbitmq.md) - How RabbitMQ is installed and configured for the DE services by the rabbitmq.yml and rabbitmq_configure.yml playbooks.
