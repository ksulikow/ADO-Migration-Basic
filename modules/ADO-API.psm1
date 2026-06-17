Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-AdoContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $OrgUrl,
        [Parameter(Mandatory)] [string] $Project,
        [Parameter(Mandatory)] [string] $PatEnvVar,
        [int] $ThrottleMs = 100,
        [int] $MaxRetries = 5
    )

    $patValue = [Environment]::GetEnvironmentVariable($PatEnvVar)
    if ([string]::IsNullOrWhiteSpace($patValue)) {
        throw "PAT environment variable '$PatEnvVar' is not set."
    }

    $normalizedOrgUrl = $OrgUrl.TrimEnd('/')
    return [PSCustomObject]@{
        OrgUrl     = $normalizedOrgUrl
        Project    = $Project
        PatEnvVar  = $PatEnvVar
        PatValue   = $patValue
        ThrottleMs = $ThrottleMs
        MaxRetries = $MaxRetries
    }
}

function New-AdoHeaders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context
    )

    $tokenBytes = [System.Text.Encoding]::ASCII.GetBytes(":" + $Context.PatValue)
    $encoded = [Convert]::ToBase64String($tokenBytes)
    return @{
        Authorization = "Basic $encoded"
        'Content-Type' = 'application/json-patch+json'
    }
}

function Get-RetryDelayMs {
    param([int] $Attempt)
    $delay = [Math]::Min(2000 * [Math]::Pow(2, $Attempt), 30000)
    return [int] $delay
}

function Invoke-AdoRestMethod {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')] [string] $Method,
        [Parameter(Mandatory)] [string] $Uri,
        [AllowNull()] $Body,
        [string] $ContentType = 'application/json'
    )

    Start-Sleep -Milliseconds $Context.ThrottleMs

    $headers = New-AdoHeaders -Context $Context
    if ($ContentType -ne 'application/json-patch+json') {
        $headers['Content-Type'] = $ContentType
    }

    for ($attempt = 0; $attempt -le $Context.MaxRetries; $attempt++) {
        try {
            $invokeArgs = @{
                Uri         = $Uri
                Method      = $Method
                Headers     = $headers
                ErrorAction = 'Stop'
            }

            if ($null -ne $Body) {
                if ($Body -is [string]) {
                    $invokeArgs.Body = $Body
                }
                else {
                    $invokeArgs.Body = ($Body | ConvertTo-Json -Depth 100)
                }
            }

            return Invoke-RestMethod @invokeArgs
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int] $_.Exception.Response.StatusCode
            }

            $isTransient = $statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -lt 600)
            if (-not $isTransient -or $attempt -ge $Context.MaxRetries) {
                throw
            }

            $delay = Get-RetryDelayMs -Attempt $attempt
            Start-Sleep -Milliseconds $delay
        }
    }
}

function Test-AdoConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context
    )

    $uri = "$($Context.OrgUrl)/_apis/projects/$($Context.Project)?api-version=7.1"
    $result = Invoke-AdoRestMethod -Context $Context -Method GET -Uri $uri
    return $null -ne $result.id
}

function Get-AdoFieldsMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context
    )

    $uri = "$($Context.OrgUrl)/_apis/wit/fields?api-version=7.1"
    $resp = Invoke-AdoRestMethod -Context $Context -Method GET -Uri $uri
    $dict = @{}

    foreach ($field in $resp.value) {
        $dict[$field.referenceName] = [PSCustomObject]@{
            ReferenceName = $field.referenceName
            Name          = $field.name
            Type          = $field.type
            ReadOnly      = [bool] $field.readOnly
            CanSortBy     = [bool] $field.canSortBy
            IsIdentity    = [bool] ($field.referenceName -match 'AssignedTo|ChangedBy|CreatedBy|AuthorizedAs|ActivatedBy|ResolvedBy|ClosedBy')
        }
    }

    return $dict
}

function Invoke-AdoWiqlQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $Wiql
    )

    $uri = "$($Context.OrgUrl)/$($Context.Project)/_apis/wit/wiql?api-version=7.1"
    $body = @{ query = $Wiql }
    return Invoke-AdoRestMethod -Context $Context -Method POST -Uri $uri -Body $body
}

