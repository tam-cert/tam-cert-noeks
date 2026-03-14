# tam-cert-noeks

Terraform + Ansible automation to deploy a production-ready 3-node Kubernetes cluster on AWS EC2 with Teleport Enterprise 18.7.1, AWS RDS PostgreSQL 17.6, and Okta SAML SSO. All infrastructure is provisioned via Terraform, cluster bootstrapping is handled via cloud-init on the master node, and all Kubernetes and Teleport configuration is managed by Ansible roles pulled directly from this repository.

---

## Repository Structure

```
tam-cert-noeks/
├── .github/
│   └── workflows/
│       └── terraform.yml                         # Unified CI/CD: plan + apply (infra + RBAC) + destroy
├── terraform/
│   ├── backend.tf                                # S3 remote state (values injected at runtime)
│   ├── main.tf                                   # EC2, VPC, networking, IAM, cloud-init,
│   │                                             #   RDS IAM user bootstrap in userdata
│   ├── rds.tf                                    # RDS PostgreSQL 17.6, S3 session recordings,
│   │                                             #   Secrets Manager (license), IAM auth enabled
│   ├── nlb.tf                                    # AWS NLB routing external traffic to Teleport
│   ├── route53.tf                                # DNS CNAME records for Teleport cluster
│   ├── teleport-oidc.tf                          # Teleport AWS OIDC integration IAM resources
│   └── ssh-node.tf                               # ssh-node-1: t2.small, dedicated IAM role,
│                                                 #   AWS IAM auto-enrollment into Teleport
└── ansible/
    ├── ansible.cfg                               # Ansible configuration
    ├── hosts                                     # Inventory: master (172.49.20.230),
    │                                             #   node1 (172.49.20.231), node2 (172.49.20.232)
    ├── site.yaml                                 # Master playbook (runs all roles in order)
    ├── k8s-setup.yaml                            # Playbook: common Kubernetes node setup
    ├── k8s-master.yaml                           # Playbook: control plane initialization
    ├── k8s-workers.yaml                          # Playbook: worker node join
    ├── teleport.yaml                             # Playbook: Teleport Enterprise deployment
    ├── teleport-oidc.yaml                        # Playbook: AWS OIDC integration
    ├── teleport-sso.yaml                         # Playbook: Okta SAML SSO connector (bootstrap)
    ├── teleport-rbac.yaml                        # Playbook: Machine ID bot + RBAC bootstrap
    ├── teleport-node.yaml                        # Playbook: IAM join token for ssh-node-1
    └── roles/
        ├── k8s-setup/                            # containerd.io 2.x, kubeadm 1.35.2,
        │                                         #   kubelet, kubectl, swap/sysctl config
        ├── k8s-master/                           # kubeadm init, Calico CNI v3.29,
        │                                         #   kubeconfig, join command generation
        ├── k8s-workers/                          # Dynamic kubeadm join,
        │                                         #   idempotency check via kubelet.conf
        ├── teleport/                             # Helm install, license secret,
        │                                         #   IAM DB user via generate-db-auth-token
        ├── teleport-oidc/                        # AWS OIDC integration resource via tctl
        ├── teleport-sso/                         # Okta SAML connector bootstrap via tctl
        ├── teleport-rbac/                        # rbac-manager role, Machine ID bot,
        │                                         #   GitHub OIDC join token, RBAC templates
        └── teleport-node/                        # AWS IAM join token for ssh-node-1
```

---

## Architecture

```
Internet
    │
    ▼
AWS NLB (grant-tam-teleport.gvteleport.com)
    │  port 443 → NodePort 32443
    │  health check → healthCheckNodePort 32444
    ▼
Kubernetes Nodes (t3.medium × 3, us-west-2a)
  ├── master  172.49.20.230   control-plane + Teleport auth
  ├── node1   172.49.20.231   worker
  └── node2   172.49.20.232   worker
        │
        ▼
  Teleport Enterprise 18.7.1
        │
        ├── PostgreSQL backend  ──►  RDS PostgreSQL 17.6 (IAM auth, no passwords)
        ├── Session recordings  ──►  S3 (grant-tam-teleport-sessions)
        ├── AWS OIDC            ──►  IAM role (grant-tam-oidc-role)
        └── SSO                 ──►  Okta SAML

ssh-node-1 (t2.small, us-west-2a)
  └── Teleport SSH node, auto-enrolls via AWS IAM join method
      team=platform label → scoped by RBAC ssh-access / ssh-root-access roles
```

---

## CI/CD Pipeline

Single GitHub Actions workflow (`.github/workflows/terraform.yml`) with three jobs:

### `plan` — runs on every PR and push to `main`
- Terraform init, validate, plan
- Uploads plan artifact (`tfplan-<sha>`)
- Posts plan output as a PR comment with status icon
- Fails fast if plan errors

### `apply` — runs on merge to `main`, gated by `production` environment approval
Two phases in one job:
1. **Terraform** — downloads plan artifact, applies infrastructure
2. **Teleport RBAC** — authenticates via Machine ID (GitHub OIDC → tbot → X.509), applies all RBAC resources via `tctl`. Skipped with a warning if the cluster isn't reachable yet.

