Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ObjectPropertyValue {
    param(
        [AllowNull()] $Object,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }

    return $null
}

function Get-WorkItemRelations {
    param(
        [Parameter(Mandatory)] $WorkItem
    )

    $relations = Get-ObjectPropertyValue -Object $WorkItem -Name 'relations'
    if (-not $relations) {
        return @()
    }

    return @($relations)
}

function Get-LinkedWorkItemIdFromUrl {
    [CmdletBinding()]
    param([string] $Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $null
    }

    $match = [regex]::Match($Url, '/workItems/(\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return [int] $match.Groups[1].Value
    }

    return $null
}

function Test-RelationExists {
    param(
        [AllowNull()] $ExistingRelations,
        [Parameter(Mandatory)] [string] $Rel,
        [AllowNull()] [string] $Url,
        [AllowNull()] [int] $LinkedWorkItemId
    )

    foreach ($existingRelation in @($ExistingRelations)) {
        if ($existingRelation.rel -ne $Rel) {
            continue
        }

        if ($null -ne $LinkedWorkItemId) {
            $existingLinkedId = Get-LinkedWorkItemIdFromUrl -Url $existingRelation.url
            if ($existingLinkedId -eq $LinkedWorkItemId) {
                return $true
            }
        }
        elseif ($existingRelation.url -eq $Url) {
            return $true
        }
    }

    return $false
}

function Resolve-RelationAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Rel,
        [AllowNull()] $RelationsConfig
    )

    $defaultAction = 'copy-original'
    if ($RelationsConfig -and $RelationsConfig.defaultWhenMissing) {
        $defaultAction = [string] $RelationsConfig.defaultWhenMissing
    }

    if ($RelationsConfig -and $RelationsConfig.overrides -and $RelationsConfig.overrides.PSObject.Properties.Name -contains $Rel) {
        return [string] $RelationsConfig.overrides.$Rel
    }

    return $defaultAction
}

function Build-RelationPatchFromSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceWorkItem,
        [Parameter(Mandatory)] [int] $TargetId,
        [Parameter(Mandatory)] [hashtable] $IdMapping,
        [AllowNull()] $RelationsConfig,
        [AllowNull()] $ExistingTargetRelations,
        [Parameter(Mandatory)] [string] $TargetOrgUrl,
        [Parameter(Mandatory)] [string] $TargetProject,
        [Parameter(Mandatory)] [ref] $RelationOutcomes
    )

    $patch = New-Object System.Collections.Generic.List[object]
    $relations = @(Get-WorkItemRelations -WorkItem $SourceWorkItem)

    if ($relations.Count -eq 0) {
        return ,$patch
    }

    foreach ($rel in $relations) {
        if ($rel.rel -eq 'AttachedFile') {
            continue
        }

        $attributes = Get-ObjectPropertyValue -Object $rel -Name 'attributes'

        if ($rel.rel -like 'ArtifactLink') {
            $RelationOutcomes.Value += [PSCustomObject]@{
                sourceId = $SourceWorkItem.id
                targetId = $TargetId
                relation = $rel.rel
                action   = 'skip-unsupported'
                details  = 'ArtifactLink relation is skipped in v1.'
            }
            continue
        }

        $linkedSourceId = Get-LinkedWorkItemIdFromUrl -Url $rel.url
        if ($null -ne $linkedSourceId -and $IdMapping.ContainsKey([string] $linkedSourceId)) {
            if ($rel.rel -eq 'System.LinkTypes.Hierarchy-Reverse') {
                $RelationOutcomes.Value += [PSCustomObject]@{
                    sourceId = $SourceWorkItem.id
                    targetId = $TargetId
                    relation = $rel.rel
                    action   = 'skip-reciprocal-hierarchy'
                    details  = "Parent relation to cloned source $linkedSourceId is represented by the parent's child link."
                }
                continue
            }

            $mappedTargetId = [int] $IdMapping[[string] $linkedSourceId]
            $newUrl = "$TargetOrgUrl/$TargetProject/_apis/wit/workItems/$mappedTargetId"
            if (Test-RelationExists -ExistingRelations $ExistingTargetRelations -Rel $rel.rel -Url $newUrl -LinkedWorkItemId $mappedTargetId) {
                $RelationOutcomes.Value += [PSCustomObject]@{
                    sourceId = $SourceWorkItem.id
                    targetId = $TargetId
                    relation = $rel.rel
                    action   = 'skip-existing'
                    details  = "Relation to target $mappedTargetId already exists."
                }
                continue
            }

            $patch.Add(@{
                op = 'add'
                path = '/relations/-'
                value = @{
                    rel = $rel.rel
                    url = $newUrl
                    attributes = $attributes
                }
            })
            $RelationOutcomes.Value += [PSCustomObject]@{
                sourceId = $SourceWorkItem.id
                targetId = $TargetId
                relation = $rel.rel
                action   = 'remap-cloned'
                details  = "Remapped linked source $linkedSourceId to target $mappedTargetId"
            }
            continue
        }

        $action = Resolve-RelationAction -Rel $rel.rel -RelationsConfig $RelationsConfig
        if ($action -eq 'skip') {
            $RelationOutcomes.Value += [PSCustomObject]@{
                sourceId = $SourceWorkItem.id
                targetId = $TargetId
                relation = $rel.rel
                action   = 'skip-config'
                details  = 'Configured to skip relation when linked item is not cloned.'
            }
            continue
        }

        if (Test-RelationExists -ExistingRelations $ExistingTargetRelations -Rel $rel.rel -Url $rel.url -LinkedWorkItemId $null) {
            $RelationOutcomes.Value += [PSCustomObject]@{
                sourceId = $SourceWorkItem.id
                targetId = $TargetId
                relation = $rel.rel
                action   = 'skip-existing'
                details  = 'Original relation URL already exists.'
            }
            continue
        }

        $patch.Add(@{
            op = 'add'
            path = '/relations/-'
            value = @{
                rel = $rel.rel
                url = $rel.url
                attributes = $attributes
            }
        })

        $RelationOutcomes.Value += [PSCustomObject]@{
            sourceId = $SourceWorkItem.id
            targetId = $TargetId
            relation = $rel.rel
            action   = 'copy-original'
            details  = 'Linked item not cloned, copied original relation URL.'
        }
    }

    return ,$patch
}

