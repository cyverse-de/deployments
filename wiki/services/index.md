# services

* [analyses](/services/analyses.md) - HTTP API over the DE database that serves analysis (job) records to other DE services.
* [app-exposer](/services/app-exposer.md) - In-cluster API that launches and manages VICE and batch analyses, exposing them via Kubernetes resources and enforcing their time limits.
* [apps](/services/apps.md) - Clojure service managing DE app definitions, categories, and job submission, backed by the DE database.
* [async-tasks](/services/async-tasks.md) - HTTP API for tracking asynchronous DE tasks, configured with the shared jobservices.yml config.
* [bulk-typer](/services/bulk-typer.md) - Assigns file types in bulk by reading files from iRODS and recording the ipc-filetype attribute, driven by AMQP.
* [clockwork](/services/clockwork.md) - Scheduler that triggers recurring DE jobs, notably infosquito indexing, publishing over AMQP and reading iRODS.
* [dashboard-aggregator](/services/dashboard-aggregator.md) - Aggregates the data shown on the DE dashboard — news/event feeds, videos, and app information such as favorites and featured apps.
* [data-info](/services/data-info.md) - HTTP API for data-store operations — file and folder metadata, permissions, path lists, and anonymous-access URLs backed by iRODS.
* [de-mailer](/services/de-mailer.md) - Sends DE email notifications over HTTP and by consuming the email_requests AMQP queue, building links from the DE base URL and relaying through an in-cluster Exim SMTP host.
* [de-webhooks](/services/de-webhooks.md) - Consumes DE notification messages from RabbitMQ and forwards them to users' configured webhook endpoints.
* [dewey](/services/dewey.md) - Indexes data-store changes into OpenSearch by consuming iRODS change messages from the irods AMQP exchange.
* [event-recorder](/services/event-recorder.md) - AMQP worker that consumes event messages from the de exchange and records them, sharing the jobservices.yml configuration with the other jobservices workers.
* [formation](/services/formation.md) - Keycloak-authenticated HTTP API (with MCP support) fronting apps, app-exposer, and permissions for launching and managing analyses, including VICE URL readiness checks.
* [group-propagator](/services/group-propagator.md) - AMQP worker that propagates Grouper group-membership changes to the data store, using iplant-groups and data-info.
* [info-typer](/services/info-typer.md) - JVM worker that consumes iRODS change messages from the irods AMQP exchange and stamps files with an ipc-filetype metadata attribute.
* [infosquito2](/services/infosquito2.md) - Periodic indexer that reconciles the iRODS ICAT and metadata database into the OpenSearch/Elasticsearch index used by DE search.
* [iplant-groups](/services/iplant-groups.md) - HTTP facade over the Grouper Web Services API that the rest of the DE uses for group and subject management.
* [job-status](/services/job-status.md) - Merged job status pipeline service - HTTP intake, AMQP recording into the DE database, and propagation of updates to the apps service.
* [kifshare](/services/kifshare.md) - Public download page for files shared from the data store via iRODS tickets.
* [maintenance-page](/services/maintenance-page.md) - Maintenance-mode page that redirects DE traffic to itself by rewriting the environment's Gateway API HTTPRoutes.
* [metadata](/services/metadata.md) - DE metadata service backed by its own metadata database on PostgreSQL.
* [notifications](/services/notifications.md) - User notifications service backed by its own notifications database, reached by other services at http://notifications/v1.
* [openldap-docker](/services/openldap-docker.md) - In-cluster OpenLDAP directory for DE deployments without an external LDAP server, deployed as a StatefulSet with config and seed data rendered from templates.
* [permissions](/services/permissions.md) - DE permissions service backed by its own PostgreSQL database, with read access to the Grouper database for group information.
* [portal-conductor](/services/portal-conductor.md) - Account-provisioning API used by the user portal, acting on LDAP, iRODS, terrain, Mailman, and formation, with an exim sidecar for outbound mail.
* [portal2](/services/portal2.md) - The CyVerse user portal web application, handling account self-registration, sessions, and service access via Keycloak, portal-conductor, and terrain.
* [requests](/services/requests.md) - HTTP service for administrative requests in the DE, backed by the DE database via the shared jobservices configuration.
* [resource-usage-api](/services/resource-usage-api.md) - HTTP API for DE resource usage data: CPU hours from the DE database and data-store usage from the ICAT database, recorded against the subscriptions service.
* [search](/services/search.md) - Search API that queries the data-store Elasticsearch/OpenSearch index and consults data-info for path information.
* [sonora](/services/sonora.md) - The Discovery Environment web user interface, a Node.js app that fronts terrain and Keycloak.
* [subscriptions](/services/subscriptions.md) - Subscription service that answers subscription requests over HTTP and serves the merged QMS /v1 API, backed by the QMS database.
* [terrain](/services/terrain.md) - The DE's public API gateway, routing UI requests to the backend services and talking to iRODS and Keycloak directly.
* [user-info](/services/user-info.md) - HTTP service backing user preferences, sessions, and saved searches, stored in the DE database.
* [vice-default-backend](/services/vice-default-backend.md) - Fallback backend for VICE wildcard traffic that serves a loading page or 302-redirects unrecognized subdomains to the owning cluster.
* [vice-operator](/services/vice-operator.md) - Operator that runs VICE analyses in a dedicated namespace, built from the app-exposer repo and deployed with its own RBAC instead of skaffold.
