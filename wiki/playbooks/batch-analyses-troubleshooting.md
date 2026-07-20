---
type: Runbook
title: Batch Analyses Troubleshooting
description: Diagnosing stuck, failed, or orphaned batch analyses executed via Argo Workflows, including the AMQP status pipeline and output transfer.
resource: /docs/batch-analyses-troubleshooting.md
tags: [batch, analyses, argo, troubleshooting, amqp, status-pipeline]
timestamp: 2026-07-20T00:00:00Z
---

This runbook covers diagnosing and resolving problems with batch (non-VICE) analyses —
the kind submitted through the DE Apps panel and executed via Argo Workflows on Kubernetes.

For VICE (interactive) app problems, see
[VICE Troubleshooting](/playbooks/vice-troubleshooting.md).

## Overview: the analysis pipeline

Understanding which service owns each stage saves time when narrowing down a failure.

There are two batch execution paths. The **modern path** (Argo Workflows) is used
by current Kubernetes-based deployments. The **legacy path** (jex-adapter → AMQP →
condor-launcher → HTCondor) still exists in the codebase but is not used in new
deployments.

### Modern path (Argo Workflows)

```
User submits job
      │
      ▼
   Terrain          ← validates request, calls apps service
      │
      ▼
     apps           ← creates analysis record, calls app-exposer
      │
      ▼
  app-exposer       ← validates quota, submits Argo Workflow to Kubernetes
      │
      ▼
 Argo Workflow      ← runs job steps as Kubernetes pods
      │
      ▼
  status-sender     ← step in the workflow; curls Argo Events webhook
      │
      ▼
 Argo Events       ← Sensor "webhook-jsl" forwards to job-status-listener
      │
      ▼
job-status-listener ← HTTP server; receives status, publishes to AMQP
      │
      ▼
job-status-recorder ← AMQP consumer; writes to `job_status_updates` table
      │
      ▼
job-status-to-apps-adapter ← polls `job_status_updates`, notifies the `apps` service
      │
      ▼
     apps           ← updates the `jobs` table with final status
```

### Legacy path (HTCondor)

```
apps → jex-adapter (HTTP POST) → publishes to AMQP (jobs.launches key) → condor-launcher → condor_submit
```

If your deployment still runs `jex-adapter`, the submission path goes through it
instead of app-exposer's `/batch` endpoint. The status pipeline is nearly identical
in both cases, except the legacy system publishes to AMQP directly from within the
job (via road-runner) rather than going through Argo Events and job-status-listener.
See [Condor](/infrastructure/condor.md) for the legacy execution infrastructure.

### Status pipeline

Status flows **separately** from execution. An analysis can finish (or fail) in Kubernetes
while the status record in the database still shows `Running` if the status pipeline is broken.

## Prerequisites

```bash
export KUBECONFIG=~/.kube/prod.conf   # or qa.conf
export NS=prod                        # or qa
export DBMS_HOST=<dbms-host>          # from dbms_host in the inventory
export RABBITMQ_HOST=<rabbitmq-host>  # from rabbitmq_host in the inventory
```

## 1. User reports: analysis is stuck on "Running" or "Submitted"

### Step 1 — Find the analysis in Kubernetes

Get the analysis UUID from the DE or from the user. The UUID is the `external_id` in the
database and appears as the Argo Workflow name.

```bash
# List Argo Workflows; look for the UUID
kubectl -n $NS get workflows | grep <uuid>

# Get detailed status
kubectl -n $NS get workflow <uuid> -o yaml | grep -A10 "status:"

# Short status summary
kubectl -n $NS get workflow <uuid> -o jsonpath='{.status.phase}'
```

Argo Workflow phases:
- `Pending` — not yet scheduled
- `Running` — actively executing
- `Succeeded` — completed successfully
- `Failed` — at least one step failed
- `Error` — Argo itself had a problem (e.g., could not schedule a pod)

### Step 2 — Check the analysis record in the database

```bash
# Connect to the database (directly accessible from workstation or via VPN)
psql -h $DBMS_HOST -U de -d de
```

```sql
-- Find by external_id (the UUID from the UI)
SELECT id, job_name, status, start_date, end_date, user_id
FROM jobs
WHERE id = '<uuid>';

-- Find recent failed jobs for a user
SELECT id, job_name, status, start_date, end_date
FROM jobs
WHERE user_id = (SELECT id FROM users WHERE username = '<username>@iplantcollaborative.org')
ORDER BY start_date DESC
LIMIT 20;
```

