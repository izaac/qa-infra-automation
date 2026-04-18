# Playwright E2E Pipeline — Adaptation Plan

Adapt the existing Cypress ansible pipeline (`../dashboard-e2e/`) to run Playwright tests from `izaac/dashboard-e2e-pw`.

**Scope:** AWS provisioning tests only (EC2 creds available). Non-AWS tests migrated later in staging Jenkins.

## Architecture

```
dashboard-e2e-pw/
├── dashboard-e2e-pw-playbook.yml   # main orchestrator
├── vars.yaml                       # config (PW-specific defaults)
├── vars.yaml.example               # template for new users
├── run.sh                          # local wrapper (Docker/Podman)
├── ansible.cfg                     # ansible config
├── README.md
├── files/
│   ├── Dockerfile.ci               # mcr.microsoft.com/playwright:v1.52.0-noble + kubectl
│   └── playwright.sh               # yarn install → npx playwright test
├── tasks/
│   ├── setup-test-env.yml          # clone PW repo, build image, generate .env
│   └── run-tests.yml               # run Playwright container, collect results
└── templates/
    └── env.j2                      # .env template (Playwright env vars)
```

## Reuse from sibling pipeline

Shared tasks included via relative path (`../dashboard-e2e/tasks/`):

| Task | Source | Changes |
|------|--------|---------|
| provision.yml | Reuse as-is | None — same EC2/K3s/Rancher infra |
| install-k3s-rancher.yml | Reuse as-is | None |
| resolve-helm-version.yml | Reuse as-is | None |
| cleanup.yml | Reuse as-is | None |

## New/adapted files

### 1. Dockerfile.ci

```
Base: mcr.microsoft.com/playwright:v1.52.0-noble
  - Pre-installed: Node 22, Chromium, Firefox, WebKit
  - Add: kubectl v1.33.10 (for cluster verification)
  - Optional: COPY imported_config /root/.kube/config
  - ENTRYPOINT: bash playwright.sh
```

Why Playwright official image: matches @playwright/test 1.52.0, all browser deps pre-installed.

### 2. playwright.sh

Replaces cypress.sh. Much simpler:

```bash
1. yarn install --frozen-lockfile
2. npx playwright install chromium  # safety net if image doesn't match
3. Parse GREP_TAGS from env
4. npx playwright test \
     --config=playwright.config.jenkins.ts \
     --reporter=junit,line
5. Exit with test exit code
```

No need for:
- grep-filter.ts (Playwright has built-in --grep)
- jrm report merge (Playwright JUnit is single file)
- overlay logic (PW repo is standalone)

### 3. setup-test-env.yml

Simplified from Cypress version:

```
1. Wait for Dashboard UI (same)
2. Clone izaac/dashboard-e2e-pw @ main (simple, no branch detection)
3. Configure Rancher users (reuse rancher_user_setup role)
4. Handle kubeconfig for import clusters (same)
5. Build Docker image (Playwright base)
6. Generate .env from env.j2 template
```

Removed: overlay branch logic, CI file copy, CYPRESSTAGS substitution.

### 4. run-tests.yml

```
1. Run Playwright container (docker run --env-file .env)
2. Collect results.xml and HTML report
3. Set exit code
```

### 5. env.j2

Env var mapping (Cypress → Playwright):

| Cypress | Playwright | Notes |
|---------|-----------|-------|
| CYPRESS_grepTags | GREP_TAGS | Tag format same (@tag) |
| CYPRESS_VIDEO=false | (not needed) | Playwright config handles this |
| CYPRESS_VIEWPORT_* | (not needed) | Playwright config handles this |
| TEST_BASE_URL | TEST_BASE_URL | Same |
| TEST_PASSWORD | TEST_PASSWORD | Same |
| TEST_USERNAME | TEST_USERNAME | Same |
| TEST_SKIP_SETUP=true | TEST_SKIP=setup | Same pattern |
| AWS_ACCESS_KEY_ID | AWS_ACCESS_KEY_ID | Same |
| AWS_SECRET_ACCESS_KEY | AWS_SECRET_ACCESS_KEY | Same |
| CUSTOM_NODE_IP | CUSTOM_NODE_IP | Same |
| CUSTOM_NODE_KEY | CUSTOM_NODE_KEY | Same |

### 6. vars.yaml

Changes from Cypress version:

```yaml
# Removed
# cypress_version, chrome_version (Playwright bundles browser)
# dashboard_overlay_branch (not needed)

# Changed
dashboard_repo: "izaac/dashboard-e2e-pw"
dashboard_branch: "main"
playwright_tags: "@provisioning+@adminUser"  # was cypress_tags

# Added
playwright_version: "1.52.0"  # pin to match @playwright/test

# Kept as-is
# All AWS, K3s, Rancher, Qase vars
```

### 7. Playbook

```yaml
tasks:
  - include_tasks: ../dashboard-e2e/tasks/provision.yml        # REUSE
  - include_tasks: ../dashboard-e2e/tasks/resolve-helm-version.yml  # REUSE
  - include_tasks: ../dashboard-e2e/tasks/install-k3s-rancher.yml   # REUSE
  - include_tasks: tasks/setup-test-env.yml                    # NEW
  - include_tasks: tasks/run-tests.yml                         # NEW
  - include_tasks: ../dashboard-e2e/tasks/cleanup.yml          # REUSE
```

## Implementation order

| Step | File | Effort |
|------|------|--------|
| 1 | files/Dockerfile.ci | Small — base image + kubectl |
| 2 | files/playwright.sh | Small — yarn install + playwright test |
| 3 | templates/env.j2 | Small — env var mapping |
| 4 | tasks/setup-test-env.yml | Medium — clone, users, build image |
| 5 | tasks/run-tests.yml | Small — docker run + collect results |
| 6 | dashboard-e2e-pw-playbook.yml | Medium — adapt orchestrator |
| 7 | vars.yaml + vars.yaml.example | Small — config |
| 8 | run.sh | Medium — adapt wrapper |
| 9 | ansible.cfg + README.md | Small — docs |
| 10 | Test locally | — verify against existing Rancher |

## Risks

1. **Playwright Docker image version drift** — must match @playwright/test in package.json
2. **kubeconfig handling** — import cluster tests need kubectl in container
3. **AWS cred passthrough** — verify env vars reach Playwright process inside container
4. **Tag format** — Playwright uses `--grep "@tag"` not Cypress `+/-` syntax. Need to verify GREP_TAGS parsing
5. **Jenkins integration** — Jenkinsfile not in scope yet (staging first)
