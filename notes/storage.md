## Deleting longhorn
```bash
$ kubectl delete ValidatingWebhookConfiguration longhorn-webhook-validator
$ kubectl delete MutatingWebhookConfiguration longhorn-webhook-mutator
$ for i in (kubectl -n longhorn-system get daemonsets -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete daemonsets $i; end
$ for i in (kubectl -n longhorn-system get deployments -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete deployments $i; end
$ for i in (kubectl -n longhorn-system get configmaps -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete configmaps $i; end
$ for i in (kubectl -n longhorn-system get secrets -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete secrets $i; end
$ for i in (kubectl -n longhorn-system get serviceaccounts -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete serviceaccounts $i; end
$ for i in (kubectl -n longhorn-system get poddisruptionbudgets.policy -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete poddisruptionbudgets.policy $i; end
$ for i in (kubectl -n longhorn-system get settings.longhorn.io -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete settings.longhorn.io $i; end
$ for i in (kubectl -n longhorn-system get events -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete events $i; end
$ for i in (kubectl -n longhorn-system get lease.coordination.k8s.io -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete lease.coordination.k8s.io $i; end
$ for i in (kubectl -n longhorn-system get backuptarget.longhorn.io -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete backuptarget.longhorn.io $i; end
$ for i in (kubectl -n longhorn-system get instancemanager.longhorn.io -o custom-columns=:.metadata.name --no-headers); kubectl -n longhorn-system delete instancemanager.longhorn.io $i; end
$ gocmd --log_level=debug get /cyverse/home/wregglej/test/configMapServices.yaml
$ kubectl delete namespace longhorn-system
```

## Installing OpenEBS

OpenEBS is deployed by the `openebs` Ansible role. It is opt-in (`openebs_enabled`
defaults to `false`), so enable it in your inventory's group_vars or pass it on the
command line:

```bash
ansible-playbook -i <inventory> --tags openebs -e openebs_enabled=true kubernetes.yml
```

The role renders the kustomization on the control machine, so it needs `kustomize` >= v5.2.0
or `kubectl` >= v1.31 on the PATH (older versions reject the overlay's multi-document patch
file). The role waits for the OpenEBS workloads to become ready before finishing.
