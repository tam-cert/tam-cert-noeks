# tam-cert-noeks

Terraform + Ansible automation to deploy a production-ready Kubernetes cluster on AWS with Teleport Enterprise 18.7.1, PostgreSQL backend, Okta SAML SSO, ArgoCD GitOps, Teleport Access Graph, and AI-powered session summaries. All infrastructure is provisioned via Terraform, cluster bootstrapping runs via cloud-init on the master node, Teleport RBAC is managed via ArgoCD GitOps, and secrets are handled without any static credentials.

---

## Architecture

```
Internet
    │
    ▼
AWS NLB (grant-tam-teleport.gvteleport.com)
    │  port 443 → NodePort 32443
    ▼
Kubernetes Nodes (t3.medium × 3, us-west-2a)
  ├── master  172.49.20.230   control-plane + Ansible runner
  ├── worker1 172.49.20.231   K8s worker
  └── worker2 172.49.20.232   K8s worker
        │
        ├── Namespace: postgres
        │     └── PostgreSQL 17 (wal2json)
        │           ├── mTLS cert auth for teleport user
        │           └── scram-sha-256 for access_graph_user
        │
        ├── Namespace: teleport
        │     ├── teleport-auth     — PostgreSQL backend, S3 sessions
        │     └── teleport-proxy    — NodePort 32443, Let's Encrypt prod cert
        │
        ├── Namespace: teleport-access-graph
        │     └── Access Graph 1.29.6 — connected to PostgreSQL, self-signed TLS
        │
        └── Namespace: argocd
              └── ArgoCD — GitOps controller for Teleport RBAC
                    └── Application: teleport-rbac
                          └── PostSync Job: tctl create -f each RBAC resource

ssh-node-1 (t2.small, private IP varies)
  └── Teleport SSH node, AWS IAM join, BPF enhanced session recording
      team=okta-teleport-users label, cgroup2 mount for BPF
```

---

## Repository Structure

```
tam-cert-noeks/
├── .github/
│   ├── DEPLOY.md                       # Quick deploy reference
│   └── workflows/terraform.yml         # plan + apply + destroy pipeline
├── helm/
│   ├── teleport-values.yaml            # Base Teleport Helm values (reference only)
│   └── postgres/                       # In-cluster PostgreSQL K8s manifests
├── terraform/
│   ├── main.tf                         # EC2, VPC, IAM, cloud-init, .teleport-env
│   ├── rds.tf                          # S3 sessions bucket + IAM policy
│   ├── nlb.tf                          # AWS NLB → NodePort 32443
│   ├── route53.tf                      # DNS CNAME records
│   ├── teleport-oidc.tf                # AWS OIDC IAM resources
│   ├── ssh-node.tf                     # ssh-node-1 EC2 + IAM instance profile
│   ├── backend.tf                      # S3 remote state (deploy trigger comment)
│   └── scripts/
│       └── ssh-node-userdata.sh        # cloud-init: Teleport install + BPF config
├── argocd/
│   └── apps/
│       ├── teleport-rbac-app.yaml      # ArgoCD Application resource
│       └── teleport-rbac/
│           ├── rbac-configmap.yaml     # All RBAC YAMLs inlined as ConfigMap data
│           ├── rbac-sync-job.yaml      # PostSync Job: tctl create -f each file
│           ├── rbac-syncer-rbac.yaml   # ServiceAccount + ClusterRole for job
│           └── resources/             # Teleport-native YAMLs (excluded from ArgoCD sync)
│               ├── login-rule-okta-team.yaml
│               ├── role-base.yaml
│               ├── role-auto-approver.yaml
│               ├── role-okta-base.yaml
│               ├── role-okta-kube.yaml
│               ├── role-okta-ssh.yaml
│               ├── role-okta-ssh-root.yaml
│               ├── role-okta-reviewer.yaml
│               ├── role-mcp-ollama-tools.yaml
│               ├── access-monitoring-rule-okta-ssh.yaml
│               ├── inference-model.yaml
│               ├── inference-policy.yaml
│               ├── cluster-auth-preference.yaml
│               └── kube-cluster-label.yaml
└── ansible/
    ├── site.yaml                       # Master playbook (steps 1-11)
    └── roles/
        ├── k8s-setup/                  # containerd, kubeadm, kubelet, kubectl
        ├── k8s-master/                 # kubeadm init, Calico CNI
        ├── k8s-workers/                # dynamic kubeadm join
        ├── postgres/                   # cert gen, deployment, pg_hba
        ├── teleport/                   # Helm install, NodePort 32443, LE cert
        ├── access-graph/               # Access Graph Helm + teleport-cluster patch
        ├── teleport-oidc/              # AWS OIDC via tctl
        ├── teleport-sso/               # Okta SAML connector bootstrap (ConfigMap mount)
        ├── teleport-rbac/              # Machine ID bot + rbac-manager join token
        ├── teleport-node/              # AWS IAM join token for ssh-node-1
        └── argocd/                     # ArgoCD Helm, RBAC GitOps, SAML full update,
                                        # inference_secret, MCP static token
```

