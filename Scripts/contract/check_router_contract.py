#!/usr/bin/env python3
"""Fail if the SDK's Comfy Router surface drifts from the vendored Router contract.

The Router surface has no generated artifact — its contract lands in the SDK as two
hand-written tables — so the drift that matters is a spec edit that never reached them:

1. **Error buckets vs ``spec/router-openapi.yaml``.** The spec's
   ``components.schemas.RouterErrorType.x-comfy-error-types`` list is the closed error set.
   ``RouterErrorType`` in ``Sources/ComfySwiftSDK/Public/RouterError.swift`` must carry
   exactly those wire values in exactly that order, so a bucket added, removed *or
   reordered* upstream all fail — not only an addition. A bucket the spec declares and the
   SDK has no case for would otherwise reach callers as ``.unknown``.
2. **The bound model-run route vs ``spec/router-openapi.yaml``.** ``RouterConstants`` in
   ``Sources/ComfySwiftSDK/Internal/RouterConstants.swift`` hard-codes the run path and the
   default host; the spec declares both — the path whose ``post.operationId`` is
   ``runRouterModel``, and ``servers[0].url``. A sync that *moves* the route while those
   constants stay put would leave the SDK posting to a route the contract no longer
   declares, with nothing else in CI noticing.

Mirrors the router half of the Python SDK's ``scripts/check_drift.py``.
``Tests/ComfySwiftSDKTests/RouterErrorMappingTests.swift`` asserts the Swift-side half of
the same invariants from ``swift test``; both exist on purpose — the suite is where a
contributor sees it, and this script is the job that fails a spec-only PR that never ran it.

Exit codes:
  0  the tables and the spec agree
  1  a bucket is missing, extra or misordered; a constant has drifted; or an input could
     not be read
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("error: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent.parent
SPEC = ROOT / "spec" / "router-openapi.yaml"
ERROR_TYPES_SWIFT = ROOT / "Sources" / "ComfySwiftSDK" / "Public" / "RouterError.swift"
CONSTANTS_SWIFT = ROOT / "Sources" / "ComfySwiftSDK" / "Internal" / "RouterConstants.swift"

# The marked block in RouterError.swift that holds the wire table, one bucket per line.
BLOCK_BEGIN = "// router-error-types:begin"
BLOCK_END = "// router-error-types:end"

IN_ACTIONS = bool(os.environ.get("GITHUB_ACTIONS"))


class ContractError(Exception):
    """An input could not be read or does not have the shape this check needs.

    Raised rather than letting a ``KeyError``/``TypeError`` escape: a sync that reshapes or
    drops part of the contract should fail this job with a sentence someone can act on, not
    with a traceback that reads like a bug in the checker.
    """


def fail(message):
    """Report one failure — as a GitHub annotation in CI, and on stderr always."""
    if IN_ACTIONS:
        # Newlines would truncate the annotation at its first line.
        print(f"::error::{message.replace(chr(10), ' ')}")
    print(f"ERROR: {message}", file=sys.stderr)


def load_spec():
    """The vendored spec as a mapping.

    ``encoding='utf-8'`` is explicit because the spec's ``meaning`` prose is not ASCII:
    reading it under a non-UTF-8 locale default would raise ``UnicodeDecodeError`` on a file
    that is perfectly fine.
    """
    if not SPEC.exists():
        raise ContractError(
            f"{SPEC.relative_to(ROOT)} is missing — vendor the Router spec back into spec/."
        )
    try:
        doc = yaml.safe_load(SPEC.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ContractError(f"{SPEC.relative_to(ROOT)} could not be read: {exc}") from exc
    except yaml.YAMLError as exc:
        raise ContractError(f"{SPEC.relative_to(ROOT)} is not valid YAML: {exc}") from exc
    if not isinstance(doc, dict):
        raise ContractError(f"{SPEC.relative_to(ROOT)} is not a mapping at the top level.")
    return doc


def declared_error_types(doc):
    """The spec's ``x-comfy-error-types`` wire values, in declaration order."""
    node = doc
    for key in ("components", "schemas", "RouterErrorType", "x-comfy-error-types"):
        if not isinstance(node, dict) or key not in node:
            raise ContractError(
                f"{SPEC.relative_to(ROOT)} has no "
                f"components.schemas.RouterErrorType.x-comfy-error-types (stopped at {key!r})."
            )
        node = node[key]
    if not isinstance(node, list) or not node:
        raise ContractError(
            f"{SPEC.relative_to(ROOT)}'s x-comfy-error-types is not a non-empty list."
        )
    values = []
    for entry in node:
        if not isinstance(entry, dict) or not isinstance(entry.get("value"), str):
            raise ContractError(
                f"{SPEC.relative_to(ROOT)} has an x-comfy-error-types entry with no string value."
            )
        # Rejected here rather than downstream: a repeated value would make the two lists
        # differ only in length and get reported below as "same values, different order",
        # sending the reader hunting for an ordering diff that does not exist.
        if entry["value"] in values:
            raise ContractError(
                f"{SPEC.relative_to(ROOT)} declares x-comfy-error-types value "
                f"{entry['value']!r} more than once."
            )
        values.append(entry["value"])
    return values