### Step 3 — Reconcile Kubernetes state with DB state

| Argo phase  | DB status   | Likely cause                                    |
|-------------|-------------|--------------------------------------------------|
| `Succeeded` | `Running`   | Status message was lost in AMQP; see §4 below    |
| `Failed`    | `Running`   | Same — status pipeline issue                     |
| Not found   | `Running`   | Workflow was deleted or never created; see §5    |
| `Running`   | `Running`   | Actually running; check pods for errors          |
| `Failed`    | `Failed`    | Normal failed state; check step logs             |

## 2. Analysis failed — finding out why

### Check Argo Workflow step logs

```bash
# List steps and their status
kubectl -n $NS get workflow <uuid> -o jsonpath='{range .status.nodes[*]}{.displayName}{"\t"}{.phase}{"\n"}{end}'

# Get logs from a specific failed step (the node name comes from the above)
kubectl -n $NS logs <pod-name>

# Or via Argo: show logs from all failed steps
kubectl -n $NS get workflow <uuid> -o yaml | grep -B2 "phase: Failed" | grep "name:"
```

### Check app-exposer batch adapter (submission failures)

If an analysis never appears as an Argo Workflow at all, app-exposer likely failed to create it.

```bash
kubectl -n $NS logs -l de-app=app-exposer --since=1h | grep -i "error\|<uuid>\|batch"
```

Common failures:
- `failed to create workflow`: the Argo Workflow spec was rejected by Kubernetes (check resource
  limits, missing secrets, or the app-exposer config)
- Quota validation failure: the user exceeded their resource allocation
- No log entry at all for the UUID: the request never reached app-exposer; check `apps` service
  logs

### Check apps service (submission and completion)

```bash
kubectl -n $NS logs -l de-app=apps --since=1h | grep -i "error\|<uuid>"
```

## 3. "Output missing" — files not appearing in the data store

### Check the upload-files step (output transfer)

Batch Argo Workflows use `gocmd` (a Go-based iRODS client) in the `upload-files` step
to transfer job output back to iRODS. If this step fails, job results are lost.

```bash
# Find the upload-files step and its status
kubectl -n $NS get workflow <uuid> -o jsonpath='{range .status.nodes[*]}{.displayName}{"\t"}{.phase}{"\n"}{end}' | grep upload

# Get the pod for the upload step and check its logs
kubectl -n $NS get pods | grep <uuid>
kubectl -n $NS logs <upload-files-pod-name>
```

Common upload failure causes:
- iRODS credential failure (wrong password, expired token) — look for `CAT_INVALID_AUTHENTICATION`
  or authentication errors in the gocmd output
- The user's output path does not exist in iRODS — look for path-not-found errors
- The user's tool wrote outputs to `/tmp` or another container-local path outside the
  shared working directory. Only files in the workflow's working volume are transferred.
  The user needs to rerun the job writing outputs to the working directory configured in
  the tool definition.

## 4. Status pipeline is broken — analyses stuck in wrong state

If many analyses are stuck in `Running` when Argo shows them as finished, the AMQP status
pipeline has a problem.

### Check the status pipeline services

```bash
# Check all three services are running
kubectl -n $NS get pods -l de-app=job-status-listener
kubectl -n $NS get pods -l de-app=job-status-recorder
kubectl -n $NS get pods -l de-app=job-status-to-apps-adapter

# Check for errors
kubectl -n $NS logs -l de-app=job-status-listener --since=1h | grep -i error
kubectl -n $NS logs -l de-app=job-status-recorder --since=1h | grep -i error
kubectl -n $NS logs -l de-app=job-status-to-apps-adapter --since=1h | grep -i error
```

### Check AMQP queue depths

Via the [RabbitMQ](/infrastructure/rabbitmq.md) management UI (usually at
`http://$RABBITMQ_HOST:15672`) or via the API:

```bash
# Get queue depths (replace credentials as needed)
curl -s -u guest:guest http://$RABBITMQ_HOST:15672/api/queues/%2F$NS%2Fde/ | \
  jq '.[] | {name, messages, consumers}'
```

A growing queue with no consumption indicates a dead consumer. Restart the appropriate service:

```bash
kubectl -n $NS rollout restart deployment/job-status-listener
```

### Manually fix a stuck analysis

