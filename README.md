# minio

Helm chart `minio`: one MinIO Tenant for the MinIO Operator.

## Purpose

One Helm release makes one MinIO `Tenant` and everything that belongs to it:

- The `Tenant`, from the upstream MinIO tenant chart templates, with names, domains, TLS and pool settings calculated from a small set of values.
- One `InfisicalStaticSecret` that writes the Tenant config Secret (`config.env`) from Infisical. The target uses `creationPolicy: Orphan`: the Secret has no owner, so deleting the `InfisicalStaticSecret` never deletes it.
- A cert-manager `Certificate` for the MinIO services, from the internal CA.
- One Traefik `IngressRoute` per host: one for the console, and one for each S3 API host.

The chart does not install the MinIO Operator (see DEVSECOPS-185). It is published to GHCR (`oci://ghcr.io/raulstechtips/charts/minio`), and not to Harbor, because Harbor stores its registry data in MinIO.

## Upstream templates

MinIO stopped the community edition (maintenance mode on 2025-12-03, archived in 2026). The tenant chart `7.1.1` is the last release. This chart has no upstream dependency. It has a copy of all the templates of `minio/tenant` `7.1.1` (chart archive sha256 `931dfbbf19871ffd687b4eca1ed23b977928b52fc9710bb3250cb381716fc0ea`), and the upstream values layout (`tenant`, `ingress`, `extraResources`) with the upstream comments.

The copy has these changes. Each one is marked `raulstechtips:` in the file.

In `templates/tenant.yaml`. Each edit uses the upstream value first, and calculates only when that value is empty:

| Field | Calculated value |
| --- | --- |
| `spec.configuration.name` | `tenant.configSecret.name`, else `<tenant.name>-minio-env-configuration` |
| `spec.externalCertSecret` | `tenant.certificate.externalCertSecret`, else the chart certificate (`<tenant.name>-minio-tls`) and then each name in `tls.externalCertSecrets` |
| `spec.features.domains` | `tenant.features.domains`, else `console: https://<ingressRoute.console.host>` and `minio: [https://<first ingressRoute.api.hosts host>]` |
| `spec.pools[].affinity` | The pool `affinity`, else a required pod anti-affinity on `kubernetes.io/hostname` for the pods with `v1.min.io/tenant: <tenant.name>` (the label that the operator puts on every Tenant pod) |
| `spec.pools[].resources`, `securityContext`, `containerSecurityContext` | The pool value, else `poolDefaults` |

In `values.yaml`, these defaults are different from upstream:

| Value | Upstream | This chart |
| --- | --- | --- |
| `tenant.name` | `myminio` | `minio` |
| `tenant.image.repository` | `quay.io/minio/minio` | `ghcr.io/raulstechtips/minio` (our mirror, same tag) |
| `tenant.configSecret` | name `myminio-env-configuration`, `accessKey: minio`, `secretKey: minio123` | `existingSecret: true`, no credentials, empty name (calculated) |
| `tenant.certificate.requestAutoCert` | `true` | `false` (cert-manager issues the certificate) |
| `tenant.features.enableSFTP` | `false` | `true` (as the live tenant; DEVSECOPS-182 reviews it) |

The other upstream templates (`api-ingress.yaml`, `console-ingress.yaml`, `tenant-configuration.yaml`, `kes-configuration-secret.yaml`, `extra-resources.yaml`, `checks.yaml`, `_helpers.tpl`) are not changed. With the chart defaults they render no object. The chart uses Traefik `IngressRoute` objects, not the upstream `Ingress` objects.

## Values of this chart

