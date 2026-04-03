# Session Summary — tam-cert-noeks
## Repo: `grantvoss-teleport/tam-cert-noeks`
## Local path: `/Users/grantvoss/Documents/tam-cert-ans/tam-cert-noeks`

---

## Stack

- **Terraform** (AWS: VPC, EC2, S3, Secrets Manager, IAM, Route53)
- **Ansible** — 10-step playbook sequence run via cloud-init on master `172.49.20.230`
- **Kubernetes** — kubeadm, Calico CNI, 1 master + 2 workers (`.231`/`.232`)
- **Teleport Enterprise 18.7.1** — Helm chart `teleport-cluster`
- **Teleport Access Graph** — Helm chart `teleport-access-graph` v1.29.6
- **In-cluster PostgreSQL** (`ateleport/test:postgres-wal2json-17-1`) with mTLS cert auth
- **Okta SAML SSO**, **AWS OIDC**, **Machine ID RBAC**
- **ArgoCD** — newly added, NodePort 32080, registered as Teleport app

## Infrastructure

| Node | Private IP | Role |
|---|---|---|
| master | 172.49.20.230 | K8s control plane, Ansible runner |
| worker-1 | 172.49.20.231 | K8s worker |
| worker-2 | 172.49.20.232 | K8s worker |
| ssh-node-1 | 172.49.20.137 (private) | Standalone Teleport SSH node, IAM join |

**Teleport proxy**: `grant-tam-teleport.gvteleport.com:443` (NodePort 32443)
**ArgoCD**: `argocd.grant-tam-teleport.gvteleport.com` (NodePort 32080)

---

## Ansible Playbook Sequence (`ansible/site.yaml`)

1. `k8s-setup.yaml` — containerd, kubeadm, kubelet, kubectl
2. `k8s-master.yaml` — kubeadm init, Calico CNI, kubeconfig
3. `k8s-workers.yaml` — dynamic kubeadm join
4. `postgres.yaml` — in-cluster postgres pod, certs, `teleport-pg-client-certs` secret
5. `teleport.yaml` — Teleport Enterprise Helm install
6. `access-graph.yaml` — Access Graph TLS cert, postgres DB, Helm install, teleport-cluster upgrade
7. `teleport-oidc.yaml` — AWS OIDC integration
8. `teleport-sso.yaml` — Okta SAML connector
9. `teleport-rbac.yaml` — Machine ID bot, rbac-manager role, join token
10. `teleport-node.yaml` — AWS IAM join token for ssh-node-1

**Standalone playbooks** (not in site.yaml):
- `ansible/metallb.yaml` — MetalLB load balancer
- `ansible/argocd.yaml` — ArgoCD + Teleport app registration


---

## PRs Merged This Session

| PR | Branch | Fix |
|---|---|---|
| #28 | `fix/ag-debug-user-creation` | `access_graph_user` created via SQL file (`kubectl cp` + `psql -f`) — fixes special char interpolation |
| #29 | `deploy/apply-20260324` | Fresh deploy trigger |
| #30 | `fix/force-unlock-and-destroy` | Force-unlock stale TF state lock (DynamoDB `ConditionalCheckFailedException`) |
| #31 | `deploy/apply-20260324b` | Fresh deploy after clean destroy |
| #32 | `fix/ag-create-db-sql-file` | `access_graph_db` created via SQL file — fixes `\gexec` failure with `psql -c` |
| #33 | `deploy/apply-20260324c` | Fresh deploy |
| #34 | `fix/disable-acme-self-signed` | Disable ACME (`acme: false`) — Let's Encrypt rate limit reached, use self-signed cert |
| #35 | `fix/ag-helm-repo-add-as-ubuntu` | Add Teleport Helm repo in `access-graph` role — `teleport` role runs as root, `access-graph` runs as ubuntu |
| #36 | `deploy/apply-20260324d` | Fresh deploy |
| #37 | `fix/ag-chart-version-1-29-6` | Pin `teleport-access-graph` chart to `1.29.6` — has independent versioning from `teleport-cluster` |
| #38 | `deploy/apply-20260324e` | Fresh deploy |
| #39 | `fix/ag-replica-count-1` | Set `replicaCount: 1` in tag-values — chart default of 2 causes `--wait` timeout on lab cluster |
| #40 | `fix/pg-hba-access-graph-user` | Add `hostssl scram-sha-256` rule for `access_graph_user` on pod CIDR `192.168.0.0/16` |
| #41 | `deploy/apply-20260325` | Fresh deploy |
| #42 | `fix/rbac-stdin-instead-of-kubectl-cp` | Apply RBAC manifests via `kubectl exec -i` stdin — `kubectl cp` requires `tar` (distroless container) |
| #44 | `fix/ssh-node-iam-token-configmap-mount` | IAM token via ConfigMap mount + correct `spec.allow` field + `--insecure` systemd drop-in for ssh-node |
| #45 | `feat/argocd` | ArgoCD Helm install + Teleport app registration |
| #46 | `fix/saml-editor-add-access-role` | Add `access` role to `okta_groups_editor` SAML mapping |