def declared_run_route(doc):
    """The spec's ``(runRouterModel path, servers[0].url)``."""
    paths = doc.get("paths")
    if not isinstance(paths, dict):
        raise ContractError(f"{SPEC.relative_to(ROOT)} has no paths object.")
    # Searched by operationId rather than looked up by the path we expect: a lookup would
    # silently find nothing the day the path moves, which is the one day this check exists
    # for.
    declared = [
        path
        for path, item in paths.items()
        if isinstance(item, dict)
        and isinstance(item.get("post"), dict)
        and item["post"].get("operationId") == "runRouterModel"
    ]
    if len(declared) != 1:
        raise ContractError(
            f"{SPEC.relative_to(ROOT)} declares {len(declared)} paths with "
            f"post.operationId 'runRouterModel' (expected exactly 1): {declared}"
        )
    servers = doc.get("servers")
    if not isinstance(servers, list) or not servers or not isinstance(servers[0], dict):
        raise ContractError(f"{SPEC.relative_to(ROOT)} has no servers[0].")
    host = servers[0].get("url")
    if not isinstance(host, str) or not host:
        raise ContractError(
            f"{SPEC.relative_to(ROOT)}'s servers[0].url is not a non-empty string."
        )
    return declared[0], host


def sdk_error_types():
    """The wire values in ``RouterError.swift``'s marked table, in source order.

    The table is one bucket per line inside the ``router-error-types`` markers, with exactly
    one quoted snake_case wire value on each — which is what makes the regex below
    unambiguous. A line carrying none, or more than one, is a malformed table and is
    reported as such rather than silently skipped.
    """
    if not ERROR_TYPES_SWIFT.exists():
        raise ContractError(f"{ERROR_TYPES_SWIFT.relative_to(ROOT)} is missing.")
    try:
        source = ERROR_TYPES_SWIFT.read_text(encoding="utf-8")
    except OSError as exc:
        raise ContractError(
            f"{ERROR_TYPES_SWIFT.relative_to(ROOT)} could not be read: {exc}"
        ) from exc

    begin = source.find(BLOCK_BEGIN)
    end = source.find(BLOCK_END)
    if begin == -1 or end == -1 or end < begin:
        raise ContractError(
            f"{ERROR_TYPES_SWIFT.relative_to(ROOT)} has no "
            f"'{BLOCK_BEGIN}' / '{BLOCK_END}' block around the wire table — "
            "restore the markers so this check can find it."
        )
    block = source[begin + len(BLOCK_BEGIN) : end]

    values = []
    for line in block.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            continue
        found = re.findall(r'"([a-z_]+)"', stripped)
        if not found:
            continue
        if len(found) > 1:
            raise ContractError(
                f"{ERROR_TYPES_SWIFT.relative_to(ROOT)}: the wire table line {stripped!r} "
                "carries more than one quoted wire value — keep it to one bucket per line."
            )
        values.append(found[0])
    if not values:
        raise ContractError(
            f"{ERROR_TYPES_SWIFT.relative_to(ROOT)}: the wire table between the markers is "
            "empty — this check cannot verify an empty table."
        )
    return values