| Value | Default | Purpose |
| --- | --- | --- |
| `infisical.authRef` | `infisical-prod-universal-auth` in `default` | The `InfisicalAuth` to use |
| `infisical.projectSlug`, `environmentSlug` | `k3s-ntpo`, `prod` | The Infisical project and environment |
| `infisical.secretPath`, `recursive` | `/minio`, `true` | The folder with the keys below |
| `infisical.refreshInterval` | `1m` | How often the operator reads Infisical |
| `oidc.enabled` | `false` | Keycloak login for the console |
| `oidc.configUrl` | `""` | The realm discovery URL. Required when `oidc.enabled` is true |
| `oidc.scopes`, `redirectUriDynamic`, `displayName` | `openid,profile,email`, `on`, `Keycloak` | Other OIDC settings |
| `tls.enabled` | `true` | Make the cert-manager `Certificate` |
| `tls.issuerRef` | `raulstechtips-internal-ca-issuer` (`ClusterIssuer`) | The issuer |
| `tls.organization` | `raulstechtips` | The certificate subject organization |
| `tls.externalCertSecrets` | `[]` | More TLS Secret names for MinIO (for example a public wildcard) |
| `ingressRoute.enabled` | `false` | Make the IngressRoutes |
| `ingressRoute.entryPoints`, `ingressClass` | `[websecure]`, `traefik-external` | Defaults for each host |
| `ingressRoute.middlewares`, `tlsSecretName` | `[]`, `""` | Defaults for each host |
| `ingressRoute.console.host` | `""` | The console host (object `minio-ingress-console`). Empty: no console route |
| `ingressRoute.api.hosts` | `[]` | The S3 API hosts. Each entry: `name` (object `minio-ingress-api-<name>`), `host`, and optional `entryPoints`, `ingressClass`, `middlewares`, `tlsSecretName` |
| `poolDefaults` | live resources, upstream security contexts | Defaults for each entry in `tenant.pools` |

The config Secret gets these keys from Infisical: `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`, and with `oidc.enabled` also `MINIO_IDENTITY_OPENID_CLIENT_ID` and `MINIO_IDENTITY_OPENID_CLIENT_SECRET`. The other `config.env` lines come from values. MinIO reads `config.env` only when it starts.

Only the **first** API host is a Tenant domain. MinIO uses it as `MINIO_SERVER_URL` (console S3 calls, OIDC login, Share links). The other hosts only get an IngressRoute; path-style S3 requests work on any host. To change the first host, see the note in DEVSECOPS-181 (it needs a planned MinIO restart).

## Use it from Argo CD

```yaml
spec:
  sources:
    - repoURL: ghcr.io/raulstechtips/charts
      chart: minio
      targetRevision: <chart version>
      helm:
        releaseName: tenant-s3
        valueFiles:
          - $values/apps/dev/minio.yaml
  destination:
    namespace: minio
```

A minimal values file:

```yaml
tenant:
  name: tenant-s3            # never change it: the PVC names come from it
  pools:
    - name: pool-0
      servers: 3
      volumesPerServer: 2
      size: 75Gi
      storageClassName: longhorn-storage-class-local
oidc:
  enabled: true
  configUrl: https://keycloak.example.com/realms/example/.well-known/openid-configuration
ingressRoute:
  enabled: true
  tlsSecretName: example-tls
  console:
    host: s3.example.com
  api:
    hosts:
      - name: prod
        host: s3-api.example.com
```

`tenant.pools` is a list, so a values file replaces the whole default list. Set the pool fields that differ; `poolDefaults` fills `resources` and both security contexts. Do not change a pool `name`, `servers` or `volumesPerServer` after the first install.

## Before first install

These must already exist. The chart reads them, but never creates them:

- The MinIO Operator and its CRDs.
- The `InfisicalAuth` in `infisical.authRef`, and the keys above in Infisical at `infisical.secretPath`.
- The cert-manager issuer in `tls.issuerRef`.
- Each TLS Secret in `tls.externalCertSecrets` and in the IngressRoute settings, in the release namespace.
- The storage class of each pool.

## Managed by hand

The chart does not manage the data inside MinIO. Make and change these in the MinIO console:

- Buckets, versioning, anonymous (public) access, quotas and lifecycle rules.
- Users, policies and access keys (see DEVSECOPS-186).

`tenant.buckets` and `tenant.users` are still upstream values, but this chart leaves them empty. The operator creates the listed buckets and users, and never deletes them.

## CI

`Jenkinsfile` runs `clusterConfigurablePipeline()` from the shared library with `project-pipeline-config.yaml`:

- `helm lint --strict` with the default values and with `charts/ci/all-on-values.yaml` (every feature on, dummy values).
- `helm unittest` (`charts/tests/`).
- `kubeconform -strict` with the Datree CRD schemas.
- Trivy and opengrep scans, then the chart is published to GHCR.
- On `main`, `argo-deploy` opens a PR in `cluster-config` that sets the new version in `argo/dev/minio.yaml`.

Run the checks on your computer:

```bash
helm lint --strict charts
helm lint --strict charts -f charts/ci/all-on-values.yaml
helm unittest charts
```
