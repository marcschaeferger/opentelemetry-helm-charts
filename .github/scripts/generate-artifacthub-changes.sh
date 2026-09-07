#!/bin/bash
# Generates the artifacthub.io/changes annotation for the charts that are about to be
# released. The change list is derived from the commits that touched the chart since its
# previous release tag, so it never has to be maintained by hand and cannot drift from
# what is actually released.
#
# This runs in the release workflow, before the charts are packaged, and writes only to
# the working copy. The annotation is deliberately not committed: the commits that make
# up a chart version are only known once they are on main, which is after the version
# bump has been reviewed and merged.
#
# A chart that cannot be processed is left without the annotation and the reason is
# logged. This script never fails the release.

set -Eeuo pipefail
IFS=$'\n\t'

REPOSITORY="${GITHUB_REPOSITORY:-open-telemetry/opentelemetry-helm-charts}"
REPOSITORY_URL="https://github.com/${REPOSITORY}"
CHARTS_DIR="${CHARTS_DIR:-charts}"
MAX_CHANGES="${MAX_CHANGES:-25}"
ANNOTATION="artifacthub.io/changes"

log() {
  echo "$*"
}

chart_version() {
  sed -n 's/^version: //p' "$1" | head -1
}

# The tag glob is deliberately paired with an exact semver match: "opentelemetry-ebpf-*"
# also matches the opentelemetry-ebpf-instrumentation tags.
previous_release_tag() {
  local chart_name="$1"
  git tag -l "${chart_name}-*" --sort=-version:refname \
    | grep -E "^${chart_name}-[0-9]+\.[0-9]+\.[0-9]+$" \
    | head -1
}

# Maps a commit subject onto one of the change kinds Artifact Hub renders.
change_kind() {
  local subject="$1" type
  type="$(printf '%s' "${subject}" | sed -nE 's/^([a-zA-Z]+)(\([^)]*\))?!?[:[:space:]].*/\1/p')"
  case "$(printf '%s' "${type}" | tr '[:upper:]' '[:lower:]')" in
    feat|feature) echo "added" ;;
    fix|bugfix|hotfix) echo "fixed" ;;
    sec|security) echo "security" ;;
    deprecate|deprecated) echo "deprecated" ;;
    remove|removed) echo "removed" ;;
    *) echo "changed" ;;
  esac
}

# Strips the squash-merge pull request suffix and the conventional commit or bracketed
# chart prefix, so the description reads as a change rather than as a commit subject.
change_description() {
  printf '%s' "$1" \
    | sed -E 's/[[:space:]]*\(#[0-9]+\)[[:space:]]*$//' \
    | sed -E 's/^[a-zA-Z]+(\([^)]*\))?!?:[[:space:]]*//' \
    | sed -E 's/^[a-zA-Z]+\([^)]*\)!?[[:space:]]+//' \
    | sed -E 's/^\[[^]]*\][[:space:]]*:?[[:space:]]*//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

pull_request_number() {
  printf '%s' "$1" | sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p'
}

yaml_quote() {
  local value="$1"
  value="${value//\/\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

# Emits the annotation value: a YAML list of Artifact Hub change entries.
render_changes() {
  local chart_name="$1" revision_range="$2"
  local subject kind description number count=0
  declare -A seen=()

  while IFS= read -r subject; do
    [ -n "${subject}" ] || continue
    description="$(change_description "${subject}")"
    [ -n "${description}" ] || description="${subject}"
    [ -z "${seen[${description}]:-}" ] || continue
    seen[${description}]=1

    kind="$(change_kind "${subject}")"
    printf -- '- kind: %s\n' "${kind}"
    printf -- '  description: %s\n' "$(yaml_quote "${description}")"

    number="$(pull_request_number "${subject}")"
    if [ -n "${number}" ]; then
      printf -- '  links:\n'
      printf -- '    - name: %s\n' "$(yaml_quote "Pull request #${number}")"
      printf -- '      url: %s/pull/%s\n' "${REPOSITORY_URL}" "${number}"
    fi

    count=$((count + 1))
    [ "${count}" -lt "${MAX_CHANGES}" ] || break
  done < <(git log --no-merges --format='%s' "${revision_range}" -- "${CHARTS_DIR}/${chart_name}")
}

# The annotation is appended, so the annotations block has to be the last top-level key.
annotations_block_is_last() {
  local last_key
  last_key="$(grep -oE '^[A-Za-z][A-Za-z0-9_.-]*:' "$1" | tail -1 | tr -d ':')"
  [ "${last_key}" = "annotations" ]
}

append_annotation() {
  local chart_yaml="$1" changes="$2"
  {
    printf '  %s: |\n' "${ANNOTATION}"
    printf '%s\n' "${changes}" | sed 's/^/    /'
  } >> "${chart_yaml}"
}

generate_for_chart() {
  local chart_yaml="$1"
  local chart_name version tag previous_tag revision_range changes

  chart_name="$(basename "$(dirname "${chart_yaml}")")"
  version="$(chart_version "${chart_yaml}")"

  if [ -z "${version}" ]; then
    log "Skipping ${chart_name}: no version in ${chart_yaml}"
    return 0
  fi

  tag="${chart_name}-${version}"
  if git rev-parse -q --verify "refs/tags/${tag}" > /dev/null; then
    log "Skipping ${chart_name}: ${tag} is already released"
    return 0
  fi

  if grep -q "^  ${ANNOTATION}:" "${chart_yaml}"; then
    log "Skipping ${chart_name}: ${ANNOTATION} is already set"
    return 0
  fi

  if ! grep -q '^annotations:' "${chart_yaml}"; then
    log "Skipping ${chart_name}: no annotations block in ${chart_yaml}"
    return 0
  fi

  if ! annotations_block_is_last "${chart_yaml}"; then
    log "Skipping ${chart_name}: the annotations block is not the last key in ${chart_yaml}"
    return 0
  fi

  previous_tag="$(previous_release_tag "${chart_name}")"
  if [ -n "${previous_tag}" ]; then
    revision_range="${previous_tag}..HEAD"
  else
    revision_range="HEAD"
  fi

  changes="$(render_changes "${chart_name}" "${revision_range}")"
  if [ -z "${changes}" ]; then
    log "Skipping ${chart_name}: no commits touching ${CHARTS_DIR}/${chart_name} in ${revision_range}"
    return 0
  fi

  append_annotation "${chart_yaml}" "${changes}"
  log "Generated ${ANNOTATION} for ${tag} from ${revision_range}"
}

main() {
  local chart_yaml
  for chart_yaml in "${CHARTS_DIR}"/*/Chart.yaml; do
    [ -f "${chart_yaml}" ] || continue
    generate_for_chart "${chart_yaml}" || log "Skipping $(basename "$(dirname "${chart_yaml}")"): generation failed"
  done
}

main "$@"
