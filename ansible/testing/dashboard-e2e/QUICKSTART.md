# Quickstart

Run Cypress E2E tests against an existing Rancher instance in under 5 minutes.
This is the simplest use case — no AWS provisioning, no K3s install,
just tests against a Rancher you already have running.

For the full pipeline (provision + deploy + test), see the [README](README.md).

## Prerequisites

1. A running Rancher instance you can reach from this machine
2. Python 3.10+ and `pip` (or `uv` if you prefer)
3. Docker installed and running
4. `curl`, `git`, and `jq`

## Step 1: Install Ansible

If you already have Ansible >= 2.16, skip this step.

```bash
# Option A: with pip
pip install ansible-core

# Option B: with uv (faster)
pip install uv
uv tool install "ansible-core<2.17" --with ansible
```

Install the required Ansible collections:

```bash
ansible-galaxy collection install \
  cloud.terraform kubernetes.core community.docker community.crypto
```

## Step 2: Clone the repo

```bash
git clone https://github.com/rancher/qa-infra-automation.git
cd qa-infra-automation/ansible/testing/dashboard-e2e
```

## Step 3: Configure variables

```bash
cp vars.yaml.example vars.yaml
```

Edit `vars.yaml` — for testing against an existing Rancher, you only need
to change these fields:

```yaml
# --- Job type ---
job_type: "existing"
create_initial_clusters: false

# --- Rancher connection ---
rancher_host: "rancher.example.com"    # FQDN of your Rancher (no https://)
rancher_password: "your-admin-password"

# --- What to test ---
rancher_helm_repo: "rancher-com-rc"
rancher_image_tag: "v2.14-head"        # Must match your Rancher version
cypress_tags: "@generic"               # Start with generic — no clusters needed

# --- Dashboard repo ---
dashboard_repo: "rancher/dashboard"
dashboard_branch: "master"
```

Leave the AWS, Qase, and Percy sections commented out — they are not needed
for this use case.

## Step 4: Run the tests

```bash
ansible-playbook dashboard-e2e-playbook.yml --tags test
```

This will:

1. Wait for your Rancher UI to be reachable
2. Create `standard_user` with role bindings (idempotent)
3. Clone the dashboard repo and overlay CI files
4. Build the Cypress Docker image
5. Generate the `.env` file with your Rancher credentials
6. Run Cypress tests inside Docker

## Step 5: Check results

After the run completes, results are in:

```bash
# JUnit XML (for CI integrations)
ls ~/dashboard/results.xml

# HTML report with screenshots
ls ~/dashboard/cypress/reports/html/
```

Open the HTML report in a browser:

```bash
xdg-open ~/dashboard/cypress/reports/html/index.html 2>/dev/null || \
  open ~/dashboard/cypress/reports/html/index.html
```

## Common tag examples

```yaml
# Generic pages (login, home, about) — no clusters needed
cypress_tags: "@generic"

# Admin user tests — needs a working Rancher with default setup
cypress_tags: "@adminUser"

# Multiple tags combined
cypress_tags: "@adminUser+@vai"

# Standard user tests
cypress_tags: "@standardUser"

# Bypass auto-filtering — run exactly the tags you specify,
# skipping the automatic +-@prime/+-@noVai exclusions
cypress_tags: "@bypass+@generic"
```

## Next steps

- **Full pipeline** (provision AWS + deploy Rancher + test): See the
  [README](README.md) for `job_type: "recurring"` configuration.
- **Helm repo options**: See "Helm Repos and Image Resolution" in the
  README for all 6 repo types with examples.
- **CI integration**: The `cypress/jenkins/init.sh` script in the dashboard
  repo wraps this playbook for Jenkins.
