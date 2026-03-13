# tam-cert-noeks

Terraform + Ansible automation to deploy a production-ready 3-node Kubernetes cluster on AWS EC2 with Teleport Enterprise 18.7.1, AWS RDS PostgreSQL 17.6, MetalLB, and Okta SAML SSO. All infrastructure is provisioned via Terraform, cluster bootstrapping is handled via cloud-init on the master node, and all Kubernetes and Teleport configuration is managed by Ansible roles pulled directly from this repository.

---

## Repository Structure

```
tam-cert-noeks/
├── .github/
│   └── workflows/
│       └── terraform.yml                         # GitHub Actions CI/CD pipeline
├── terraform/
│   ├── backend.tf                                # S3 remote state (values injected at runtime)
│   ├── main.tf                                   # EC2, VPC, networking, IAM, cloud-init
│   ├── rds.tf                                    # RDS PostgreSQL 17.6, S3 session recordings,
│   │                                             #   Secrets Manager (DB password + license)
│   ├── nlb.tf                                    # AWS NLB routing external traffic to Teleport
│   ├── route53.tf                                # DNS CNAME records for Teleport cluster
│   └── teleport-oidc.tf                          # Teleport AWS OIDC integration IAM resources
└── ansible/
    ├── ansible.cfg                               # Ansible configuration
    ├── hosts                                     # Inventory: master (172.49.20.230),
    │                                             #   node1 (172.49.20.231), node2 (172.49.20.232)
    ├── site.yaml                                 # Master playbook (runs all roles in order)
    ├── k8s-setup.yaml                            # Playbook: common Kubernetes node setup
    ├── k8s-master.yaml                           # Playbook: control plane initialization
    ├── k8s-workers.yaml                          # Playbook: worker node join
    ├── metallb.yaml                              # Playbook: MetalLB bare-metal load balancer
    ├── teleport.yaml                             # Playbook: Teleport Enterprise deployment
    ├── teleport-oidc.yaml                        # Playbook: AWS OIDC integration
    ├── teleport-sso.yaml                         # Playbook: Okta SAML SSO connector
    └── roles/
        ├── k8s-setup/
        │   ├── defaults/main.yaml                # k8s_version and k8s_keyring variables
        │   └── tasks/main.yaml                   # containerd.io 2.x, kubeadm 1.35.2,
        │                                         #   kubelet, kubectl, swap/sysctl config
        ├── k8s-master/
        │   └── tasks/main.yaml                   # kubeadm init, Calico CNI v3.29,
        │                                         #   kubeconfig, join command generation
        ├── k8s-workers/
        │   └── tasks/main.yaml                   # Dynamic kubeadm join from master,
        │                                         #   idempotency check via kubelet.conf
        ├── metallb/
        │   └── tasks/main.yaml                   # MetalLB Helm install, IPAddressPool
        │                                         #   172.49.20.100-150, L2Advertisement
        ├── teleport/
        │   ├── tasks/main.yaml                   # License secret, PG credentials secret,
        │   │                                     #   Helm install, NodePort pin (32443/32444)
        │   └── templates/
        │       └── teleport-values.yaml.j2       # Teleport Helm values: enterprise, PostgreSQL
        │                                         #   backend, S3 sessions, ACME TLS, NodePort
        ├── teleport-oidc/
        │   └── tasks/main.yaml                   # AWS OIDC integration resource via tctl,
        │                                         #   reads role ARN from .teleport-env
        └── teleport-sso/
            └── tasks/main.yaml                   # Okta SAML connector via tctl,
                                                  #   sets Okta as default auth connector
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
  ├── node1   172.49.20.231   Teleport proxy pod
  └── node2   172.49.20.232   worker
        │
        ▼
  MetalLB (L2, 172.49.20.100-150)
  Teleport Enterprise 18.7.1
        │
        ├── PostgreSQL backend  ──►  RDS PostgreSQL 17.6 (grant-tam-pg-1)
        ├── Session recordings  ──►  S3 (grant-tam-teleport-sessions)
        ├── AWS OIDC            ──►  IAM role (grant-tam-oidc-role)
        └── SSO                 ──►  Okta SAML
```

