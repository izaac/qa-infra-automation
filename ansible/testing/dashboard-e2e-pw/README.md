# Dashboard E2E (Playwright) Test Pipeline

Ansible playbook that orchestrates the full Rancher Dashboard **Playwright**
end-to-end test pipeline. It provisions AWS infrastructure, deploys Rancher on
K3s, runs Playwright tests inside a Docker container, and tears everything
down afterward.

This playbook is **independent** of the Cypress-based `ansible/testing/dashboard-e2e/`
sibling. Every task, template, and helper script it needs lives under this
directory — `dashboard-e2e/` can be missing or renamed without affecting this
playbook.

## What It Does

```text
1. Provision    AWS EC2 instances via OpenTofu (rancher HA cluster, import cluster, custom node)
2. Deploy       K3s on each cluster, then Rancher via Helm on the HA cluster
3. Setup        Clone rancher/dashboard-e2e-pw, copy CI files, build Docker image
4. Test         Run `playwright test --config=playwright.config.jenkins.ts --grep <tags>`
                inside Docker against the live Rancher instance
5. Cleanup      Destroy all AWS resources (EC2, Route53 records, security groups)
```

Each phase is controlled by Ansible tags so you can run them independently.

## Quick Start

```bash
cd ansible/testing/dashboard-e2e-pw

# 1. Copy and edit variables
cp vars.yaml.example vars.yaml
# Edit vars.yaml — at minimum set AWS variables + rancher_password

# 2. Export AWS + (optional) reporting credentials
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export QASE_TOKEN="..."   # optional, enables Qase reporting when qase_enabled=true

# 3. Run the full pipeline
ansible-playbook dashboard-e2e-pw-playbook.yml
```

## Usage Examples

```bash
# Full pipeline (provision → setup → test)
ansible-playbook dashboard-e2e-pw-playbook.yml --tags provision,setup,test

# Re-run tests against existing infra (faster iteration)
ansible-playbook dashboard-e2e-pw-playbook.yml --tags setup,test

# Provision only — useful when iterating on the dashboard-e2e-pw repo locally
ansible-playbook dashboard-e2e-pw-playbook.yml --tags provision

# Different tag expression
ansible-playbook dashboard-e2e-pw-playbook.yml --tags test \
  -e 'pw_grep_tags=@manager+@adminUser'

# Point at a specific dashboard-e2e-pw branch (for testing PRs)
ansible-playbook dashboard-e2e-pw-playbook.yml --tags setup,test \
  -e 'dashboard_pw_repo=izaac/dashboard-e2e-pw' \
  -e 'dashboard_pw_branch=my-feature-branch'

# Destroy everything
ansible-playbook dashboard-e2e-pw-playbook.yml --tags cleanup
```

## Key Variables

| Variable                | Default                          | Notes |
|-------------------------|----------------------------------|-------|
| `dashboard_pw_repo`     | `rancher/dashboard-e2e-pw`       | Override to a fork (e.g. `izaac/dashboard-e2e-pw`) |
| `dashboard_pw_branch`   | `main`                           | Auto-mapped to `release-<X.Y>` when `rancher_image_tag=vX.Y-head` |
| `pw_grep_tags`          | `@adminUser`                     | Passed verbatim to `playwright test --grep` |
| `playwright_image`      | `mcr.microsoft.com/playwright:v1.49.0-noble` | Docker base image (browsers bundled) |
| `rancher_image_tag`     | `v2.14-head`                     | Drives helm version + branch auto-detection |
| `job_type`              | `recurring`                      | `recurring` (provision) or `existing` (BYO host) |
| `create_initial_clusters` | `true`                         | Provision import-cluster + custom-node helpers |
| `qase_enabled`          | `false`                          | Enable Qase reporter — requires `QASE_TOKEN` env |

See `vars.yaml.example` for the full list.

## How It Differs From `dashboard-e2e/`

| Aspect                | `dashboard-e2e/` (Cypress)              | `dashboard-e2e-pw/` (Playwright)           |
|-----------------------|------------------------------------------|---------------------------------------------|
| Test repo             | `rancher/dashboard` (cypress/ subdir)    | `rancher/dashboard-e2e-pw` (root is the spec project) |
| Runner image          | `cypress/factory:7.3.1`                  | `mcr.microsoft.com/playwright:v1.49.0-noble` |
| Runner script         | `cypress/jenkins/cypress.sh`             | `jenkins/playwright.sh`                     |
| Tag CLI               | `cypress.grepTags` env + `--spec`        | `playwright test --grep <expr>`             |
| Tag env var           | `CYPRESS_grepTags`                       | `GREP_TAGS`                                 |
| JUnit output          | `cypress/jenkins/reports/junit/*.xml`    | `e2e/jenkins/reports/junit/results.xml`     |
| HTML report           | `cypress/reports/html/`                  | `playwright-report/`                        |
| Image tag             | `dashboard-test:<executor>`              | `dashboard-pw-test:<executor>`              |
| Container name        | `cypress-<executor>-<prefix>-<host>`     | `playwright-<executor>-<prefix>-<host>`     |
| Reporting integrations | Qase + Percy                            | Qase only (no Percy in dashboard-e2e-pw)    |
| Cross-branch overlay  | Yes (dependency files from master)       | No (single source of truth in one repo)     |

## File Layout

```text
dashboard-e2e-pw/
├── README.md                      ← this file
├── dashboard-e2e-pw-playbook.yml  ← orchestrator
├── vars.yaml.example
├── ansible.cfg
├── inventory                       ← localhost
├── .ansible-lint
├── .gitignore
├── files/
│   ├── Dockerfile.ci              ← Playwright base + kubectl + curl
│   └── playwright.sh              ← runs `playwright test` inside the container
├── tasks/
│   ├── provision.yml              ← AWS infra via OpenTofu
│   ├── install-k3s-rancher.yml    ← K3s + Rancher Helm deploy
│   ├── resolve-helm-version.yml   ← chart/image version lookup
│   ├── setup-test-env.yml         ← clone repo, build image
│   ├── run-tests.yml              ← docker run + result collection
│   └── cleanup.yml                ← tofu destroy + image rm
└── templates/
    ├── env.j2                     ← Playwright env vars (.env file)
    └── tfvars.j2                  ← OpenTofu input
```
