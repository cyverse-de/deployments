# DE Administration Procedures

This runbook covers administrative tasks performed through the Terrain admin API and the
Sonora admin panel, rather than through `kubectl`. These are the day-to-day user-facing
administration tasks: managing subscriptions, granting VICE access, handling workshops,
and moderating DOI requests.

---

## Prerequisites

All Terrain admin API calls require an admin token. Use Terrain's `/token` endpoint,
which accepts HTTP Basic authentication and returns a Keycloak access token:

```bash
export DE_HOST=https://de.cyverse.org   # or your deployment's de_hostname

# Get a token (replace with your admin credentials)
TOKEN=$(curl -s -u "$ADMIN_USER:$ADMIN_PASS" \
  "$DE_HOST/terrain/token/keycloak" | jq -r '.access_token')

export AUTH_HEADER="Authorization: Bearer $TOKEN"
```

Alternatively, you can call the Keycloak token endpoint directly. This requires the
`client_secret` for the DE's confidential client (found in the deployment inventory as
`keycloak_client_secret`):

```bash
export KEYCLOAK_URL=https://auth.cyverse.org
export REALM=CyVerse

TOKEN=$(curl -s -X POST \
  "$KEYCLOAK_URL/auth/realms/$REALM/protocol/openid-connect/token" \
  -d "client_id=de" \
  -d "client_secret=$KEYCLOAK_CLIENT_SECRET" \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASS" \
  -d "grant_type=password" | jq -r '.access_token')

export AUTH_HEADER="Authorization: Bearer $TOKEN"
```

> **Note:** Admin API access requires that your username is in one of the groups listed in
> `admin_groups` in the inventory. See [keycloak.md](keycloak.md) §4 for group management.

---

## Debugging user issues

If you need to see the DE as a particular user sees it — to investigate a problem they've
reported or verify that something looks correct from their perspective — you can
impersonate their account via Keycloak. This gives you a full authenticated session as
that user in the DE without needing their credentials.

See [keycloak.md](keycloak.md) §9 for the impersonation procedure.

---

## 1. Workshop and event access provisioning

When running a workshop or training event, participants typically need:
- A **Pro subscription** (for CPU hours and data quota)
- **VICE access** (concurrent job limit > 0)

### Automated provisioning

Most workshop provisioning is handled automatically:

- **User portal** (`user.cyverse.org`): The portal2 workshop system manages enrollment,
  email pre-approval, and automatic VICE access grants (sets concurrent job limit to 2)
  when participants are added to a workshop.
- **Kubernetes CronJobs**: The `subscription-granter` and `workshop-subscriptions` jobs in
  the `k8s-resources` repository handle recurring subscription grants for workshop
  participants and users matching LDAP patterns.

The portal handles VICE access automatically but does **not** grant QMS subscriptions
(Pro plan). For that, use either the k8s jobs above or the manual procedure below.

### Manual bulk provisioning via the API

If you need to grant Pro subscriptions to workshop participants manually (e.g., for a
one-off event not covered by the k8s jobs), you can use the bulk subscription endpoint.

**Get workshop emails from the portal:**
```bash
curl -sH "$AUTH_HEADER" \
  "https://user.cyverse.org/api/workshops/<workshop-id>/emails" \
  | jq -r '.[].email'
```

**Look up a username by email:**
```bash
curl -sH "$AUTH_HEADER" \
  "https://user.cyverse.org/api/users?limit=100&keyword=<email>" \
  | jq -r '.results[] | select(.email == "<email>") | .username'
```

**Grant Pro subscriptions in bulk:**
```bash
curl -sH "$AUTH_HEADER" -X POST \
  "${DE_HOST}/terrain/admin/qms/subscriptions" \
  -H 'Content-Type: application/json' \
  -d '{"subscriptions": [
    {"username": "user1", "plan_name": "Pro", "paid": false},
    {"username": "user2", "plan_name": "Pro", "paid": false}
  ]}' | jq .
```

**Grant VICE access to one user** (if not handled by the portal):
```bash
curl -sH "$AUTH_HEADER" -X PUT \
  "${DE_HOST}/terrain/admin/settings/concurrent-job-limits/<username>" \
  -H 'Content-Type: application/json' \
  -d '{"concurrent_jobs": 2}'
```

---

## 2. Subscription management

Subscriptions, quotas, and add-ons are managed in the Sonora admin panel at
`/admin/subscriptions`. From there you can:

- View any user's current plan and resource usage
- Create, upgrade, or change subscriptions
- Edit quotas and manage add-ons
- Browse all subscriptions with search and pagination

For bulk subscription creation (e.g., workshop provisioning), see §1 above which uses
the `POST /terrain/admin/qms/subscriptions` batch endpoint.

---

## 3. VICE concurrent job limits

Single-user job limit management (lookup, set, revoke) is available in the Sonora admin
panel at `/admin/vice` (the "Quota Requests" tab includes a Job Limits card). Setting a
user's limit to 0 effectively revokes their VICE access.

The following operation is only available via the API:

### List all users with a concurrent job limit set

```bash
curl -sH "$AUTH_HEADER" \
  "${DE_HOST}/terrain/admin/settings/concurrent-job-limits" \
  | jq .
```

---

## 4. VICE analysis administration