**Closed/superseded**: PR #43 (superseded by #44)

---

## Key Design Decisions & Lessons Learned

### kubectl exec -i stdin truncation (distroless containers)
The Teleport auth container is distroless — no `sh`, `tar`, `cat`, nothing except Teleport binaries. `kubectl cp` requires `tar` and fails. `kubectl exec -i` stdin piping truncates multi-line YAML before the full content arrives.

**Solution (established pattern)**: Render YAML to a file on master → stage as a ConfigMap in `teleport` namespace → JSON-patch volume + volumeMount onto auth deployment → `kubectl exec -- tctl create -f /tmp/bootstrap/file.yaml` (no stdin) → cleanup patch + delete ConfigMap.

This pattern is used in:
- `ansible/roles/teleport-node/tasks/main.yaml`
- `ansible/roles/argocd/tasks/main.yaml`

### IAM join token YAML schema
IAM join tokens use `spec.allow` (top-level under spec), **NOT** `spec.iam.allow` (which is the EC2 join method). Every `tctl create` failure with `requires defined token allow rules` was caused by this wrong field name.

### `--insecure` for self-signed cert
After disabling ACME (PR #34), nodes connecting to the Teleport proxy must use `--insecure`. This is a **CLI flag only** — `insecure: true` is not a valid `teleport.yaml` v3 field and causes a parse error. Use a systemd drop-in:
```
[Service]
ExecStart=
ExecStart=/usr/local/bin/teleport start --config /etc/teleport.yaml --pid-file=/run/teleport.pid --insecure
```

### teleport-access-graph chart versioning
`teleport-access-graph` uses **independent versioning** (`1.x`) from `teleport-cluster` (`18.x`). Latest as of 2026-03-25 is `1.29.6`.

### Helm repo user context
The `teleport` Ansible role runs with `become: yes` (root) — `helm repo add` writes to `/root/.config/helm/`. The `access-graph` role runs with `become: false` (ubuntu) and needs its own `helm repo add` at the top of its tasks.

### pg_hba.conf for access_graph_user
Access Graph connects from Calico pod CIDR `192.168.x.x` using password auth (URI secret). Requires explicit `hostssl` rule — it does NOT use client certs like the `teleport` user.


---

## Current Cluster State (as of session end)

### Running services
- Teleport Enterprise 18.7.1 — proxy NodePort 32443, self-signed cert (ACME disabled)
- Teleport Access Graph 1.29.6 — healthy, connected to postgres
- PostgreSQL — mTLS cert auth for `teleport` user, scram-sha-256 for `access_graph_user`
- ssh-node-1 — registered in Teleport via AWS IAM join (`tctl nodes ls` confirms)
- ArgoCD — installed, NodePort 32080, registered as Teleport app resource

### Manually applied on live cluster (not via fresh deploy)
These were applied manually and are in the repo but would run automatically on next fresh deploy:
- PR #42: RBAC bootstrap (rbac-manager role, bot, join token) — applied via `ansible-playbook teleport-rbac.yaml`
- PR #44: ssh-node IAM join token — applied via `ansible-playbook teleport-node.yaml`
- PR #45: ArgoCD — applied via `ansible-playbook argocd.yaml` (files curled to master)
- PR #46: SAML connector update — applied manually via ConfigMap mount + `tctl create`
- RBAC roles (base, kube-access, ssh-access, ssh-root-access, auto-approver, login-rule) — applied manually via ConfigMap mount loop (GH Actions workflow blocked, no active PR)

### Pending / in-progress
- PR #46 merged but SAML connector + all RBAC roles applied manually
- `okta_groups_editor` SAML mapping now includes both `editor` and `access` roles

---

## GitHub Actions Workflow

**File**: `.github/workflows/terraform.yml`

- **Plan**: runs on PR open (touches `terraform/**` or `ansible/**`)
- **Apply**: runs on merge to `main`, gated by `production` environment approval
- **Destroy**: `workflow_dispatch` only, gated by `production` environment
- **RBAC apply**: Phase 2 of apply job — uses Machine ID (`tbot`) + `tctl` to apply all RBAC templates. Requires Teleport cluster to be reachable. **Currently blocked** — `workflow_dispatch apply` requires a PR.

**SSH key**: Uploaded as artifact `grant-tam-key` with 1-day retention. Retrieve with:
```bash
gh run download <run-id> --repo grantvoss-teleport/tam-cert-noeks --name grant-tam-key --dir /tmp/grant-tam-key
```
If expired, get from Terraform state:
```bash
cd terraform && terraform init -backend-config=... && terraform output -raw private_key_pem > /tmp/key.pem
```

**Master public IP**: `54.245.49.201` (from last apply run #23526661313)
**ssh-node-1 public IP**: `35.90.50.186` (from last apply run)

---

## Fresh Deploy Procedure

```bash
cd /Users/grantvoss/Documents/tam-cert-ans/tam-cert-noeks
git checkout main && git pull origin main
git checkout -b deploy/apply-YYYYMMDD
sed -i '' 's/# deploy trigger:.*/# deploy trigger: YYYYMMDD/' terraform/backend.tf
git add terraform/backend.tf && git commit -m "chore: fresh apply after environment destroy (YYYY-MM-DD)"
git push origin deploy/apply-YYYYMMDD
gh pr create --title "chore: fresh apply..." --body "..." --base main
```
Then merge PR → approve `production` gate → apply runs.

## Destroy Procedure

```bash
gh workflow run terraform.yml --repo grantvoss-teleport/tam-cert-noeks --field action=destroy
# Then approve production gate in GitHub Actions UI
```
If state lock exists first:
1. Add `terraform force-unlock -force <lock-id>` step before destroy in workflow (see PR #30 pattern)
2. Merge, then trigger destroy


---

## Session — 2026-04-02

### PRs Merged

| PR | Branch | Description |
|---|---|---|
| #66 | `feat/okta-rbac-roles-argocd` | Add `okta_*` RBAC roles, migrate RBAC apply from GH Actions jinja2/tbot/tctl to ArgoCD GitOps |
| #67 | `deploy/apply-20260402` | Fresh deploy trigger (plan only — apply not triggered, workflow bug) |
| #68 | `deploy/apply-20260402b` | Fresh deploy trigger (same — workflow bug not yet fixed) |
| #69 | `fix/workflow-apply-trigger` | Fix workflow: remove `paths` filter from push trigger, add `action=apply` to plan job `if`, tighten apply `needs` condition |
| #70 | `fix/rbac-sync-job-idempotent-volume` | Make ArgoCD PostSync Job idempotent — check for stale `rbac-sync` volume before patching, move cleanup to `trap EXIT` |
| #71 | `fix/saml-connector-ownership` | Move SAML connector ownership fully to Ansible; remove from ArgoCD apply loop to eliminate split-brain |
| #75 | `fix/rbac-cleanup` | Combined: role annotations list format fix, login rule groups trait, remove duplicate `kube-access`/`ssh-access`/`ssh-root-access` roles |
| #76 | `fix/ssh-node-team-label` | Change ssh-node-1 `team` label from `platform` → `okta-teleport-users` in Terraform and userdata |
| #77 | `fix/node-labels-wildcard` | `okta_ssh`/`okta_ssh_root` node_labels use `team: '*'` — `{{internal.team}}` list expansion doesn't work as label selector |
| #78 | `fix/enhanced-recording-bpf` | Enable BPF enhanced session recording on ssh-node-1 — `enhanced_recording` under `ssh_service`, mount `/cgroup2`, `systemctl daemon-reexec` |
| #79 | `fix/admin-group-auditor-role` | Add `auditor` role to `okta-teleport-admins` SAML mapping — required for session recording visibility in UI |

**Closed/superseded**: PRs #72, #73, #74 (combined into #75)

---

### New Roles — `okta_*` RBAC Model

| Role | Description |
|---|---|
| `okta_base` | No standing privileges. Can request `okta_kube`, `okta_ssh`, `okta_ssh_root`. `okta_ssh`-only auto-approved. |
| `okta_kube` | K8s namespace access scoped to `{{internal.team}}` |
| `okta_ssh` | SSH to team-labeled nodes, root denied |
| `okta_ssh_root` | SSH with sudo, 4h TTL |

**SAML mappings** (final):
- `*` → `base`
- `okta-teleport-admins` → `editor`, `access`, `auditor`
- `okta-teleport-users` → `okta_base`

**Removed**: `kube-access`, `ssh-access`, `ssh-root-access` (superseded by `okta_*`)

---

### ArgoCD GitOps RBAC Pattern

All Teleport RBAC resources are now managed via ArgoCD:
- **Manifest location**: `argocd/apps/teleport-rbac/`
- **ConfigMap**: `teleport-rbac-files` in `teleport` namespace — contains all role YAMLs as inline data
- **PostSync Job**: `teleport-rbac-apply` — patches `rbac-sync` volume onto `teleport-auth`, execs `tctl create -f` for each file, cleans up via `trap EXIT`
- **SAML connector**: owned by Ansible step 11 (`argocd` role) — applied after ArgoCD sync completes and custom roles exist. Never managed by ArgoCD to avoid chicken-and-egg rejection from `tctl`.

**ArgoCD Application**: `argocd/apps/teleport-rbac-app.yaml` — automated sync, `selfHeal: true`, `prune: false`

---

### Key Lessons Learned This Session

#### GH Actions apply workflow — paths filter on push
The `push` trigger had a `paths` filter (`terraform/**`, `ansible/**`). Deploy PRs use empty commits with no file changes — merge to main never fired the apply job. **Fix**: remove `paths` filter from `push` trigger (keep it on `pull_request` to avoid noisy plan runs).

#### GH Actions apply — plan job skipped on `workflow_dispatch action=apply`
The `plan` job `if` condition only matched `action == 'plan'`. On `workflow_dispatch action=apply`, plan was skipped, causing the `needs: plan` apply job to also be skipped. **Fix**: add `action == 'apply'` to plan job `if` condition.

#### ArgoCD PostSync Job — stale volume crash loop
The PostSync Job patches a `rbac-sync` volume onto `teleport-auth` for `tctl` access. If the job crashes before cleanup, the volume stays mounted. The next sync attempt hits `Duplicate value: "rbac-sync"` and crashes immediately. **Fix**: check if volume already present before patching; move cleanup to `trap EXIT` so it always runs.

#### SAML connector split brain
Ansible seeded the SAML connector into `teleport-rbac-files` ConfigMap at deploy time with stale role mappings. ArgoCD adopted the ConfigMap but the PostSync Job kept crashing before it could apply the corrected SAML connector. **Fix**: Ansible owns the SAML connector end-to-end. Bootstrap connector (step 8, built-in roles only) → ArgoCD applies custom roles (step 11) → Ansible applies full connector with `okta_base` mapping after ArgoCD sync.

#### Login rule `traits_map` drops all unlisted traits
`traits_map` in a `login_rule` **replaces** all traits — it does not merge. The `okta-team-trait` rule only listed `logins` and `team`, so `groups` was silently dropped. The SAML `attributes_to_roles` mapping is evaluated against traits **after** login rules run — with `groups` missing, no roles could be mapped. **Fix**: add `groups: [external.groups]` to `traits_map`.

#### `{{internal.team}}` doesn't work in `node_labels` when trait is a list
When a user is in multiple Okta groups, `internal.team` resolves to a list (e.g. `[okta-teleport-users, Everyone]`). Teleport does not iterate list values for node label matching — the whole list is treated as a single string that never matches the node's label. **Fix**: use `team: '*'` in `node_labels`. Access control is enforced at the request layer (`okta_base` thresholds).

#### BPF enhanced recording — cgroup2 and `daemon-reexec`
- Field is `enhanced_recording` under `ssh_service` in v3 config (not `enhanced_session_recording`, not top-level)
- `cgroup_path` must be `/cgroup2` — using `/sys/fs/cgroup` conflicts with systemd's own cgroup hierarchy and causes `status=219/CGROUP`
- After mounting `/cgroup2` in cloud-init, `systemctl daemon-reexec` is required before starting Teleport — otherwise systemd fails to create the service cgroup

#### `auditor` role required for session recording UI
`editor` has `session_recording_config` permissions (manage config) but not `session: [list, read]` (view recordings). The `auditor` role is required for Activity → Session Recordings to show recordings. Admin group needs `editor` + `access` + `auditor`.

---

### Current Cluster State (as of 2026-04-02 session end)

**Master public IP**: `54.202.164.27` (from apply run #23924325857)
**ssh-node-1 private IP**: `172.49.20.157`

### Running services
- Teleport Enterprise 18.7.1 — proxy NodePort 32443, self-signed cert
- Teleport Access Graph 1.29.6 — healthy
- PostgreSQL — healthy
- ssh-node-1 — registered, `team=okta-teleport-users`, BPF enhanced recording active
- ArgoCD — synced, PostSync Job applying RBAC via GitOps

### RBAC state
- `base`, `okta_base`, `okta_kube`, `okta_ssh`, `okta_ssh_root`, `auto-approver` — all applied
- `kube-access`, `ssh-access`, `ssh-root-access` — deleted
- SAML connector: `*→base`, `okta-teleport-admins→editor+access+auditor`, `okta-teleport-users→okta_base`
- Login rule: `groups`, `logins`, `team` all forwarded

### Verified end-to-end
- ✅ `okta-teleport-users` login → lands with `base` + `okta_base`, zero standing privileges
- ✅ Access request for `okta_ssh` → auto-approved by bot
- ✅ Access request for `okta_ssh_root` → manually approved
- ✅ ssh-node-1 visible and accessible after assuming role
- ✅ Session recordings uploaded to S3 with `enhanced_recording: true`
- ✅ Session recordings visible in UI for `okta-teleport-admins`

---

## Session — 2026-04-03 (continued)

### PRs Merged

| PR | Branch | Description |
|---|---|---|
| #80 | `feat/ai-session-summary` | AI session summary via Skynet inference endpoint — `inference_model`, `inference_policy` via ArgoCD; `inference_secret` via Ansible post-sync |
| #81 | `fix/s3-list-bucket-versions` | Add `s3:ListBucketVersions` + `s3:GetObjectVersion` to sessions bucket IAM policy — required for AI session summary to read recordings from S3 |

---

### AI Session Summary Implementation

**Resources:**

| Resource | Kind | Applied by |
|---|---|---|
| `skynet-gemma` | `inference_model` | ArgoCD PostSync Job |
| `skynet-gemma-policy` | `inference_policy` | ArgoCD PostSync Job |
| `grant-skynet-secret` | `inference_secret` | Ansible `argocd` role (post-sync, ConfigMap mount pattern) |

**Model**: `gemma3:4b` via OpenAI-compatible endpoint at `skynet.gvteleport.com:443`
**Policy**: applies to `ssh` session kind

**Secret handling**: `SKYNET_API_KEY` GH Actions secret → Terraform var → written to `.teleport-env` → read by Ansible → written via `python3 yaml.dump` (handles special chars) → applied via ConfigMap mount + `tctl create -f`

**S3 permissions added** (`terraform/rds.tf`):
- `s3:ListBucketVersions` — required for inference service to locate session recording objects
- `s3:GetObjectVersion` — required to read versioned session recording objects

---

### Access Graph "Failed to fetch" — Root Cause & Fix

**Symptom**: UI showed "An error generating Access Graph / Network error (Failed to fetch)"

**Root cause**: The `teleport-auth` pod had lost its connection to the Access Graph service. The Helm values were correct (`access_graph.endpoint` was set), but repeated auth pod restarts from the ArgoCD PostSync Job volume mount/unmount cycle caused the in-memory gRPC connection to Access Graph to drop without re-establishing.

**Fix**: Re-run `helm upgrade` with both values files to trigger an auth pod rollout:
```bash
helm upgrade teleport teleport/teleport-cluster \
  --namespace teleport \
  --version 18.7.1 \
  --values /home/ubuntu/teleport-values.yaml \
  --values /home/ubuntu/teleport-access-graph-patch.yaml \
  --wait --timeout 10m
```

**Prevention**: The ArgoCD PostSync Job should avoid unnecessary auth pod restarts. The idempotent volume patch (PR #70) reduces this, but any auth pod restart can drop the Access Graph connection. If this recurs, the helm upgrade above is the recovery procedure.

---

### Access Graph Warnings (cosmetic, non-blocking)
Access Graph logs show repeated warnings:
```
"role kube-access not found" / "role ssh-access not found" / "role ssh-root-access not found"
```
These are from Access Graph trying to expand request roles that referenced the old deleted roles. They are harmless — Access Graph will stop seeing these once it completes a full resync cycle. No action needed.

---

### Current Cluster State (as of 2026-04-03)

**Master public IP**: `54.202.164.27`
**ssh-node-1 private IP**: `172.49.20.157`

### Verified end-to-end
- ✅ Okta SSO login → `base` + `okta_base`
- ✅ Access requests — `okta_ssh` auto-approved, `okta_ssh_root` manual
- ✅ ssh-node-1 visible after role assumption, BPF enhanced recording active
- ✅ Session recordings in S3 + visible in UI (`auditor` role on admin group)
- ✅ Access Graph — connected and healthy (after helm upgrade)
- ✅ AI session summary — `inference_model` + `inference_policy` + `inference_secret` applied
- ✅ S3 IAM policy includes `s3:ListBucketVersions` + `s3:GetObjectVersion`
