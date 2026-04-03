terraform {
  backend "s3" {
    # Values supplied at init time via -backend-config in the GitHub Action.
    # Do not hardcode bucket/key/region here — they are injected as secrets.
  }
}
# deploy trigger: 20260402b
# 2026-03-19T21:45:35Z
# fresh apply after environment destroy: 2026-03-24
