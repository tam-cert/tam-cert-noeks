# Deploy trigger: Fri Mar 20 2026
# Fresh apply after environment destroy — includes fixes:
#   - PR #8: remove stale postgres-certs-job.yaml fetch from cloud-init
#   - PR #9: pass POSTGRES_ADMIN_PASSWORD to ansible-playbook via cloud-init env