def sdk_run_route():
    """``(runPathTemplate, defaultBaseURL)`` as written in ``RouterConstants.swift``."""
    if not CONSTANTS_SWIFT.exists():
        raise ContractError(f"{CONSTANTS_SWIFT.relative_to(ROOT)} is missing.")
    try:
        source = CONSTANTS_SWIFT.read_text(encoding="utf-8")
    except OSError as exc:
        raise ContractError(
            f"{CONSTANTS_SWIFT.relative_to(ROOT)} could not be read: {exc}"
        ) from exc

    path_match = re.search(r'\brunPathTemplate\s*(?::[^=]+)?=\s*"([^"]*)"', source)
    if not path_match:
        raise ContractError(
            f"{CONSTANTS_SWIFT.relative_to(ROOT)}: could not find "
            '`static let runPathTemplate = "…"` — keep it a single string literal on one line.'
        )
    host_match = re.search(
        r'\bdefaultBaseURL\s*(?::[^=]+)?=\s*URL\(string:\s*"([^"]*)"\)', source
    )
    if not host_match:
        raise ContractError(
            f"{CONSTANTS_SWIFT.relative_to(ROOT)}: could not find "
            '`static let defaultBaseURL = URL(string: "…")!` — keep it a single string '
            "literal on one line."
        )
    return path_match.group(1), host_match.group(1)


def check_error_types(declared):
    """Membership and order of the SDK's wire table against the spec's. True on drift."""
    known = sdk_error_types()
    if known == declared:
        return False

    fail(
        "the Router error-type table has drifted from "
        f"{SPEC.relative_to(ROOT)} ({ERROR_TYPES_SWIFT.relative_to(ROOT)})."
    )
    missing = [value for value in declared if value not in known]
    extra = [value for value in known if value not in declared]
    if missing:
        print(
            f"  declared in the spec, no case in the SDK: {', '.join(missing)}\n"
            "  Add one RouterErrorType case per value (lowerCamelCase of the wire value),\n"
            "  with its row in the `wire` table positioned in the spec's declaration order.",
            file=sys.stderr,
        )
    if extra:
        print(
            f"  a case in the SDK, not declared in the spec: {', '.join(extra)}\n"
            "  Removing a case is a source-breaking change for anyone switching on it —\n"
            "  decide it deliberately, but the two lists must end up equal.",
            file=sys.stderr,
        )
    if not missing and not extra:
        print(
            "  same values, different order. Both SDKs present the set in the spec's order.\n"
            f"    spec: {declared}\n"
            f"    sdk:  {known}",
            file=sys.stderr,
        )
    return True


def check_run_route(declared_path, declared_host):
    """The SDK's two route constants against the spec's. True on drift."""
    path, host = sdk_run_route()
    drifted = False
    if path != declared_path:
        fail(
            f"the bound model-run route has drifted from {SPEC.relative_to(ROOT)}: "
            f"spec (runRouterModel) is {declared_path!r} but "
            f"RouterConstants.runPathTemplate is {path!r} — update the constant to the "
            "spec's path."
        )
        drifted = True
    if host != declared_host:
        fail(
            f"the default Router host has drifted from {SPEC.relative_to(ROOT)}: "
            f"spec (servers[0].url) is {declared_host!r} but "
            f"RouterConstants.defaultBaseURL is {host!r} — update the constant to the "
            "spec's server URL."
        )
        drifted = True
    return drifted


def main():
    try:
        doc = load_spec()
        declared_types = declared_error_types(doc)
        declared_path, declared_host = declared_run_route(doc)
    except ContractError as exc:
        fail(str(exc))
        return 1

    # Both checks run every time: reporting only the first would hide the second behind a
    # fix for it.
    try:
        types_drifted = check_error_types(declared_types)
        route_drifted = check_run_route(declared_path, declared_host)
    except ContractError as exc:
        fail(str(exc))
        return 1

    if types_drifted or route_drifted:
        print(
            "\nRouter contract check FAILED — the SDK and spec/router-openapi.yaml disagree.",
            file=sys.stderr,
        )
        return 1

    print(
        f"OK: {len(declared_types)} error types, "
        f"POST {declared_host}{declared_path} bound — "
        f"in sync with {SPEC.relative_to(ROOT)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