> **Note:** The `resources/` directory contains the canonical source-of-truth YAML files for each Teleport resource. They are excluded from ArgoCD's K8s sync (`exclude: 'resources/*'`) because they are not K8s manifests. Their content is also inlined into `rbac-configmap.yaml` which the PostSync Job mounts into the auth pod for `tctl create`.

---

## Playbook Sequence (`ansible/site.yaml`)

| Step | Role | Description |
|---|---|---|
| 1 | `k8s-setup` | containerd, kubeadm, kubelet, kubectl |
| 2 | `k8s-master` | kubeadm init, Calico CNI, kubeconfig |
| 3 | `k8s-workers` | dynamic kubeadm join |
| 4 | `postgres` | cert gen (openssl), PostgreSQL deployment, pg_hba |
| 5 | `teleport` | Teleport Enterprise Helm install, NodePort 32443, Let's Encrypt prod cert |
| 6 | `access-graph` | Access Graph TLS, postgres DB, Helm install, teleport-cluster upgrade |
| 7 | `teleport-oidc` | AWS OIDC integration resource |
| 8 | `teleport-sso` | Okta SAML connector bootstrap via ConfigMap mount (built-in roles only) |
| 9 | `teleport-rbac` | Machine ID bot, rbac-manager role, GitHub OIDC join token |
| 10 | `teleport-node` | AWS IAM join token for ssh-node-1 |
| 11 | `argocd` | ArgoCD Helm, teleport-rbac GitOps app, ArgoCD resource exclusions, wait for PostSync, full SAML connector update, inference_secret, MCP static join token |

**Standalone playbooks** (not in `site.yaml`, for manual use):
- `ansible/argocd.yaml` — re-run ArgoCD role only
- `ansible/teleport-sso.yaml` — re-run SAML bootstrap only
- `ansible/teleport-node.yaml` — re-run ssh-node token only
- `ansible/teleport-rbac.yaml` — re-run Machine ID bot + join token only

---

## CI/CD Pipeline

Single GitHub Actions workflow (`.github/workflows/terraform.yml`):

### `plan` — runs on every PR and every push to `main`
- Terraform init, validate, plan
- Uploads plan artifact keyed by git SHA (5-day retention)
- Posts formatted plan output as a PR comment

### `apply` — runs on merge to `main`, gated by `production` environment approval
- Downloads plan artifact, runs `terraform apply`
- Uploads SSH key artifact (`grant-tam-key`, 1-day retention)
- Triggers cloud-init on master which runs the full Ansible playbook
- ArgoCD syncs automatically and applies all RBAC via PostSync Job

### `destroy` — `workflow_dispatch` only, gated by `production` environment

> **Deploy PRs** use a comment bump in `terraform/backend.tf` to trigger the apply. The `push` trigger has no `paths` filter so merging any PR to `main` fires the apply job.

---

## RBAC — ArgoCD GitOps

All Teleport RBAC resources are managed via ArgoCD. On every merge to `main`, ArgoCD detects changes in `argocd/apps/teleport-rbac/` and runs a PostSync Job that applies resources to the live cluster via `tctl`.

### How it works

```
Git push to main
    └── ArgoCD detects diff in argocd/apps/teleport-rbac/
          └── Sync phase: applies rbac-configmap.yaml (namespace: teleport)
                          applies rbac-syncer-rbac.yaml (namespace: argocd)
                └── PostSync Job (teleport-rbac-apply, namespace: argocd)
                      ├── Patches rbac-sync ConfigMap volume onto teleport-auth pod
                      ├── Waits for auth pod rollout
                      ├── kubectl exec -- tctl create -f <each file in order>
                      └── trap EXIT: always removes volume + ConfigMap
```

### Apply order (important — Teleport validates role references at create time)

```
login-rule-okta-team  → role-base → role-auto-approver
→ role-okta-kube → role-okta-ssh → role-okta-ssh-root → role-okta-reviewer
→ role-mcp-ollama-tools → role-okta-base          ← must come after okta_ssh/kube/root
→ access-monitoring-rule-okta-ssh → inference-model → inference-policy
→ cluster-auth-preference (--confirm) → kube-cluster-label (--confirm, last — may fail if cluster not registered)
```

### ArgoCD resource exclusions

The `argocd-cm` ConfigMap must exclude all Teleport-native resource kinds to prevent ArgoCD from trying to apply them as K8s resources. Applied by Ansible step 11:

```
role, login_rule, cluster_auth_preference, saml, kube_cluster,
access_monitoring_rule, inference_model, inference_policy
```

### Role model

| Role | Granted to | Description |
|---|---|---|
| `base` | All authenticated users (`*` wildcard) | No standing privileges |
| `okta_base` | `okta-teleport-users` Okta group | Can request `okta_kube/ssh/ssh_root` |
| `okta_kube` | Via access request (manual) | K8s namespace access scoped to `{{internal.team}}` |
| `okta_ssh` | Via access request (auto-approved) | SSH to team-labeled nodes, no root |
| `okta_ssh_root` | Via access request (manual) | SSH + sudo, 4h TTL |
| `okta_reviewer` | `okta-teleport-admins` | Can review `okta_ssh_root` / `okta_kube` requests |
| `auto-approver` | Machine ID bot | Auto-approves pure `okta_ssh` requests |
| `mcp-ollama-tools` | `okta-teleport-admins` | MCP tool access via Teleport app access |
| `editor` + `access` + `auditor` | `okta-teleport-admins` | Full admin + session recording visibility |

### SAML connector mappings

| Okta group | Teleport roles |
|---|---|
| `*` (everyone) | `base` |
| `okta-teleport-admins` | `editor`, `access`, `auditor`, `okta_reviewer`, `mcp-ollama-tools` |
| `okta-teleport-users` | `okta_base` |

### Login rule (`okta-team-trait`)

Maps Okta SSO attributes to Teleport internal traits. `traits_map` **replaces** ALL traits — every needed trait must be explicitly listed:

```yaml
traits_map:
  logins:   [external.logins]   # SSH logins
  groups:   [external.groups]   # Preserved for SAML attributes_to_roles matching
  team:     [external.groups]   # Maps Okta group → internal.team for node/K8s scoping
```

### Secrets ownership

| Resource | Applied by | Reason |
|---|---|---|
| `inference_model` + `inference_policy` | ArgoCD PostSync Job | No secrets — safe in repo |
| `inference_secret` (Skynet API key) | Ansible step 11 (`argocd` role) | API key from `SKYNET_API_KEY` GH secret |
| SAML connector (full, with `okta_base`) | Ansible step 11 (`argocd` role) | Okta metadata URL from `.teleport-env`; applied after ArgoCD PostSync so custom roles exist |
| MCP static join token | Ansible step 11 (`argocd` role) | Token value from `MCP_TOKEN_VALUE` GH secret |

> **SAML bootstrap vs full:** Step 8 (`teleport-sso`) creates a bootstrap connector with built-in roles only. Step 11 (`argocd`) replaces it with the full connector including `base` wildcard and `okta_base` mapping after ArgoCD has applied the custom roles.


---

## PostgreSQL — In-Cluster with mTLS

PostgreSQL 17 runs in the `postgres` namespace using `ateleport/test:postgres-wal2json-17-1`.

### Users and auth

| User | Auth method | Used by |
|---|---|---|
| `teleport` | Client certificate (CN=teleport) | Teleport auth — backend + audit |
| `access_graph_user` | scram-sha-256 password | Access Graph service |
| `postgres` | md5 (localhost only) | Admin/bootstrap only |

### Connection strings

```
# Backend + audit (Teleport auth pod)
postgresql://teleport@postgres-service.postgres.svc.cluster.local:5432/teleport_backend
  ?sslmode=verify-full&sslcert=/pg-certs/client.crt
  &sslkey=/pg-certs/client.key&sslrootcert=/pg-certs/ca.crt

# Access Graph (password auth, TLS required)
postgresql://access_graph_user:<password>@postgres-service.postgres.svc.cluster.local:5432/access_graph_db
  ?sslmode=require
```

---

## Teleport Access Graph

Access Graph v1.29.6 runs in the `teleport-access-graph` namespace. Uses its own self-signed TLS cert (`teleport-access-graph-tls` secret) for the internal gRPC endpoint — independent of the Teleport proxy cert.

The `teleport-cluster` Helm chart is upgraded by Ansible step 6 with an access_graph patch:

```yaml
auth:
  teleportConfig:
    access_graph:
      enabled: true
      endpoint: teleport-access-graph.teleport-access-graph.svc.cluster.local:443
      ca: /var/run/access-graph/ca.pem
```

**Recovery — "Failed to fetch" in UI:** Re-run the Helm upgrade on master:
```bash
helm upgrade teleport teleport/teleport-cluster \
  --namespace teleport --version 18.7.1 \
  --values /home/ubuntu/teleport-values.yaml \
  --values /home/ubuntu/teleport-access-graph-patch.yaml \
  --wait --timeout 10m
```

---

## AI Session Summary

Session summaries are generated using a Skynet-hosted Gemma 3 model via an OpenAI-compatible API.

| Resource | Value |
|---|---|
| `inference_model` | `skynet-gemma` — endpoint `skynet.gvteleport.com:443`, model `gemma3:4b` |
| `inference_policy` | `skynet-gemma-policy` — applies to `ssh` session kind |
| `inference_secret` | `grant-skynet-secret` — API key from `SKYNET_API_KEY` GH secret |

The `inference_model` and `inference_policy` are applied by ArgoCD PostSync Job. The `inference_secret` is applied by Ansible step 11 using the ConfigMap mount pattern so the API key never touches the repo.

S3 IAM policy includes `s3:ListBucketVersions` and `s3:GetObjectVersion` for the sessions bucket — required for the inference service to read versioned session recording objects.

---

## ssh-node-1

Standalone `t2.small` Ubuntu node. Auto-enrolls via AWS IAM join — no static tokens.

**Labels:** `team=okta-teleport-users`, `env=demo`, `node=ssh-node-1`

**BPF enhanced session recording** — captures commands and network activity:
```yaml
ssh_service:
  enhanced_recording:
    enabled: true
    cgroup_path: /cgroup2   # separate mount — NOT /sys/fs/cgroup (conflicts with systemd)
```
Cloud-init mounts `/cgroup2` and runs `systemctl daemon-reexec` before starting Teleport to avoid `status=219/CGROUP` failures.

**TLS:** Teleport proxy uses a Let's Encrypt production cert — no `--insecure` flag needed on ssh-node.

---

## Prerequisites

### 1. AWS Bootstrap Resources

```bash
# S3 bucket for Terraform state
aws s3api create-bucket \
  --bucket <tf-state-bucket> --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2
aws s3api put-bucket-versioning \
  --bucket <tf-state-bucket> \
  --versioning-configuration Status=Enabled

# DynamoDB table for state locking
aws dynamodb create-table \
  --table-name <tf-lock-table> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-west-2
```

### 2. GitHub Repository Secrets

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `AWS_SESSION_TOKEN` | Session token (required for STS/SSO credentials) |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform remote state |
| `TF_LOCK_TABLE` | DynamoDB table name for state locking |
| `CUSTOMER_IP` | Your public IP in CIDR notation (e.g. `1.2.3.4/32`) |
| `TELEPORT_LICENSE` | Teleport Enterprise license file contents |
| `AWS_OIDC_ARN` | ARN of the IAM role for Teleport AWS OIDC integration |
| `OKTA_METADATA_URL` | SAML metadata URL from Okta app Sign On tab |
| `OKTA_GROUPS_EDITOR` | Okta group name for the admin/editor group |
| `OKTA_GROUPS_ACCESS` | Okta group name for the standard access group |
| `SKYNET_API_KEY` | API key for the Skynet AI inference endpoint |
| `MCP_TOKEN_VALUE` | Static token value for the MCP server join token |

### 3. GitHub Environment

Create a **`production`** environment under **Settings → Environments** with required reviewers to gate all `apply` and `destroy` operations.

### 4. Okta SAML App

Create a SAML 2.0 application in Okta:
- **SSO URL**: `https://grant-tam-teleport.gvteleport.com/v1/webapi/saml/acs/okta`
- **Audience URI**: `https://grant-tam-teleport.gvteleport.com/v1/webapi/saml/acs/okta`
- **Name ID format**: `EmailAddress`
- **Attribute**: `username` → `user.login`
- **Group attribute**: `groups`, filter `Matches regex: .*`
- Copy the **Metadata URL** from Sign On tab → `OKTA_METADATA_URL` secret

Create two Okta groups and assign users:
- Admin group → `OKTA_GROUPS_EDITOR` (gets `editor`, `access`, `auditor`, `okta_reviewer`, `mcp-ollama-tools`)
- Access group → `OKTA_GROUPS_ACCESS` (gets `okta_base` — must request all access)


---

## Deploying

### Via Pull Request (recommended)

```bash
git checkout main && git pull origin main
git checkout -b deploy/apply-$(date +%Y%m%d)
# Bump the deploy trigger comment in terraform/backend.tf
sed -i '' 's/# deploy trigger:.*/# deploy trigger: $(date +%Y%m%d)/' terraform/backend.tf
git add terraform/backend.tf
git commit -m "chore: fresh apply after environment destroy ($(date +%Y-%m-%d))"
git push origin deploy/apply-$(date +%Y%m%d)
gh pr create --title "chore: fresh apply" --base main
# Merge PR → apply job starts → approve production gate → infrastructure deploys
```

### Destroy

```bash
gh workflow run terraform.yml \
  --repo grantvoss-teleport/tam-cert-noeks \
  --field action=destroy
