# tf-smvp-aws Atlantis image.
#
# The customer's Atlantis control-plane image. Extends the official Atlantis
# release with OpenTofu (the default IaC engine for Aardlijn engagements) plus
# the tf-smvp policy/lint toolchain (tflint, Trivy, conftest), so plans and
# applies that run server-side use the same engine and checks as local dev
# (tofu-roll) and CI (tf-smvp-ops). Stage 06-atlantis runs it on ECS.
#
# Three build paths consume this one file: Gitea Actions (dev), GitHub Actions
# (released to ghcr), and CodeBuild via buildspec.yml inside the customer's own
# account after handoff. Keep build logic here rather than in any one of those
# pipelines -- a customer who builds it themselves has to get the same image.
#
# The base image's entrypoint/CMD are preserved — the ECS task definition
# (tf-smvp-aws-atlantis module) drives the server purely through ATLANTIS_* env
# vars and secrets, so this image must NOT override the entrypoint.
#
# All added binaries are SHA256-verified against pinned, per-architecture hashes
# — the supply-chain trust anchor. Bump a tool by editing its *_VERSION + the
# matching *_SHA256_* args (use scripts/fetch-tool-sha256s.sh on a trusted host).
#
# The AWS provider is baked in as a filesystem mirror, so a stack does not pull
# its own. That makes the provider version a property of this image rather than
# of a pull request, keeps plans off the provider registry entirely, and stops
# each project directory paying its own ~850 MiB copy. See the mirror stage.
#
# The base image tag is a multi-arch manifest (amd64 + arm64); the runtime
# resolves the right arch, and TARGETARCH selects the matching tool hash — so
# this builds correctly on x86 CodeBuild, Graviton CodeBuild, an emulated
# cross-build in Actions, or an Apple Silicon dev box without edits.
#
# Build locally (single arch):
#   podman build -t tf-smvp-aws-atlantis-image -f Containerfile .

FROM ghcr.io/runatlantis/atlantis:v0.46.0

# TARGETARCH: amd64 | arm64. Set automatically by buildah/BuildKit.
ARG TARGETARCH

# --- Pinned tool versions ---------------------------------------------------
ARG OPENTOFU_VERSION=1.12.3
ARG TFLINT_VERSION=0.63.1
ARG TRIVY_VERSION=0.71.2
ARG CONFTEST_VERSION=0.68.2

# The AWS provider is baked in and pinned here, at the runner, rather than
# resolved per stack. Bumping it is an ops action -- rebuild, re-tag, roll the
# task -- not something a pull request can do. See the filesystem mirror below.
ARG AWS_PROVIDER_VERSION=6.60.0

# --- Pinned per-arch SHA256 hashes (re-derive with scripts/fetch-tool-sha256s.sh)
ARG OPENTOFU_SHA256_AMD64="46b48c3438c65cf479fc076c9281422ffa2f493548d1e813d154c835c5986a08"
ARG OPENTOFU_SHA256_ARM64="b2110d1ce46e366ce861b7f53d293dad99080075629aed7fb50d7328916d91c2"
ARG TFLINT_SHA256_AMD64="8441a7d97df20431f19c9b9d27ff4c63e308c964e86660bc7cc0cf7bbe0725e8"
ARG TFLINT_SHA256_ARM64="6d858ca7f11858c3fe3c5e29cc746823abccb55e2d2e2da130fa7ad7ea4eecb8"
ARG TRIVY_SHA256_AMD64="0510e71e2fd39bf863856d499c8dc19feb4e7336546394c502a8f5cc7ab27460"
ARG TRIVY_SHA256_ARM64="fe1c7106e15a5365d485b098a8c338f91e3b7ba71cb0e4963b98a3a098763cfc"
ARG CONFTEST_SHA256_AMD64="e8144c6d6d2ae0260b869caa60c7c262a1f95ac63ec1e5d2fb19be452d606347"
ARG CONFTEST_SHA256_ARM64="4005441089655ded475384cb87d57762ae08ebef78305bada49c70530d2f4184"

