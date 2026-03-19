# tam-cert-noeks

Terraform + Ansible automation to deploy a production-ready 3-node Kubernetes cluster on AWS EC2 with Teleport Enterprise 18.7.1, an in-cluster PostgreSQL 17 backend with mutual TLS certificate authentication, and Okta SAML SSO. All infrastructure is provisioned via Terraform, cluster bootstrapping is handled via cloud-init on the master node, and all Kubernetes and Teleport configuration is managed by Ansible roles pulled directly from this repository.

---

## Architecture

```
Internet
    │
    ▼
AWS NLB (grant-tam-teleport.gvteleport.com)
    │  port 443 → NodePort 32443 (TCP health check on 32443)
    ▼
Kubernetes Nodes (t3.medium × 3, us-west-2a)
  ├── master  172.49.20.230   control-plane + Teleport auth
  ├── node1   172.49.20.231   worker
  └── node2   172.49.20.232   worker
        │
        ├── Namespace: postgres
        │     └── PostgreSQL 17 pod
        │           ├── mTLS cert auth (no passwords)
        │           ├── wal_level=logical (replication slots)
        │           └── pg_hba.conf: hostssl teleport cert clientcert=verify-full
        │
        └── Namespace: teleport
              └── Teleport Enterprise 18.7.1
                    ├── PostgreSQL backend  ──►  postgres-service.postgres.svc.cluster.local
                    │                            (sslmode=verify-full + client cert at /pg-certs/)
                    ├── Session recordings  ──►  S3 (grant-tam-teleport-sessions)
                    ├── AWS OIDC            ──►  IAM role (grant-tam-oidc-role)
                    └── SSO                 ──►  Okta SAML

ssh-node-1 (t2.small, us-west-2a)
  └── Teleport SSH node, joins via AWS IAM join method (no static tokens)
      team=platform label → scoped by RBAC ssh-access / ssh-root-access roles
```

---

## Repository Structure

```
tam-cert-noeks/
├── .github/
│   └── workflows/
│       └── terraform.yml               # Unified CI/CD: plan + apply (infra + RBAC) + destroy
├── helm/
│   ├── teleport-values.yaml            # Reference Teleport Helm values
│   └── postgres/                       # In-cluster PostgreSQL manifests
│       ├── namespace.yaml
│       ├── postgres-config.yaml        # postgresql.conf (SSL, WAL, connections)
│       ├── pg-hba-config.yaml          # cert auth for teleport user, md5 for admin
│       ├── init-sql.yaml               # Creates teleport user + databases on first boot
│       ├── postgres-deployment.yaml    # Deployment with cert permission initContainer
│       └── postgres-svc.yaml           # ClusterIP service (postgres-service:5432)
├── terraform/
│   ├── backend.tf                      # S3 remote state
│   ├── main.tf                         # EC2, VPC, networking, IAM, cloud-init
│   ├── rds.tf                          # S3 session recordings, license secret
│   ├── nlb.tf                          # AWS NLB → NodePort 32443
│   ├── route53.tf                      # DNS CNAME records
│   ├── teleport-oidc.tf                # AWS OIDC integration IAM resources
│   └── ssh-node.tf                     # ssh-node-1: t2.small, IAM auto-enrollment
└── ansible/
    ├── ansible.cfg
    ├── hosts                           # master (172.49.20.230), node1/2 (.231/.232)
    ├── site.yaml                       # Master playbook (all roles in order)
    ├── k8s-setup.yaml
    ├── k8s-master.yaml
    ├── k8s-workers.yaml
    ├── postgres.yaml                   # In-cluster PostgreSQL deployment
    ├── teleport.yaml
    ├── teleport-oidc.yaml
    ├── teleport-sso.yaml
    ├── teleport-rbac.yaml
    ├── teleport-node.yaml
    └── roles/
        ├── k8s-setup/                  # containerd.io 2.x, kubeadm 1.35.2
        ├── k8s-master/                 # kubeadm init, Calico CNI v3.29
        ├── k8s-workers/                # Dynamic kubeadm join
        ├── postgres/
        │   ├── tasks/main.yaml         # Cert generation (openssl on master),
        │   │                           #   Secret creation, Deployment, copies client
        │   │                           #   certs to teleport namespace
        │   └── files/                  # All postgres manifests (from helm/postgres/)
        ├── teleport/
        │   ├── tasks/main.yaml         # Helm install, license secret,
        │   │                           #   jq-based NodePort patch to 32443
        │   └── templates/
        │       └── teleport-values.yaml.j2
        ├── teleport-oidc/              # AWS OIDC integration via tctl
        ├── teleport-sso/               # Okta SAML connector bootstrap via tctl
        ├── teleport-rbac/              # Machine ID bot + rbac-manager role + GitHub
        │                               #   OIDC join token + RBAC role templates
        └── teleport-node/              # AWS IAM join token for ssh-node-1
```

