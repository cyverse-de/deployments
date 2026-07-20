---
type: Service
title: OpenLDAP
description: How OpenLDAP is installed for the DE by the ldap_slapd.yml playbook, and the base entities, groups, and service accounts it defines.
resource: /docs/ldap.md
tags: [ldap, openldap, authentication]
timestamp: 2026-07-20T00:00:00Z
---

The `ldap_slapd.yml` playbook installs OpenLDAP for the Discovery Environment (DE). This step can be skipped if an
existing LDAP service will be used. Note: as of this writing, the DE has only been used with an OpenLDAP instance
using an RFC 2307 schema.

## Playbooks

### ldap_slapd.yml

This playbook installs OpenLDAP itself. This is the only playbook required for this installation step. After
installing OpenLDAP itself, this playbook installs the RFC 2307 schema and defines the following entities:

| Entity      | Entity Type | Description                                                                  |
| ------      | ----------- | -----------                                                                  |
| Base Domain | Domain      | This is the base for all of the other domains, and the name is configurable. |
| People      | Domain      | This is the base entity for all DE users.                                    |
| Groups      | Domain      | This is the base entity for some groups of users.                            |
| everyone    | Group       | This is the group containing all DE users.                                   |
| de_admins   | Group       | Members of this group will have administrative privileges in the DE.         |
| de_grouper  | User        | This is an account used by DE services to access Grouper.                    |
| ldap_reader | User        | This is the account used by Grouper and Keycloak to access LDAP.             |

## Inventory Setup

The inventory for this playbook contains only the LDAP node itself:

```
[ldap]
ldap.example.org
```

## Group Variable Setup

This playbook requires a few group variables:

| Variable                  | Description                                                |
| --------                  | -----------                                                |
| ldap.dn_suffix            | This is the name of the base domain in the LDAP directory. |
| ldap.root_password        | This is the password of the LDAP administrative account.   |
| ldap.de_grouper_password  | This is the password of the `de_grouper` account.          |
| ldap.ldap_reader_password | This is the password of the `ldap_reader` account.         |

Example group variables file:

``` yaml
ldap:
  dn_suffix: "dc=example,dc=org"
  root_password: "some-password"
  de_grouper_password: "some-other-password"
  ldap_reader_password: "yet-another-password"
```

## LDAP Admin Account

The name of the administrative account is determined by the domain name (`ldap.dn_suffix`). For example, if the domain
name is `dc=example,dc=org`, then the manager account is `cn=Manager,dc=example,dc=org`.

## Installing LDAP

This installation involves merely running the playbook:

```
$ ansible-playbook -i /path/to/inventory -K ldap_slapd.yml
```

# Citations

[1] `docs/ldap.md` — source document for this page.
[2] `ansible/ldap_slapd.yml` — the playbook described here.
