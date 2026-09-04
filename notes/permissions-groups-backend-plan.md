> # ⚠️ SUPERSEDED — DO NOT FOLLOW
>
> This plan targets the **abandoned Keycloak-backed** groups service and the
> HTTP `clients/groups` package behind a `groups.enabled` toggle (permissions
> PR #30). That direction was dropped on 2026-07-24: group data now lives in the
> `permissions` schema of the DE database, and the permissions service expands
> membership with a SQL join instead of calling out of process. **PR #30 is
> closed and its `groups-backend` branch deleted.**
>
> Current plan: `~/.claude/plans/foamy-puzzling-cascade.md` (Phase 3 replaces
> everything below). Kept only for the reasoning history.

# Permissions-on-Groups Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the permissions service resolve group memberships through the new Keycloak-backed groups service instead of querying the Grouper PostgreSQL database directly, selected by configuration.

**Architecture:** Two small changes in two repos. (1) The groups service gains an `admin.users` config listing trusted service accounts that bypass per-group permission checks, so the permissions service can read any group's membership. (2) The permissions repo gains a `clients/groups` package implementing its existing 5-method `grouper.Grouper` interface over the groups service HTTP API, wired in behind a `groups.enabled` config toggle (default off → existing Grouper DB behavior unchanged). Subject source IDs are derived locally from the permissions DB's own `subject_type`, preserving the legacy `"ldap"`/`"g:gsa"` wire values.

**Tech Stack:** Go. groups repo: Echo v4, koanf config, testify, `just` for build/test. permissions repo: go-swagger, viper via `cyverse-de/configurate`, testify, net/http/httptest.

## Global Constraints

- Repos: `/home/johnw/work/src/github.com/cyverse-de/groups` (call it **groups repo**) and `/home/johnw/work/src/github.com/cyverse-de/permissions` (call it **permissions repo**). Create a feature branch in each before the first commit: `git checkout -b admin-users` (groups repo), `git checkout -b groups-backend` (permissions repo).
- **Flat membership assumption (user-verified):** groups never contain groups. Every member of a group is a user.
- **Wire contract:** the permissions API's `subject_source_id` must keep emitting `"ldap"` for users and `"g:gsa"` for groups — downstream consumers (apps, sonora) compare against these strings.
- **No caching** in this change. It can be added later if needed.
- Never edit go-swagger generated files in the permissions repo (`models/`, `restapi/operations/`, `restapi/embedded_spec.go`). Only `restapi/configure_permissions.go` (hand-maintained) and new packages.
- The groups service HTTP API surface must not change (no new endpoints, no swagger regeneration needed) — only authorization behavior changes.
- Follow repo test style: table-driven tests, testify `assert`/`require`, existing mock patterns.
- Run tests with `just test` in the groups repo and `go test ./...` in the permissions repo.
- Log messages for unusual conditions must state the probable cause.

## Out of Scope (do not do these)

- Cutover data migration of group-type subject IDs in the permissions DB (Grouper UUIDs → Keycloak UUIDs). Separate effort at cutover time.
- Deployment wiring (ansible roles, config templates for either service). Separate deployments-repo task.
- Removing the Grouper DB client from permissions. It stays as the default backend until cutover.
- Migrating any other iplant-groups consumer (apps, group-propagator, etc.).

---

### Task 1: groups repo — `admin.users` trusted service accounts

**Files:**
- Modify: `cmd/groups/app.go` (App struct ~line 22, `NewApp` ~line 37; add `adminUsersFromConfig` helper near `permissionsBaseURL` ~line 88)
- Modify: `cmd/groups/authz.go` (add `isAdminUser`; short-circuit `requireLevel` ~line 40 and `requireReadOrMember` ~line 54)
- Modify: `configs/default.yml` (document the new key)
- Modify: `README.md` (configuration section)
- Test: `cmd/groups/authz_test.go`

**Interfaces:**
- Consumes: existing `App` struct, `actingUser(c)`, test helpers `newTestAppWith`, `doRequestAs`, `mockKeycloak`, `mockPermissions` (all in `cmd/groups/`).
- Produces: `App.adminUsers map[string]struct{}` field; `(*App).isAdminUser(user string) bool`; config key `admin.users` (list of usernames). Task 5's permissions config points its `groups.user` at an account listed here at deploy time.

- [ ] **Step 1: Write the failing tests**

Append to `cmd/groups/authz_test.go`:

```go
func TestAdminUserBypassesMemberAuthz(t *testing.T) {
	kc := &mockKeycloak{
		groupMembersFn: func(_ context.Context, id string) ([]keycloak.Subject, error) {
			assert.Equal(t, "g1", id)
			return []keycloak.Subject{{ID: "alice"}}, nil
		},
	}
	// Deny every permission check; only the admin bypass can let the request through.
	perms := &mockPermissions{
		checkFn: func(_ context.Context, _, _, _, _, _ string, _ bool) (bool, error) {
			return false, nil
		},
	}
	app := newTestAppWith(kc, perms)
	app.adminUsers = map[string]struct{}{"permissions-svc": {}}

	rec := doRequestAs(app, http.MethodGet, "/groups/g1/members", "", "permissions-svc")
	assert.Equal(t, http.StatusOK, rec.Code)
}

func TestAdminUserBypassesLevelAuthz(t *testing.T) {
	kc := &mockKeycloak{
		updateGroupFn: func(_ context.Context, id string, spec keycloak.GroupSpec) (*keycloak.Group, error) {
			return &keycloak.Group{ID: id, Name: spec.Name}, nil
		},
	}
	perms := &mockPermissions{
		checkFn: func(_ context.Context, _, _, _, _, _ string, _ bool) (bool, error) {
			return false, nil
		},
	}
	app := newTestAppWith(kc, perms)
	app.adminUsers = map[string]struct{}{"permissions-svc": {}}

	rec := doRequestAs(app, http.MethodPut, "/groups/g1", `{"name":"team-a"}`, "permissions-svc")
	assert.Equal(t, http.StatusOK, rec.Code)
}

func TestNonAdminUserStillForbidden(t *testing.T) {
	kc := &mockKeycloak{
		groupMembersFn: func(_ context.Context, _ string) ([]keycloak.Subject, error) {
			return []keycloak.Subject{{ID: "alice"}}, nil
		},
	}
	perms := &mockPermissions{
		checkFn: func(_ context.Context, _, _, _, _, _ string, _ bool) (bool, error) {
			return false, nil
		},
	}
	app := newTestAppWith(kc, perms)
	app.adminUsers = map[string]struct{}{"permissions-svc": {}}

	// "mallory" is not an admin and not a member (members list is only alice) -> 403.
	rec := doRequestAs(app, http.MethodGet, "/groups/g1/members", "", "mallory")
	assert.Equal(t, http.StatusForbidden, rec.Code)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/groups && go test ./cmd/groups/ -run 'TestAdminUser|TestNonAdminUser' -v`
Expected: compile error — `app.adminUsers undefined (type *App has no field or method adminUsers)`.

- [ ] **Step 3: Implement the App field and config parsing**

In `cmd/groups/app.go`, add the field to the `App` struct:

```go
// App ties together the HTTP API and the clients that back it.
type App struct {
	config      *koanf.Koanf
	router      *echo.Echo
	keycloak    keycloak.Client
	permissions permissions.Client
	events      eventing.Publisher
	adminUsers  map[string]struct{}
}
```

In `NewApp`, add to the `App` literal (after `events: events,`):

```go
		adminUsers:  adminUsersFromConfig(config),
```

Add the helper near `permissionsBaseURL`:

```go
// adminUsersFromConfig builds the set of trusted service accounts (admin.users)
// that bypass per-group permission checks.
func adminUsersFromConfig(config *koanf.Koanf) map[string]struct{} {
	users := config.Strings("admin.users")
	admins := make(map[string]struct{}, len(users))
	for _, user := range users {
		admins[user] = struct{}{}
	}
	return admins
}
```

- [ ] **Step 4: Implement the authz bypass**

In `cmd/groups/authz.go`, add after `actingUser`:

```go
// isAdminUser reports whether the acting user is a configured administrative
// service account (admin.users) that bypasses per-group permission checks.
func (a *App) isAdminUser(user string) bool {
	_, ok := a.adminUsers[user]
	return ok
}
```

At the top of `requireLevel` (before the `a.permissions.Check` call):

```go
	if a.isAdminUser(actingUser(c)) {
		return nil
	}
```

At the top of `requireReadOrMember` (before the `a.permissions.Check` call):

```go
	if a.isAdminUser(user) {
		return nil
	}
```

(`requireReadOrMember` already assigns `user := actingUser(c)`; place the bypass after that assignment.)

- [ ] **Step 5: Run the new tests and the full suite**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/groups && go test ./cmd/groups/ -run 'TestAdminUser|TestNonAdminUser' -v && just test`
Expected: all PASS (nil `adminUsers` map in other tests is safe — lookups on a nil map return the zero value).

- [ ] **Step 6: Document the setting**

In `configs/default.yml`, append after the `amqp:` block:

```yaml
# Trusted service accounts that bypass per-group permission checks. Intended
# for internal DE services (e.g. the permissions service) that must be able to
# read any group's membership. Leave empty to disable the bypass entirely.
admin:
  users: []
```

In `README.md`, find the configuration documentation (the section describing `keycloak.*` / `permissions.base` / `amqp.*` settings) and add, matching its existing format:

```markdown
- `admin.users` — list of trusted service account usernames that bypass
  per-group permission checks (for example, the DE permissions service).
  Default: empty.
```

- [ ] **Step 7: Lint and commit**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/groups && gofmt -l . && golangci-lint run`
Expected: no output from gofmt, no lint findings.

```bash
cd /home/johnw/work/src/github.com/cyverse-de/groups
git checkout -b admin-users
git add cmd/groups/app.go cmd/groups/authz.go cmd/groups/authz_test.go configs/default.yml README.md
git commit -m "Add admin.users service accounts that bypass group authz"
```

---

### Task 2: permissions repo — groups client scaffolding + GroupsForSubject

**Files:**
- Create: `clients/groups/groups.go`
- Test: `clients/groups/groups_test.go`

**Interfaces:**
- Consumes: `grouper.Grouper` interface and `grouper.GroupInfo` struct from `github.com/cyverse-de/permissions/clients/grouper`; `models.SubjectSourceID`, `models.ExternalSubjectID`, `models.SubjectOut`, `models.Permission` from `github.com/cyverse-de/permissions/models`. Groups service endpoint `GET /subjects/{id}/groups?user=` returning `{"groups":[{"id":"…","name":"…"}]}` (404 for unknown subject).
- Produces: `groups.NewClient(baseURI, user string) (*groups.Client, error)`; `(*groups.Client).GroupsForSubject(ctx, subjectID string) ([]*grouper.GroupInfo, error)`. Tasks 3–4 add the remaining interface methods to this same `Client`; Task 5 constructs it in `configure_permissions.go`.

- [ ] **Step 1: Write the failing tests**

Create `clients/groups/groups_test.go`:

```go
package groups

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNewClientValidation(t *testing.T) {
	tests := []struct {
		name    string
		baseURI string
		user    string
		wantErr bool
	}{
		{"valid", "http://groups", "permissions-svc", false},
		{"missing base URI", "", "permissions-svc", true},
		{"missing user", "http://groups", "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := NewClient(tt.baseURI, tt.user)
			if tt.wantErr {
				assert.Error(t, err)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}

func TestGroupsForSubject(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/subjects/alice/groups", r.URL.Path)
		assert.Equal(t, "permissions-svc", r.URL.Query().Get("user"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"groups":[{"id":"g1","name":"team-a"},{"id":"g2","name":"team-b"}]}`))
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "permissions-svc")
	require.NoError(t, err)

	groups, err := client.GroupsForSubject(context.Background(), "alice")
	require.NoError(t, err)
	require.Len(t, groups, 2)
	assert.Equal(t, "g1", groups[0].ID)
	assert.Equal(t, "team-a", groups[0].Name)
	assert.Equal(t, "g2", groups[1].ID)
	assert.Equal(t, "team-b", groups[1].Name)
}

