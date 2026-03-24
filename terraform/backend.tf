terraform {
  backend "s3" {
    # Values supplied at init time via -backend-config in the GitHub Action.
    # Do not hardcode bucket/key/region here — they are injected as secrets.
  }
}
# deploy trigger: Thu Mar 19 21:09:57 UTC 2026
# 2026-03-19T21:45:35Z
# fresh apply after environment destroy: 2026-03-24
