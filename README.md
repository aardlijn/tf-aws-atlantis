# tf-smvp-aws-atlantis-image

The customer's [Atlantis](https://www.runatlantis.io) control-plane image for
tf-smvp engagements. Extends the official Atlantis release with **OpenTofu**
(the default Aardlijn IaC engine) plus the tf-smvp policy/lint toolchain, so
server-side plans/applies use the same engine and checks as local dev
([tofu-roll](../tofu-roll)) and CI (`tf-smvp-ops/ci`).

This is the image whose absence blocks a working Atlantis: stage `06-atlantis`
runs it on ECS Fargate and has nothing to pull until it is published.

While Aardlijn runs the engagement the image is built by our CI and pulled from
a registry we publish. After handoff the customer builds it in their own account
from the same `Containerfile`. Both paths are supported and both are expected to
stay working — see below.

## What's added to the base

| Tool | Why |
|------|-----|
| OpenTofu (`tofu`) | IaC engine Atlantis runs for plan/apply |
| conftest | OPA policy checks (also usable by Atlantis `policy_check`) |
| tflint | HCL lint step for custom workflows |
| Trivy | IaC misconfig scan for custom workflows |

Base: `ghcr.io/runatlantis/atlantis:v0.46.0` (multi-arch). The entrypoint/CMD
are inherited unchanged — the ECS task definition (the `tf-smvp-aws-atlantis`
module) drives the server entirely through `ATLANTIS_*` env vars and Secrets
Manager secrets, so this image must not override them.

`ATLANTIS_DEFAULT_TF_DISTRIBUTION=opentofu` is baked as a default; the ECS task
env can still override any `ATLANTIS_*` value.

## How it gets built

Three paths, deliberately. The first two are ours; the third is the customer's,
and it exists so that handing over the engagement hands over a stack they can
keep building rather than one they can only keep pulling.

| Path | Produced by | Lands in | Audience |
|------|-------------|----------|----------|
| Dev | Gitea Actions build ([`.gitea/workflows/image.yaml`](.gitea/workflows/image.yaml)) | `git.lsquared.me/aardlijn/tf-smvp-aws-atlantis-image` | Aardlijn dev + internal testing |
| Release | the **same** workflow's `promote` job, on a `v*` tag | `ghcr.io/aardlijn/tf-smvp-aws-atlantis-image` | Engagements |
| In-account | CodeBuild, from [`buildspec.yml`](buildspec.yml) | the customer's own ECR | The customer, post-handoff |

**Release is a promotion, not a second build.** The `promote` job copies the
manifest with `skopeo copy --all`, so the released image is byte-identical to
the one tested on Gitea — same digest, whole multi-arch index intact. Rebuilding
on the far side would produce a different digest and could pick up a drifted
base image between the two runs, meaning the thing customers pull would not be
the thing that was verified.

Releases are published under Aardlijn's own name. The publishing namespace has
to be an account the release App is installed on, and maintaining a second
installation on a client-facing org — purely so the image URI reads differently
— buys appearance at the cost of a second trust relationship to manage. The
packages are private either way, which is the shape a customer's own on-prem
build would have, so the namespace is visible only to accounts already granted
a pull.

Engagements are still contracted and delivered through Delta Arc; only the
registry path names Aardlijn. If that ever needs to change, `RELEASE_IMAGE` is
a variable and the App can be installed elsewhere.

**All three build the same `Containerfile`.** That is the constraint that makes
handoff meaningful — a customer who forks this repo and runs the CodeBuild path
gets the image we would have shipped them, from the same pinned versions and the
same verified hashes, rather than an approximation of it. Any build logic that
lives in a workflow instead of the `Containerfile` breaks that equivalence.

### In-account build (handoff)

CodeBuild consumes `buildspec.yml`: ECR login → `docker build` → push to
`<ecr>:<atlantis_image_tag>`. It needs `AWS_DEFAULT_REGION`, `AWS_ACCOUNT_ID`,
`ECR_REPOSITORY_URI` and `IMAGE_TAG` in the project environment, and the project
must run in **privileged mode** since it builds a container.

```bash
aws codebuild start-build --project-name <customer>-atlantis-build
```

> **Gap:** the ECR repository and CodeBuild project this path needs are not
> currently provisioned by any `smvp-ops` stage — ADR 0001 removed them from
> `04-devops` when the registry moved to ghcr. `buildspec.yml` is therefore ready
> but unwired. Reinstating that infrastructure, gated to the handoff case rather
> than provisioned for every customer from day one, is outstanding work.

## How it fits the bootstrap

1. Set `atlantis_image` on the `tf-smvp-aws//atlantis` module to a
   **commit-SHA-tagged** image from whichever path applies. Every build prints
   the tag to pin.
2. **Stage 06-atlantis** deploys the ECS service from that URI.

Pin the commit SHA, never `:latest`. Two reasons, and the second is the one that
bites:

- The SHA names the source that produced the image, so a running Atlantis can be
  traced back to a diff without consulting a build log.
- An ECS task definition that references a moving tag redeploys **nothing** when
  the tag moves. The task definition itself is unchanged, so there is nothing
  for ECS to reconcile and the new image never rolls out.

A manifest digest (`@sha256:…`) is the stricter pin — a git SHA tag is immutable
by convention, a digest by construction — so prefer the digest where a rebuild
of the same commit must be ruled out. It costs readability: the digest says
nothing about which commit it came from.

Pulling from a private registry needs `repositoryCredentials` on the task
definition, pointing at a Secrets Manager secret holding the registry username
and token. ECR is the exception: access there is IAM, so the in-account path
needs no such secret.

## Multi-platform

Builds and runs on linux/amd64 and linux/arm64 (x86 or Graviton Fargate, Apple
Silicon dev box). The base tag is a multi-arch manifest, and
`TARGETARCH` selects the matching pinned hash for each added tool — no per-host
edits. The added tools are static Go binaries, so they run on the base's
musl/alpine userland.

```bash
# Local single-arch build
podman build -t tf-smvp-aws-atlantis-image -f Containerfile .

# Inspect the toolchain
podman run --rm --entrypoint sh tf-smvp-aws-atlantis-image -c \
  'tofu version; conftest --version; tflint --version; trivy --version; atlantis version'
```

## Supply chain

Every added binary is SHA256-verified against pinned, per-arch hashes at build
time — version pinning alone is insufficient (Trivy's upstream CI has been
compromised more than once). The base image is pinned by tag; pin it by manifest
digest if you want immutability across both arches.

Bump a tool:

```bash
./scripts/fetch-tool-sha256s.sh --all            # all tools, both arches
./scripts/fetch-tool-sha256s.sh opentofu 1.12.4  # one tool
```

Paste the emitted `*_SHA256_AMD64` / `*_SHA256_ARM64` lines into the matching
ARG defaults in `Containerfile` and bump the `*_VERSION`.

### Pinned versions

| Component | Version |
|-----------|---------|
| Atlantis (base) | v0.46.0 |
| OpenTofu | 1.12.3 |
| tflint | 0.63.1 |
| Trivy | 0.71.2 |
| conftest | 0.68.2 |

## License

Aardlijn proprietary. See [LICENSE](LICENSE).