---

## CI/CD Pipeline

Single GitHub Actions workflow (`.github/workflows/terraform.yml`) with three jobs:

### `plan` — runs on every PR and push to `main`
- Terraform init, validate, plan
- Uploads plan artifact keyed by git SHA
- Posts formatted plan output as a PR comment with status icon
- Triggers on changes to `terraform/**` or `ansible/**`

### `apply` — runs on merge to `main`, gated by `production` environment approval
Two phases in one job:
1. **Terraform** — downloads plan artifact, applies all infrastructure
2. **Teleport RBAC** — authenticates via Machine ID (GitHub OIDC → `tbot` → X.509 cert, no static secrets), applies all RBAC resources via `tctl`. Skips gracefully with a warning if the cluster is not yet reachable (e.g. first apply before cloud-init completes).

### `destroy` — manual `workflow_dispatch` only, gated by `production` environment approval

---

## Playbook Sequence (cloud-init on master)

| Step | Playbook | Description |
|---|---|---|
| 1 | `k8s-setup.yaml` | containerd.io 2.x, kubeadm/kubelet/kubectl 1.35.2, swap off, sysctl |
| 2 | `k8s-master.yaml` | kubeadm init, Calico CNI v3.29, kubeconfig |
| 3 | `k8s-workers.yaml` | Dynamic kubeadm join from master |
| 4 | `postgres.yaml` | Self-signed CA + server + client cert generation via openssl on master, postgres-certs Secret, admin secret, Deployment, Service, client certs copied to teleport namespace |
| 5 | `teleport.yaml` | Helm install, license secret, NodePort patched to 32443 via jq |
| 6 | `teleport-oidc.yaml` | AWS OIDC integration resource via tctl |
| 7 | `teleport-sso.yaml` | Okta SAML connector bootstrap via tctl |
| 8 | `teleport-rbac.yaml` | rbac-manager role, Machine ID bot, GitHub OIDC join token |
| 9 | `teleport-node.yaml` | AWS IAM join token for ssh-node-1 auto-enrollment |

---

## PostgreSQL — In-Cluster with mTLS

PostgreSQL runs as a Kubernetes Deployment in the `postgres` namespace using the `ateleport/test:postgres-wal2json-17-1` image (PostgreSQL 17 + wal2json for logical replication).

### Certificate authentication

The `postgres` Ansible role generates all certificates on the master node using `openssl`:

| Certificate | CN | Purpose |
|---|---|---|
| CA | `postgres-ca` | Signs all other certs |
| Server | `postgres-service.postgres.svc.cluster.local` | Used by the postgres pod |
| Client | `teleport` | Used by Teleport auth pod — CN must match PostgreSQL username |

All certs are stored in the `postgres-certs` Secret in the `postgres` namespace. The client cert/key/CA are copied to `teleport-pg-client-certs` in the `teleport` namespace and mounted at `/pg-certs/` in the Teleport auth pod.

### pg_hba.conf

```
# Teleport user: client certificate required (CN=teleport)
hostssl all    teleport all  cert clientcert=verify-full
# Admin user: password (localhost only, bootstrap/maintenance)
host    all    postgres 127.0.0.1/32  md5
# Deny all other connections
host    all    all      all           reject
```

### Connection strings (in Teleport Helm values)

