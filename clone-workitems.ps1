[CmdletBinding()]
param(
    [string] $ConfigPath = '.\config\example-config.json',
    [string] $SchemaPath = '.\config\config.schema.json',
    [string] $OutputDir = '.\output',
    [switch] $DryRun,
    [switch] $ContinueOnError,
    [int] $FailureThreshold = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot 'modules/ADO-API.psm1') -Force
Import-Module (Join-Path $scriptRoot 'modules/Field-Mapper.psm1') -Force
Import-Module (Join-Path $scriptRoot 'modules/Link-Handler.psm1') -Force
Import-Module (Join-Path $scriptRoot 'modules/Validation.psm1') -Force

if (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $scriptRoot $ConfigPath
}
if (-not [System.IO.Path]::IsPathRooted($SchemaPath)) {
    $SchemaPath = Join-Path $scriptRoot $SchemaPath
}
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $scriptRoot $OutputDir
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$mappingPath = Join-Path $OutputDir 'id-mapping.json'
$summaryPath = Join-Path $OutputDir 'run-summary.json'
$itemResultsPath = Join-Path $OutputDir 'item-results.json'
$relationResultsPath = Join-Path $OutputDir 'relation-results.json'
$failuresPath = Join-Path $OutputDir 'failures.json'

$logEntries = New-Object System.Collections.Generic.List[object]
$itemResults = New-Object System.Collections.Generic.List[object]
$relationResults = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[object]
$warnings = New-Object System.Collections.Generic.List[string]

function Write-StructuredLog {
    param(
        [string] $Level,
        [string] $Operation,
        [string] $Message,
        [AllowNull()] [int] $SourceId,
        [AllowNull()] [int] $TargetId,
        [AllowNull()] [int] $StatusCode
    )

    $entry = [PSCustomObject]@{
        timestamp  = (Get-Date).ToString('o')
        level      = $Level
        operation  = $Operation
        sourceId   = $SourceId
        targetId   = $TargetId
        statusCode = $StatusCode
        message    = $Message
    }

    $logEntries.Add($entry)
    Write-Host "[$Level] [$Operation] $Message"
}

function Save-JsonFile {
    param(
        [string] $Path,
        $Data
    )

    ConvertTo-Json -InputObject $Data -Depth 100 | Set-Content -Path $Path -Encoding UTF8
}

