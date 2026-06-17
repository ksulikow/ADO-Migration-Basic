Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-CloneConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ConfigPath
    )

    if (-not (Test-Path -Path $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    $raw = Get-Content -Path $ConfigPath -Raw
    return $raw | ConvertFrom-Json -Depth 100
}

function Test-RequiredConfigKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config
    )

    $requiredPaths = @(
        'source.orgUrl',
        'source.project',
        'source.patEnvVar',
        'target.orgUrl',
        'target.project',
        'target.patEnvVar',
        'query.wiql',
        'traceability.sourceReferenceField',
        'traceability.sourceReferenceValue',
        'processing.mode'
    )

    $missing = @()
    foreach ($path in $requiredPaths) {
        $parts = $path.Split('.')
        $cursor = $Config
        $exists = $true
        foreach ($part in $parts) {
            if ($null -eq $cursor -or -not ($cursor.PSObject.Properties.Name -contains $part)) {
                $exists = $false
                break
            }
            $cursor = $cursor.$part
        }

        if (-not $exists -or [string]::IsNullOrWhiteSpace([string] $cursor)) {
            $missing += $path
        }
    }

    return $missing
}

function Test-CloneConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ConfigPath,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    if (-not (Test-Path -Path $SchemaPath)) {
        throw "Schema file not found: $SchemaPath"
    }

    $configRaw = Get-Content -Path $ConfigPath -Raw
    $schemaRaw = Get-Content -Path $SchemaPath -Raw

    $isValid = Test-Json -Json $configRaw -Schema $schemaRaw -ErrorAction Stop
    if (-not $isValid) {
        throw 'Configuration file failed schema validation.'
    }

    $config = $configRaw | ConvertFrom-Json -Depth 100
    $missing = Test-RequiredConfigKeys -Config $config
    if ($missing.Count -gt 0) {
        throw "Missing required config keys: $($missing -join ', ')"
    }

    $allowedMode = @('upsert')
    if ($allowedMode -notcontains [string] $config.processing.mode) {
        throw "Unsupported processing.mode '$($config.processing.mode)'. Allowed: $($allowedMode -join ', ')"
    }

    return $config
}

function Assert-Preflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceContext,
        [Parameter(Mandatory)] $TargetContext,
        [Parameter(Mandatory)] $Config
    )

    $sourcePat = [Environment]::GetEnvironmentVariable([string] $Config.source.patEnvVar)
    $targetPat = [Environment]::GetEnvironmentVariable([string] $Config.target.patEnvVar)
    if ([string]::IsNullOrWhiteSpace($sourcePat)) {
        throw "Missing source PAT environment variable '$($Config.source.patEnvVar)'"
    }
    if ([string]::IsNullOrWhiteSpace($targetPat)) {
        throw "Missing target PAT environment variable '$($Config.target.patEnvVar)'"
    }

    $sourceReachable = Test-AdoConnection -Context $SourceContext
    if (-not $sourceReachable) {
        throw 'Source project API reachability check failed.'
    }

    $targetReachable = Test-AdoConnection -Context $TargetContext
    if (-not $targetReachable) {
        throw 'Target project API reachability check failed.'
    }

    return $true
}

Export-ModuleMember -Function Read-CloneConfig, Test-CloneConfig, Assert-Preflight
