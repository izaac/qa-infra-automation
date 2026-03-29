# Dashboard E2E Test Pipeline

Ansible playbook that orchestrates the full Rancher Dashboard Cypress end-to-end
test pipeline. It provisions AWS infrastructure, deploys Rancher on K3s, runs
Cypress tests inside a Docker container, and tears everything down afterward.

## What It Does

```
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
ansible-galaxy collection install cloud.terraform kubernetes.core community.docker community.crypto
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

### Full pipeline (provision, deploy, test, cleanup)

Run everything in a single command. Ideal for local development or standalone CI.

```bash
ansible-playbook dashboard-e2e-playbook.yml
```

### Setup only (provision + deploy, skip Cypress run)

Provision infrastructure, install K3s, deploy Rancher, build Docker image, and
generate `.env` but skip the actual Cypress docker run. Useful when you want to
run tests manually or stream output in real time (e.g. Jenkins).

```bash
ansible-playbook dashboard-e2e-playbook.yml --skip-tags test-run
```

Then run Cypress directly for real-time streaming:

```bash
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
  --tags test
```

### Cleanup only (destroy infrastructure)

Tear down all AWS resources (EC2, Route53) created during provisioning. This
requires both the `cleanup` and `never` tags because cleanup tasks use Ansible's
special `never` tag to prevent accidental execution during normal runs.

```bash
ansible-playbook dashboard-e2e-playbook.yml --tags cleanup,never
```

### jenkins integration

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

Jenkins uses `--skip-tags test-run` so that Cypress output streams directly to
the Jenkins console with color support, then runs the Docker container itself.

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
| `rancher_helm_repo` | `rancher-com-rc` | Helm repo name (`rancher-stable`, `rancher-prime`, `rancher-latest`, etc.) |
| `rancher_image_tag` | `v2.14-head` | Rancher image tag. Controls target branch: `v2.14-head` -> `release-2.14`, `head` -> `master` |
| `k3s_kubernetes_version` | `v1.30.0+k3s1` | K3s version for all clusters |
| `bootstrap_password` | `password` | Rancher first-boot password |
| `rancher_password` | `password1234` | Permanent admin password set after bootstrap |

### Cypress test runner

| Variable | Default | Description |
|----------|---------|-------------|
| `cypress_tags` | `@adminUser` | Cypress grep tags to run (e.g. `@userMenu`, `@adminUser+@components`) |
| `job_type` | `recurring` | `recurring` provisions new infra; `existing` skips provisioning |
| `create_initial_clusters` | `true` | Whether to create import cluster and custom node (accepts `true`/`yes`/`1`) |
| `dashboard_repo` | `rancher/dashboard` | Dashboard GitHub repo to clone |
| `dashboard_branch` | `master` | Branch containing the CI scripts (overlaid onto target branch) |

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
| kubectl | `v1.29.8` | Kubernetes stable |

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
| `provision` | Infrastructure provisioning + K3s + Rancher deploy |
| `test` | Test environment setup + Cypress execution |
| `test-run` | Cypress Docker run only (subset of `test`) |
| `cleanup` | Infrastructure teardown (requires `--tags cleanup,never`) |

## Outputs

After a successful run, the following artifacts are available:

| Path | Description |
|------|-------------|
| `~/dashboard/results.xml` | JUnit XML test results |
| `~/dashboard/cypress/reports/html/` | Mochawesome HTML report with screenshots |
| `<workspace>/notification_values.txt` | Rancher version info for Slack notifications |
| `~/.qa-infra/outputs/` | SSH keys, kubeconfigs, tfvars (cleaned up on destroy) |

## Architecture

```
dashboard-e2e-playbook.yml          Main orchestrator
  pre_tasks:
    validate AWS vars
    adjust Cypress tags               Appends -@prime/-@noVai exclusions
  tasks:
    tasks/provision.yml               OpenTofu apply (3 workspaces in parallel via async)
    tasks/resolve-helm-version.yml    Resolves Rancher Helm chart version from image tag
    tasks/install-k3s-rancher.yml     Delegates to k3s + rancher-ha playbooks (parallel)
    tasks/setup-test-env.yml          Clone repo, rancher-setup.ts, yarn install, Docker build
    tasks/run-tests.yml               Docker run, collect JUnit + HTML reports
    tasks/cleanup.yml                 OpenTofu destroy (loop), remove artifacts
```

### Key TypeScript Scripts (from [rancher/dashboard](https://github.com/rancher/dashboard))

The playbook uses two TypeScript scripts from
[`cypress/jenkins/`](https://github.com/rancher/dashboard/tree/master/cypress/jenkins)
in the dashboard repository:

- **[`rancher-setup.ts`](https://github.com/rancher/dashboard/blob/master/cypress/jenkins/rancher-setup.ts)**
  -- Configures Rancher after deploy: admin login, standard
  user creation, role bindings, and target branch detection. Runs via
  `node --experimental-strip-types` (no build step needed).
- **[`grep-filter.ts`](https://github.com/rancher/dashboard/blob/master/cypress/jenkins/grep-filter.ts)**
  -- Pre-filters Cypress spec files by tag before Cypress
  launches. Runs inside the Docker container to reduce unnecessary spec loading.

## Troubleshooting

**OpenTofu init fails with "Failed to install provider"**

Transient GitHub rate limit. Re-run the pipeline -- it will retry automatically.

**K3s fails to start**

Check the K3s version compatibility with your AMI. The default `v1.30.0+k3s1`
works with Ubuntu 22.04/24.04 AMIs. If using a newer AMI, you may need a newer
K3s version.

**Rancher setup returns 401 Unauthorized**

The playbook changes the admin password from `bootstrap_password` to
`rancher_password` during deploy. Make sure `rancher_password` in vars.yaml
matches what you expect. The `rancher-setup.ts` script uses `rancher_password`.

**Cypress tests fail with "baseUrl not reachable"**

The Rancher UI may not be ready yet. The playbook waits up to 5 minutes for
`/dashboard/auth/login` to return 200. If your Rancher is slow to start,
increase the `retries` value in `setup-test-env.yml`.

**Cleanup fails with "workspace not found"**

This is safe to ignore. The cleanup uses `|| exit 0` so missing workspaces
(e.g. if provisioning was skipped) do not cause failures.

## Dependencies

Ansible collections required (see `requirements.yml` or install manually):

- `cloud.terraform` -- OpenTofu/Terraform state lookups and provider management
- `kubernetes.core` -- Kubernetes resource operations
- `community.docker` -- Docker image build and container management
- `community.crypto` -- SSH keypair generation
