Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SystemManagedFields = @(
    'System.Id',
    'System.Rev',
    'System.AreaId',
    "System.AreaLevel1",
    "System.AreaLevel2",
    'System.NodeName',
    'System.IterationId',
    "System.IterationLevel1",
    "System.IterationLevel2",
    'System.ExternalLinkCount',
    'System.HyperLinkCount',
    'System.AttachedFileCount',
    'System.WorkItemType',
    'System.TeamProject',
    'System.Watermark',
    'System.AuthorizedDate',
    'System.CreatedDate',
    'System.ChangedDate',
    'System.CreatedBy',
    'System.ChangedBy',
    'System.AuthorizedAs',
    'Microsoft.VSTS.Common.StateChangeDate',
    'System.PersonId'
)

function Resolve-TargetWorkItemType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceType,
        [AllowNull()] $TypeMappings
    )

    if ($TypeMappings -and $TypeMappings.PSObject.Properties.Name -contains $SourceType) {
        return [string] $TypeMappings.$SourceType
    }

    return $SourceType
}

function Get-FallbackValueForType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TargetType,
        [string] $Policy = 'empty'
    )

    $normalizedPolicy = $Policy.ToLowerInvariant()
    if ($normalizedPolicy -eq 'null') {
        return $null
    }

    switch ($TargetType.ToLowerInvariant()) {
        'string' { return '' }
        'html' { return '' }
        'plaintext' { return '' }
        'integer' { return 0 }
        'double' { return 0.0 }
        'boolean' { return $false }
        'datetime' { return [DateTime]::UtcNow.ToString('o') }
        default { return $null }
    }
}

function Convert-FieldValue {
    [CmdletBinding()]
    param(
        [AllowNull()] $Value,
        [string] $Conversion = 'passthrough'
    )

    if ($null -eq $Value) {
        return $null
    }

    switch ($Conversion.ToLowerInvariant()) {
        'passthrough' { return $Value }
        'tostring' { return [string] $Value }
        'toint' { return [int] $Value }
        'todouble' { return [double] $Value }
        'todatetime' { return ([DateTime] $Value).ToString('o') }
        'tolower' { return ([string] $Value).ToLowerInvariant() }
        'toupper' { return ([string] $Value).ToUpperInvariant() }
        default { return $Value }
    }
}

function Test-FieldCompatibility {
    [CmdletBinding()]
    param(
        [string] $SourceType,
        [string] $TargetType
    )

    if ([string]::IsNullOrWhiteSpace($SourceType) -or [string]::IsNullOrWhiteSpace($TargetType)) {
        return $false
    }

    if ($SourceType -eq $TargetType) {
        return $true
    }

    if ($TargetType -in @('string', 'html', 'plainText')) {
        return $true
    }

    if ($SourceType -in @('integer', 'double') -and $TargetType -in @('integer', 'double')) {
        return $true
    }

    return $false
}

function Build-WorkItemFieldPatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceWorkItem,
        [Parameter(Mandatory)] [string] $TargetType,
        [Parameter(Mandatory)] $SourceFieldMetadata,
        [Parameter(Mandatory)] $TargetFieldMetadata,
        [AllowNull()] $FieldMappings,
        [Parameter(Mandatory)] [string] $FallbackPolicy,
        [Parameter(Mandatory)] [string] $TraceField,
        [Parameter(Mandatory)] [string] $TraceValue,
        [Parameter(Mandatory)] [ref] $Warnings
    )

    $patch = New-Object System.Collections.Generic.List[object]
    $patch.Add(@{ op = 'add'; path = '/fields/System.Title'; value = [string] $SourceWorkItem.fields.'System.Title' })

    $sourceFields = $SourceWorkItem.fields.PSObject.Properties
    foreach ($sourceFieldProp in $sourceFields) {
        $sourceRef = $sourceFieldProp.Name
        $sourceVal = $sourceFieldProp.Value

        if ($script:SystemManagedFields -contains $sourceRef) {
            continue
        }

        if ($sourceRef -eq 'System.Title') {
            continue
        }

        $mappingRule = $null
        $isExplicitMapped = $false
        $targetRef = $sourceRef
        $conversion = 'passthrough'

        if ($FieldMappings -and $FieldMappings.PSObject.Properties.Name -contains $sourceRef) {
            $mappingRule = $FieldMappings.$sourceRef
            $isExplicitMapped = $true
            if ($mappingRule -is [string]) {
                $targetRef = $mappingRule
            }
            else {
                if ($mappingRule.targetField) {
                    $targetRef = [string] $mappingRule.targetField
                }
                if ($mappingRule.transform) {
                    $conversion = [string] $mappingRule.transform
                }
                if ($mappingRule.PSObject.Properties.Name -contains "replaceTo" -and $mappingRule.replaceTo.PSObject.Properties.Name -contains "$sourceVal") {
                    $newVal = $mappingRule.replaceTo."$sourceVal"
                    $sourceVal = $newVal
                }
            }
        }

        if ($targetRef -eq $TraceField) {
            continue
        }

        if (-not $TargetFieldMetadata.ContainsKey($targetRef)) {
            continue
        }

        $targetMeta = $TargetFieldMetadata[$targetRef]
        if ($targetMeta.ReadOnly -or ($targetMeta.IsIdentity -and $targetRef -ne 'System.AssignedTo')) {
            continue
        }

        $sourceType = $null
        if ($SourceFieldMetadata.ContainsKey($sourceRef)) {
            $sourceType = $SourceFieldMetadata[$sourceRef].Type
        }

        $targetTypeName = $targetMeta.Type
        $isCompatible = Test-FieldCompatibility -SourceType $sourceType -TargetType $targetTypeName

        if (-not $isCompatible -and -not $isExplicitMapped) {
            $fallback = Get-FallbackValueForType -TargetType $targetTypeName -Policy $FallbackPolicy
            $Warnings.Value += "Incompatible unmapped field '$sourceRef' -> '$targetRef'. Applied fallback value."
            $patch.Add(@{ op = 'add'; path = "/fields/$targetRef"; value = $fallback })
            continue
        }

        $converted = Convert-FieldValue -Value $sourceVal -Conversion $conversion
        $patch.Add(@{ op = 'add'; path = "/fields/$targetRef"; value = $converted })
    }

    if ($TargetFieldMetadata.ContainsKey($TraceField)) {
        $patch.Add(@{ op = 'add'; path = "/fields/$TraceField"; value = $TraceValue })
    }

    return ,$patch
}

Export-ModuleMember -Function Resolve-TargetWorkItemType, Build-WorkItemFieldPatch, Get-FallbackValueForType, Test-FieldCompatibility