func TestGroupsForSubjectUnknownSubject(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"message":"not found"}`, http.StatusNotFound)
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "permissions-svc")
	require.NoError(t, err)

	// The Grouper DB implementation returns an empty list for unknown
	// subjects; a 404 from the groups service must behave the same way.
	groups, err := client.GroupsForSubject(context.Background(), "nobody")
	require.NoError(t, err)
	assert.Empty(t, groups)
}

func TestGroupsForSubjectServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "permissions-svc")
	require.NoError(t, err)

	_, err = client.GroupsForSubject(context.Background(), "alice")
	assert.Error(t, err)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && go test ./clients/groups/ -v`
Expected: FAIL to build — `undefined: NewClient`.

- [ ] **Step 3: Implement the client and GroupsForSubject**

Create `clients/groups/groups.go`:

```go
// Package groups provides an implementation of the grouper.Grouper interface
// backed by the DE groups service (Keycloak) instead of the Grouper database.
package groups

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	"github.com/cyverse-de/permissions/clients/grouper"
	"github.com/cyverse-de/permissions/models"
)

// Source IDs preserved from the Grouper era: permissions API clients still
// compare subject_source_id against these values, so they are part of the wire
// contract even though Grouper itself is going away.
const (
	userSubjectSource  = models.SubjectSourceID("ldap")
	groupSubjectSource = models.SubjectSourceID("g:gsa")
)

// errNotFound marks a 404 from the groups service so callers can decide
// whether a missing entity is an error.
var errNotFound = errors.New("not found")

// Client is a groups-service-backed implementation of grouper.Grouper.
type Client struct {
	base *url.URL
	user string
	hc   *http.Client
}

// NewClient validates the settings and returns a groups service client. The
// user is the trusted service account sent to the groups service as the acting
// user; it must be listed in the groups service's admin.users setting or
// membership listings will be rejected with a 403.
func NewClient(baseURI, user string) (*Client, error) {
	if baseURI == "" {
		return nil, errors.New("the groups service base URI must be specified")
	}
	if user == "" {
		return nil, errors.New("the groups service user must be specified")
	}
	base, err := url.Parse(baseURI)
	if err != nil {
		return nil, fmt.Errorf("invalid groups service base URI: %w", err)
	}
	return &Client{
		base: base,
		user: user,
		hc:   &http.Client{Timeout: 30 * time.Second},
	}, nil
}

// get performs a GET against the groups service and decodes the JSON response
// body into out. A 404 response returns errNotFound.
func (c *Client) get(ctx context.Context, out interface{}, pathSegments ...string) error {
	requestURL := c.base.JoinPath(pathSegments...)
	query := requestURL.Query()
	query.Set("user", c.user)
	requestURL.RawQuery = query.Encode()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL.String(), nil)
	if err != nil {
		return err
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return errNotFound
	}
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("groups service returned status %d for %s: %s", resp.StatusCode, requestURL.Path, body)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// subjectGroupsResponse matches the groups service GET /subjects/{id}/groups body.
type subjectGroupsResponse struct {
	Groups []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"groups"`
}