```
postgresql://teleport@postgres-service.postgres.svc.cluster.local:5432/teleport_backend
  ?sslmode=verify-full
  &sslcert=/pg-certs/client.crt
  &sslkey=/pg-certs/client.key
  &sslrootcert=/pg-certs/ca.crt
```

No passwords anywhere in the data path.

---

## Teleport RBAC

All roles managed as Jinja2 templates in `ansible/roles/teleport-rbac/templates/`, applied by GitHub Actions Machine ID after each merge to `main`.

| Role | Description |
|---|---|
| `base` | Zero standing privilege. Can request `ssh-access` (auto-approved), `kube-access` and `ssh-root-access` (manual approval) |
| `kube-access` | Kubernetes access scoped to `{{internal.team}}` namespace derived from Okta group |
| `ssh-access` | SSH to nodes labeled `team={{internal.team}}`, login `ubuntu` only, no root, 8h TTL |
| `ssh-root-access` | SSH + sudo to team-labeled nodes, 4h TTL |
| `auto-approver` | Machine ID bot role — auto-approves pure `ssh-access` requests |
| `rbac-manager` | Machine ID bot role — `tctl` permissions for roles/SAML/login_rule only |

**Login rule:** Okta `groups` attribute → `internal.team` trait, which drives both K8s namespace scoping and EC2 node label scoping.

**Machine ID flow:**
```
GitHub Actions runner
  └── tbot (ephemeral, credential-ttl: 10m)
        └── GitHub OIDC JWT → Teleport X.509 cert (via rbac-github-bot-token)
              └── tctl applies RBAC resources to grant-tam-teleport.gvteleport.com:443
```

---

## ssh-node-1

A standalone `t2.small` Ubuntu EC2 instance that auto-enrolls into Teleport using the AWS IAM join method — no static tokens, no secrets.

**How it works:**
1. Node boots, Teleport agent starts with `join_method: iam`
2. Agent calls `sts:GetCallerIdentity` using its EC2 instance IAM role
3. AWS returns a signed response proving the node's identity
4. Teleport verifies the signature and checks the IAM role ARN matches `ssh-node-iam-token` allow rules
5. Node appears in `tsh ls` with labels `team=platform`, `env=demo`

Users with the `ssh-access` role whose Okta group maps to `platform` can connect via `tsh ssh ubuntu@ssh-node-1`.

---

## Prerequisites

### 1. AWS Bootstrap Resources

```bash
# S3 bucket for Terraform state
aws s3api create-bucket \
  --bucket <your-tf-state-bucket> \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

aws s3api put-bucket-versioning \
  --bucket <your-tf-state-bucket> \
  --versioning-configuration Status=Enabled

# DynamoDB table for state locking
aws dynamodb create-table \
  --table-name <your-tf-lock-table> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-west-2
```

### 2. GitHub Repository Secrets

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `AWS_SESSION_TOKEN` | Session token (required for STS/SSO credentials) |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform remote state |
| `TF_LOCK_TABLE` | DynamoDB table name for state locking |
| `CUSTOMER_IP` | Your public IP in CIDR notation (e.g. `136.25.0.29/32`) |
| `TELEPORT_LICENSE` | Teleport Enterprise license file contents |
| `AWS_OIDC_ARN` | ARN of the IAM role for Teleport AWS OIDC integration |
| `OKTA_METADATA_URL` | SAML metadata URL from Okta app Sign On tab |
| `OKTA_GROUPS_EDITOR` | Okta group name mapped to Teleport `editor` role |
| `OKTA_GROUPS_ACCESS` | Okta group name mapped to Teleport `access` role |

> **Note:** `DB_PASSWORD` is no longer required. PostgreSQL uses certificate authentication — no passwords are stored or passed anywhere.

### 3. GitHub Environment

Create a **`production`** environment under **Settings → Environments** with required reviewers to gate all `apply` and `destroy` operations.

### 4. Okta Prerequisites

