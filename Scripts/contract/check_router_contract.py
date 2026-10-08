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
3. **The four queued-delivery routes vs ``spec/router-openapi.yaml``.** Same rule as the run
   route, four more times — submit, status, result and cancel — and with the HTTP **method**
   checked as well, because ``cancelRouterModelRequest`` is a ``PUT`` and is the one route in
   this contract that a reader will assume is a ``POST``.

   This third check **stands down when the spec declares none of the four**, and that is
   deliberate rather than a loophole. ``spec/*.yaml`` is a one-way vendored copy (see
   ``spec/README.md``) and the Router-leg spec-publish pipeline is what carries the queue paths
   into this repo; the client work lands first. Failing on a spec that has not caught up yet
   would make this job red for a reason no PR in this repo can fix, which is how a check gets
   disabled. So: none declared → a notice and a pass, and the day the sync lands the check
   arms itself with no further edit. A **partial** set is always a failure — that is a
   contract that genuinely disagrees with itself, not one that has not arrived.

Mirrors the router half of the Python SDK's ``scripts/check_drift.py``.
``Tests/ComfySwiftSDKTests/RouterErrorMappingTests.swift`` asserts the Swift-side half of
the same invariants from ``swift test``; both exist on purpose — the suite is where a
contributor sees it, and this script is the job that fails a spec-only PR that never ran it.

Exit codes:
  0  the tables and the spec agree
  1  a bucket is missing, extra or misordered; a constant has drifted; a queue operation is
     declared on a different path or method than the SDK binds, or only some of the four are
     declared; or an input could not be read
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

# The four queued-delivery routes: (operationId, HTTP method, RouterConstants property).
#
# The METHOD is part of the identity on purpose. `cancelRouterModelRequest` is a `PUT`, and it
# is the one route in this contract a reader will assume is a `POST` — so a spec that moved it,
# or an SDK that bound it wrong, has to fail here rather than at runtime against a `405`.
QUEUE_OPERATIONS = (
    ("submitRouterModelRequest", "post", "submitPathTemplate"),
    ("getRouterModelRequestStatus", "get", "requestStatusPathTemplate"),
    ("getRouterModelRequestResult", "get", "requestResultPathTemplate"),
    ("cancelRouterModelRequest", "put", "requestCancelPathTemplate"),
)

# Every HTTP method an OpenAPI path item may carry an operation under. Searched exhaustively
# rather than only under the expected one, so a route declared under the WRONG method reports
# as "declared as POST, the SDK sends PUT" instead of as a route the spec does not have.
HTTP_METHODS = ("get", "put", "post", "delete", "options", "head", "patch", "trace")

IN_ACTIONS = bool(os.environ.get("GITHUB_ACTIONS"))

# Anything a GitHub workflow command reads as structure rather than as text.
CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f]")


class ContractError(Exception):
    """An input could not be read or does not have the shape this check needs.

    Raised rather than letting a ``KeyError``/``TypeError`` escape: a sync that reshapes or
    drops part of the contract should fail this job with a sentence someone can act on, not
    with a traceback that reads like a bug in the checker.
    """


def fail(message):
    """Report one failure — as a GitHub annotation in CI, and on stderr always.

    Every message below interpolates values read out of the spec, and on a fork PR the spec
    is attacker-controlled, so the annotation form is escaped rather than printed raw. ``%``
    goes first because it is the escape character itself; every control character then
    flattens to a space, since a raw CR or LF would truncate the annotation at its first
    line — or let a crafted value open a ``::`` workflow command of its own on the next one.
    """
    if IN_ACTIONS:
        safe = CONTROL_CHARS.sub(" ", message.replace("%", "%25"))
        print(f"::error::{safe}")
    print(f"ERROR: {message}", file=sys.stderr)


def notice(message):
    """Report one non-failing observation, escaped exactly as ``fail`` escapes its own."""
    if IN_ACTIONS:
        safe = CONTROL_CHARS.sub(" ", message.replace("%", "%25"))
        print(f"::notice::{safe}")
    print(f"note: {message}")


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
    one quoted wire value on each — which is what makes the regex below unambiguous. Only
    the literal's own two structural lines (its declaration and its closing bracket) carry
    no value by design; any other line carrying none, or carrying more than one, is a
    malformed table and is reported as such rather than silently skipped. Silently skipping
    is what would drop a bucket out of the SDK list and report it as "declared in the spec,
    no case in the SDK", sending the reader to the wrong file.
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
        # The two lines of the array literal itself, which hold no bucket.
        if stripped.endswith("= [") or stripped == "]":
            continue
        # Deliberately wider than the snake_case the buckets use today: a wire value that
        # grows a digit or a capital upstream must be read out of the table and compared,
        # not dropped from it and then reported as a case the SDK is missing.
        found = re.findall(r'"([A-Za-z0-9_]+)"', stripped)
        if not found:
            raise ContractError(
                f"{ERROR_TYPES_SWIFT.relative_to(ROOT)}: the wire table line {stripped!r} "
                "carries no quoted wire value — keep it to one bucket per line."
            )
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


def declared_queue_routes(doc):
    """``{operationId: (path, method)}`` for every queue operation the spec declares.

    Searched across every HTTP method rather than only the expected one — see
    ``HTTP_METHODS`` — so a route the spec moved to a different verb reports as the method
    mismatch it is. Missing operations are simply absent from the result; the caller decides
    whether that is "not vendored yet" or "a partial sync".
    """
    paths = doc.get("paths")
    if not isinstance(paths, dict):
        raise ContractError(f"{SPEC.relative_to(ROOT)} has no paths object.")

    wanted = {operation for operation, _, _ in QUEUE_OPERATIONS}
    found = {}
    for path, item in paths.items():
        if not isinstance(item, dict):
            continue
        for method in HTTP_METHODS:
            operation = item.get(method)
            if not isinstance(operation, dict):
                continue
            operation_id = operation.get("operationId")
            if operation_id not in wanted:
                continue
            # Two paths claiming one operationId makes "the SDK binds the wrong one" a coin
            # flip, so it is reported rather than resolved — the same reasoning as the
            # exactly-one assertion on `runRouterModel`.
            if operation_id in found:
                raise ContractError(
                    f"{SPEC.relative_to(ROOT)} declares operationId {operation_id!r} more than "
                    f"once: {found[operation_id][0]!r} and {path!r}."
                )
            found[operation_id] = (path, method)
    return found


def sdk_queue_routes():
    """``{RouterConstants property: template}`` for the four queue route constants."""
    if not CONSTANTS_SWIFT.exists():
        raise ContractError(f"{CONSTANTS_SWIFT.relative_to(ROOT)} is missing.")
    try:
        source = CONSTANTS_SWIFT.read_text(encoding="utf-8")
    except OSError as exc:
        raise ContractError(
            f"{CONSTANTS_SWIFT.relative_to(ROOT)} could not be read: {exc}"
        ) from exc

    templates = {}
    for _, _, constant in QUEUE_OPERATIONS:
        match = re.search(rf'\b{constant}\s*(?::[^=]+)?=\s*"([^"]*)"', source)
        if not match:
            raise ContractError(
                f"{CONSTANTS_SWIFT.relative_to(ROOT)}: could not find "
                f'`static let {constant} = "…"` — keep it a single string literal on one line.'
            )
        templates[constant] = match.group(1)
    return templates


def check_queue_routes(doc):
    """The SDK's four queue route constants against the spec's. True on drift.

    Stands down — with a notice, and no failure — when the spec declares NONE of the four.
    See the module docstring: the vendored spec is a one-way copy that the Router-leg publish
    pipeline updates on its own schedule, and the client work lands before that sync. A
    partial set is a genuine disagreement and always fails.
    """
    declared = declared_queue_routes(doc)
    if not declared:
        notice(
            f"{SPEC.relative_to(ROOT)} declares none of the four queued-delivery operations "
            f"({', '.join(operation for operation, _, _ in QUEUE_OPERATIONS)}) — the vendored "
            "spec predates them. The SDK's queue route constants are NOT being checked; this "
            "check arms itself automatically on the next Router-leg spec sync."
        )
        return False

    templates = sdk_queue_routes()
    drifted = False

    missing = [
        operation for operation, _, _ in QUEUE_OPERATIONS if operation not in declared
    ]
    if missing:
        fail(
            f"{SPEC.relative_to(ROOT)} declares only some of the queued-delivery operations — "
            f"missing: {', '.join(missing)}. Either all four are in the contract or none are; "
            "a partial set is a spec sync that landed half a feature."
        )
        drifted = True

    for operation, method, constant in QUEUE_OPERATIONS:
        if operation not in declared:
            continue
        declared_path, declared_method = declared[operation]
        if declared_method != method:
            fail(
                f"the queued-delivery route {operation} has drifted from "
                f"{SPEC.relative_to(ROOT)}: the spec declares it as "
                f"{declared_method.upper()} but the SDK sends {method.upper()} — update "
                "RouterQueueTransport.swift to the spec's method."
            )
            drifted = True
        if templates[constant] != declared_path:
            fail(
                f"the bound {operation} route has drifted from {SPEC.relative_to(ROOT)}: "
                f"spec is {declared_path!r} but RouterConstants.{constant} is "
                f"{templates[constant]!r} — update the constant to the spec's path."
            )
            drifted = True

    return drifted


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

    # Both checks run every time, each under its own `try`: reporting only the first would
    # hide the second behind a fix for it, and a shared `try` would do exactly that the
    # moment one of them cannot read its input.
    failed = False
    try:
        failed |= check_error_types(declared_types)
    except ContractError as exc:
        fail(str(exc))
        failed = True
    try:
        failed |= check_run_route(declared_path, declared_host)
    except ContractError as exc:
        fail(str(exc))
        failed = True
    try:
        failed |= check_queue_routes(doc)
    except ContractError as exc:
        fail(str(exc))
        failed = True

    if failed:
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
