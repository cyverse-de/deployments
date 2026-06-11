de-slapd
========

Installs the OpenLDAP Server for the CyVerse Discovery Environment

Role Variables
--------------

| Variable             | Description                                          | Default           |
| -------------------- | ---------------------------------------------------- | ----------------- |
| dn_suffix            | The suffix to use for DNs in the LDAP directory.     | dc=cyverse,dc=org |
| root_password        | The password to use for the manager account.         | notprod           |
| de_grouper_password  | The password to use for the `de_grouper` account.    | notprod           |
| ldap_reader_password | The password to use for the `ldap_reader` account.   | notprod           |

Use of the default role variable values is not recommended for production systems.

Example Playbook
----------------

``` yaml
- hosts: ldap
  roles:
     - role: de-slapd
       vars:
         dn_suffix: dc=example,dc=org
         root_password: notreal
         de_grouper_password: notreal
         ldap_reader_password: notreal
```

License
-------

BSD - https://www.cyverse.org/license