try {
    Write-StructuredLog -Level 'INFO' -Operation 'startup' -Message 'Loading and validating configuration.'
    $config = Test-CloneConfig -ConfigPath $ConfigPath -SchemaPath $SchemaPath

    if ($DryRun.IsPresent) {
        $config.dryRun.enabled = $true
    }

    $throttleMs = 100
    if ($config.logging.throttleMs) {
        $throttleMs = [int] $config.logging.throttleMs
    }

    $maxRetries = 5
    if ($config.logging.maxRetries) {
        $maxRetries = [int] $config.logging.maxRetries
    }

    $sourceContext = New-AdoContext -OrgUrl $config.source.orgUrl -Project $config.source.project -PatEnvVar $config.source.patEnvVar -ThrottleMs $throttleMs -MaxRetries $maxRetries
    $targetContext = New-AdoContext -OrgUrl $config.target.orgUrl -Project $config.target.project -PatEnvVar $config.target.patEnvVar -ThrottleMs $throttleMs -MaxRetries $maxRetries

    Write-StructuredLog -Level 'INFO' -Operation 'preflight' -Message 'Running preflight checks.'
    Assert-Preflight -SourceContext $sourceContext -TargetContext $targetContext -Config $config | Out-Null

    Write-StructuredLog -Level 'INFO' -Operation 'metadata' -Message 'Fetching source and target field metadata.'
    $sourceFieldMetadata = Get-AdoFieldsMetadata -Context $sourceContext
    $targetFieldMetadata = Get-AdoFieldsMetadata -Context $targetContext

    Write-StructuredLog -Level 'INFO' -Operation 'selection' -Message 'Executing WIQL source selection.'
    $wiqlResult = Invoke-AdoWiqlQuery -Context $sourceContext -Wiql $config.query.wiql
    $selectedIds = @($wiqlResult.workItems | ForEach-Object { [int] $_.id })

    if ($selectedIds.Count -eq 0) {
        Write-StructuredLog -Level 'WARN' -Operation 'selection' -Message 'WIQL returned no source items.'
    }

    $includeTypes = @()
    if ($config.workItemTypes -and $config.workItemTypes.includeTypes) {
        $includeTypes = @($config.workItemTypes.includeTypes)
    }

    $sourceItems = New-Object System.Collections.Generic.List[object]
    $batchSize = 200
    for ($i = 0; $i -lt $selectedIds.Count; $i += $batchSize) {
        $end = [Math]::Min($i + $batchSize - 1, $selectedIds.Count - 1)
        $batch = $selectedIds[$i..$end]
        $batchItems = Get-AdoWorkItemsBatch -Context $sourceContext -Ids $batch -Expand 'All'
        foreach ($item in $batchItems) {
            if ($includeTypes.Count -gt 0 -and $includeTypes -notcontains [string] $item.fields.'System.WorkItemType') {
                continue
            }
            $traceFieldName = [string] $config.traceability.sourceReferenceField
            if ($item.fields.PSObject.Properties.Name -contains $traceFieldName -and -not [string]::IsNullOrWhiteSpace([string] $item.fields.$traceFieldName)) {
                $sourceItemId = [int] $item.id
                $warning = "Skipping source $sourceItemId because traceability field '$traceFieldName' is already populated."
                $warnings.Add($warning)
                Write-StructuredLog -Level 'WARN' -Operation 'selection' -Message $warning -SourceId $sourceItemId
                continue
            }
            $sourceItems.Add($item)
        }
    }

    Write-StructuredLog -Level 'INFO' -Operation 'selection' -Message "Selected $($sourceItems.Count) source items after includeTypes filtering."

    $idMapping = @{}
    if (-not $config.dryRun.enabled -and (Test-Path $mappingPath)) {
        try {
            $existingMapping = Get-Content -Path $mappingPath -Raw | ConvertFrom-Json -Depth 100
            foreach ($entry in $existingMapping) {
                $idMapping[[string] $entry.sourceId] = [int] $entry.targetId
            }
            Write-StructuredLog -Level 'INFO' -Operation 'resume' -Message "Loaded $($idMapping.Count) existing mapping entries for resumability."
        }
        catch {
            Write-StructuredLog -Level 'WARN' -Operation 'resume' -Message 'Failed to parse existing mapping file; starting with empty mapping.'
        }
    }

    $processed = 0
    $created = 0
    $updated = 0
    $skipped = 0
    $errors = 0

    foreach ($sourceItem in $sourceItems) {
        $sourceId = [int] $sourceItem.id
        $sourceType = [string] $sourceItem.fields.'System.WorkItemType'

        try {
            $targetType = Resolve-TargetWorkItemType -SourceType $sourceType -TypeMappings $config.typeMapping
            $traceValue = if ($config.traceability.sourceReferenceValue -eq 'url') {
                "$($sourceContext.OrgUrl)/$($sourceContext.Project)/_workitems/edit/$sourceId"
            }
            else {
                [string] $sourceId
            }

            $itemWarnings = @()
            $patch = Build-WorkItemFieldPatch -SourceWorkItem $sourceItem -TargetType $targetType -SourceFieldMetadata $sourceFieldMetadata -TargetFieldMetadata $targetFieldMetadata -FieldMappings $config.fieldMapping -FallbackPolicy $config.fieldFallback.policy -TraceField $config.traceability.sourceReferenceField -TraceValue $traceValue -Warnings ([ref] $itemWarnings)

            foreach ($w in $itemWarnings) {
                $warnings.Add($w)
                Write-StructuredLog -Level 'WARN' -Operation 'field-map' -Message $w -SourceId $sourceId
            }

            $existingTargetId = $null
            if ([string] $config.processing.mode -eq 'upsert') {
                $existingTargetId = Find-AdoWorkItemByField -Context $targetContext -FieldReferenceName $config.traceability.sourceReferenceField -FieldValue $traceValue
            }

            $action = 'create'
            $targetId = $null
            if ($existingTargetId) {
                $action = 'update'
                if ($config.dryRun.enabled) {
                    $targetId = [int] $existingTargetId
                    Write-StructuredLog -Level 'INFO' -Operation 'dry-run' -Message "Validate update for source $sourceId -> target $targetId" -SourceId $sourceId -TargetId $targetId
                    Update-AdoWorkItem -Context $targetContext -Id $targetId -Patch $patch -ValidateOnly $true | Out-Null
                }
                else {
                    $updatedItem = Update-AdoWorkItem -Context $targetContext -Id ([int] $existingTargetId) -Patch $patch
                    $targetId = [int] $updatedItem.id
                }
                $updated++
            }
            else {
                if ($config.dryRun.enabled) {
                    Write-StructuredLog -Level 'INFO' -Operation 'dry-run' -Message "Validate create for source $sourceId as type $targetType" -SourceId $sourceId
                    $validateResult = New-AdoWorkItem -Context $targetContext -WorkItemType $targetType -Patch $patch -ValidateOnly $true
                    if ($validateResult -and $validateResult.PSObject.Properties.Name -contains 'id' -and $validateResult.id) {
                        $targetId = [int] $validateResult.id
                    }
                }
                else {
                    $createdItem = New-AdoWorkItem -Context $targetContext -WorkItemType $targetType -Patch $patch
                    $targetId = [int] $createdItem.id
                }
                $created++
            }

            $processed++
            if ($targetId) {
                $idMapping[[string] $sourceId] = $targetId
            }

            $itemResults.Add([PSCustomObject]@{
                sourceId = $sourceId
                targetId = $targetId
                status = 'success'
                action = $action
                sourceType = $sourceType
                targetType = $targetType
                warnings = $itemWarnings
            })

            Write-StructuredLog -Level 'INFO' -Operation 'upsert' -Message "Processed source $sourceId with action '$action'." -SourceId $sourceId -TargetId $targetId

            if (-not $config.dryRun.enabled) {
                $mappingEntries = @()
                foreach ($k in $idMapping.Keys) {
                    $mappingEntries += [PSCustomObject]@{ sourceId = [int] $k; targetId = [int] $idMapping[$k] }
                }
                Save-JsonFile -Path $mappingPath -Data $mappingEntries
            }
            else {
                Write-StructuredLog -Level 'INFO' -Operation 'dry-run' -Message 'Dry-run mode active: mapping persistence skipped.'
            }
        }
        catch {
            $errors++
            $message = $_.Exception.Message
            $failures.Add([PSCustomObject]@{
                sourceId = $sourceId
                phase = 'first-pass'
                error = $message
            })
            $itemResults.Add([PSCustomObject]@{
                sourceId = $sourceId
                targetId = $null
                status = 'failed'
                action = 'none'
                sourceType = $sourceType
                targetType = $null
                warnings = @()
            })
            Write-StructuredLog -Level 'ERROR' -Operation 'upsert' -Message $message -SourceId $sourceId

            if (-not $ContinueOnError.IsPresent -and $errors -ge $FailureThreshold) {
                throw "Failure threshold reached during first pass ($errors failures)."
            }

            $skipped++
        }
    }

    if (-not $config.dryRun.enabled) {
        $tempDirectory = Join-Path $OutputDir '.attachments-temp'
        if (-not (Test-Path $tempDirectory)) {
            New-Item -ItemType Directory -Path $tempDirectory | Out-Null
        }

        foreach ($sourceItem in $sourceItems) {
            $sourceId = [int] $sourceItem.id
            if (-not $idMapping.ContainsKey([string] $sourceId)) {
                continue
            }

            $targetId = [int] $idMapping[[string] $sourceId]
            try {
                $targetItemForRelations = Get-AdoWorkItem -Context $targetContext -Id $targetId -Expand Relations
                $existingTargetRelations = @()
                if ($targetItemForRelations.PSObject.Properties.Name -contains 'relations') {
                    $existingTargetRelations = @($targetItemForRelations.relations)
                }

                $relationPatch = Build-RelationPatchFromSource -SourceWorkItem $sourceItem -TargetId $targetId -IdMapping $idMapping -RelationsConfig $config.relations -ExistingTargetRelations $existingTargetRelations -TargetOrgUrl $targetContext.OrgUrl -TargetProject $targetContext.Project -RelationOutcomes ([ref] $relationResults)

                $attachmentPatch = @()
                if ($config.attachments.enabled) {
                    $attachmentPatch = Copy-AttachmentsForWorkItem -SourceContext $sourceContext -TargetContext $targetContext -SourceWorkItem $sourceItem -TargetId $targetId -TempDirectory $tempDirectory -RelationOutcomes ([ref] $relationResults)
                }

                $combinedPatch = @($relationPatch + $attachmentPatch)
                if ($combinedPatch.Count -gt 0) {
                    Update-AdoWorkItem -Context $targetContext -Id $targetId -Patch $combinedPatch | Out-Null
                    Write-StructuredLog -Level 'INFO' -Operation 'second-pass' -Message "Updated relations/attachments for source $sourceId" -SourceId $sourceId -TargetId $targetId
                }
            }
            catch {
                $errors++
                $failures.Add([PSCustomObject]@{
                    sourceId = $sourceId
                    targetId = $targetId
                    phase = 'second-pass'
                    error = $_.Exception.Message
                })
                Write-StructuredLog -Level 'ERROR' -Operation 'second-pass' -Message $_.Exception.Message -SourceId $sourceId -TargetId $targetId

                if (-not $ContinueOnError.IsPresent -and $errors -ge $FailureThreshold) {
                    throw "Failure threshold reached during second pass ($errors failures)."
                }
            }
        }

        Remove-Item -Path $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-StructuredLog -Level 'INFO' -Operation 'dry-run' -Message 'Second pass skipped in dry-run mode.'
    }

    Save-JsonFile -Path $itemResultsPath -Data $itemResults
    Save-JsonFile -Path $relationResultsPath -Data $relationResults
    Save-JsonFile -Path $failuresPath -Data $failures

    $summary = [PSCustomObject]@{
        timestamp = (Get-Date).ToString('o')
        selected = $sourceItems.Count
        processed = $processed
        created = $created
        updated = $updated
        skipped = $skipped
        warningCount = $warnings.Count
        errorCount = $errors
        dryRun = [bool] $config.dryRun.enabled
        sourceProject = "$($sourceContext.OrgUrl)/$($sourceContext.Project)"
        targetProject = "$($targetContext.OrgUrl)/$($targetContext.Project)"
    }

    Save-JsonFile -Path $summaryPath -Data $summary

    Write-Host ''
    Write-Host '=== Run Summary ==='
    Write-Host "Selected:  $($summary.selected)"
    Write-Host "Processed: $($summary.processed)"
    Write-Host "Created:   $($summary.created)"
    Write-Host "Updated:   $($summary.updated)"
    Write-Host "Skipped:   $($summary.skipped)"
    Write-Host "Warnings:  $($summary.warningCount)"
    Write-Host "Errors:    $($summary.errorCount)"
    Write-Host "Dry Run:   $($summary.dryRun)"

    if ($errors -gt 0) {
        exit 2
    }

    exit 0
}
catch {
    Write-StructuredLog -Level 'ERROR' -Operation 'fatal' -Message $_.Exception.Message

    $fatalSummary = [PSCustomObject]@{
        timestamp = (Get-Date).ToString('o')
        fatal = $true
        error = $_.Exception.Message
    }

    Save-JsonFile -Path $summaryPath -Data $fatalSummary
    Save-JsonFile -Path $itemResultsPath -Data $itemResults
    Save-JsonFile -Path $relationResultsPath -Data $relationResults
    Save-JsonFile -Path $failuresPath -Data $failures

    exit 2
}
