# tam-cert-noeks

Terraform + Ansible automation to deploy a 3-node Kubernetes cluster (1 master, 2 workers) on AWS EC2 with Teleport 18.7.1 and an AWS RDS PostgreSQL 17.6 backend. Infrastructure is provisioned via Terraform, cluster bootstrapping is handled via cloud-init on the master node, and Kubernetes/Teleport configuration is managed by Ansible roles pulled directly from this repository.

---

## Repository Structure

```
tam-cert-noeks/
├── .github/
│   └── workflows/
│       └── terraform.yml                        # GitHub Actions CI/CD pipeline
├── terraform/
│   ├── main.tf                                  # EC2, VPC, networking, IAM, cloud-init
│   ├── rds.tf                                   # RDS PostgreSQL, Secrets Manager, subnet group
│   └── backend.tf                               # S3 remote state (values injected at runtime)
└── ansible/
    ├── ansible.cfg                              # Ansible configuration
    ├── hosts                                    # Inventory (master + workers)
    ├── site.yaml                                # Master playbook (all roles in order)
    ├── k8s-setup.yaml                           # Playbook: common node setup
    ├── k8s-master.yaml                          # Playbook: master initialization
    ├── k8s-workers.yaml                         # Playbook: worker join
    ├── teleport.yaml                            # Playbook: Teleport deployment
    └── roles/
        ├── k8s-setup/
        │   ├── defaults/main.yaml               # k8s_version, k8s_keyring vars
        │   └── tasks/main.yaml                  # containerd.io, kubeadm, kubelet, kubectl
        ├── k8s-master/
        │   └── tasks/main.yaml                  # kubeadm init, Calico CNI
        ├── k8s-workers/
        │   └── tasks/main.yaml                  # kubeadm join
        └── teleport/
            ├── tasks/main.yaml                  # Helm install of Teleport
            └── templates/
                └── teleport-values.yaml.j2      # Teleport Helm values template
```

---

## Prerequisites

### 1. AWS Bootstrap Resources

The S3 backend and DynamoDB lock table must exist before the first pipeline run. Create them once with the AWS CLI:

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
| `AWS_ACCESS_KEY_ID` | IAM access key with EC2, VPC, RDS, IAM, and Secrets Manager permissions |
| `AWS_SECRET_ACCESS_KEY` | Corresponding IAM secret key |
| `AWS_SESSION_TOKEN` | Session token (required for temporary/STS credentials) |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform remote state |
| `TF_LOCK_TABLE` | DynamoDB table name for state locking |
| `CUSTOMER_IP` | Your public IP in CIDR notation (e.g. `136.25.0.29/32`) |
| `DB_PASSWORD` | Master password for the RDS PostgreSQL instance |
| `TELEPORT_LICENSE` | Teleport Enterprise license file contents (from teleport.sh dashboard) |

### 3. GitHub Environment (Recommended)

Create a **`production`** environment under **Settings → Environments** and add required reviewers to gate all `apply` and `destroy` operations behind manual approval.

---

## Deploying via GitHub Actions

### Automatic deploy on push to `main`

Any push to `main` that modifies files under `terraform/` triggers a plan followed by an automatic apply:

```bash
git push origin main
```

### Manual trigger

1. Navigate to **Actions → Terraform - K8s Cluster → Run workflow**
2. Select the desired action:
   - **`plan`** — preview infrastructure changes, no resources created
   - **`apply`** — create or update all infrastructure
   - **`destroy`** — tear down all resources
3. Click **Run workflow**

### Pull request plan preview

Open a pull request targeting `main`. The workflow runs a plan automatically and posts the full output as a comment on the PR for review before merging.

---

## How It Works

### Infrastructure (Terraform)

