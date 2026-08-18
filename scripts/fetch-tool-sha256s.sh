#!/usr/bin/env bash
# Fetch the official SHA256SUMS for a tool from its upstream release page,
# extract the linux-amd64 and linux-arm64 hashes, and print them ready to paste
# into the Containerfile ARG defaults.
#
# Supply-chain caveat: the SHA comes from the same upstream as the binary, so
# treat it as trust-on-first-use — once committed, any FUTURE change to the
# upstream artifact (legitimate or malicious) fails verification. For higher
# assurance, cross-check against a trusted out-of-band source.
#
# Usage:
#   ./fetch-tool-sha256s.sh opentofu 1.12.3          # both arches
#   ./fetch-tool-sha256s.sh opentofu 1.12.3 amd64    # single arch
#   ./fetch-tool-sha256s.sh --all                    # all tools, both arches

set -euo pipefail

# Currently pinned versions — keep in sync with the Containerfile ARG defaults.
PINNED_OPENTOFU="1.12.3"
PINNED_TFLINT="0.63.1"
PINNED_TRIVY="0.71.2"
PINNED_CONFTEST="0.68.2"

resolve_artifact() {
  local tool="$1" version="$2" arch="$3"
  case "${tool}" in
    opentofu) echo "tofu_${version}_linux_${arch}.zip" ;;
    tflint)   echo "tflint_linux_${arch}.zip" ;;
    trivy)
      case "${arch}" in
        amd64) echo "trivy_${version}_Linux-64bit.tar.gz" ;;
        arm64) echo "trivy_${version}_Linux-ARM64.tar.gz" ;;
        *) return 1 ;;
      esac ;;
    conftest)
      case "${arch}" in
        amd64) echo "conftest_${version}_Linux_x86_64.tar.gz" ;;
        arm64) echo "conftest_${version}_Linux_arm64.tar.gz" ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

resolve_checksum_url() {
  local tool="$1" version="$2"
  case "${tool}" in
    opentofu) echo "https://github.com/opentofu/opentofu/releases/download/v${version}/tofu_${version}_SHA256SUMS" ;;
    tflint)   echo "https://github.com/terraform-linters/tflint/releases/download/v${version}/checksums.txt" ;;
    trivy)    echo "https://github.com/aquasecurity/trivy/releases/download/v${version}/trivy_${version}_checksums.txt" ;;
    conftest) echo "https://github.com/open-policy-agent/conftest/releases/download/v${version}/checksums.txt" ;;
    *) return 1 ;;
  esac
}

resolve_arg_prefix() {
  case "$1" in
    opentofu) echo "OPENTOFU_SHA256" ;;
    tflint)   echo "TFLINT_SHA256" ;;
    trivy)    echo "TRIVY_SHA256" ;;
    conftest) echo "CONFTEST_SHA256" ;;
    *) return 1 ;;
  esac
}

fetch_one_arch() {
  local tool="$1" version="$2" arch="$3"
  case "${arch}" in
    amd64|arm64) ;;
    *) echo "ERROR: unsupported arch '${arch}' (use amd64 or arm64)" >&2; return 1 ;;
  esac

  local filename
  if ! filename=$(resolve_artifact "${tool}" "${version}" "${arch}"); then
    echo "ERROR: unknown tool '${tool}'" >&2
    echo "Supported: opentofu | tflint | trivy | conftest" >&2
    return 1
  fi

  local arg_prefix arg_name checksums_url
  arg_prefix=$(resolve_arg_prefix "${tool}")
  arg_name="${arg_prefix}_${arch^^}"
  checksums_url=$(resolve_checksum_url "${tool}" "${version}")

  echo "==> ${tool} v${version} (${arch})" >&2
  echo "    Fetching: ${checksums_url}" >&2

  local sums line sha
  if ! sums=$(curl -fsSL "${checksums_url}"); then
    echo "ERROR: failed to fetch ${checksums_url}" >&2
    return 1
  fi

  line=$(echo "${sums}" | grep " ${filename}$" || echo "${sums}" | grep "  ${filename}$" || true)
  if [[ -z "${line}" ]]; then
    echo "ERROR: artifact '${filename}' not found in checksums file." >&2
    echo "${sums}" >&2
    return 1
  fi

  sha=$(echo "${line}" | awk '{print $1}')
  if ! [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: extracted value is not a hex SHA256: '${sha}'" >&2
    return 1
  fi

  echo "${arg_name}=${sha}"
}

fetch_both_arches() {
  fetch_one_arch "$1" "$2" amd64
  fetch_one_arch "$1" "$2" arm64
}

if [[ "${1:-}" == "--all" ]]; then
  fetch_both_arches opentofu "${PINNED_OPENTOFU}"
  fetch_both_arches tflint   "${PINNED_TFLINT}"
  fetch_both_arches trivy    "${PINNED_TRIVY}"
  fetch_both_arches conftest "${PINNED_CONFTEST}"
elif [[ $# -eq 3 ]]; then
  fetch_one_arch "$1" "$2" "$3"
elif [[ $# -eq 2 ]]; then
  fetch_both_arches "$1" "$2"
else
  cat >&2 <<EOF
Usage:
  $0 --all                                # all pinned tools, both arches
  $0 <tool> <version>                     # both arches for one tool
  $0 <tool> <version> <amd64|arm64>       # single arch

Tools:  opentofu | tflint | trivy | conftest
Arches: amd64 | arm64

Output is ARG_NAME=hash lines suitable for the Containerfile ARG defaults or
--build-arg flags.
EOF
  exit 1
fi