# Provider zip hashes come from the OpenTofu registry's download endpoint
# (/v1/providers/hashicorp/aws/<version>/download/linux/<arch>, field "shasum")
# and match the `zh:` entries a `tofu init` writes into .terraform.lock.hcl, so
# the two can be cross-checked against each other.
ARG AWS_PROVIDER_SHA256_AMD64="a0c9604f236ea32555dd78862b55208beecca44339a0ef65c6915cfea5ef8cd6"
ARG AWS_PROVIDER_SHA256_ARM64="11bb0620cd8f038f998f553c5b4250e9693251a6e59cb64265d55709dcf86037"

# The base image runs as the unprivileged `atlantis` user; switch to root to
# install tools, then switch back so the server runs unprivileged.
USER root

# curl + unzip are not guaranteed in the base; tar and sha256sum come from
# busybox. The added tools are static Go binaries, so they run on musl/alpine.
#
# PINNED, because this was the last unreproducible input. Everything else here
# is fetched by pinned SHA256, but an unpinned `apk add` installs whatever the
# Alpine mirror serves that day -- a content difference, which no amount of
# timestamp rewriting in the build can normalise away. Unpinned, this layer's
# digest changes whenever Alpine publishes, and every image built after that
# point stops sharing layers with every image built before it.
#
# The versions match what the base image already records in its own environment
# (CURL_VERSION, UNZIP_VERSION), so this pins to what was there rather than
# moving anything.
#
# Cost of the pin: Alpine prunes superseded packages from the repository, so
# these eventually 404 and the build fails until they are bumped. That is a
# visible, dated failure rather than a silent loss of deduplication.
ARG CURL_VERSION=8.19.0-r0
ARG UNZIP_VERSION=6.0-r16
RUN apk add --no-cache "curl=${CURL_VERSION}" "unzip=${UNZIP_VERSION}"

# Where each component's licence text is kept.
#
# Every archive below is extracted in full and its LICENSE/NOTICE copied here
# before the rest is discarded -- previously only the binary was kept, which
# left the image carrying Apache-2.0 and MPL-2.0 software with none of the
# attribution either licence asks for. Cheap while the archive is already open;
# awkward to reconstruct afterwards.
ARG LICENSE_DIR=/usr/local/share/licenses
RUN mkdir -p "${LICENSE_DIR}"

# --- OpenTofu ---------------------------------------------------------------
RUN set -eu \
 && case "${TARGETARCH}" in \
      amd64) ARCH_TAG=amd64; EXPECTED_SHA="${OPENTOFU_SHA256_AMD64}"; HASH_VAR=OPENTOFU_SHA256_AMD64 ;; \
      arm64) ARCH_TAG=arm64; EXPECTED_SHA="${OPENTOFU_SHA256_ARM64}"; HASH_VAR=OPENTOFU_SHA256_ARM64 ;; \
      *) echo "ERROR: unsupported TARGETARCH=${TARGETARCH} (expected amd64 or arm64)" >&2; exit 1 ;; \
    esac \
 && [ -n "${EXPECTED_SHA}" ] || { echo "ERROR: ${HASH_VAR} build-arg is required." >&2; exit 1; } \
 && curl -fsSL "https://github.com/opentofu/opentofu/releases/download/v${OPENTOFU_VERSION}/tofu_${OPENTOFU_VERSION}_linux_${ARCH_TAG}.zip" -o /tmp/tofu.zip \
 && echo "${EXPECTED_SHA}  /tmp/tofu.zip" | sha256sum -c - \
 && unzip /tmp/tofu.zip -d /tmp/tofu \
 && mv /tmp/tofu/tofu /usr/local/bin/tofu \
 && mkdir -p "${LICENSE_DIR}/opentofu" \
 && cp /tmp/tofu/LICENSE* "${LICENSE_DIR}/opentofu/" \
 && rm -rf /tmp/tofu.zip /tmp/tofu \
 && chmod +x /usr/local/bin/tofu \
 && tofu version