// GroupsForSubject returns the groups the subject belongs to. An unknown
// subject yields an empty list, matching the Grouper database behavior.
func (c *Client) GroupsForSubject(ctx context.Context, subjectID string) ([]*grouper.GroupInfo, error) {
	var body subjectGroupsResponse
	if err := c.get(ctx, &body, "subjects", subjectID, "groups"); err != nil {
		if errors.Is(err, errNotFound) {
			return []*grouper.GroupInfo{}, nil
		}
		return nil, err
	}
	groups := make([]*grouper.GroupInfo, 0, len(body.Groups))
	for _, group := range body.Groups {
		groups = append(groups, &grouper.GroupInfo{ID: group.ID, Name: group.Name})
	}
	return groups, nil
}
```

(The `models` import is used by the source-ID constants; Tasks 3–4 use it further. The `var _ grouper.Grouper` compile-time assertion is added in Task 4 when the interface is fully implemented.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && go test ./clients/groups/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/johnw/work/src/github.com/cyverse-de/permissions
git checkout -b groups-backend
git add clients/groups/
git commit -m "Add groups service client with GroupsForSubject"
```

---

### Task 3: permissions repo — ListUsersInGroup

**Files:**
- Modify: `clients/groups/groups.go`
- Test: `clients/groups/groups_test.go`