function Get-AdoWorkItemsBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [int[]] $Ids,
        [string[]] $Fields,
        [ValidateSet('None', 'Relations', 'Fields', 'Links', 'All')] [string] $Expand = 'All'
    )

    if (-not $Ids -or $Ids.Count -eq 0) {
        return @()
    }

    $uri = "$($Context.OrgUrl)/_apis/wit/workitemsbatch?api-version=7.1"
    $body = @{
        ids    = $Ids
        fields = $Fields
        expand = $Expand
        errorPolicy = 'Omit'
    }

    $resp = Invoke-AdoRestMethod -Context $Context -Method POST -Uri $uri -Body $body
    return @($resp.value)
}

function Find-AdoWorkItemByField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $FieldReferenceName,
        [Parameter(Mandatory)] [string] $FieldValue,
        [string[]] $IncludeTypes = @()
    )

    $escaped = $FieldValue.Replace("'", "''")
    $typeFilter = ''
    if ($IncludeTypes -and $IncludeTypes.Count -gt 0) {
        $typeValues = ($IncludeTypes | ForEach-Object { "'$_'" }) -join ','
        $typeFilter = " AND [System.WorkItemType] IN ($typeValues)"
    }

    $wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = '$($Context.Project)' AND [$FieldReferenceName] = '$escaped'$typeFilter ORDER BY [System.ChangedDate] DESC"
    $resp = Invoke-AdoWiqlQuery -Context $Context -Wiql $wiql

    if (-not $resp.workItems -or $resp.workItems.Count -eq 0) {
        return $null
    }

    return [int] $resp.workItems[0].id
}

function New-AdoWorkItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $WorkItemType,
        [Parameter(Mandatory)] [object[]] $Patch,
        [bool] $ValidateOnly = $false
    )

    $uri = "$($Context.OrgUrl)/$($Context.Project)/_apis/wit/workitems/`$$WorkItemType?api-version=7.1"
    if ($ValidateOnly) {
        $uri = "$uri&validateOnly=true"
    }

    $patchJson = $Patch | ConvertTo-Json -Depth 100
    return Invoke-AdoRestMethod -Context $Context -Method POST -Uri $uri -Body $patchJson -ContentType 'application/json-patch+json'
}

function Update-AdoWorkItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [int] $Id,
        [Parameter(Mandatory)] [object[]] $Patch,
        [bool] $ValidateOnly = $false
    )

    $uri = "$($Context.OrgUrl)/_apis/wit/workitems/$Id?api-version=7.1"
    if ($ValidateOnly) {
        $uri = "$uri&validateOnly=true"
    }

    $patchJson = $Patch | ConvertTo-Json -Depth 100
    return Invoke-AdoRestMethod -Context $Context -Method PATCH -Uri $uri -Body $patchJson -ContentType 'application/json-patch+json'
}

function Get-AdoWorkItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [int] $Id,
        [ValidateSet('None', 'Relations', 'Fields', 'Links', 'All')] [string] $Expand = 'All'
    )

    $uri = "$($Context.OrgUrl)/_apis/wit/workitems/$Id?`$expand=$Expand&api-version=7.1"
    return Invoke-AdoRestMethod -Context $Context -Method GET -Uri $uri
}

function Get-AdoAttachment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $DownloadUrl,
        [Parameter(Mandatory)] [string] $OutputPath
    )

    $headers = New-AdoHeaders -Context $Context
    $null = $headers.Remove('Content-Type')

    Invoke-WebRequest -Uri $DownloadUrl -Headers $headers -OutFile $OutputPath -ErrorAction Stop | Out-Null
    return $OutputPath
}

function Add-AdoAttachment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)] [string] $FilePath,
        [string] $FileName
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        $FileName = [System.IO.Path]::GetFileName($FilePath)
    }

    $encodedName = [Uri]::EscapeDataString($FileName)
    $uri = "$($Context.OrgUrl)/$($Context.Project)/_apis/wit/attachments?fileName=$encodedName&uploadType=Simple&api-version=7.1"

    $headers = New-AdoHeaders -Context $Context
    $headers['Content-Type'] = 'application/octet-stream'

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $resp = Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $bytes -ErrorAction Stop
    return $resp.url
}

Export-ModuleMember -Function New-AdoContext, Invoke-AdoRestMethod, Test-AdoConnection, Get-AdoFieldsMetadata, Invoke-AdoWiqlQuery, Get-AdoWorkItemsBatch, Find-AdoWorkItemByField, New-AdoWorkItem, Update-AdoWorkItem, Get-AdoWorkItem, Get-AdoAttachment, Add-AdoAttachment