# --- tflint -----------------------------------------------------------------
# Alone among these, tflint's release archive contains only the binary -- no
# licence text -- so MPL-2.0's requirement that a copy accompany the software
# has to be met by fetching it from the tagged source. Pinned by hash like
# every other download here; a licence that changed unnoticed is exactly the
# thing this file is otherwise careful about.
ARG TFLINT_LICENSE_SHA256="1f256ecad192880510e84ad60474eab7589218784b9a50bc7ceee34c2b91f1d5"
RUN set -eu \
 && case "${TARGETARCH}" in \
      amd64) ARCH_TAG=amd64; EXPECTED_SHA="${TFLINT_SHA256_AMD64}"; HASH_VAR=TFLINT_SHA256_AMD64 ;; \
      arm64) ARCH_TAG=arm64; EXPECTED_SHA="${TFLINT_SHA256_ARM64}"; HASH_VAR=TFLINT_SHA256_ARM64 ;; \
      *) echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && [ -n "${EXPECTED_SHA}" ] || { echo "ERROR: ${HASH_VAR} build-arg is required." >&2; exit 1; } \
 && curl -fsSL "https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_${ARCH_TAG}.zip" -o /tmp/tflint.zip \
 && echo "${EXPECTED_SHA}  /tmp/tflint.zip" | sha256sum -c - \
 && unzip /tmp/tflint.zip -d /tmp/tflint \
 && mv /tmp/tflint/tflint /usr/local/bin/tflint \
 && rm -rf /tmp/tflint.zip /tmp/tflint \
 && chmod +x /usr/local/bin/tflint \
 && tflint --version \
 && mkdir -p "${LICENSE_DIR}/tflint" \
 && curl -fsSL "https://raw.githubusercontent.com/terraform-linters/tflint/v${TFLINT_VERSION}/LICENSE" -o "${LICENSE_DIR}/tflint/LICENSE" \
 && echo "${TFLINT_LICENSE_SHA256}  ${LICENSE_DIR}/tflint/LICENSE" | sha256sum -c -

# --- Trivy ------------------------------------------------------------------
# Trivy uses 64bit (amd64) / ARM64 (arm64). Aqua's CI has been compromised more
# than once — the pinned hash is the protection.
RUN set -eu \
 && case "${TARGETARCH}" in \
      amd64) ARCH_FILE=Linux-64bit; EXPECTED_SHA="${TRIVY_SHA256_AMD64}"; HASH_VAR=TRIVY_SHA256_AMD64 ;; \
      arm64) ARCH_FILE=Linux-ARM64; EXPECTED_SHA="${TRIVY_SHA256_ARM64}"; HASH_VAR=TRIVY_SHA256_ARM64 ;; \
      *) echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && [ -n "${EXPECTED_SHA}" ] || { echo "ERROR: ${HASH_VAR} build-arg is required." >&2; exit 1; } \
 && curl -fsSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_${ARCH_FILE}.tar.gz" -o /tmp/trivy.tar.gz \
 && echo "${EXPECTED_SHA}  /tmp/trivy.tar.gz" | sha256sum -c - \
 && mkdir -p /tmp/trivy \
 && tar -xzf /tmp/trivy.tar.gz -C /tmp/trivy \
 && mv /tmp/trivy/trivy /usr/local/bin/trivy \
 && mkdir -p "${LICENSE_DIR}/trivy" \
 && cp /tmp/trivy/LICENSE* "${LICENSE_DIR}/trivy/" \
 && rm -rf /tmp/trivy.tar.gz /tmp/trivy \
 && chmod +x /usr/local/bin/trivy \
 && trivy --version