**Interfaces:**
- Consumes: `(*Client).get` helper from Task 2; groups service endpoint `GET /groups/{id}/members?user=` returning `{"members":[{"id":"…","name":"…","source_id":"…"}]}` (404 for a missing group; requires the acting user to be an admin.users entry — Task 1).
- Produces: `(*Client).ListUsersInGroup(ctx, groupID models.ExternalSubjectID) ([]*models.SubjectOut, error)` — each element has only `SubjectID` and `SubjectSourceID` set (always `"ldap"`), mirroring what the Grouper DB implementation populates.

- [ ] **Step 1: Write the failing tests**

Append to `clients/groups/groups_test.go` (add `"github.com/cyverse-de/permissions/models"` to the imports):

```go
func TestListUsersInGroup(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/groups/g1/members", r.URL.Path)
		assert.Equal(t, "permissions-svc", r.URL.Query().Get("user"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"members":[{"id":"alice","name":"alice","source_id":"ldap-provider-uuid"},{"id":"bob","name":"bob"}]}`))
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "permissions-svc")
	require.NoError(t, err)

	members, err := client.ListUsersInGroup(context.Background(), models.ExternalSubjectID("g1"))
	require.NoError(t, err)
	require.Len(t, members, 2)
	assert.Equal(t, models.ExternalSubjectID("alice"), *members[0].SubjectID)
	assert.Equal(t, models.ExternalSubjectID("bob"), *members[1].SubjectID)
	// Group membership is flat, so every member is a user, and the legacy
	// "ldap" source is reported regardless of the Keycloak source_id value.
	assert.Equal(t, models.SubjectSourceID("ldap"), *members[0].SubjectSourceID)
	assert.Equal(t, models.SubjectSourceID("ldap"), *members[1].SubjectSourceID)
}