# Then approve production gate in GitHub Actions UI
```

If a state lock exists first, see the force-unlock pattern in PR #30.

---

## Accessing the Cluster

```bash
# Get SSH key from the apply run artifacts (1-day retention)
gh run download <run-id> --repo grantvoss-teleport/tam-cert-noeks \
  --name grant-tam-key --dir /tmp/grant-tam-key
chmod 600 /tmp/grant-tam-key/grant-tam-key.pem

# Get master public IP from apply run logs
gh run view <run-id> --log | grep master_public_ip

# SSH to master
ssh -i /tmp/grant-tam-key/grant-tam-key.pem ubuntu@<master_public_ip>

# Check cluster
kubectl get nodes && kubectl get pods -A

# Check Teleport
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') -- tctl status

# Check RBAC roles applied
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') -- tctl get roles --format text

# Check ArgoCD sync status
kubectl get application teleport-rbac -n argocd \
  -o jsonpath='{.status.sync.status} {.status.health.status}'

# Monitor cloud-init progress
sudo tail -f /var/log/cloud-init-teleport.log
```

---

## Common Operations

### Re-trigger ArgoCD PostSync Job (without a code change)

```bash
PASS=$(kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sk -X POST http://localhost:32080/api/v1/session \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${PASS}\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")
curl -sk -X POST http://localhost:32080/api/v1/applications/teleport-rbac/sync \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{"revision":"HEAD","strategy":{"hook":{"force":true}}}'
```

### Remove stale rbac-sync volume from teleport-auth

If the PostSync Job crashes mid-run, a stale `rbac-sync` volume may remain on `teleport-auth`. Remove it:

```bash
VOL_IDX=$(kubectl get deployment teleport-auth -n teleport \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' | \
  awk '/^rbac-sync$/{print NR-1; exit}')
MOUNT_IDX=$(kubectl get deployment teleport-auth -n teleport \
  -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.name}{"\n"}{end}' | \
  awk '/^rbac-sync$/{print NR-1; exit}')
kubectl patch deployment teleport-auth -n teleport --type=json \
  -p="[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/${MOUNT_IDX}\"},{\"op\":\"remove\",\"path\":\"/spec/template/spec/volumes/${VOL_IDX}\"}]"
kubectl rollout status deployment/teleport-auth -n teleport --timeout=120s
```

### Apply any Teleport resource manually (ConfigMap mount pattern)

The auth container is distroless — no `tar`, no stdin piping, no `kubectl cp`. Use this pattern for any manual `tctl create`:

```bash
# 1. Write resource to a temp file on master
cat > /tmp/my-resource.yaml << 'EOF'
kind: role
version: v7
...
EOF

# 2. Create ConfigMap and mount onto auth pod
kubectl create configmap manual-patch -n teleport \
  --from-file=my-resource.yaml=/tmp/my-resource.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl patch deployment teleport-auth -n teleport --type=json -p='[
  {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"manual-patch","configMap":{"name":"manual-patch"}}},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"manual-patch","mountPath":"/tmp/manual-patch","readOnly":true}}
]'
kubectl rollout status deployment/teleport-auth -n teleport --timeout=120s