# --- conftest (OPA) ---------------------------------------------------------
# conftest uses x86_64 (amd64) / arm64 (arm64).
RUN set -eu \
 && case "${TARGETARCH}" in \
      amd64) ARCH_FILE=x86_64; EXPECTED_SHA="${CONFTEST_SHA256_AMD64}"; HASH_VAR=CONFTEST_SHA256_AMD64 ;; \
      arm64) ARCH_FILE=arm64;  EXPECTED_SHA="${CONFTEST_SHA256_ARM64}"; HASH_VAR=CONFTEST_SHA256_ARM64 ;; \
      *) echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && [ -n "${EXPECTED_SHA}" ] || { echo "ERROR: ${HASH_VAR} build-arg is required." >&2; exit 1; } \
 && curl -fsSL "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/conftest_${CONFTEST_VERSION}_Linux_${ARCH_FILE}.tar.gz" -o /tmp/conftest.tar.gz \
 && echo "${EXPECTED_SHA}  /tmp/conftest.tar.gz" | sha256sum -c - \
 && mkdir -p /tmp/conftest \
 && tar -xzf /tmp/conftest.tar.gz -C /tmp/conftest \
 && mv /tmp/conftest/conftest /usr/local/bin/conftest \
 && mkdir -p "${LICENSE_DIR}/conftest" \
 && cp /tmp/conftest/LICENSE* "${LICENSE_DIR}/conftest/" \
 && rm -rf /tmp/conftest.tar.gz /tmp/conftest \
 && chmod +x /usr/local/bin/conftest \
 && conftest --version

# --- AWS provider filesystem mirror -----------------------------------------
#
# The provider is supplied by the runner, not fetched per stack. Three things
# follow from that, and each is the reason for a specific detail below.
#
# DISK. `tofu init` materialises every provider into the project's own
# .terraform directory. The AWS provider unpacks to ~850 MiB, so an estate of
# ~32 stacks wants ~27 GiB of provider copies -- against a Fargate ephemeral
# storage default of 20 GiB, which it exhausts. The UNPACKED mirror layout is
# what avoids this: OpenTofu symlinks a project at an unpacked mirror directory
# instead of deep-copying it, so the 850 MiB is paid once for the whole task.
# The packed (.zip) layout cannot symlink -- it has to extract per project --
# so the choice of layout here is load-bearing, not stylistic.
#
# EGRESS. With the mirror serving every AWS provider request, a plan needs no
# route to a provider registry at all. That is what lets the Atlantis task's
# egress be narrowed to the VCS.
#
# CONCURRENCY. A mirror is read-only, so any number of concurrent inits share
# it safely. TF_PLUGIN_CACHE_DIR would also save the disk, but it is a
# write-through cache whose own documentation promises only a "best effort" at
# concurrency safety -- the wrong primitive for a server running parallel plans.
#
# Only hashicorp/aws is mirrored, because it is the only provider this
# framework's stacks declare. `direct` is excluded for it and left available for
# everything else: a stack that introduces a new provider still installs it
# normally, while the AWS version stays a property of this image. A stack whose
# version constraint the mirror cannot satisfy fails at init and says so, rather
# than quietly resolving to something else:
#
#   Error: Failed to resolve provider packages
#   Could not resolve provider hashicorp/aws: no available releases match the
#   given constraints ~> 7.0
#
# Two expected messages, neither of them a fault:
#
#   "Installed hashicorp/aws vX (unauthenticated)" -- OpenTofu does not GPG-
#   verify a mirror install, because a mirror carries no signature. The pinned
#   SHA256 checked above is the trust anchor in its place, which is the same
#   anchor used for every other binary in this image.
#
#   "Incomplete lock file information for providers ... only includes checksums
#   for linux_amd64" -- a mirror install can only hash the platform present.
#   Harmless for a Linux-only runner, and moot for estates that keep the lock
#   file out of version control.
#
# Verified against this image: `tofu init` succeeds with the container's network
# disabled entirely, and the installed provider is a symlink -- the project's
# .terraform measures 4 KiB on disk against 841 MiB dereferenced.
ARG AWS_PROVIDER_MIRROR=/usr/local/share/tofu/providers

