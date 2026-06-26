# oci-pax-helper-tool

Helper tooling for packaging [Spectro Cloud Palette](https://www.spectrocloud.com/) packs and pushing them to a private OCI registry — **Amazon ECR** or a **Zot / basic OCI** registry — as OCI artifacts, using [ORAS](https://oras.land/).

Use it to publish packs (e.g. from a local checkout of [`pack-central`](https://github.com/spectrocloud/pack-central) or `pax`) into your own ECR registry so you can add that registry to Palette and test the packs before opening a PR.

## Quick start

You need `aws`, `oras` (**v1.0.0 or later**), and `jq` installed, and an authenticated AWS session (`aws sso login` if you use SSO). See [Prerequisites](#prerequisites) for install instructions.

**1. Push a pack to ECR:**

```bash
./push-to-ecr.sh ../pack-central/packs/kata-deploy-3.32.0
```

The script prints exactly what it will push and where, then asks for confirmation. That's it — the pack is now in your ECR registry.

**…or push to a Zot registry** (the backend is auto-detected when `ZOT_HOST` is set):

```bash
ZOT_HOST=my-zot.example.com:30003 ZOT_USERNAME=admin ZOT_PASSWORD=… \
  ./push-to-ecr.sh ../pack-central/packs/kata-deploy-3.32.0
```

**2. Push *and* sync Palette in one command (optional):**

```bash
cp .env.example .env
# edit .env: set PALETTE_API_KEY and PALETTE_REGISTRY_NAME="<your registry's name in Palette>"

./push-to-ecr.sh --sync --wait ../pack-central/packs/kata-deploy-3.32.0
```

This pushes the pack, then triggers a registry sync in Palette and waits until the pack is available to use.

> Tip: pass several pack directories at once, and add `-y` to skip the prompt:
> ```bash
> ./push-to-ecr.sh -y ../pack-central/packs/*/
> ```

See [Configuration](#configuration) and [Usage](#usage) below for all options.

## Contents

| File | Purpose |
|---|---|
| `push-to-ecr.sh` | Package one or more packs and push them to ECR. |
| `.env.example` | Template for local configuration. Copy to `.env`. |
| `api-test.sh` | Older single-pack variant, kept for reference. Prefer `push-to-ecr.sh`. |

## Prerequisites

| Tool | Min version | Why | Needed for |
|---|---|---|---|
| [`oras`](https://oras.land/docs/installation) | **v1.0.0** | OCI registry client used to push packs | always |
| [`aws` CLI](https://docs.aws.amazon.com/cli/) | v2 | ECR login, repo creation, account lookup | push to **ECR** only |
| [`jq`](https://jqlang.github.io/jq/) | 1.6+ | reads `pack.json` and Palette API responses | always |
| `tar` | system tar | packages the pack directory | push |
| `curl` | system curl | calls the Palette API | `--sync` only |
| `bash` | 3.2+ | runs the script (macOS' default bash is fine) | always |

> [!IMPORTANT]
> **ORAS must be v1.0.0 or later.** The script uses the ORAS 1.0+ command syntax (`oras login`, `oras push`, `oras manifest fetch`); the older 0.x CLI is incompatible and will fail. Check yours with `oras version`.

### Installing ORAS

**macOS** (Homebrew):

```bash
brew install oras
```

**Linux** (binary download — replace `amd64` with `arm64` for ARM hosts):

```bash
VERSION="1.2.0"   # any release >= 1.0.0
curl -LO "https://github.com/oras-project/oras/releases/download/v${VERSION}/oras_${VERSION}_linux_amd64.tar.gz"
mkdir -p oras-install/
tar -zxf "oras_${VERSION}_linux_amd64.tar.gz" -C oras-install/
sudo mv oras-install/oras /usr/local/bin/
rm -rf "oras_${VERSION}_linux_amd64.tar.gz" oras-install/
```

**Windows** (Chocolatey):

```powershell
choco install oras
```

Or download `oras_<version>_windows_amd64.zip` from the [ORAS releases page](https://github.com/oras-project/oras/releases) and add `oras.exe` to your `PATH`.

After installing, verify the version:

```bash
oras version   # Version: 1.0.0 (or later)
```

### Installing the other tools

- **AWS CLI:** macOS `brew install awscli` · Linux see the [AWS install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) · Windows `choco install awscli`. Then authenticate (`aws configure` or `aws sso login`) — `aws sts get-caller-identity` must succeed, and your identity needs permission to create repositories and push images in the target ECR registry.
- **jq:** macOS `brew install jq` · Linux `sudo apt-get install jq` (or your package manager) · Windows `choco install jq`.
- **curl / tar / bash** ship with macOS and Linux; on Windows use Git Bash or WSL to run the script.

## What a pack must look like

Each pack is a directory named `<name>-<version>` containing at least a `pack.json` (with matching `name` and `version` fields). Typically:

```
kata-deploy-3.32.0/
├── pack.json          # name: kata-deploy, version: 3.32.0
├── values.yaml
├── README.md
├── logo.png
└── charts/
    └── kata-deploy-3.32.0.tgz
```

The script reads `name` and `version` from `pack.json`, tars the directory, and pushes it.

## Configuration

Settings are resolved with the following precedence (highest first):

**CLI flag → shell environment variable → `.env` file → built-in default**

| Setting | Env / `.env` key | Flag | Default |
|---|---|---|---|
| Push backend | `REGISTRY_BACKEND` | `--backend ecr\|zot` | auto (`zot` if `ZOT_HOST` set, else `ecr`) |
| ECR registry namespace | `REGISTRY_NAME` | `-r`, `--registry` | `custeng-sa-oci` (ECR only) |
| AWS region | `AWS_DEFAULT_REGION` | `--region` | `eu-west-2` |
| Repo base path | `PACK_BASE_PATH` | `-b`, `--base-path` | `spectro-packs/archive` |
| Zot host | `ZOT_HOST` | `--zot-host` | — |
| Zot username | `ZOT_USERNAME` | `--zot-username` | — |
| Zot password | `ZOT_PASSWORD` | *(secret — env/`.env` only)* | — |
| Zot CA cert | `ZOT_CA_FILE` | `--ca-file` | — |
| Skip TLS verify | — | `--insecure` | off |
| Plain HTTP | — | `--plain-http` | off |
| Palette API key | `PALETTE_API_KEY` | *(secret — env/`.env` only)* | — |
| Palette host | `PALETTE_HOST` | `--palette-host` | `api.spectrocloud.com` |
| Palette registry name | `PALETTE_REGISTRY_NAME` | `--registry-name` | — |
| Palette registry type | `PALETTE_REGISTRY_TYPE` | `--registry-type` | `ecr` (auto-detected) |
| Palette project UID | `PALETTE_PROJECT_UID` | `--project-uid` | — (tenant scope) |

To set persistent local defaults:

```bash
cp .env.example .env
# edit .env
```

`.env` is gitignored — never commit real values. A custom path can be supplied via `ENV_FILE=/path/to/env`. **Quote any value containing spaces** (e.g. `PALETTE_REGISTRY_NAME="SA OCI Registry"`) — the file is sourced as shell. The `PALETTE_API_KEY` is never accepted as a CLI flag and is never printed (it is passed to `curl` via a 0600 config file, not the command line).

## Usage

```
./push-to-ecr.sh [options] [PACK_DIR ...]
```

If no `PACK_DIR` is given, the current directory is used.

| Option | Description |
|---|---|
| `--backend ecr\|zot` | Force the push backend (otherwise auto-detected from `ZOT_HOST`) |
| `-r`, `--registry NAME` | ECR registry namespace (ECR only) |
| `--region REGION` | AWS region (ECR only) |
| `--zot-host HOST` | Zot registry host[:port] |
| `--zot-username U` | Zot registry username |
| `--ca-file PATH` | CA certificate for the Zot registry's TLS |
| `--insecure` | Skip TLS verification (self-signed certs) |
| `--plain-http` | Use plain HTTP (no TLS) |
| `-b`, `--base-path PATH` | Repo base path under the registry |
| `--lean` | Exclude the unpacked `charts/<chart>/` tree from the artifact (keeps `charts/*.tgz`) |
| `-s`, `--sync` | Trigger a Palette registry sync after a successful push |
| `--sync-only` | Skip pushing; only trigger the Palette sync |
| `--wait` | Poll sync status until it completes (use with `--sync`/`--sync-only`) |
| `--registry-name N` | Palette registry display name (resolved to its UID via the API) |
| `--registry-type T` | `ecr` or `basic` (auto-detected from the registry; override if needed) |
| `--project-uid UID` | Scope the API calls to a project (omit for tenant scope) |
| `--palette-host H` | Palette API host |
| `--sync-timeout S` | Seconds to wait with `--wait` (default: 600) |
| `-y`, `--yes` | Skip the confirmation prompt (required when running non-interactively) |
| `-h`, `--help` | Show help |

### Examples

Push a single pack (prompts for confirmation):

```bash
./push-to-ecr.sh ../pack-central/packs/kata-deploy-3.32.0
```

Push several at once, no prompt, leaner artifacts:

```bash
./push-to-ecr.sh --yes --lean \
  ../pack-central/packs/kata-deploy-3.32.0 \
  ../pack-central/packs/confidential-containers-0.20.0 \
  ../pack-central/packs/confidential-containers-0.21.0
```

Override the target registry/region for one run:

```bash
REGISTRY_NAME=my-registry ./push-to-ecr.sh --region us-east-1 ./mypack-1.0.0
```

### Pushing to Zot (or any basic OCI registry)

Set `ZOT_HOST` and credentials and the tool switches to the Zot backend automatically — no AWS needed, and repositories are created on push. Packs go to `<ZOT_HOST>/spectro-packs/archive/<name>:<version>` (no namespace prefix).

Put the credentials in `.env` (recommended — keeps the password out of your shell history):

```bash
# .env
ZOT_HOST="my-zot.example.com:30003"
ZOT_USERNAME="admin"
ZOT_PASSWORD="…"          # secret — never passed as a flag
```

```bash
./push-to-ecr.sh -y ../pack-central/packs/*/
```

TLS options for Zot:

```bash
# HTTPS with a private CA
./push-to-ecr.sh --ca-file /path/to/ca.crt -y ./mypack-1.0.0
# HTTPS with a self-signed cert (skip verification)
./push-to-ecr.sh --insecure -y ./mypack-1.0.0
# plain HTTP (no TLS)
./push-to-ecr.sh --plain-http -y ./mypack-1.0.0
```

> The backend is auto-detected from `ZOT_HOST`. Use `--backend ecr` to force ECR even if `ZOT_HOST` is present, or `--backend zot` to be explicit.

## Sync to Palette

After pushing, Palette needs to re-index the registry before the new packs appear. The tool can trigger (and optionally wait for) that sync via the Palette API, so the whole flow is one command.

Set the API key and registry name (typically in `.env`):

```bash
PALETTE_API_KEY="<your-api-key>"
PALETTE_REGISTRY_NAME="SA OCI Registry"   # the registry's display name in Palette
```

The tool resolves that **name to its registry UID** automatically (via `GET /v1/registries/oci/summary`) and auto-detects whether it's an `ecr` or `basic` registry — you don't need to look up the UID. Create an API key in Palette under **User Menu → API Keys** ([docs](https://docs.spectrocloud.com/user-management/authentication/api-key/create-api-key/)).

Push and sync, waiting until the packs are available:

```bash
./push-to-ecr.sh --sync --wait --yes \
  ../pack-central/packs/kata-deploy-3.32.0 \
  ../pack-central/packs/confidential-containers-0.20.0 \
  ../pack-central/packs/confidential-containers-0.21.0
```

Re-sync only (no push) — handy after pushing out of band:

```bash
./push-to-ecr.sh --sync-only --wait --yes
```

Notes:
- Default is **fire-and-forget** (returns once the sync is accepted, HTTP 202). Add `--wait` to poll `…/sync/status` until the new run reports `Completed`.
- For **project-scoped** registries, add `--project-uid <uid>`; tenant-scoped registries (the default) need no project and a tenant-admin key.
- For **self-hosted / Vertex** Palette, set `PALETTE_HOST` to your FQDN.
- Underlying API: `POST /v1/registries/oci/{uid}/ecr/sync` (and `…/sync/status`); `basic` registries use `…/sync` without the `ecr` segment.

## Where packs land

**ECR:**

```
<account-id>.dkr.ecr.<region>.amazonaws.com/<REGISTRY_NAME>/<PACK_BASE_PATH>/<name>:<version>
# e.g. <account-id>.dkr.ecr.eu-west-2.amazonaws.com/custeng-sa-oci/spectro-packs/archive/kata-deploy:3.32.0
```

The account ID is derived automatically from your AWS credentials. The script creates the base-path repository and each per-pack repository if they don't already exist.

**Zot:**

```
<ZOT_HOST>/<PACK_BASE_PATH>/<name>:<version>
# e.g. my-zot.example.com:30003/spectro-packs/archive/kata-deploy:3.32.0
```

No namespace prefix is used, and Zot creates repositories automatically on push. Either way, the mandatory `spectro-packs/archive` path (Palette's expected namespace for custom OCI registries) is always present.

## Behaviour notes

- **Confirmation:** when run interactively the script prints a summary and asks before pushing. When run **non-interactively** (no TTY, e.g. piped or in CI) it refuses unless `--yes` is given — this prevents accidental pushes.
- **Idempotent:** pushing the same `name:version` again overwrites that tag.
- **Safe by default:** uses `set -euo pipefail`, validates prerequisites and `pack.json`, logs in to ECR once, and cleans up temporary archives automatically.
- **Artifact format:** the OCI layer is a `gzip` tarball of the pack directory whose title is `<name>-<version>.tar.gz`, matching the format of packs already published to the registry.

## After pushing

The **first time** you use a new ECR registry, add it to Palette as a custom OCI pack registry (see the [Spectro Cloud docs](https://docs.spectrocloud.com/registries-and-packs/registries/oci-registry/)). From then on, the pushed packs become available once Palette re-indexes the registry — either on its automatic schedule, or immediately when you run with [`--sync`](#sync-to-palette). They then show up for use in cluster profiles.