func TestListUsersInGroupMissingGroup(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, `{"message":"not found"}`, http.StatusNotFound)
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "permissions-svc")
	require.NoError(t, err)

	// The Grouper DB implementation returns an empty list for a group it
	// cannot find (e.g. one deleted after a permission was granted).
	members, err := client.ListUsersInGroup(context.Background(), models.ExternalSubjectID("gone"))
	require.NoError(t, err)
	assert.Empty(t, members)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && go test ./clients/groups/ -v`
Expected: FAIL to build — `client.ListUsersInGroup undefined`.

- [ ] **Step 3: Implement ListUsersInGroup**

Append to `clients/groups/groups.go`:

```go
// membersResponse matches the groups service GET /groups/{id}/members body.
type membersResponse struct {
	Members []struct {
		ID string `json:"id"`
	} `json:"members"`
}

// ListUsersInGroup returns the users belonging to a group. Group membership is
// flat (groups never contain groups), so every member is a user and the legacy
// "ldap" source ID is reported to preserve the wire contract. A missing group
// yields an empty list, matching the Grouper database behavior for groups that
// were deleted after a permission was granted to them.
func (c *Client) ListUsersInGroup(
	ctx context.Context,
	groupID models.ExternalSubjectID,
) ([]*models.SubjectOut, error) {
	var body membersResponse
	if err := c.get(ctx, &body, "groups", string(groupID), "members"); err != nil {
		if errors.Is(err, errNotFound) {
			return []*models.SubjectOut{}, nil
		}
		return nil, err
	}
	members := make([]*models.SubjectOut, 0, len(body.Members))
	for _, member := range body.Members {
		id := models.ExternalSubjectID(member.ID)
		source := userSubjectSource
		members = append(members, &models.SubjectOut{SubjectID: &id, SubjectSourceID: &source})
	}
	return members, nil
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && go test ./clients/groups/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /home/johnw/work/src/github.com/cyverse-de/permissions
git add clients/groups/
git commit -m "Add ListUsersInGroup to the groups service client"
```

---

### Task 4: permissions repo — source-ID derivation and interface completion

**Files:**
- Modify: `clients/groups/groups.go`
- Test: `clients/groups/groups_test.go`

**Interfaces:**
- Consumes: `models.Permission` (its `Subject *models.SubjectOut` always has `SubjectType` populated by the DB layer — see `restapi/impl/db/permission_dto.go:26`); `models.SubjectTypeUser` / `models.SubjectTypeGroup` constants; `grouper.Grouper` interface.
- Produces: `(*Client).IsGroupSource(models.SubjectSourceID) bool`, `(*Client).AddSourceIDToPermissions(ctx, []*models.Permission) error`, `(*Client).AddSourceIDToPermission(ctx, *models.Permission) error`; compile-time assertion `var _ grouper.Grouper = (*Client)(nil)`. After this task the Client satisfies the full interface Task 5 wires in.

- [ ] **Step 1: Write the failing tests**

Append to `clients/groups/groups_test.go`:

```go
func subjectTypePtr(t models.SubjectType) *models.SubjectType { return &t }

func permissionWithSubjectType(subjectID string, st *models.SubjectType) *models.Permission {
	id := models.ExternalSubjectID(subjectID)
	return &models.Permission{Subject: &models.SubjectOut{SubjectID: &id, SubjectType: st}}
}

func TestAddSourceIDToPermissions(t *testing.T) {
	client, err := NewClient("http://groups", "permissions-svc")
	require.NoError(t, err)

	tests := []struct {
		name       string
		perm       *models.Permission
		wantSource models.SubjectSourceID
	}{
		{"user subject", permissionWithSubjectType("alice", subjectTypePtr(models.SubjectTypeUser)), "ldap"},
		{"group subject", permissionWithSubjectType("g1", subjectTypePtr(models.SubjectTypeGroup)), "g:gsa"},
		{"missing subject type defaults to user", permissionWithSubjectType("bob", nil), "ldap"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			require.NoError(t, client.AddSourceIDToPermissions(context.Background(), []*models.Permission{tt.perm}))
			require.NotNil(t, tt.perm.Subject.SubjectSourceID)
			assert.Equal(t, tt.wantSource, *tt.perm.Subject.SubjectSourceID)
		})
	}
}