Terminating, saving, and extending VICE analyses is available in the Sonora admin panel
at `/admin/vice` (the "Analyses" tab). Prefer the UI for one-off operations.

The following is only available via the API:

### Check current time limit for an analysis

```bash
curl -sH "$AUTH_HEADER" \
  "${DE_HOST}/terrain/admin/vice/analyses/<analysis-id>/time-limit" \
  | jq .
```

---

## 5. DOI (permanent identifier) requests

> **Note:** This section documents CyVerse's DataCite DOI integration and may not apply to
> other DE deployments.

The full DOI curation procedure is documented in detail in the Sonora admin panel. The
following is an operational summary for reference.

DOI requests are visible in the DE admin panel at `/admin/doi`. The workflow:

1. A user submits a DOI request through the DE. An Intercom ticket is created automatically.
2. In the admin panel, set the request status to **Pending** (if you won't review immediately)
   or **Evaluation** (when you are actively reviewing).
3. **Check the user's subscription tier**: users on a Basic plan are not entitled to DOIs.
   Set status to **Rejected** with a comment if so.
4. **Review the dataset** in `/iplant/home/shared/commons_repo/staging`:
   - A `ReadMe` file with manifest/inventory
   - No spaces in folder or file names
   - Organized sensibly; if sequences are included, BioSample IDs should be listed
   - Metadata using the DataCite 4.1 template (check via DE metadata viewer)
5. If changes are needed, email the submitter and update the request comments. Ensure
   the submitter has at least write permission on their staging folder.
6. Once data and metadata pass review, set status to **Approved**.
7. Click **Create Permanent Identifier** in the admin panel. A DOI is assigned, the
   folder moves from `staging` to `curated`, and the user receives an email.
8. **Post-creation:** Add `identifierType` metadata AVU to the curated folder:
   - Attribute: `identifierType`
   - Value: `DOI`
   - (No unit)
   This is required to fix a known bug where the citation on the landing page does not
   display correctly without this AVU.

### Updating a DOI dataset (new version)

When a dataset needs a new version:
1. Have the user copy the old folder to their home directory, make changes, and submit a
   new DOI request. They should fill in the `Version` field.
2. Add a `relatedIdentifier` link in the new version's metadata pointing to the old DOI.
3. After creating the new DOI, edit the old DOI's metadata:
   - Add a `relatedIdentifier` linking to the new version.
   - If the old version is being deprecated (due to an error), check the "deprecated" field
     in the DataCite template and add "DEPRECATED" to the folder title.
4. Any metadata changes must also be synced manually in DataCite Fabrica.

### DOI datasets with more than 1000 files

The DE cannot automatically move large datasets. If the move fails:
1. The requestor's email will include a notice. You will also receive one.
2. Get owner permission on the folder from the requestor.
3. Use iCommands to manually move the folder:
   ```bash
   imv /iplant/home/<user>/<folder> /iplant/home/shared/commons_repo/staging/<folder>
   ```
4. Curate as usual. When the DOI is created, manually move the curated folder:
   ```bash
   imv /iplant/home/shared/commons_repo/staging/<folder> \
       /iplant/home/shared/commons_repo/curated/<folder>
   ```
5. Set permissions on the curated folder:
   ```bash
   ichmod -rV read anonymous <folder>
   ichmod -rV read public <folder>
   ```

---

## 6. Alerts

System-wide alerts (banners shown to all DE users) are managed from the Sonora admin panel
at `/admin/alerts`.

To create an alert via the API:

```bash
curl -sH "$AUTH_HEADER" -X POST \
  "${DE_HOST}/terrain/admin/alerts" \
  -H 'Content-Type: application/json' \
  -d '{
    "start-date": "2026-08-01T08:00:00-00:00",
    "end-date": "2026-08-01T10:00:00-00:00",
    "alert-text": "The DE will be unavailable on Saturday 2026-08-01 from 8am–10am UTC for scheduled maintenance."
  }'
```

---

## 7. App and tool administration

The Sonora admin panel (`/admin/apps`, `/admin/tools`) covers most app/tool moderation.
Common tasks that may need to be done via the API:

### Get the admin status of an app

```bash
curl -sH "$AUTH_HEADER" \
  "${DE_HOST}/terrain/admin/apps/de/<app-id>" \
  | jq .
```

### Delete (shred) an app permanently

```bash
curl -sH "$AUTH_HEADER" -X DELETE \
  "${DE_HOST}/terrain/admin/apps/de/<app-id>"
```

The path includes a system ID (`de`) before the app ID.

### List pending publication requests

```bash
curl -sH "$AUTH_HEADER" \
  "${DE_HOST}/terrain/admin/apps/publication-requests" \
  | jq .
```

---

## 8. Useful lookup: username ↔ email

The user portal API is useful for cross-referencing usernames and email addresses:

```bash
# Find username by email
curl -sH "$AUTH_HEADER" \
  "https://user.cyverse.org/api/users?limit=100&keyword=<email>" \
  | jq -r '.results[] | select(.email == "<email>") | .username'

# Find email by username
curl -sH "$AUTH_HEADER" \
  "https://user.cyverse.org/api/users?limit=100&keyword=<username>" \
  | jq -r '.results[] | select(.username == "<username>") | .email'
```
