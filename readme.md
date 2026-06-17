# Azure DevOps Work Item Clone and Update Script

This repository includes a PowerShell implementation to clone Azure DevOps work items between projects (or within the same project) using REST APIs.

The script is designed for safe repeated runs:
- First run creates cloned items.
- Later runs update already cloned items instead of creating duplicates.

## Implemented capabilities

- WIQL-based source selection.
- Include-types safety filtering.
- Type mapping from source type to target type.
- Field mapping with optional transforms.
- Unmapped incompatible-field fallback policy (`empty` or `null`) with warnings.
- Upsert mode by configurable traceability field.
- Traceability value as source ID or source URL.
- Two-pass processing:
  - First pass creates or updates base work items.
  - Second pass rebuilds relations and clones attachments.
- Relation fallback behavior for non-cloned linked items (`copy-original` or `skip`, with per-relation overrides).
- Retry policy for transient API failures (429/5xx) and throttle controls.
- Dry-run validation mode (`validateOnly`) with payload validation and no target mutation persistence.
- JSON output artifacts for mapping, summary, item outcomes, relation outcomes, and failures.

## Repository layout

- `clone-workitems.ps1`: main entry point.
- `modules/ADO-API.psm1`: auth, API wrappers, retries, WIQL, batch fetch, create/update, attachments.
- `modules/Field-Mapper.psm1`: type mapping, field mapping, compatibility checks, fallback values.
- `modules/Link-Handler.psm1`: relation remap/copy logic and attachment cloning support.
- `modules/Validation.psm1`: config read, schema validation, required-key checks, preflight.
- `config/config.schema.json`: JSON schema for config contract.
- `config/example-config.json`: sample config with mappings and behaviors.
- `output/`: run artifacts.

## Required behavior rules

### 1. Incompatible field fallback

When field mapping is not configured and source and target fields are incompatible:
- Log a warning.
- Do not fail the item.
- Write null or empty value based on target field type policy.

### 2. Original source reference field

Each cloned target work item stores a reference to its original source work item in a configurable custom single-line field.

Common options:
- Store source work item ID.
- Store source work item URL.

### 3. Update processing (upsert)

Before creating a new target item, the script queries target items by the configured source-reference field.

If match exists:
- Update existing target item.

If no match exists:
- Create new target item.

This ensures idempotent re-runs and prevents duplicate clones.

## Configuration contract

Use one JSON config file validated by `config/config.schema.json`.

Main sections:
- `source`: `orgUrl`, `project`, `patEnvVar`
- `target`: `orgUrl`, `project`, `patEnvVar`
- `query`: `wiql`
- `workItemTypes`: `includeTypes`
- `typeMapping`
- `fieldMapping`
- `fieldFallback`: `policy` (`empty` or `null`)
- `traceability`: `sourceReferenceField`, `sourceReferenceValue` (`id` or `url`)
- `processing`: `mode` (`upsert`), optional thresholds
- `relations`: fallback and per-relation overrides
- `attachments`: `enabled`
- `dryRun`: `enabled`
- `logging`: `throttleMs`, `maxRetries`

## Authentication

Use PAT values from environment variables.

Recommended:
- ADO_SOURCE_PAT
- ADO_TARGET_PAT

Do not hardcode PAT secrets in committed files.

## Run

1. Set PAT environment variables.

PowerShell example:

```powershell
$env:ADO_SOURCE_PAT = "<source-pat>"
$env:ADO_TARGET_PAT = "<target-pat>"
```

2. Edit `config/example-config.json` for your org/project, WIQL, mappings, and behaviors.

3. Dry-run first:

```powershell
.\clone-workitems.ps1 -ConfigPath .\config\example-config.json -DryRun
```

4. Live run:

```powershell
.\clone-workitems.ps1 -ConfigPath .\config\example-config.json -ContinueOnError -FailureThreshold 10
```

## Processing flow

1. Validate config against JSON schema.
2. Run startup preflight checks (required keys, PAT env vars, source/target reachability).
3. Execute WIQL and apply `includeTypes` filter.
4. Retrieve source items in batches of 200 with fields and relations.
5. First pass upsert:
	- Resolve target type.
	- Build field patch using mappings and fallback policy.
	- Set traceability field.
	- Update existing target item by traceability lookup, else create.
	- Persist incremental source-to-target mapping (except dry-run).
6. Second pass (non-dry-run):
	- Rebuild relations with remap or fallback behavior.
	- Clone attachments and add new `AttachedFile` relations.
7. Emit run artifacts and summary.

## API endpoints used

Core Azure DevOps WIT REST APIs:
- `POST wiql`
- `POST workitemsbatch`
- `POST workitems/{type}`
- `PATCH workitems/{id}`
- `GET workitems/{id}`
- `POST attachments`

## Logging and outputs

Console summary includes selected, processed, created, updated, skipped, warnings, errors, and dry-run flag.

JSON artifacts are written to `output/`:
- `run-summary.json`
- `id-mapping.json` (non-dry-run)
- `item-results.json`
- `relation-results.json`
- `failures.json`

## Validation checklist

Before production run:
- Validate config schema.
- Validate WIQL returns expected set.
- Validate target work item types and mapped fields.
- Validate source-reference custom field exists and is writable.
- Run dry-run on a small sample.

After run:
- Confirm source-reference field populated for all processed items.
- Confirm re-run updates existing clones instead of creating duplicates.
- Confirm incompatible unmapped fields produced warnings and fallback values.
- Confirm relation remap and copy-original logic.
- Confirm attachments cloned as expected.

## Known limitations (v1)

- No advanced identity/user remapping tables.
- No automatic process-template reconciliation.
- Report output is JSON only (no HTML/CSV formatter).