function Copy-AttachmentsForWorkItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceContext,
        [Parameter(Mandatory)] $TargetContext,
        [Parameter(Mandatory)] $SourceWorkItem,
        [Parameter(Mandatory)] [int] $TargetId,
        [Parameter(Mandatory)] [string] $TempDirectory,
        [Parameter(Mandatory)] [ref] $RelationOutcomes
    )

    $attachmentPatch = New-Object System.Collections.Generic.List[object]
    $relations = @(Get-WorkItemRelations -WorkItem $SourceWorkItem)
    if ($relations.Count -eq 0) {
        return ,$attachmentPatch
    }

    foreach ($rel in $relations) {
        if ($rel.rel -ne 'AttachedFile') {
            continue
        }

        $fileName = $null
        $attributes = Get-ObjectPropertyValue -Object $rel -Name 'attributes'
        $attributeName = Get-ObjectPropertyValue -Object $attributes -Name 'name'
        if ($attributeName) {
            $fileName = [string] $attributeName
        }
        if ([string]::IsNullOrWhiteSpace($fileName)) {
            $fileName = "attachment-$($SourceWorkItem.id)-$([Guid]::NewGuid().ToString('N')).bin"
        }

        $localPath = Join-Path $TempDirectory $fileName
        Get-AdoAttachment -Context $SourceContext -DownloadUrl $rel.url -OutputPath $localPath | Out-Null
        $newAttachmentUrl = Add-AdoAttachment -Context $TargetContext -FilePath $localPath -FileName $fileName

        $attachmentPatch.Add(@{
            op = 'add'
            path = '/relations/-'
            value = @{
                rel = 'AttachedFile'
                url = $newAttachmentUrl
                attributes = @{
                    comment = "Cloned from source $($SourceWorkItem.id)"
                    name = $fileName
                }
            }
        })

        $RelationOutcomes.Value += [PSCustomObject]@{
            sourceId = $SourceWorkItem.id
            targetId = $TargetId
            relation = 'AttachedFile'
            action   = 'attachment-cloned'
            details  = $fileName
        }

        Remove-Item -Path $localPath -ErrorAction SilentlyContinue
    }

    return ,$attachmentPatch
}

Export-ModuleMember -Function Build-RelationPatchFromSource, Copy-AttachmentsForWorkItem
