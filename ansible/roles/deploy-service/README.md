# deploy-service

Deploys a DE service with `skaffold deploy`, using the image built into
`<build_json_dir>/<project_name>.json`.

## Generated manifests

Before running skaffold, this role renders the service's Kubernetes manifest
from `roles/services/<svc>/templates/k8s/<manifest>.j2` into
`<skaffold_dir>/k8s/<manifest>` (the path skaffold reads). The rendered
`files/k8s/*.yml` / `*.yaml` files are **generated build artifacts** and are
git-ignored — edit the `.j2` template, not the rendered file. The template
consumes the owning role's `<svc>_replicas` and `<svc>_pod_anti_affinity`
variables (see each service role's `defaults/main.yml`).

`manifest_file` defaults to `{{ project_name }}.yml`; override it in the
`include_role` call when the manifest name differs (e.g. `maintenance-page`
uses `maintenance-page.yaml`). If no template exists for a caller, the render
step is skipped and skaffold deploys whatever manifest is already on disk.