Create a SAML 2.0 app in Okta:
- **Single sign-on URL**: `https://grant-tam-teleport.gvteleport.com/v1/webapi/saml/acs/okta`
- **Audience URI**: `https://grant-tam-teleport.gvteleport.com/v1/webapi/saml/acs/okta`
- **Name ID format**: `EmailAddress`
- **Attribute**: `username` → `user.login`
- **Group attribute**: `groups`, filter `Matches regex: .*`
- Copy the **Metadata URL** from Sign On tab → `OKTA_METADATA_URL` secret

---

## Deploying

### Via Pull Request (recommended)

```bash
git checkout -b your-feature-branch
# make changes to terraform/ or ansible/
git add . && git commit -m "your change"
git push origin your-feature-branch
# Open PR on GitHub → plan runs automatically and posts output to PR
# Merge PR → apply job starts, pauses for production environment approval
# Approve → Terraform applies infrastructure, then RBAC is applied via Machine ID
```

### Manual trigger

**Actions → Deploy - K8s Cluster + Teleport RBAC → Run workflow**
- `plan` — preview changes only
- `apply` — apply infrastructure + RBAC (gated by production approval)
- `destroy` — tear down all resources (gated by production approval)

---

## Accessing the Cluster

```bash
# Get master public IP
cd terraform && terraform output master_public_ip

# Download SSH key from Actions → your run → Artifacts → grant-tam-key
ssh -i grant-tam-key.pem ubuntu@<master_public_ip>

# Verify K8s cluster
kubectl get nodes
kubectl get pods -A

# Check Teleport status
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') \
  -- tctl status

# Check PostgreSQL
kubectl exec -n postgres \
  $(kubectl get pod -n postgres -l app=postgres \
    -o jsonpath='{.items[0].metadata.name}') \
  -- pg_isready -U postgres
```

---

## Teleport Access

Teleport is accessible at `https://grant-tam-teleport.gvteleport.com`.

### Login

Users authenticate via Okta SAML SSO. Navigate to the URL and click **Login with Okta**.

### Create a local admin user (emergency break-glass)

```bash
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') \
  -- tctl users add admin --roles=editor,access --logins=ubuntu
```

### Verify integrations

```bash
AUTH_POD=$(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
  -o jsonpath='{.items[0].metadata.name}')

# AWS OIDC integration
kubectl exec -n teleport $AUTH_POD -- tctl get integration/grant-tam-teleport-integration

# Okta SAML connector
kubectl exec -n teleport $AUTH_POD -- tctl get saml/okta

# RBAC roles
kubectl exec -n teleport $AUTH_POD -- \
  tctl get roles/base roles/kube-access roles/ssh-access roles/ssh-root-access
```

---

## Tearing Down

### Via GitHub Actions (recommended)

**Actions → Deploy - K8s Cluster + Teleport RBAC → Run workflow → `destroy`**

### Manually

```bash
cd terraform
terraform destroy -auto-approve \
  -var="training_prefix=grant-tam" \
  -var="customer_ip=136.25.0.29/32" \
  -var="tf_state_bucket=<your-tf-state-bucket>" \
  -var="teleport_license=<your-license>" \
  -var="aws_oidc_role_arn=<your-oidc-role-arn>" \
  -var="okta_metadata_url=<your-okta-metadata-url>" \
  -var="okta_groups_editor=<editor-group>" \
  -var="okta_groups_access=<access-group>"
```

---

## Notes

- `grant-tam-key.pem` is written to `terraform/` after apply and is listed in `.gitignore` — never commit it
- Terraform state is stored in S3 with DynamoDB locking — do not use local state in shared environments
- AWS session tokens expire — refresh `AWS_SESSION_TOKEN` in GitHub Secrets before running if credentials have expired
- Monitor cloud-init progress on master: `sudo tail -f /var/log/cloud-init-k8s.log`
- PostgreSQL uses certificate authentication — no passwords stored anywhere in the running system
- NodePort `32443` is pinned via `kubectl patch` using `jq` to locate the correct port by name — the Teleport Helm chart does not support setting `nodePort` via values
- Teleport ACME/Let's Encrypt TLS requires DNS to be configured before certificates can be issued
- The RBAC GitHub Actions workflow skips gracefully if the cluster is not reachable on first apply — re-run after cloud-init completes