---

## Prerequisites

### 1. AWS Bootstrap Resources

The S3 backend and DynamoDB lock table must exist before the first pipeline run:

```bash
# S3 bucket for Terraform state
aws s3api create-bucket \
  --bucket <your-tf-state-bucket> \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

aws s3api put-bucket-versioning \
  --bucket <your-tf-state-bucket> \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket <your-tf-state-bucket> \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# DynamoDB table for state locking
aws dynamodb create-table \
  --table-name <your-tf-lock-table> \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-west-2
```

### 2. GitHub Repository Secrets

Navigate to **Settings → Secrets and variables → Actions** and add:

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `AWS_SESSION_TOKEN` | Session token (required for STS/SSO credentials) |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform remote state |
| `TF_LOCK_TABLE` | DynamoDB table name for state locking |
| `CUSTOMER_IP` | Your public IP in CIDR notation (e.g. `136.25.0.29/32`) |
| `DB_PASSWORD` | Master password for RDS PostgreSQL |
| `TELEPORT_LICENSE` | Teleport Enterprise license file contents |
| `AWS_OIDC_ARN` | ARN of the IAM role for Teleport AWS OIDC integration |
| `OKTA_METADATA_URL` | SAML metadata URL from Okta app Sign On tab |
| `OKTA_GROUPS_EDITOR` | Okta group name mapped to Teleport `editor` role |
| `OKTA_GROUPS_ACCESS` | Okta group name mapped to Teleport `access` role |

### 3. GitHub Environment

Create a **`production`** environment under **Settings → Environments** and add required reviewers to gate all `apply` and `destroy` operations behind manual approval.

### 4. Okta Prerequisites

Before deploying, create a SAML 2.0 app in Okta with:
- **Single sign-on URL**: `https://grant-tam-teleport.gvteleport.com/v1/webapi/saml/acs/okta`
- **Audience URI**: `https://grant-tam-teleport.gvteleport.com/v1/webapi/saml/acs/okta`
- **Name ID format**: `EmailAddress`
- **Attribute**: `username` → `user.login`
- **Group attribute**: `groups`, filter `Matches regex: .*`
- Copy the **Metadata URL** from the Sign On tab → add as `OKTA_METADATA_URL` secret

---

## Deploying via GitHub Actions

### Automatic deploy on push to `main`

Any push to `main` that modifies files under `terraform/` triggers plan then apply:

```bash
git push origin main
```

### Manual trigger

1. **Actions → Terraform - K8s Cluster → Run workflow**
2. Select the action:
   - **`plan`** — preview changes, no resources created
   - **`apply`** — create or update all infrastructure
   - **`destroy`** — tear down all resources
3. Click **Run workflow**

### Pull request plan preview

Open a PR targeting `main` — the workflow runs a plan and posts the output as a PR comment.

---

## How It Works

### Infrastructure (Terraform)

1. Provisions VPC, subnet (us-west-2a), internet gateway, security groups
2. Generates SSH key pair, writes private key as a GitHub Actions artifact
3. Stores RDS password and Teleport license in **AWS Secrets Manager**
4. Provisions **RDS PostgreSQL 17.6** (`grant-tam-pg-1`) with `rds.logical_replication=1`
5. Creates **S3 bucket** for Teleport session recordings
6. Provisions an **AWS NLB** targeting all three node IPs on NodePort `32443` with health checks on `32444`
7. Creates **Route53 CNAME** records for `grant-tam-teleport.gvteleport.com` and `*.grant-tam-teleport.gvteleport.com`
8. Registers Teleport as an **AWS IAM OIDC provider** reference for the OIDC integration
9. Attaches an **IAM instance profile** to all EC2 nodes granting Secrets Manager read access
10. Launches 3 × `t3.medium` EC2 instances running Ubuntu 24.04 LTS

### Bootstrap (cloud-init)

The master node runs at first boot:
1. Waits for `apt` lock, sets kernel modules and sysctl params
2. Installs Ansible, AWS CLI v2, and minimal dependencies
3. Writes `.teleport-env` with all runtime variables (RDS address, secret names, Okta config, OIDC role ARN)
4. Fetches all Ansible playbooks and roles from this GitHub repository
5. Runs playbooks in sequence

