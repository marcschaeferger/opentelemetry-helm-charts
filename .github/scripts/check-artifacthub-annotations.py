#!/usr/bin/env python3
"""Validates the Artifact Hub annotations of the published charts.

Every annotation Artifact Hub reads is a string, so the structured ones carry YAML
inside a block scalar. This checks both layers: that Chart.yaml itself is valid, and
that the annotation values decode to the structures Artifact Hub expects.

Usage: check-artifacthub-annotations.py <chart directory> [<chart directory> ...]
"""

import pathlib
import sys

import yaml

REPOSITORY_URL = "https://github.com/open-telemetry/opentelemetry-helm-charts"
# The key the release workflow signs the charts with, served next to index.yaml.
SIGN_KEY_FINGERPRINT = "809A5AC5DA08F79218A2962799CA262FF8EBBB9B"
SIGN_KEY_URL = "https://open-telemetry.github.io/opentelemetry-helm-charts/pubkey.asc"
LICENSE = "Apache-2.0"
# https://artifacthub.io/docs/topics/annotations/helm/
CATEGORIES = {
    "ai-machine-learning",
    "database",
    "integration-delivery",
    "monitoring-logging",
    "networking",
    "security",
    "storage",
    "streaming-messaging",
    "skip-prediction",
}
CHANGE_KINDS = {"added", "changed", "deprecated", "removed", "fixed", "security"}
REQUIRED = (
    "artifacthub.io/category",
    "artifacthub.io/license",
    "artifacthub.io/links",
    "artifacthub.io/signKey",
)


def decode(annotations, key, failures):
    """Decodes a block-scalar annotation, reporting malformed YAML instead of raising."""
    try:
        return yaml.safe_load(annotations[key])
    except yaml.YAMLError as error:
        failures.append(f"{key} is not valid YAML: {error}")
        return None


def check_links(links, chart_name, failures):
    if not isinstance(links, list) or not links:
        failures.append("artifacthub.io/links does not decode to a non-empty list")
        return
    for link in links:
        if not isinstance(link, dict) or set(link) != {"name", "url"}:
            failures.append(f"artifacthub.io/links entry {link!r} is not a name/url pair")
            return
    by_name = {link["name"]: link["url"] for link in links}
    expected = {
        "Chart source": f"{REPOSITORY_URL}/tree/main/charts/{chart_name}",
        "Chart releases": f"{REPOSITORY_URL}/releases?q={chart_name}&expanded=true",
        "support": f"{REPOSITORY_URL}/issues",
    }
    for name, url in expected.items():
        if name not in by_name:
            failures.append(f"artifacthub.io/links is missing the {name!r} link")
        elif by_name[name] != url:
            failures.append(f"artifacthub.io/links {name!r} is {by_name[name]}, expected {url}")


def check_sign_key(sign_key, failures):
    if not isinstance(sign_key, dict) or set(sign_key) != {"fingerprint", "url"}:
        failures.append("artifacthub.io/signKey does not decode to a fingerprint/url mapping")
        return
    if sign_key["fingerprint"] != SIGN_KEY_FINGERPRINT:
        failures.append(f"artifacthub.io/signKey fingerprint is {sign_key['fingerprint']}")
    if sign_key["url"] != SIGN_KEY_URL:
        failures.append(f"artifacthub.io/signKey url is {sign_key['url']}")


def check_changes(changes, failures):
    """The changes annotation is injected at release time, so it is only checked if set."""
    if not isinstance(changes, list) or not changes:
        failures.append("artifacthub.io/changes does not decode to a non-empty list")
        return
    for entry in changes:
        if not isinstance(entry, dict):
            failures.append(f"artifacthub.io/changes entry {entry!r} is not a mapping")
            return
        if entry.get("kind") not in CHANGE_KINDS:
            failures.append(f"artifacthub.io/changes entry has invalid kind {entry.get('kind')!r}")
        if not entry.get("description"):
            failures.append("artifacthub.io/changes entry has an empty description")
        for link in entry.get("links", []):
            if not isinstance(link, dict) or set(link) != {"name", "url"}:
                failures.append(f"artifacthub.io/changes link {link!r} is not a name/url pair")


def check_chart(chart_dir):
    chart_yaml = pathlib.Path(chart_dir) / "Chart.yaml"
    failures = []
    try:
        chart = yaml.safe_load(chart_yaml.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as error:
        return [f"{chart_yaml} could not be read: {error}"]

    annotations = chart.get("annotations")
    if not isinstance(annotations, dict):
        return [f"{chart_yaml} has no annotations block"]

    # chart-testing validates Chart.yaml against annotations: map(str(), str()).
    for key, value in annotations.items():
        if not isinstance(key, str) or not isinstance(value, str):
            failures.append(f"annotation {key!r} is not a string to string entry")

    for key in REQUIRED:
        if key not in annotations:
            failures.append(f"{key} is missing")
    if failures:
        return failures

    if annotations["artifacthub.io/category"] not in CATEGORIES:
        failures.append(f"artifacthub.io/category {annotations['artifacthub.io/category']!r} is not an Artifact Hub category")
    if annotations["artifacthub.io/license"] != LICENSE:
        failures.append(f"artifacthub.io/license is {annotations['artifacthub.io/license']!r}, expected {LICENSE!r}")

    links = decode(annotations, "artifacthub.io/links", failures)
    if links is not None:
        check_links(links, chart.get("name", ""), failures)

    sign_key = decode(annotations, "artifacthub.io/signKey", failures)
    if sign_key is not None:
        check_sign_key(sign_key, failures)

    if "artifacthub.io/changes" in annotations:
        changes = decode(annotations, "artifacthub.io/changes", failures)
        if changes is not None:
            check_changes(changes, failures)

    return failures


def main(chart_dirs):
    failed = False
    for chart_dir in chart_dirs:
        name = pathlib.Path(chart_dir).name
        failures = check_chart(chart_dir)
        if failures:
            failed = True
            for failure in failures:
                print(f"Failed {name}. {failure}")
        else:
            print(f"Checked Artifact Hub annotations: {name}")
    if failed:
        print("Failed. Fix the Artifact Hub annotations, see CONTRIBUTING.md")
        return 1
    print("Passed")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: check-artifacthub-annotations.py <chart directory> [<chart directory> ...]")
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