If an analysis has genuinely completed (Argo shows `Succeeded` or `Failed`) but the DB still
shows `Running`, you can update it directly:

```bash
psql -h $DBMS_HOST -U de -d de
```

```sql
-- Verify the workflow is actually done before updating
-- Only do this if you have confirmed the Argo Workflow has finished

UPDATE jobs
SET status = 'Failed',   -- or 'Completed'
    end_date = NOW()
WHERE id = '<uuid>'
  AND status = 'Running';
```

> **Important:** Only update status directly as a last resort, and only when you have verified
> the Argo Workflow state. Updating while a workflow is still running will confuse the status
> pipeline.

## 5. Workflow was never created / analysis immediately failed

### Check Terrain logs

The analysis request enters through Terrain, which validates it and forwards it to the apps
service.

```bash
kubectl -n $NS logs -l de-app=terrain --since=30m | grep -i "error\|<uuid>"
```

Look for:
- Authentication failures (the user's token was invalid at submission time)
- App or tool lookup failures (the app was deleted or is disabled)

### Check apps service logs

```bash
kubectl -n $NS logs -l de-app=apps --since=30m | grep -i "error\|<uuid>"
```

### Check app-exposer logs

```bash
kubectl -n $NS logs -l de-app=app-exposer --since=30m | grep -i "error\|<uuid>\|batch\|workflow"
```

## 6. "Jobs are failing" — widespread failure across many users

When many analyses fail at once, the problem is usually infrastructure rather than a specific
analysis.

### Quick infrastructure check

```bash
# Are the core services running?
kubectl -n $NS get pods | grep -v -E 'Running|Completed'

# Are there node-level issues?
kubectl get nodes
kubectl describe node <problem-node>

# Check recent Kubernetes events in the DE namespace
kubectl -n $NS get events --sort-by='.lastTimestamp' | tail -30
```

### Check Argo Workflow controller

```bash
kubectl -n argo get pods
kubectl -n argo logs -l app=workflow-controller --since=1h | grep -i error
```

### Check iRODS connectivity

If file transfers are failing globally, the iRODS server may be unreachable:

```bash
# Quick TCP connectivity test (iRODS uses a binary protocol, not HTTP)
kubectl -n $NS run irods-check --rm -it --restart=Never --image=alpine -- \
  sh -c "nc -zv $IRODS_HOST 1247 && echo OK || echo FAILED"

# Functional check via data-info's health endpoint (verifies authentication too)
kubectl -n $NS port-forward svc/data-info 60000:60000 &
curl -s http://localhost:60000/ | jq '.iRODS'
```

See [iRODS](/infrastructure/irods.md) for more detailed iRODS diagnostics.

## 7. Cleaning up orphaned / zombie analyses

An orphaned analysis is one where the Argo Workflow no longer exists (was deleted, or the
cluster was rebuilt) but the database still shows `Running`.

### Find orphaned analyses

```bash
# Get all Running job IDs from the DB
psql -h $DBMS_HOST -U de -d de -t -A -c \
  "SELECT id FROM jobs WHERE status='Running' AND start_date < NOW() - INTERVAL '24 hours'"
```

For each returned UUID, check whether an Argo Workflow exists:

```bash
kubectl -n $NS get workflow <uuid> 2>/dev/null || echo "NOT FOUND"
```

### Clean up

For any UUID where no Workflow exists:

```sql
UPDATE jobs
SET status = 'Failed',
    end_date = NOW()
WHERE id = '<uuid>'
  AND status = 'Running';
```

## 8. Useful one-liners

```bash
# All non-Running pods in the DE namespace (spot crashes quickly)
kubectl -n $NS get pods | grep -v Running | grep -v Completed

# Watch status pipeline services
watch 'kubectl -n $NS get pods -l "de-app in (job-status-listener,job-status-recorder,job-status-to-apps-adapter)"'

# Count analyses by status in the DB
psql -h $DBMS_HOST -U de -d de -c \
  "SELECT status, count(*) FROM jobs GROUP BY status ORDER BY count DESC;"

# Find analyses that have been Running for more than 8 hours
psql -h $DBMS_HOST -U de -d de -c \
  "SELECT id, job_name, user_id, start_date FROM jobs
   WHERE status='Running' AND start_date < NOW() - INTERVAL '8 hours'
   ORDER BY start_date;"
```

# Citations

[1] `docs/batch-analyses-troubleshooting.md` — source document for this page.
