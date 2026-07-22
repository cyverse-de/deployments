# Certificate Management

This page covers the TLS certificates used by the DE, how they are issued and renewed, and
what to do when a certificate has expired or is about to expire.

---

## Certificate inventory

The DE uses certificates in several places. In the CyVerse production deployment,
HAProxy terminates TLS for external traffic using a certificate from an external CA,
then connects to Traefik internally with `verify none`. Other deployments may expose
Traefik directly, in which case the cert-manager certificates become user-facing.

| Certificate | Namespace | How issued | What breaks if it expires |
|---|---|---|---|
| HAProxy external cert | host filesystem (`/etc/ssl/cyverse.combined`) | External CA (manual renewal) | All external HTTPS access fails |
| DE UI internal (`de_hostname`) | `prod` | cert-manager (Let's Encrypt or self-signed CA) | Traefik cannot serve the DE; breaks if no HAProxy in front |
| VICE wildcard (`*.vice_base_domain`) | `prod` | cert-manager (Let's Encrypt or self-signed CA) | VICE apps inaccessible if Traefik is directly exposed |
| User portal (`portal_hostname`) | `prod` | cert-manager (same issuer as DE UI) | User portal inaccessible if directly exposed |
| Keycloak TLS (`keycloak_hostname`) | `keycloak` | cert-manager (Let's Encrypt or self-signed CA) | Auth fails for all services |
| Traefik default TLS | `traefik` | cert-manager self-signed CA (always) | Internal routing breaks |
| NATS client/server TLS | `prod` | cert-manager self-signed CA (always) | Services using NATS fail to connect |
| portal-conductor SSL | `prod` | cert-manager self-signed (always) | portal-conductor internal comms break |

The `cert_manager_provider` inventory variable (derived from `cert_manager_use_letsencrypt`)
controls the issuer for the DE UI, VICE, portal, and Keycloak certificates. Internal-only
certificates (Traefik, NATS, portal-conductor) are always self-signed regardless of this
setting.

In deployments where HAProxy terminates TLS (like CyVerse production), the cert-manager
certificates for the DE UI and VICE are not directly user-facing — HAProxy presents its
own externally-issued certificate. The internal certs still need to be valid for Traefik
to serve traffic, but browsers never see them.

Most certificates managed by cert-manager renew **automatically** when they approach the
configured `renewBefore` threshold (default: 10 days before expiry). Automatic renewal
requires that cert-manager is running and that the issuer can reach its backend (Route 53
for Let's Encrypt, or no external dependency for self-signed).

---

## Prerequisites

```bash
export KUBECONFIG=~/.kube/prod.conf
export NS=prod
```

---

## 1. Checking certificate status

### All cert-manager Certificates in the DE namespace

```bash
kubectl -n $NS get certificates
```

Output columns:
- `READY`: `True` = valid and current; `False` = expired, renewal in progress, or issuance failed
- `SECRET`: the Kubernetes Secret holding the cert
- `AGE`: how long since the Certificate object was created (not cert expiry)

For expiry details:

```bash
kubectl -n $NS get certificates -o custom-columns=\
'NAME:.metadata.name,READY:.status.conditions[0].status,EXPIRY:.status.notAfter'
```

### Check a specific certificate

```bash
kubectl -n $NS describe certificate <name>
```

Look at the `Status.Conditions` section. If `Ready` is `False`, the `Message` field explains why.

> **Note:** Most certificates are in `$NS`, but Keycloak certificates are in the `keycloak`
> namespace. Use `kubectl -n keycloak get certificates` for those. NATS certificates are
> named `nats-client-tls` and `nats-server-tls` in `$NS`.

### Decode the actual certificate to see expiry

```bash
# Get the secret name from the Certificate object
SECRET=$(kubectl -n $NS get certificate <cert-name> -o jsonpath='{.spec.secretName}')

# Decode and check expiry
kubectl -n $NS get secret $SECRET -o jsonpath='{.data.tls\.crt}' | \
  base64 -d | openssl x509 -noout -text | grep -A2 "Validity"
```

---

## 2. Forcing manual renewal of a cert-manager certificate

cert-manager will not renew a certificate that is still within its validity period unless you
force it. To trigger immediate renewal:

```bash
# Delete the Secret — cert-manager will notice and reissue immediately
kubectl -n $NS delete secret <secret-name>

# Or, if you have cert-manager's cmctl installed:
cmctl renew -n $NS <certificate-name>
```

Watch the renewal:

```bash
kubectl -n $NS get certificate <cert-name> -w
# Wait for READY to become True
```

cert-manager events for the certificate will show the renewal progress:

```bash
kubectl -n $NS describe certificate <cert-name> | tail -20
```

---

## 3. Let's Encrypt certificates (cert_manager_use_letsencrypt: true)

When `cert_manager_use_letsencrypt` is enabled, the `letsencrypt` ClusterIssuer is used. It
performs DNS-01 challenges via Route 53.

### Verify the ClusterIssuer is healthy

```bash
kubectl get clusterissuer letsencrypt
kubectl describe clusterissuer letsencrypt
```

The `Status.Conditions[0].Type` should be `Ready` with `Status: True`. If not, the most
common causes are:
- The Route 53 IAM credentials in the `cert-manager-letsencrypt-aws-creds` Secret are invalid
  or expired.
- The hosted zone ID or region is wrong.

### Verify Route 53 credentials

```bash
kubectl -n cert-manager get secret cert-manager-letsencrypt-aws-creds -o yaml
```

Decode the values and verify they are valid AWS access key/secret key. If the keys have been
rotated in AWS IAM, update the Secret and delete any failed `CertificateRequest` objects to
restart issuance:

```bash
kubectl -n $NS delete certificaterequest --all   # only if all are failed; verify first
```

### Check cert-manager logs for ACME errors

```bash
kubectl -n cert-manager logs -l app=cert-manager --since=1h | grep -i "error\|acme\|route53"
```

---

## 4. Self-signed certificates (alternative option)

Some deployments use self-signed CAs managed by cert-manager. The CA certificates
themselves are also managed as cert-manager `Certificate` objects (e.g., `selfsigned-ca` in
the DE namespace for NATS, `kc-selfsigned-ca` in the keycloak namespace) and have a 1-year
validity (`8766h`).

### Check the CA certificates

```bash
kubectl -n $NS get certificate | grep -i "ca"
kubectl -n keycloak get certificate | grep -i "ca"
```

If a CA certificate expires, all leaf certificates signed by it also become invalid. Renewing
the CA is the same process as renewing any other cert-manager Certificate (delete the Secret),
but after CA renewal you must also force-renew all leaf certificates signed by that CA:

```bash
# After renewing the CA, force-renew all certs in the namespace
for cert in $(kubectl -n $NS get certificates -o name); do
  SECRET=$(kubectl -n $NS get $cert -o jsonpath='{.spec.secretName}')
  kubectl -n $NS delete secret $SECRET
done
```

This is disruptive — all services will briefly lose their certs while cert-manager reissues.
Schedule this during a maintenance window.

---

## 5. HAProxy combined certificate (bare-metal deployments)

For deployments where the external entry point is HAProxy (not Traefik behind an AWS ALB),
the combined certificate is managed outside Kubernetes and copied to hosts in the
`[de_proxy]` inventory group via the `tls_certs_main.yml` playbook.

### Check when the current certificate expires

```bash
# On the HAProxy host
openssl x509 -enddate -noout -in /etc/ssl/cyverse.combined
```

### Update the combined certificate

1. Obtain the new certificate files (PEM-formatted cert chain + private key).
2. Combine them into a single file if they are separate:
   ```bash
   cat fullchain.pem privkey.pem > cyverse.combined
   ```
3. Run the deployment playbook (the `combined_cert_src` variable defaults to
   `/etc/ssl/cyverse.combined` but should be passed explicitly):
   ```bash
   ansible-playbook \
     -i /path/to/inventory \
     -e combined_cert_src=/path/to/cyverse.combined \
     -K \
     tls_certs_main.yml
   ```
4. Reload HAProxy on the proxy host:
   ```bash
   ansible de_proxy -i /path/to/inventory -K --become -m service \
     -a "name=haproxy state=reloaded"
   ```

---

## 6. NATS TLS certificates

NATS uses its own client and server TLS certificates. These are cert-manager-managed
self-signed certificates. To extract them for debugging or out-of-cluster use, see
[nats.md](nats.md).

If the NATS certificates expire, services that connect to NATS (subscriptions, terrain,
app-exposer, jex-adapter, discoenv-analyses, data-usage-api,
resource-usage-api) will fail to connect. Symptoms: services log TLS
handshake errors; NATS-dependent operations silently fail.

To renew:

```bash
kubectl -n $NS delete secret nats-client-tls nats-server-tls
# cert-manager will reissue; watch progress:
kubectl -n $NS get certificate | grep nats -w
```

After renewal, restart all NATS-connected services so they pick up the new certificates:

```bash
kubectl -n $NS rollout restart \
  deployment/app-exposer \
  deployment/data-usage-api \
  deployment/discoenv-analyses \
  deployment/jex-adapter \
  deployment/resource-usage-api \
  deployment/subscriptions \
  deployment/terrain
```

---

## 7. What to do when a certificate has already expired

If a cert expired and services are already failing:

1. **Identify which cert:** Check all certificates (step 1 above). The `READY=False` cert is
   the culprit.
2. **Force immediate renewal:** Delete the Secret backing the expired cert (step 2 above).
3. **Restart affected services:** Services cache their TLS config at startup. A rollout
   restart is needed after the new cert is issued.
4. **Verify:** Decode the new cert (step 1) and confirm the `Not After` date is in the future.

For HAProxy-managed external certs, follow step 5.

---

## 8. cert-manager is not renewing automatically

If a cert is approaching expiry and cert-manager is not renewing it automatically:

```bash
# Check cert-manager itself is running
kubectl -n cert-manager get pods

# Check for controller errors
kubectl -n cert-manager logs -l app=cert-manager --since=2h | grep -i error

# Check the Certificate object for a stale status
kubectl -n $NS describe certificate <name>
```

The most common cause is that cert-manager is running but the `CertificateRequest` is stuck.
Describe the request to find the error:

```bash
kubectl -n $NS get certificaterequests
kubectl -n $NS describe certificaterequest <name>
```

If the request is stuck in a failed state, delete it — cert-manager will create a new one:

```bash
kubectl -n $NS delete certificaterequest <name>
```