func TestAddSourceIDToPermission(t *testing.T) {
	client, err := NewClient("http://groups", "permissions-svc")
	require.NoError(t, err)

	perm := permissionWithSubjectType("g1", subjectTypePtr(models.SubjectTypeGroup))
	require.NoError(t, client.AddSourceIDToPermission(context.Background(), perm))
	assert.Equal(t, models.SubjectSourceID("g:gsa"), *perm.Subject.SubjectSourceID)
}

func TestIsGroupSource(t *testing.T) {
	client, err := NewClient("http://groups", "permissions-svc")
	require.NoError(t, err)

	assert.True(t, client.IsGroupSource(models.SubjectSourceID("g:gsa")))
	assert.False(t, client.IsGroupSource(models.SubjectSourceID("ldap")))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && go test ./clients/groups/ -v`
Expected: FAIL to build — `client.AddSourceIDToPermissions undefined`.

- [ ] **Step 3: Implement the remaining interface methods**

Append to `clients/groups/groups.go`:

```go
// Compile-time check that the full grouper.Grouper interface is implemented.
var _ grouper.Grouper = (*Client)(nil)

// IsGroupSource returns true if the given source ID marks a group subject.
func (c *Client) IsGroupSource(sourceID models.SubjectSourceID) bool {
	return sourceID == groupSubjectSource
}

// AddSourceIDToPermissions derives each subject's source ID from the subject
// type already stored in the permissions database, so no external lookup is
// needed. Subjects without a type are treated as users; that only happens for
// permissions built outside the DB layer, which always populates the type.
func (c *Client) AddSourceIDToPermissions(_ context.Context, permissions []*models.Permission) error {
	for _, permission := range permissions {
		source := userSubjectSource
		if permission.Subject.SubjectType != nil && *permission.Subject.SubjectType == models.SubjectTypeGroup {
			source = groupSubjectSource
		}
		permission.Subject.SubjectSourceID = &source
	}
	return nil
}

// AddSourceIDToPermission derives the subject's source ID from its subject type.
func (c *Client) AddSourceIDToPermission(ctx context.Context, permission *models.Permission) error {
	return c.AddSourceIDToPermissions(ctx, []*models.Permission{permission})
}
```

- [ ] **Step 4: Run the package tests**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && go test ./clients/groups/ -v`
Expected: PASS, including the compile-time interface assertion.

- [ ] **Step 5: Commit**

```bash
cd /home/johnw/work/src/github.com/cyverse-de/permissions
git add clients/groups/
git commit -m "Complete the grouper.Grouper interface in the groups client"
```

---

### Task 5: permissions repo — config toggle and wiring

**Files:**
- Modify: `restapi/configure_permissions.go` (DefaultConfig ~line 47; `var grouperClient` ~line 85; client construction ~lines 124-129)
- Modify: `README.md` (configuration documentation)

**Interfaces:**
- Consumes: `groups.NewClient(baseURI, user string)` from Task 2; `grouper.NewGrouperClient(dbURI, prefix)` (existing); `grouper.Grouper` interface.
- Produces: config keys `groups.enabled` (bool, default `false`), `groups.base_uri`, `groups.user`. When `groups.enabled` is true the service never connects to the Grouper database.

- [ ] **Step 1: Update the default configuration**

In `restapi/configure_permissions.go`, extend `DefaultConfig`:

```go
// DefaultConfig contains the default permissions configuration.
const DefaultConfig = `
db:
  uri: "postgresql://de:notprod@dedb:5432/de?sslmode=disable"
  schema: "permissions"

grouperdb:
  uri: "postgresql://de:notprod@adedb:5432/grouper?sslmode=disable"
  folder_name_prefix: "iplant:de:docker-compose"

groups:
  enabled: false
  base_uri: "http://groups"
  user: "permissions-svc"
`
```

- [ ] **Step 2: Switch the client variable to the interface type**

Change line 85 from:

```go
var grouperClient *grouper.Client
```

to:

```go
var grouperClient grouper.Grouper
```

- [ ] **Step 3: Select the backend from configuration**

Add `groupsclient "github.com/cyverse-de/permissions/clients/groups"` to the imports of `restapi/configure_permissions.go`, then replace the client construction (currently lines 124-129):

```go
	if cfg.GetBool("groups.enabled") {
		grouperClient, err = groupsclient.NewClient(cfg.GetString("groups.base_uri"), cfg.GetString("groups.user"))
		if err != nil {
			return err
		}
	} else {
		grouperDburi := cfg.GetString("grouperdb.uri")
		grouperFolderNamePrefix := cfg.GetString("grouperdb.folder_name_prefix")
		grouperClient, err = grouper.NewGrouperClient(grouperDburi, grouperFolderNamePrefix)
		if err != nil {
			return err
		}
	}
```

(`groups.NewClient` fails fast on a missing base URI or user, satisfying validate-config-at-startup. When `groups.enabled` is true, no Grouper DB connection is opened at all.)

- [ ] **Step 4: Build and run the full test suite**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && go build ./... && go test ./...`
Expected: build succeeds, all tests PASS (existing handler tests use the `grouper.Grouper` interface via mocks, so the variable type change is transparent).

- [ ] **Step 5: Document the settings**

In the permissions repo `README.md`, find the configuration documentation (the section covering `db.*` and `grouperdb.*`) and add, matching its existing format:

```markdown
- `groups.enabled` — when true, group memberships are resolved through the DE
  groups service instead of the Grouper database. Default: `false`.
- `groups.base_uri` — base URL of the groups service. Only used when
  `groups.enabled` is true.
- `groups.user` — service account username sent to the groups service as the
  acting user. It must be listed in the groups service's `admin.users`
  setting. Only used when `groups.enabled` is true.
```

If the README has no configuration section, add these lines under a new `## Configuration` heading instead.

- [ ] **Step 6: Lint and commit**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && gofmt -l . | grep -v '^models/\|^restapi/operations/' ; golangci-lint run`
Expected: no gofmt output for hand-maintained files, no new lint findings. (Check `.github/workflows/` for a pinned golangci-lint version and use that binary if it differs from the local one.)

```bash
cd /home/johnw/work/src/github.com/cyverse-de/permissions
git add restapi/configure_permissions.go README.md
git commit -m "Add groups.enabled toggle to back memberships with the groups service"
```

---

### Task 6: final verification across both repos

**Files:** none modified — verification only.

- [ ] **Step 1: Full test suites**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/groups && just test`
Expected: PASS.

Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && go test ./...`
Expected: PASS.

- [ ] **Step 2: Lint both repos**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/groups && golangci-lint run`
Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && golangci-lint run`
Expected: no new findings in either repo.

- [ ] **Step 3: Confirm the groups service API surface is unchanged**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/groups && git diff main --stat`
Expected: no changes under `docs/` (Swagger untouched) and no changes to `registerRoutes` in `cmd/groups/app.go`.

- [ ] **Step 4: Review the diffs**

Run: `cd /home/johnw/work/src/github.com/cyverse-de/groups && git log main..HEAD --oneline && git diff main`
Run: `cd /home/johnw/work/src/github.com/cyverse-de/permissions && git log main..HEAD --oneline && git diff main`
Confirm: only the files named in Tasks 1-5 changed; no generated files modified in the permissions repo.
