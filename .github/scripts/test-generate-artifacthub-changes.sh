#!/bin/bash
# Tests generate-artifacthub-changes.sh against a throwaway repository, so the expected
# change lists stay deterministic and no release has to be published to exercise them.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="${SCRIPT_DIR}/generate-artifacthub-changes.sh"
TESTDATA="${SCRIPT_DIR}/testdata/generate-artifacthub-changes"
WORK_DIR=""
FAILURES=0

cleanup() {
  [ -z "${WORK_DIR}" ] || rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

fail() {
  echo "  FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

assert_contains() {
  grep -qF -- "$2" "$1" || fail "expected $(basename "$1") to contain: $2"
}

assert_not_contains() {
  grep -qF -- "$2" "$1" && fail "expected $(basename "$1") not to contain: $2"
  return 0
}

commit_change() {
  local chart_name="$1" subject="$2"
  mkdir -p "charts/${chart_name}"
  echo "${subject}" >> "charts/${chart_name}/values.yaml"
  git add --all
  git commit --quiet --message "${subject}"
}

set_version() {
  local chart_name="$1" version="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v v="${version}" '/^version: / { print "version: " v; next } { print }' \
    "charts/${chart_name}/Chart.yaml" > "${tmp}"
  mv "${tmp}" "charts/${chart_name}/Chart.yaml"
}

new_repository() {
  local fixture="${1:-chart-annotations-last.yaml}"
  WORK_DIR="$(mktemp -d)"
  cd "${WORK_DIR}"
  git init --quiet
  git config user.name "test"
  git config user.email "test@example.com"
  git config commit.gpgsign false
  mkdir -p charts/example-chart charts/other-chart
  cp "${TESTDATA}/${fixture}" charts/example-chart/Chart.yaml
  sed 's/^name: example-chart$/name: other-chart/' "${TESTDATA}/chart-annotations-last.yaml" \
    > charts/other-chart/Chart.yaml
  echo "{}" > charts/example-chart/values.yaml
  echo "{}" > charts/other-chart/values.yaml
  git add --all
  git commit --quiet --message "initial commit"
  git tag example-chart-0.1.0
  git tag other-chart-0.1.0
}

run_generator() {
  GITHUB_REPOSITORY="open-telemetry/opentelemetry-helm-charts" \
    bash "${GENERATOR}" > generator.log 2>&1
}

annotation_value() {
  sed -n '/^  artifacthub.io\/changes: |$/,$p' charts/example-chart/Chart.yaml | tail -n +2 | sed 's/^    //'
}

test_generates_scoped_and_kinded_changes() {
  echo "test: generates chart-scoped changes with kinds and pull request links"
  new_repository
  commit_change example-chart "feat(example-chart): add a preset (#101)"
  commit_change example-chart "fix(example-chart): stop dropping attributes (#102)"
  commit_change example-chart "chore(deps): bump a dependency (#103)"
  commit_change example-chart "[example-chart]: bump to 1.2.3 (#104)"
  commit_change other-chart "feat(other-chart): unrelated change (#105)"
  set_version example-chart 0.1.1
  run_generator

  local chart="charts/example-chart/Chart.yaml"
  assert_contains "${chart}" "  artifacthub.io/changes: |"
  assert_contains "${chart}" "- kind: added"
  assert_contains "${chart}" 'description: "add a preset"'
  assert_contains "${chart}" "- kind: fixed"
  assert_contains "${chart}" 'description: "stop dropping attributes"'
  assert_contains "${chart}" "- kind: changed"
  assert_contains "${chart}" 'description: "bump a dependency"'
  assert_contains "${chart}" 'description: "bump to 1.2.3"'
  assert_contains "${chart}" 'name: "Pull request #101"'
  assert_contains "${chart}" "url: https://github.com/open-telemetry/opentelemetry-helm-charts/pull/101"
  # The other chart's commit must not leak in, and it must not be released either.
  assert_not_contains "${chart}" "unrelated change"
  assert_not_contains "charts/other-chart/Chart.yaml" "artifacthub.io/changes"

  annotation_value > changes.yaml
  if command -v python3 > /dev/null; then
    python3 - <<'PY' || fail "the generated changes annotation is not a valid Artifact Hub change list"
import sys, yaml
changes = yaml.safe_load(open("changes.yaml", encoding="utf-8"))
kinds = {"added", "changed", "deprecated", "removed", "fixed", "security"}
assert isinstance(changes, list) and changes, changes
for entry in changes:
    assert entry["kind"] in kinds, entry
    assert entry["description"], entry
PY
  fi
  if command -v helm > /dev/null; then
    helm show chart charts/example-chart > /dev/null || fail "helm cannot parse the generated Chart.yaml"
  fi
}

test_escapes_quotes_in_descriptions() {
  echo "test: escapes quotes so the annotation stays valid YAML"
  new_repository
  commit_change example-chart 'fix(example-chart): quote the "mode" value (#201)'
  set_version example-chart 0.1.1
  run_generator
  assert_contains "charts/example-chart/Chart.yaml" 'description: "quote the \"mode\" value"'
  if command -v python3 > /dev/null; then
    annotation_value > changes.yaml
    python3 -c "import yaml;yaml.safe_load(open('changes.yaml',encoding='utf-8'))" \
      || fail "escaped description does not round-trip through YAML"
  fi
}

test_skips_already_released_version() {
  echo "test: skips a version that is already tagged"
  new_repository
  commit_change example-chart "feat(example-chart): add a preset (#301)"
  run_generator
  assert_not_contains "charts/example-chart/Chart.yaml" "artifacthub.io/changes"
  assert_contains generator.log "is already released"
}

test_skips_when_no_commits_touch_the_chart() {
  echo "test: skips instead of writing an empty change list"
  new_repository
  commit_change other-chart "feat(other-chart): unrelated change (#401)"
  set_version example-chart 0.1.1
  run_generator
  assert_not_contains "charts/example-chart/Chart.yaml" "artifacthub.io/changes"
  assert_contains generator.log "no commits touching charts/example-chart"
}

test_skips_when_annotations_block_is_not_last() {
  echo "test: skips when the annotations block is not the last key"
  new_repository chart-annotations-not-last.yaml
  commit_change example-chart "feat(example-chart): add a preset (#501)"
  set_version example-chart 0.1.1
  run_generator
  assert_not_contains "charts/example-chart/Chart.yaml" "artifacthub.io/changes"
  assert_contains generator.log "is not the last key"
}

test_keeps_an_existing_changes_annotation() {
  echo "test: does not overwrite an existing changes annotation"
  new_repository
  commit_change example-chart "feat(example-chart): add a preset (#601)"
  set_version example-chart 0.1.1
  printf '  artifacthub.io/changes: |\n    - kind: added\n      description: "hand written"\n' \
    >> charts/example-chart/Chart.yaml
  run_generator
  assert_contains "charts/example-chart/Chart.yaml" 'description: "hand written"'
  assert_not_contains "charts/example-chart/Chart.yaml" 'description: "add a preset"'
  assert_contains generator.log "is already set"
}

main() {
  test_generates_scoped_and_kinded_changes
  test_escapes_quotes_in_descriptions
  test_skips_already_released_version
  test_skips_when_no_commits_touch_the_chart
  test_skips_when_annotations_block_is_not_last
  test_keeps_an_existing_changes_annotation

  if [ "${FAILURES}" -ne 0 ]; then
    echo "Failed. ${FAILURES} assertion(s) failed"
    exit 1
  fi
  echo "Passed"
}

main "$@"