RUN set -eu \
 && case "${TARGETARCH}" in \
      amd64) ARCH_TAG=amd64; EXPECTED_SHA="${AWS_PROVIDER_SHA256_AMD64}"; HASH_VAR=AWS_PROVIDER_SHA256_AMD64 ;; \
      arm64) ARCH_TAG=arm64; EXPECTED_SHA="${AWS_PROVIDER_SHA256_ARM64}"; HASH_VAR=AWS_PROVIDER_SHA256_ARM64 ;; \
      *) echo "ERROR: unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && [ -n "${EXPECTED_SHA}" ] || { echo "ERROR: ${HASH_VAR} build-arg is required." >&2; exit 1; } \
 && DEST="${AWS_PROVIDER_MIRROR}/registry.opentofu.org/hashicorp/aws/${AWS_PROVIDER_VERSION}/linux_${ARCH_TAG}" \
 && mkdir -p "${DEST}" \
 && curl -fsSL "https://github.com/opentofu/terraform-provider-aws/releases/download/v${AWS_PROVIDER_VERSION}/terraform-provider-aws_${AWS_PROVIDER_VERSION}_linux_${ARCH_TAG}.zip" -o /tmp/aws-provider.zip \
 && echo "${EXPECTED_SHA}  /tmp/aws-provider.zip" | sha256sum -c - \
 && unzip -q /tmp/aws-provider.zip -d "${DEST}" \
 && rm /tmp/aws-provider.zip \
 && chmod -R a+rX "${AWS_PROVIDER_MIRROR}" \
 && chmod a+x "${DEST}/terraform-provider-aws" \
 && [ -x "${DEST}/terraform-provider-aws" ] || { echo "ERROR: provider binary missing or not executable in ${DEST}" >&2; exit 1; } \
 && mkdir -p "${LICENSE_DIR}/terraform-provider-aws" \
 && cp "${DEST}/LICENSE" "${LICENSE_DIR}/terraform-provider-aws/" \
 && grep -qi 'Mozilla Public License' "${LICENSE_DIR}/terraform-provider-aws/LICENSE" \
    || { echo "ERROR: provider licence is not MPL-2.0 -- registry may have changed. Review before shipping." >&2; exit 1; }

# The CLI config is written at build time so the mirror applies to every caller
# -- the Atlantis server, and anyone who execs into the task to debug.
#
# Note for consumers: a .terraform.lock.hcl generated against a registry records
# `zh:` (zip) hashes, which a mirror install cannot reproduce -- it has no zip.
# Estates built on this image therefore leave the lock file out of version
# control, which is consistent with the provider version being owned here.
RUN set -eu \
 && mkdir -p /etc/tofu \
 && printf '%s\n' \
      'provider_installation {' \
      '  filesystem_mirror {' \
      "    path    = \"${AWS_PROVIDER_MIRROR}\"" \
      '    include = ["registry.opentofu.org/hashicorp/aws"]' \
      '  }' \
      '  direct {' \
      '    exclude = ["registry.opentofu.org/hashicorp/aws"]' \
      '  }' \
      '}' \
    > /etc/tofu/tofurc \
 && chmod 0644 /etc/tofu/tofurc

ENV TF_CLI_CONFIG_FILE=/etc/tofu/tofurc