### `destroy` — manual `workflow_dispatch` only, gated by `production` environment approval

---

## Teleport RBAC

All roles managed as Jinja2 templates in `ansible/roles/teleport-rbac/templates/`, applied by GitHub Actions Machine ID (no static secrets).

| Role | Description |
|---|---|
| `base` | Zero standing privilege. Requests `ssh-access` (auto-approved), `kube-access` and `ssh-root-access` (manual approval) |
| `kube-access` | Kubernetes access scoped to `{{internal.team}}` namespace from Okta group |
| `ssh-access` | SSH to nodes labeled `team={{internal.team}}`, login `ubuntu` only |
| `ssh-root-access` | SSH + sudo to team nodes, 4h TTL |
| `rbac-manager` | Machine ID bot role — `tctl` permissions for RBAC/SAML/login_rule only |

**Login rule:** Okta `groups` attribute → `internal.team` trait (drives namespace + node label scoping)

---

## Prerequisites

### 1. AWS Bootstrap Resources

```bash
aws s3api create-bucket \
  --bucket <your-tf-state-bucket> \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

aws s3api put-bucket-versioning \
  --bucket <your-tf-state-bucket> \
  --versioning-configuration Status=Enabled

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
| `DB_PASSWORD` | Master password for RDS PostgreSQL (bootstrap only, never used by Teleport) |
| `TELEPORT_LICENSE` | Teleport Enterprise license file contents |
| `AWS_OIDC_ARN` | ARN of the IAM role for Teleport AWS OIDC integration |
| `OKTA_METADATA_URL` | SAML metadata URL from Okta app Sign On tab |
| `OKTA_GROUPS_EDITOR` | Okta group name mapped to Teleport `editor` role |
| `OKTA_GROUPS_ACCESS` | Okta group name mapped to Teleport `access` role |

### 3. GitHub Environment

Create a **`production`** environment under **Settings → Environments** with required reviewers to gate all `apply` and `destroy` operations.

### 4. Okta Prerequisites

Create a SAML 2.0 app in Okta:
- **Single sign-on URL**: `https://grant-tam-teleport.gvteleport.com/v1/webapi/saml/acs/okta`
- **Audience URI**: `https://grant-tam-teleport.gvteleport.com/v1/webapi/saml/acs/okta`
- **Name ID format**: `EmailAddress`
- **Attribute**: `username` → `user.login`
- **Group attribute**: `groups`, filter `Matches regex: .*`
- Copy **Metadata URL** from Sign On tab → `OKTA_METADATA_URL` secret

---

## Deploying

### Via Pull Request (recommended)

```bash
git checkout -b your-feature-branch
# make changes to terraform/ or ansible/
git add . && git commit -m "your change"
git push origin your-feature-branch
# open PR → plan runs automatically and posts to PR
# merge PR → apply runs after production environment approval
```

### Manual trigger

**Actions → Deploy - K8s Cluster + Teleport RBAC → Run workflow**
- `plan` — preview changes only
- `apply` — apply infrastructure + RBAC
- `destroy` — tear down all resources

---

## Playbook Sequence (cloud-init on master)

| Order | Playbook | Description |
|---|---|---|
| 1 | `k8s-setup.yaml` | containerd.io 2.x, kubeadm/kubelet/kubectl 1.35.2, swap off, sysctl |
| 2 | `k8s-master.yaml` | kubeadm init, Calico CNI, kubeconfig |
| 3 | `k8s-workers.yaml` | Dynamic kubeadm join from master |
| 4 | `teleport.yaml` | Teleport Enterprise Helm install, license secret |
| 5 | `teleport-oidc.yaml` | AWS OIDC integration resource in Teleport |
| 6 | `teleport-sso.yaml` | Okta SAML connector bootstrap |
| 7 | `teleport-rbac.yaml` | Machine ID bot + rbac-manager role + GitHub join token |
| 8 | `teleport-node.yaml` | AWS IAM join token for ssh-node-1 auto-enrollment |

---

## Accessing the Cluster

```bash
# Get master public IP
cd terraform && terraform output master_public_ip

# Download SSH key from Actions → your run → Artifacts → grant-tam-key
ssh -i grant-tam-key.pem ubuntu@<master_public_ip>

# Verify cluster
kubectl get nodes
kubectl get pods -A

# Check Teleport status
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') \
  -- tctl status
```

---

## Notes

- `grant-tam-key.pem` is written to `terraform/` after apply and is in `.gitignore` — never commit it
- Terraform state is stored in S3 with DynamoDB locking
- AWS session tokens expire — refresh `AWS_SESSION_TOKEN` before running if credentials have expired
- Monitor cloud-init on master: `sudo tail -f /var/log/cloud-init-k8s.log`
- RDS uses IAM authentication — no passwords stored anywhere in the running system
- NodePorts `32443` and `32444` are pinned in Helm values to survive destroy/apply cycles
- Teleport RBAC workflow requires the cluster to be up — skipped with a warning on first apply
