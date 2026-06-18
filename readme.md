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

The config describes where to read work items from, where to create/update clones, which items to include, how fields and types map, and how relation/attachment behavior should work.

### Full config shape

```json
{
	"source": {
		"orgUrl": "https://dev.azure.com/your-source-org",
		"project": "SourceProject",
		"patEnvVar": "ADO_SOURCE_PAT"
	},
	"target": {
		"orgUrl": "https://dev.azure.com/your-target-org",
		"project": "TargetProject",
		"patEnvVar": "ADO_TARGET_PAT"
	},
	"query": {
		"wiql": "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = 'SourceProject' AND [System.WorkItemType] IN ('Feature','User Story','Bug','Task') ORDER BY [System.ChangedDate] DESC"
	},
	"workItemTypes": {
		"includeTypes": ["Feature", "User Story", "Bug", "Task"]
	},
	"typeMapping": {
		"Feature": "Feature",
		"User Story": "User Story",
		"Bug": "Bug",
		"Task": "Task"
	},
	"fieldMapping": {
		"System.Description": {
			"targetField": "System.Description",
			"transform": "passthrough"
		},
		"Microsoft.VSTS.Common.Priority": {
			"targetField": "Microsoft.VSTS.Common.Priority",
			"transform": "toInt"
		},
		"Custom.BusinessValue": {
			"targetField": "Custom.BusinessValue",
			"transform": "toString"
		}
	},
	"fieldFallback": {
		"policy": "empty"
	},
	"traceability": {
		"sourceReferenceField": "Custom.SourceWorkItemRef",
		"sourceReferenceValue": "url"
	},
	"processing": {
		"mode": "upsert",
		"continueOnError": true,
		"failureThreshold": 10
	},
	"relations": {
		"defaultWhenMissing": "copy-original",
		"overrides": {
			"System.LinkTypes.Dependency-Forward": "copy-original",
			"System.LinkTypes.Remote.Related": "skip"
		}
	},
	"attachments": {
		"enabled": true
	},
	"dryRun": {
		"enabled": true
	},
	"logging": {
		"throttleMs": 125,
		"maxRetries": 5
	}
}
```

### Section reference

`source` identifies the project to read from.

- `orgUrl`: Azure DevOps organization URL, for example `https://dev.azure.com/contoso`.
- `project`: source project name.
- `patEnvVar`: environment variable that contains the PAT used for source API calls.

`target` identifies the project to create or update clones in.

- `orgUrl`: target Azure DevOps organization URL.
- `project`: target project name.
- `patEnvVar`: environment variable that contains the PAT used for target API calls.

`query` controls the first source selection.

- `wiql`: WIQL query that returns source work item IDs.
- Keep the `[System.TeamProject]` filter aligned with `source.project`.
- Use a small query for early dry-runs before widening scope.

`workItemTypes` applies an extra safety filter after WIQL.

- `includeTypes`: only source work items with these types are processed.
- This is useful when your WIQL changes or returns more types than expected.

`typeMapping` maps source work item types to target work item types.

Examples:

```json
{
	"User Story": "Product Backlog Item",
	"Bug": "Bug",
	"Task": "Task"
}
```

```json
{
	"Feature": "Feature",
	"User Story": "User Story"
}
```

`fieldMapping` controls explicit field mappings and transforms. Keys are source field reference names. `targetField` is the target field reference name.

Supported transforms:

- `passthrough`
- `toString`
- `toInt`
- `toDouble`
- `toDateTime`
- `toLower`
- `toUpper`

Example mapping a custom numeric source field to a string target field:

```json
"fieldMapping": {
	"Custom.BusinessValue": {
		"targetField": "Custom.BusinessValueText",
		"transform": "toString"
	}
}
```

Some system-managed fields are intentionally not copied, including project/path fields such as `System.TeamProject`, `System.AreaPath`, and `System.IterationPath`. This prevents cloned work items from being placed back into the source project.

`fieldFallback` controls what happens when an unmapped compatible-looking source field exists but the target field type is incompatible.

- `empty`: writes an empty value based on target field type where possible.
- `null`: writes `null`.

`traceability` is required for idempotent upsert behavior.

- `sourceReferenceField`: writable target custom field that stores the original source reference.
- `sourceReferenceValue`: `id` or `url`.

Recommended target field type: single-line text. Example:

```json
"traceability": {
	"sourceReferenceField": "Custom.ReflectedWorkItemId",
	"sourceReferenceValue": "url"
}
```

On rerun, the script searches target work items by this field. If it finds a match, it updates the clone instead of creating a duplicate. Source items that already have this field populated are skipped, which helps prevent accidental re-cloning of previously reflected items.

`processing` controls run behavior.

- `mode`: currently only `upsert` is supported.
- `continueOnError`: records item failures and continues until the threshold is reached.
- `failureThreshold`: maximum errors before the run fails.

`relations` controls second-pass link rebuilding.

- If a linked source item was also cloned, the relation is remapped to the cloned target ID.
- Parent/child hierarchy is rebuilt from parent-to-child links; Azure DevOps creates the reciprocal parent link automatically.
- If a linked source item was not cloned, `defaultWhenMissing` decides whether to copy the original link or skip it.
- `overrides` can customize behavior for specific relation types.

Example:

```json
"relations": {
	"defaultWhenMissing": "copy-original",
	"overrides": {
		"System.LinkTypes.Remote.Related": "skip",
		"System.LinkTypes.Dependency-Forward": "copy-original"
	}
}
```

Allowed actions are:

- `copy-original`: keep the relation pointing to the original source work item when no cloned target exists.
- `skip`: do not create the relation when no cloned target exists.

`attachments` controls file attachment cloning.

```json
"attachments": {
	"enabled": true
}
```

When enabled, the script downloads source attachments, uploads them to the target project, and adds new `AttachedFile` relations to the cloned item.

`dryRun` controls validate-only behavior.

```json
"dryRun": {
	"enabled": true
}
```

When `enabled` is `true`, the script calls Azure DevOps with `validateOnly=true` for create/update payloads and skips target mutation and second-pass relation/attachment updates. Passing the `-DryRun` switch also forces dry-run mode on.

`logging` controls API pacing and retry behavior.

- `throttleMs`: delay before each API call.
- `maxRetries`: retry attempts for transient 429 and 5xx failures.

### Example: cross-project clone in same organization

```json
{
	"source": {
		"orgUrl": "https://dev.azure.com/Kriss365-Dev",
		"project": "ADO-Migration-Test",
		"patEnvVar": "ADO_KRISS_PAT"
	},
	"target": {
		"orgUrl": "https://dev.azure.com/Kriss365-Dev",
		"project": "ADO-Migration-Test-Target",
		"patEnvVar": "ADO_KRISS_PAT"
	},
	"query": {
		"wiql": "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = 'ADO-Migration-Test' AND [System.WorkItemType] IN ('Feature','User Story','Bug','Task') ORDER BY [System.ChangedDate] DESC"
	},
	"workItemTypes": {
		"includeTypes": ["Feature", "User Story", "Bug", "Task"]
	},
	"typeMapping": {
		"Feature": "Feature",
		"User Story": "User Story",
		"Bug": "Bug",
		"Task": "Task"
	},
	"fieldMapping": {
		"System.Description": {
			"targetField": "System.Description",
			"transform": "passthrough"
		}
	},
	"fieldFallback": {
		"policy": "empty"
	},
	"traceability": {
		"sourceReferenceField": "Custom.ReflectedWorkItemId",
		"sourceReferenceValue": "url"
	},
	"processing": {
		"mode": "upsert",
		"continueOnError": true,
		"failureThreshold": 10
	},
	"relations": {
		"defaultWhenMissing": "copy-original",
		"overrides": {
			"System.LinkTypes.Remote.Related": "skip"
		}
	},
	"attachments": {
		"enabled": true
	},
	"dryRun": {
		"enabled": true
	},
	"logging": {
		"throttleMs": 125,
		"maxRetries": 5
	}
}
```

### Example: process-template type conversion

Use `typeMapping` when source and target projects use different process templates.

```json
"typeMapping": {
	"User Story": "Product Backlog Item",
	"Feature": "Feature",
	"Bug": "Bug",
	"Task": "Task"
}
```

### Minimal required config

The schema requires these top-level sections:

- `source`
- `target`
- `query`
- `traceability`
- `processing`
- `relations`
- `attachments`
- `dryRun`

`workItemTypes`, `typeMapping`, `fieldMapping`, `fieldFallback`, and `logging` are optional in the schema, but they are recommended for predictable migrations.

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
- `POST workitems/${type}`
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