# --- Attribution -------------------------------------------------------------
#
# Covers what this image redistributes, including the parts inherited from the
# base rather than added here. Two of those are worth knowing about:
#
#   Terraform. The upstream Atlantis image ships several Terraform binaries
#   (~476 MiB of them). Every version present is 1.6.0 or later, so they are
#   BUSL-1.1 -- source-available, NOT open source. BUSL grants redistribution
#   but requires the licence be displayed on each copy, which is the gap this
#   file closes. They cannot be removed by deleting them in a later layer: the
#   bytes stay in the base layer and remain extractable, so `rm` would buy
#   neither size nor a cleaner licence position. Nothing here runs them --
#   ATLANTIS_DEFAULT_TF_DISTRIBUTION is opentofu.
#
#   The AWS provider. MPL-2.0, because it is fetched from
#   registry.opentofu.org. The identically-named provider on
#   registry.terraform.io is BUSL-1.1. The registry this image mirrors from is
#   therefore a licensing decision as much as a supply-chain one, and the build
#   asserts the licence it actually received rather than trusting that.
#
# MPL-2.0 requires recipients be told where to obtain source; the URLs below
# are that notice. Apache-2.0 requires the licence accompany the work, which
# the per-component directories provide.
RUN set -eu \
 && printf '%s\n' \
 'This image redistributes the following components. Licence texts, where the' \
 'upstream archive provides one, are in /usr/local/share/licenses/<component>/.' \
 '' \
 'ADDED BY THIS IMAGE' \
 '  OpenTofu                MPL-2.0     https://github.com/opentofu/opentofu' \
 '  tflint                  MPL-2.0     https://github.com/terraform-linters/tflint' \
 '  Trivy                   Apache-2.0  https://github.com/aquasecurity/trivy' \
 '  conftest                Apache-2.0  https://github.com/open-policy-agent/conftest' \
 '  terraform-provider-aws  MPL-2.0     https://github.com/opentofu/terraform-provider-aws' \
 '' \
 'INHERITED FROM THE BASE IMAGE (ghcr.io/runatlantis/atlantis)' \
 '  Atlantis                Apache-2.0  https://github.com/runatlantis/atlantis' \
 '  Terraform               BUSL-1.1    https://github.com/hashicorp/terraform' \
 '  Alpine base packages    various     https://pkgs.alpinelinux.org' \
 '' \
 'Terraform is source-available under the Business Source Licence, not open' \
 'source. It is present because the base image ships it; this image does not' \
 'invoke it (ATLANTIS_DEFAULT_TF_DISTRIBUTION=opentofu).' \
 '' \
 'The Aardlijn build definition itself is not licensed for redistribution; see' \
 'the LICENSE in the source repository named by org.opencontainers.image.source.' \
    > "${LICENSE_DIR}/NOTICE" \
 && chmod 0644 "${LICENSE_DIR}/NOTICE"

# --- Image metadata ----------------------------------------------------------
#
# Overriding the base's labels, not adding to them. Inherited unchanged, this
# image announces itself as `title=atlantis`, `authors=@runatlantis Github Org`
# and `source=github.com/runatlantis/atlantis` -- so a registry links the
# package to a repository that did not build it, and anyone reading the
# metadata is told upstream authored a tree they never saw.
#
# `source` is also what makes a package page link back to its build definition,
# so it has to be the repository holding THIS Containerfile.
#
# The licence expression is deliberately the union of what ships, BUSL
# included, rather than the licence of the parts we happen to have chosen.
ARG IMAGE_SOURCE=https://github.com/aardlijn/tf-aws-atlantis
# Revision only. There is deliberately no version label.
#
# A release tag is applied by RE-TAGGING the image the branch build already
# produced, not by building again -- so at the moment the image is built, the
# version it will be released under is not yet known, and baking one in would
# mean rebuilding. That rebuild is what this arrangement exists to avoid: it
# produced a second, near-identical image per release and left the first
# orphaned in the registry.
#
# The revision is stable for a given commit, so it survives the re-tag and
# still answers "what built this". The version lives in the tag itself and in
# the published source commit.
ARG IMAGE_REVISION=""

LABEL org.opencontainers.image.title="tf-aws-atlantis" \
      org.opencontainers.image.description="Atlantis with OpenTofu, a baked-in AWS provider mirror, and the tf-smvp policy toolchain (tflint, Trivy, conftest)." \
      org.opencontainers.image.vendor="Aardlijn B.V." \
      org.opencontainers.image.authors="Aardlijn B.V." \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.url="${IMAGE_SOURCE}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.licenses="Apache-2.0 AND MPL-2.0 AND BUSL-1.1" \
      org.opencontainers.image.base.name="ghcr.io/runatlantis/atlantis:v0.46.0"

# Default Atlantis to OpenTofu. The ECS task env (set by the atlantis module)
# can still override any ATLANTIS_* value. Leaving TF download enabled lets a
# repo pin a specific tofu version; the baked tofu on PATH serves the unpinned
# default. Set ATLANTIS_TF_DOWNLOAD=false in the task env for a hermetic
# (airgap) posture once every repo pins to the baked version.
ENV ATLANTIS_DEFAULT_TF_DISTRIBUTION=opentofu

# Back to the unprivileged user; entrypoint/CMD inherited from the base image.
USER atlantis
