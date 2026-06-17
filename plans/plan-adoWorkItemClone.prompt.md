## Plan: ADO Work Item Clone Script

Build a PowerShell-based Azure DevOps work item cloning utility that uses REST APIs, supports source/target project cloning (including same-project), type transformation, configurable field mapping, WIQL-based selection, create-or-update processing, and two-pass relation handling with fallback to original links when linked items are not cloned. The first version includes attachment cloning and outputs console summary plus JSON mapping/report artifacts.

**Steps**
1. Phase 1 - Project scaffolding and configuration contract
2. Create the script entry point and supporting module layout for API calls, field/type mapping, relation processing, configuration validation, and reporting.
3. Define a single JSON config contract with sections for source/target endpoints, WIQL selection, includeTypes filter, type mappings, field mappings, relation fallback modes, original-source-reference field (configurable single-line field), attachment behavior, dry-run, and logging.
4. Add JSON schema validation and startup preflight checks (required keys, PAT env vars, project/org presence, API reachability). *Blocks later phases.*
5. Phase 2 - Source selection and data retrieval
6. Implement WIQL execution to select source IDs, then enforce includeTypes filtering for safety. *Depends on 4.*
7. Implement batched retrieval (200 IDs per request) with fields + relations expansion to get clone-ready payloads and relation metadata. *Depends on 6.*
8. Phase 3 - First-pass clone (base work items)
9. Implement field extraction and compatibility checks to drop read-only/system-managed fields and evaluate source-to-target field compatibility by type.
10. Apply configurable type mapping and field mapping transforms to produce JSON Patch create payloads for each target item.
11. When field mapping is not configured and source/target fields are incompatible, log a warning and write null/empty fallback value (based on target field type policy) instead of failing the item.
12. On initial clone, set the configured custom single-line field to the original source work item reference (source ID or URL per config policy).
13. Add update-processing logic (upsert mode): before creating a target item, query target by the configured original-source-reference field and update existing cloned item when found; create only when not found.
14. Persist source->target ID mapping in memory and incremental JSON artifact (for resumability). *Depends on 7, 9, 10, 11, 12, 13.*
15. Add dry-run behavior using validateOnly mode and payload preview logs without persistence. *Parallel with 9-14 once API wrapper exists.*
16. Phase 4 - Second-pass relation and attachment reconstruction
17. Traverse original relations for each processed source item and rebuild relations on cloned/updated targets.
18. If linked work item is also cloned, remap relation URL to cloned target ID.
19. If linked work item is not cloned, apply configured fallback: default copy link to original work item URL, with optional per-relation override (skip/copy-original).
20. Rebuild hierarchy and related/dependency links in safe order and skip unsupported cross-project relation types with warnings.
21. Clone attachments (requested for v1): download source attachment content, upload to target via attachment API, then attach new URL relation to cloned work item. *Depends on 14 and API wrappers.*
22. Phase 5 - Observability, safety, and usability
23. Add structured logging (operation, item ID, API status, relation action, warnings/errors) and execution summary counters.
24. Emit console summary plus JSON output artifacts: run summary, source->target mapping, failures/skips with reasons, relation outcomes, created-vs-updated counts.
25. Add retry policy for transient API failures (429/5xx), throttle controls, and continue-on-error mode with final non-zero exit when failures exceed threshold.
26. Phase 6 - Documentation and examples
27. Document configuration, env vars, authentication setup, dry-run usage, and known limitations.
28. Provide at least one example config showing type conversion, field mapping, includeTypes + WIQL, link fallback behavior, null/empty fallback policy for incompatible unmapped fields, and original-source-reference field behavior for updates.

**Relevant files**
- /readme.md - update usage and operational guidance.
- Planned new file: /clone-workitems.ps1 - orchestration entry point and CLI parameter handling.
- Planned new file: /config/example-config.json - user-facing sample configuration.
- Planned new file: /config/config.schema.json - config validation schema.
- Planned new file: /modules/ADO-API.psm1 - REST wrapper and auth headers.
- Planned new file: /modules/Field-Mapper.psm1 - field transform and writeability logic.
- Planned new file: /modules/Link-Handler.psm1 - relation remap/copy logic and attachment handling.
- Planned new file: /modules/Validation.psm1 - preflight and config checks.

**Verification**
1. Run config/schema validation against valid and intentionally invalid configs (missing mappings, unknown fields, invalid modes).
2. Execute dry-run against a small WIQL set (5-10 items) and confirm validateOnly passes, mapping report generated, and no target mutations occur.
3. Execute live run in same-project clone mode with type changes and verify created items count equals selected source count minus intentional skips.
4. Re-run the same input in update mode and verify already cloned items are updated (not duplicated) by lookup on the configured original-source-reference field.
5. Verify the configured custom single-line reference field is populated on newly created cloned items and preserved/updated consistently on subsequent runs.
6. Verify field mapping correctness on sampled items, including transformed fields and skipped identity fields.
7. Verify unmapped incompatible fields are logged as warnings and stored as null/empty fallback values according to target field type policy.
8. Verify relation behavior for three cases: cloned target remap, non-cloned fallback to original link, unsupported relation skip with warning.
9. Verify attachment cloning by checking file names, count, and downloadable content on sampled cloned items.
10. Run across-project scenario and confirm expected handling for hierarchy restrictions and relation fallback.
11. Validate JSON output artifacts for completeness: sourceId, targetId, status, action(create/update), relation actions, error details.

**Decisions**
- Authentication: PATs from environment variables.
- Config format: single JSON file.
- Default relation fallback when target not cloned: copy original work item link.
- Scope: include attachment cloning in initial version.
- Run output: console summary + JSON mapping/report.
- Clone traceability/update key: configurable custom single-line field storing original source work item reference.
- Processing mode: create-or-update (upsert) using lookup by configured original-source-reference field.
- Behavior for unmapped incompatible fields: log warning and apply null/empty fallback value per target type policy.
- Included in scope: same-project and cross-project cloning within Azure DevOps REST API constraints.
- Excluded in initial scope: advanced identity/user remapping tables, HTML/CSV reports, automatic process-template reconciliation.

**Further Considerations**
1. Resume strategy recommendation: persist checkpoint after first-pass creation so second-pass relation rebuild can resume safely after interruption.
2. Security recommendation: support optional Azure DevOps PAT retrieval from secure secret store later, while keeping env vars as default now.
3. Scale recommendation: for large migrations, add paging windows and max-item cap per run to limit API pressure and simplify rollback.