Worker nodes set kernel params and install minimal dependencies, then wait for Ansible from the master.

### Playbook Sequence

| Order | Playbook | Description |
|---|---|---|
| 1 | `k8s-setup.yaml` | containerd.io 2.x, kubeadm/kubelet/kubectl 1.35.2, swap off, sysctl |
| 2 | `k8s-master.yaml` | kubeadm init, Calico CNI, kubeconfig |
| 3 | `k8s-workers.yaml` | Dynamic kubeadm join from master |
| 4 | `metallb.yaml` | MetalLB Helm install, IP pool `172.49.20.100-150` |
| 5 | `teleport.yaml` | Teleport Enterprise Helm install, license secret, PostgreSQL backend |
| 6 | `teleport-oidc.yaml` | AWS OIDC integration resource in Teleport |
| 7 | `teleport-sso.yaml` | Okta SAML connector, set as default auth |

---

## Accessing the Cluster

Get the master's public IP from Terraform outputs:

```bash
cd terraform
terraform output master_public_ip
```

Download the SSH key from GitHub Actions:
**Actions → your run → Artifacts → grant-tam-key**

SSH into the master:

```bash
ssh -i grant-tam-key.pem ubuntu@<master_public_ip>
```

Verify cluster health:

```bash
kubectl get nodes
kubectl get pods -A
```

Check Teleport status:

```bash
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') \
  -- tctl status
```

---

## Teleport

Teleport is accessible at `https://grant-tam-teleport.gvteleport.com`.

### Login

Users authenticate via Okta SSO. Navigate to the URL and click **Login with Okta**.

### Create a local admin user (emergency access)

```bash
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') \
  -- tctl users add admin --roles=editor,access --logins=ubuntu
```

### Verify integrations

```bash
# AWS OIDC integration
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') \
  -- tctl get integration/grant-tam-teleport-integration

# Okta SAML connector
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
    -o jsonpath='{.items[0].metadata.name}') \
  -- tctl get saml/okta
```

---

## Tearing Down

### Via GitHub Actions (recommended)

1. **Actions → Terraform - K8s Cluster → Run workflow → `destroy`**

### Manually

```bash
cd terraform
terraform destroy -auto-approve \
  -var="training_prefix=grant-tam" \
  -var="customer_ip=136.25.0.29/32" \
  -var="tf_state_bucket=<your-tf-state-bucket>" \
  -var="db_password=<your-db-password>" \
  -var="teleport_license=<your-license>" \
  -var="aws_oidc_role_arn=<your-oidc-role-arn>" \
  -var="okta_metadata_url=<your-okta-metadata-url>" \
  -var="okta_groups_editor=<editor-group>" \
  -var="okta_groups_access=<access-group>"
```

---

## Manual Terraform Usage

### Setup

```bash
cd terraform

terraform init \
  -backend-config="bucket=<your-tf-state-bucket>" \
  -backend-config="key=tam-cert-noeks/terraform.tfstate" \
  -backend-config="region=us-west-2" \
  -backend-config="encrypt=true" \
  -backend-config="dynamodb_table=<your-tf-lock-table>"
```

### Retrieve SSH Key After Apply

```bash
terraform output -raw private_key_pem > grant-tam-key.pem
chmod 600 grant-tam-key.pem
```

---

## Notes

- `grant-tam-key.pem` is written to `terraform/` after apply and is listed in `.gitignore` — never commit it
- Terraform state is stored in S3 with DynamoDB locking — do not use local state in shared environments
- AWS session tokens expire — refresh `AWS_SESSION_TOKEN` in GitHub Secrets before running if credentials have expired
- Monitor cloud-init progress on the master: `sudo tail -f /var/log/cloud-init-k8s.log`
- The RDS instance requires `rds.logical_replication=1` — handled automatically by Terraform on first provision
- NodePort `32443` and healthCheckNodePort `32444` are pinned in the Helm values to survive destroy/apply cycles
- Teleport ACME/Let's Encrypt TLS requires DNS to be configured before certificates can be issued
