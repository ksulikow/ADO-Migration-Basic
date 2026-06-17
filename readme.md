# Azure DevOps Work Item Clone and Update Script

This repository defines a PowerShell script approach to clone Azure DevOps work items between projects (or within the same project) using Azure DevOps REST APIs.

The script is designed to be safe for repeated runs:
- First run creates cloned items.
- Later runs can update already cloned items instead of creating duplicates.

## Supported capabilities

- Clone work items from source to target project using WIQL selection.
- Filter by included work item types.
- Map source work item types to target work item types.
- Map fields through configuration.
- Handle unmapped incompatible fields by warning and applying null or empty fallback values.
- Preserve source traceability in a configurable custom single-line field on target work items.
- Use traceability field for upsert behavior (create or update).
- Rebuild links in a second pass:
	- Remap links to cloned targets when available.
	- Copy links to original source items when related items are not cloned.
- Clone attachments.
- Produce execution summary and JSON mapping/report artifacts.

## Required behavior rules

### 1. Incompatible field fallback

When field mapping is not configured and source and target fields are incompatible:
- Log a warning.
- Do not fail the item.
- Write null or empty value based on target field type policy.

### 2. Original source reference field

Each cloned target work item must store reference to its original source work item in a configurable custom single-line field.

Common options:
- Store source work item ID.
- Store source work item URL.

### 3. Update processing (upsert)

Before creating a new target item, the script must query target items by the configured source-reference field.

If match exists:
- Update existing target item.

If no match exists:
- Create new target item.

This ensures idempotent re-runs and prevents duplicate clones.

## High-level flow

1. Validate config and connectivity.
2. Run WIQL to collect source IDs.
3. Retrieve source items in batch with fields and relations.
4. For each source item:
	 - Resolve mapped target type.
	 - Build field patch payload.
	 - Set source-reference custom field.
	 - Upsert by source-reference field lookup.
5. Second pass:
	 - Rebuild/remap work item links.
	 - Clone attachments.
6. Emit reports and logs.

## Configuration model

Use a single JSON file.

Minimum expected sections:
- source: org, project, auth reference.
- target: org, project, auth reference.
- query: WIQL.
- workItemTypes: includeTypes.
- typeMapping: source to target work item type.
- fieldMapping: field mapping rules and fallback policy.
- traceability:
	- sourceReferenceField: target custom single-line field reference name.
	- sourceReferenceValue: id or url.
- processing:
	- mode: upsert.
- relations: remap/copy-original/skip behavior.
- attachments: enabled true or false.
- dryRun: enabled true or false.

## Authentication

Use PAT values from environment variables.

Recommended:
- ADO_SOURCE_PAT
- ADO_TARGET_PAT

Do not hardcode PAT secrets in committed files.

## API endpoints used

Core Azure DevOps WIT REST APIs:
- POST wiql
- POST workitemsbatch
- POST workitems/{type}
- PATCH workitems/{id}

Plus relation and attachment endpoints as needed.

## Logging and outputs

The script should emit:
- Console summary:
	- selected count
	- created count
	- updated count
	- skipped count
	- warning count
	- error count
- JSON artifacts:
	- source-to-target mapping
	- per-item create or update action
	- relation actions
	- warnings and errors

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

## Repository status

This repository currently documents behavior and implementation plan. Script and module files can now be implemented according to this README contract.