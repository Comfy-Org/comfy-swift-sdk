# Vendored specs

Vendored copies of the canonical HTTP contracts this SDK is built against, synced **one-way** — never hand-edit a file in this directory; change the upstream contract instead and re-sync. The same directory and the same file names are used by the Python and TypeScript SDKs, so one spec-push pipeline feeds all three.

- **`router-openapi.yaml`** — the **Comfy Router** public contract (OpenAPI 3.0.2): the model catalog, the model-ID-addressed invocation routes, and the closed set of error buckets they return.

Nothing is generated from the Router spec. What it does gate is the SDK's typed error surface: `Scripts/contract/check_router_contract.py` (CI job `router-contract` in `.github/workflows/openapi-contract.yml`) fails unless `RouterErrorType`'s wire table is exactly the spec's `RouterErrorType.x-comfy-error-types` values in exactly that order, and unless `RouterConstants.runPathTemplate` / `RouterConstants.defaultBaseURL` still match the spec's `runRouterModel` path and `servers[0].url`. A bucket added, removed or reordered upstream fails the check, so syncing a new spec is a two-step change and the second step is unskippable.