# 3. Apply via tctl
AUTH_POD=$(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n teleport $AUTH_POD -- tctl create -f /tmp/manual-patch/my-resource.yaml

# 4. Cleanup
VOL_IDX=$(kubectl get deployment teleport-auth -n teleport \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' | \
  awk '/^manual-patch$/{print NR-1; exit}')
MOUNT_IDX=$(kubectl get deployment teleport-auth -n teleport \
  -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.name}{"\n"}{end}' | \
  awk '/^manual-patch$/{print NR-1; exit}')
kubectl patch deployment teleport-auth -n teleport --type=json \
  -p="[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/volumeMounts/${MOUNT_IDX}\"},{\"op\":\"remove\",\"path\":\"/spec/template/spec/volumes/${VOL_IDX}\"}]"
kubectl delete configmap manual-patch -n teleport
```

### Fix Access Graph "Failed to fetch"

```bash
helm upgrade teleport teleport/teleport-cluster \
  --namespace teleport --version 18.7.1 \
  --values /home/ubuntu/teleport-values.yaml \
  --values /home/ubuntu/teleport-access-graph-patch.yaml \
  --wait --timeout 10m
```

### Emergency break-glass admin user

```bash
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') \
  -- tctl users add admin --roles=editor,access,auditor --logins=ubuntu
```

---

## Known Gotchas

- **AWS session tokens expire** — refresh `AWS_SESSION_TOKEN` in GitHub Secrets before running apply/destroy
- **`traits_map` replaces ALL traits** — every trait needed downstream must be explicitly listed in the login rule
- **`{{internal.team}}` in `node_labels` doesn't work with list traits** — use `team: '*'` and rely on role-level access control
- **Teleport v7 validates role references at `tctl create` time** — roles listed in `allow.request.roles` must exist before the referencing role is created
- **`bitnami/kubectl` has no `python3` or `jq`** — use `kubectl jsonpath` + `awk` for JSON inspection in the PostSync Job
- **`tctl create` for `cluster_auth_preference` requires `--confirm`** — resource is managed by static config
- **`auditor` role required for session recording UI** — `editor` alone does not grant `session: [list, read]`
- **BPF requires `cgroup_path: /cgroup2`** — using `/sys/fs/cgroup` conflicts with systemd and causes `status=219/CGROUP`
- **`systemctl daemon-reexec` required after mounting `/cgroup2`** — otherwise systemd fails to create the Teleport service cgroup
- **NodePort 32443 is pinned via `kubectl patch`** — the Teleport Helm chart does not support `nodePort` in values
- **ArgoCD PostSync Job runs in `argocd` namespace** — but patches volumes onto `teleport-auth` in `teleport` namespace; `teleport-rbac-syncer` ClusterRole must include `watch` on deployments for `kubectl rollout status`
- **After any volume mount/unmount patch on `teleport-auth`**, the pod rolls over — always re-query pod name before the next `kubectl exec`
- **`kube-cluster-label.yaml` apply may fail** if the K8s cluster hasn't registered with Teleport yet — this is non-fatal and expected on first deploy
