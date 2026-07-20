# playbooks

* [Building and Deploying Services](/playbooks/build-and-deploy.md) - How service container images are built from source with build_it.yml and build_release.yml, and deployed with deploy_it.yml.
* [Deploying TLS Certificates](/playbooks/deploy-tls-certs.md) - How the tls_certs_main.yml playbook copies the combined TLS certificate to the proxy nodes for HAProxy.
* [Longhorn Teardown](/playbooks/longhorn-teardown.md) - The all-or-nothing procedure for deleting a Longhorn install from a cluster, and how to recover if the default BackupTarget was deleted prematurely.
