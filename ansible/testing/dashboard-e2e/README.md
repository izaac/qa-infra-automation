# Dashboard E2E Test Pipeline

Ansible playbook that orchestrates the full Rancher Dashboard Cypress end-to-end
test pipeline. It provisions AWS infrastructure, deploys Rancher on K3s, runs
Cypress tests inside a Docker container, and tears everything down afterward.

## What It Does

```text
1. Provision    AWS EC2 instances via OpenTofu (rancher HA cluster, import cluster, custom node)
2. Deploy       K3s on each cluster, then Rancher via Helm on the HA cluster
3. Setup        Clone dashboard repo, configure Rancher (users, roles), build Docker image
4. Test         Run Cypress specs inside Docker against the live Rancher instance
5. Cleanup      Destroy all AWS resources (EC2, Route53 records, security groups)
```

Each phase is controlled by Ansible tags so you can run them independently.

## Prerequisites

The following must be available on the machine running the playbook:

| Tool | Install | Notes |
|------|---------|-------|
| Ansible >= 2.16 | `pip install ansible-core` or `uv tool install ansible-core` | The Jenkins init.sh script installs this automatically |
| OpenTofu >= 1.11 | [opentofu.org/docs/intro/install](https://opentofu.org/docs/intro/install/) | Or set `TOFU_VERSION` in Jenkins |
| Docker | System package | For building and running the Cypress test image |
| Helm 3 | [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/) | Used during Rancher deploy |
| curl, git, jq | System packages | Standard utilities |

Required Ansible collections (installed automatically by `init.sh` in Jenkins):

```bash
ansible-galaxy collection install \
  cloud.terraform kubernetes.core "community.docker:<5" "community.crypto:<3" --upgrade
```

## Quick Start

```bash
cd ansible/testing/dashboard-e2e

# 1. Copy and edit variables
cp vars.yaml.example vars.yaml
# Edit vars.yaml  --  at minimum you need to set the AWS variables
# (see "Configuration" below for what each variable does)

# 2. Export AWS credentials
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_AMI="ami-..."
export AWS_ROUTE53_ZONE="Z..."
export AWS_VPC="vpc-..."
export AWS_SUBNET="subnet-..."
export AWS_SECURITY_GROUP="sg-name"

# 3. Run the full pipeline
ansible-playbook dashboard-e2e-playbook.yml
```

## Usage Examples

### Full pipeline (provision, deploy, test)

Run everything in a single command. Ideal for standalone CI or local full-stack testing.

```bash
ansible-playbook dashboard-e2e-playbook.yml --tags provision,setup,test
```

### Provision only (infrastructure + deploy)

Provision AWS, deploy K3s and Rancher, but don't run tests. Useful for
setting up a long-lived environment.

```bash
ansible-playbook dashboard-e2e-playbook.yml --tags provision
```

### Setup + test (against provisioned infra)

Clone dashboard, build Docker image, run Cypress. Use after provisioning
or against an existing Rancher (`job_type=existing`).

```bash
ansible-playbook dashboard-e2e-playbook.yml --tags setup,test
```

### Real-time Docker streaming

The playbook's `test` stage buffers Docker output. For real-time streaming
with colors (e.g. local dev or Jenkins), run setup only, then Docker manually:

```bash
# Setup: clone dashboard, build image, generate .env
ansible-playbook dashboard-e2e-playbook.yml --tags setup

# Run Cypress with real-time streaming
docker run --rm -t \
  --shm-size=2g \
  --env-file ~/.env \
  -e NODE_PATH="" \
  -v "$HOME:/e2e" \
  -w /e2e \
  dashboard-test:latest
```

### Test only (against existing Rancher)

Skip provisioning and run tests against an already-deployed Rancher instance.
You must set `rancher_host` to your Rancher URL and `job_type` to `existing`.

```bash
ansible-playbook dashboard-e2e-playbook.yml \
  --extra-vars "job_type=existing rancher_host=rancher.example.com" \
  --tags setup,test
```

### Cleanup only (destroy infrastructure)

Tear down all AWS resources (EC2, Route53) created during provisioning. This
requires both the `cleanup` and `never` tags because cleanup tasks use Ansible's
special `never` tag to prevent accidental execution during normal runs.

```bash
ansible-playbook dashboard-e2e-playbook.yml --tags cleanup,never
```

### Jenkins integration

The [`cypress/jenkins/init.sh`](https://github.com/rancher/dashboard/blob/master/cypress/jenkins/init.sh)
script in the [rancher/dashboard](https://github.com/rancher/dashboard) repository
wraps this playbook. It handles prerequisite installation, variable generation
from Jenkins environment variables, and real-time Cypress streaming.

```bash
# Full run (called by Jenkinsfile)
cypress/jenkins/init.sh

# Destroy only (called by Jenkinsfile finally block)
cypress/jenkins/init.sh destroy
```

Jenkins uses `--skip-tags test` so that Cypress output streams directly to
the Jenkins console with color support via init.sh's Docker run.

## Configuration

Variables are loaded from `vars.yaml` (copy from `vars.yaml.example`). When
running from Jenkins, `init.sh` generates this file automatically from
environment variables.

### AWS infrastructure

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-west-1` | AWS region for all resources |
| `aws_instance_type` | `t3a.xlarge` | EC2 instance type |
| `aws_volume_size` | `60` | Root volume size in GB |
| `server_count` | `3` | Number of Rancher HA nodes (1 or 3) |

The following are **required** and have no defaults. In Jenkins they come from
credentials; for local runs, export them as environment variables:

`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_AMI`, `AWS_ROUTE53_ZONE`,
`AWS_VPC`, `AWS_SUBNET`, `AWS_SECURITY_GROUP`

### Rancher

| Variable | Default | Description |
|----------|---------|-------------|
| `rancher_helm_repo` | `rancher-com-rc` | Helm repo name (see "Helm Repos and Image Resolution" below) |
| `rancher_image_tag` | `v2.14-head` | Rancher image tag. Controls target branch: `v2.14-head` -> `release-2.14`, `head` -> `master` |
| `k3s_kubernetes_version` | `v1.30.0+k3s1` | K3s version for all clusters |
| `bootstrap_password` | `password` | Rancher first-boot password |
| `rancher_password` | `password1234` | Permanent admin password set after bootstrap |

### Helm Repos and Image Resolution

Rancher is released through two pipelines: **Prime** (SUSE registry) and
**Community** (Docker Hub). Each pipeline has production, RC, and alpha stages.

**Prime repos** use a two-repo strategy: the Helm chart is always installed from
`rancher-prime` (charts.rancher.com), while the image tag is resolved from a
separate staging repo. **Community repos** are self-contained — chart and image
come from the same repo.

| `rancher_helm_repo` | Chart source | Image registry | Image tag resolution |
|---------------------|-------------|----------------|---------------------|
| `rancher-prime` | charts.rancher.com/server-charts/prime | `registry.suse.com` | `v{chart_version}` from rancher-prime |
| `rancher-latest` | charts.rancher.com/server-charts/prime | `stgregistry.suse.com` | Highest `-rc` match from optimus.rancher.io/latest |
| `rancher-alpha` | charts.rancher.com/server-charts/prime | `stgregistry.suse.com` | Highest `-alpha` match from optimus.rancher.io/alpha |
| `rancher-community` | releases.rancher.com/server-charts/stable | Docker Hub | `rancher_image_tag` as-is |
| `rancher-com-rc` | releases.rancher.com/server-charts/latest | Docker Hub | `rancher_image_tag` as-is |
| `rancher-com-alpha` | releases.rancher.com/server-charts/alpha | Docker Hub | `rancher_image_tag` as-is |

### Examples

```yaml
# Prime stable — released 2.13.4
rancher_helm_repo: "rancher-prime"
rancher_image_tag: "v2.13.4"
# → chart 2.13.4 from rancher-prime, image registry.suse.com/rancher/rancher:v2.13.4

# Prime RC — test the latest 2.13 release candidate
rancher_helm_repo: "rancher-latest"
rancher_image_tag: "v2.13"
# → chart 2.13.4 from rancher-prime, image stgregistry.suse.com/rancher/rancher:v2.13.4-rc1

# Prime alpha — test the next minor
rancher_helm_repo: "rancher-alpha"
rancher_image_tag: "v2.14"
# → chart from rancher-prime (latest 2.14.x), image stgregistry.suse.com/rancher/rancher:v2.14.0-alpha13

# Community GA — stable community release
rancher_helm_repo: "rancher-community"
rancher_image_tag: "v2.13.3"
# → chart 2.13.3 from releases.rancher.com/stable, image rancher/rancher:v2.13.3

# Community RC (default) — test upcoming community release
rancher_helm_repo: "rancher-com-rc"
rancher_image_tag: "v2.14-head"
# → latest 2.14.x chart from releases.rancher.com/latest, image rancher/rancher:v2.14-head

# Community alpha
rancher_helm_repo: "rancher-com-alpha"
rancher_image_tag: "v2.14.0-alpha9"
# → chart 2.14.0-alpha9 from releases.rancher.com/alpha, image rancher/rancher:v2.14.0-alpha9

# Dev head — latest from any repo
rancher_helm_repo: "rancher-com-rc"
rancher_image_tag: "head"
# → latest chart in the repo, image rancher/rancher:head
```

### Cypress test runner

| Variable | Default | Description |
|----------|---------|-------------|
| `cypress_tags` | `@adminUser` | Cypress grep tags to run (e.g. `@userMenu`, `@adminUser+@components`) |
| `job_type` | `recurring` | `recurring` provisions new infra; `existing` skips provisioning |
| `create_initial_clusters` | `true` | Whether to create import cluster and custom node. In `existing` mode, provisions only these resources (not the Rancher server) |
| `dashboard_repo` | `rancher/dashboard` | Dashboard GitHub repo to clone |
| `dashboard_branch` | (auto-detected) | Branch to clone. Auto-detected from `rancher_image_tag` (e.g. `v2.14-head` → `release-2.14`) |
| `dashboard_overlay_branch` | `master` | Branch to overlay dependency files from (package.json, yarn.lock, cypress.config.ts). CI files come from the playbook's `files/` directory |

### Pinned versions

These are kept in sync with the
[Cypress Docker factory](https://github.com/cypress-io/cypress-docker-images/blob/master/factory/.env).
Only change them if the factory updates.

| Tool | Default | Source |
|------|---------|--------|
| Chrome | `146.0.7680.164-1` | Factory `.env` |
| Node.js | `24.14.0` | Factory `.env` |
| Yarn | `1.22.22` | Factory `.env` |
| Cypress | `11.1.0` | Dashboard `package.json` |
| kubectl | `v1.33.10` | Kubernetes stable |

## Cypress Tag System

The playbook automatically adjusts Cypress tags before running tests. This
mirrors the logic in the upstream dashboard `init.sh`:

- **Non-prime repos** (e.g. `rancher-com-rc`, `rancher-stable`): Appends
  `+-@prime` to exclude prime-only tests.
- **Prime repos** (`rancher-prime`, `rancher-latest`, `rancher-alpha`): Appends
  `+-@noPrime` to exclude non-prime tests.
- **Always**: Appends `+-@noVai` to exclude VAI-specific tests.
- **Bypass**: If `@bypass` is present in the tags, no automatic exclusions are
  added. Use this when you want full control over which tests run.

Example: Input `@userMenu` with repo `rancher-com-rc` becomes
`@userMenu+-@prime+-@noVai`.

## Tags

| Tag | What it runs |
|-----|-------------|
| `provision` | Infrastructure provisioning (OpenTofu) + K3s + Rancher deploy + Helm resolution |
| `setup` | Clone dashboard, copy CI files, build Docker image, generate .env |
| `test` | Cypress Docker run + result collection |
| `cleanup` | Infrastructure teardown (requires `--tags cleanup,never`) |

Pre-tasks (validation, tag adjustment) use `always` — they run regardless of
which tags you specify.

## Outputs

After a successful run, the following artifacts are available:

| Path | Description |
|------|-------------|
| `~/dashboard/results.xml` | JUnit XML test results |
| `~/dashboard/cypress/reports/html/` | Mochawesome HTML report with screenshots |
| `<workspace>/notification_values.txt` | Rancher version info for Slack notifications |
| `~/.qa-infra/outputs/` | SSH keys, kubeconfigs, tfvars (cleaned up on destroy) |

## Architecture

```text
dashboard-e2e-playbook.yml          Main orchestrator
  pre_tasks: [always]
    validate AWS vars
    adjust Cypress tags               Appends -@prime/-@noVai exclusions
  tasks:
    tasks/provision.yml       [provision]  OpenTofu apply (3 workspaces in parallel via async)
    tasks/resolve-helm-version.yml  [provision, setup]  Resolve Rancher Helm chart version
    tasks/install-k3s-rancher.yml   [provision]  K3s + rancher-ha playbooks (parallel)
    tasks/setup-test-env.yml  [setup]    Clone repo, copy CI files from files/, Docker build
    tasks/run-tests.yml       [test]     Docker run, collect JUnit + HTML reports
    tasks/cleanup.yml         [cleanup]  OpenTofu destroy (loop), remove artifacts

files/                               CI files (copied into dashboard clone at setup)
  Dockerfile.ci                      Cypress factory image + kubectl
  cypress.sh                         Container entrypoint — runs Cypress + jrm
  cypress.config.jenkins.ts          Cypress config (reporters, retries, Qase)
  grep-filter.ts                     Pre-filter specs by tag
  utils.sh                           Shared shell utilities (clean_tags, etc.)
```

### Key Scripts and Tasks

- **`files/`** — CI files that are infrastructure concern, not test code.
  The playbook copies them into the dashboard clone during setup, making the
  playbook fully self-contained. No git overlay needed for CI files.
- **`tasks/configure-rancher-users.yml`** — Creates `standard_user`
  with global and project role bindings via the Rancher API. Idempotent
  (skips if resources already exist). Fatal on `recurring` jobs if
  verification fails; warns and continues on `existing` jobs.
- **`files/grep-filter.ts`** — Pre-filters Cypress spec files by tag before
  Cypress launches. Runs inside the Docker container to reduce unnecessary
  spec loading.

## Troubleshooting

### OpenTofu init fails with "Failed to install provider"

Transient GitHub rate limit. Re-run the pipeline -- it will retry automatically.

### K3s fails to start

Check the K3s version compatibility with your AMI. The default `v1.30.0+k3s1`
works with Ubuntu 22.04/24.04 AMIs. If using a newer AMI, you may need a newer
K3s version.

### Rancher setup returns 401 Unauthorized

The playbook changes the admin password from `bootstrap_password` to
`rancher_password` during deploy. Make sure `rancher_password` in vars.yaml
matches what you expect. The `configure-rancher-users.yml` task uses `rancher_password`.

### Cypress tests fail with "baseUrl not reachable"

The Rancher UI may not be ready yet. The playbook waits up to 5 minutes for
`/dashboard/auth/login` to return 200. If your Rancher is slow to start,
increase the `retries` value in `setup-test-env.yml`.

### Cleanup fails with "workspace not found"

This is safe to ignore. The cleanup uses `|| exit 0` so missing workspaces
(e.g. if provisioning was skipped) do not cause failures.

## Dependencies

Ansible collections required (install manually or let `init.sh` handle it in Jenkins):

- `cloud.terraform` — OpenTofu/Terraform state lookups and provider management
- `kubernetes.core` — Kubernetes resource operations
- `community.docker` **< 5** — Docker image build and container management (v5+ requires ansible-core ≥ 2.17)
- `community.crypto` **< 3** — SSH keypair generation (v3+ requires ansible-core ≥ 2.17)