1. Provisions a VPC, subnet (us-west-2a), internet gateway, route table, and security groups
2. Generates an SSH key pair and writes the private key to S3 as an Actions artifact
3. Stores the RDS master password in **AWS Secrets Manager**
4. Provisions an **RDS PostgreSQL 17.6** instance (`grant-tam-pg-1`) with `rds.logical_replication=1` enabled (required by Teleport's PostgreSQL backend)
5. Attaches an **IAM instance profile** to all EC2 nodes granting read access to the DB password secret
6. Launches 3 x `t3.medium` EC2 instances (1 master, 2 workers) running Ubuntu 24.04 LTS

### Bootstrap (cloud-init)

The master node runs a cloud-init script at first boot that:

1. Waits for `apt` lock to be released by `unattended-upgrades`
2. Loads kernel modules (`overlay`, `br_netfilter`) and sets sysctl params for Kubernetes networking
3. Installs `ansible` and minimal dependencies
4. Writes a `.teleport-env` file containing `RDS_ADDRESS` and `DB_SECRET_NAME` (injected by Terraform at provision time)
5. Pulls all Ansible playbooks and roles from this GitHub repository
6. Runs `k8s-setup.yaml` → `k8s-master.yaml` → `k8s-workers.yaml` in sequence

Worker nodes run a minimal cloud-init that sets kernel params and installs basic dependencies, then wait for the master to join them via Ansible.

### Kubernetes (Ansible)

- **`k8s-setup`** — installs `containerd.io` 2.x from Docker's apt repo, configures `SystemdCgroup=true`, installs kubeadm/kubelet/kubectl 1.35.2, disables swap, sets kernel params
- **`k8s-master`** — runs `kubeadm init` with Calico CNI (`192.168.0.0/16` pod CIDR), generates join command
- **`k8s-workers`** — fetches a fresh join command from the master and joins each worker node

### Teleport (Ansible + Helm)

- **`teleport`** role sources `.teleport-env`, fetches the DB password from AWS Secrets Manager via the AWS CLI, renders `teleport-values.yaml.j2` with the correct RDS connection strings, and deploys Teleport 18.7.1 via Helm
- Teleport cluster name: `grant-tam-teleport.gvteleport.com`
- Backend: RDS PostgreSQL (`teleport_backend` + `teleport_audit` databases)
- TLS: ACME / Let's Encrypt

---

## Deploying Teleport

After the cluster is up, SSH into the master and run the Teleport playbook:

```bash
ssh -i grant-tam-key.pem ubuntu@<master_public_ip>
ansible-playbook ~/ansible/teleport.yaml -i ~/ansible/hosts --become
```

The playbook automatically reads `RDS_ADDRESS` and `DB_SECRET_NAME` from `~/.teleport-env` and fetches the DB password from AWS Secrets Manager — no manual variable passing required.

Verify the deployment:

```bash
kubectl get pods -n teleport
kubectl get svc -n teleport
```

### DNS Configuration

Point `grant-tam-teleport.gvteleport.com` to the external LoadBalancer address:

```bash
kubectl get svc -n teleport
# Note the EXTERNAL-IP of the teleport service
```

Create a DNS A or CNAME record at your DNS provider pointing `grant-tam-teleport.gvteleport.com` to that address.

### Create First Admin User

```bash
kubectl exec -n teleport \
  $(kubectl get pod -n teleport -l app.kubernetes.io/component=auth -o jsonpath='{.items[0].metadata.name}') \
  -- tctl users add admin --roles=editor,access --logins=ubuntu
```

---

## Accessing the Cluster

Get the master's public IP from Terraform outputs:

```bash
cd terraform
terraform output master_public_ip
```

SSH into the master:

```bash
ssh -i grant-tam-key.pem ubuntu@<master_public_ip>
```

Verify cluster health:

```bash
kubectl get nodes
kubectl get pods -A
```

Download the SSH private key from the GitHub Actions run:
**Actions → your run → Artifacts → grant-tam-key**

---

## Tearing Down

### Via GitHub Actions (recommended)

1. **Actions → Terraform - K8s Cluster → Run workflow → `destroy`**
2. Wait for completion

### Manually

```bash
cd terraform
terraform destroy -auto-approve \
  -var="training_prefix=grant-tam" \
  -var="customer_ip=136.25.0.29/32" \
  -var="tf_state_bucket=<your-tf-state-bucket>" \
  -var="db_password=<your-db-password>"
```

---

## Manual Terraform Usage (Secondary Option)

If running Terraform locally rather than via GitHub Actions:

### Prerequisites

- Terraform >= 1.8.5
- AWS CLI configured with appropriate credentials
- `aws-vault` or equivalent for credential management recommended

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

### Plan

```bash
terraform plan \
  -var="training_prefix=grant-tam" \
  -var="customer_ip=136.25.0.29/32" \
  -var="tf_state_bucket=<your-tf-state-bucket>" \
  -var="db_password=<your-db-password>"
```

### Apply

```bash
terraform apply \
  -var="training_prefix=grant-tam" \
  -var="customer_ip=136.25.0.29/32" \
  -var="tf_state_bucket=<your-tf-state-bucket>" \
  -var="db_password=<your-db-password>"
```

### Retrieve SSH Key

```bash
terraform output -raw private_key_pem > grant-tam-key.pem
chmod 600 grant-tam-key.pem
```

---

## Notes

- `grant-tam-key.pem` is written to `terraform/` after apply and is listed in `.gitignore` — never commit it
- Terraform state is stored remotely in S3 with DynamoDB locking — do not use local state in shared environments
- AWS session tokens from STS/SSO expire — refresh `AWS_SESSION_TOKEN` in repository secrets before running if credentials have expired
- Monitor cloud-init progress on the master: `sudo tail -f /var/log/cloud-init-k8s.log`
- The RDS instance requires `rds.logical_replication=1` and a reboot to enable Teleport's PostgreSQL change feed — this is handled automatically by Terraform on first provision
- Teleport's ACME/Let's Encrypt TLS requires port 443 to be publicly accessible and DNS to be configured before certificates can be issued
