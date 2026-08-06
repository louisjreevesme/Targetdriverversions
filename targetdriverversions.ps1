 ##sbe
 
<#
    Script Name : SBE Target Match
    Description : Compare SBE DriverComponents.xml target versions
                  with driver versions found in the Windows Driver Store.
#>
 
[CmdletBinding()]
param(
    [string]$XmlPath = (Join-Path $PWD 'DriverComponents.xml')
)
 
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
 
Import-Module FailoverClusters -ErrorAction Stop
 
if (-not (Test-Path -LiteralPath $XmlPath -PathType Leaf)) {
    throw "DriverComponents.xml was not found: $XmlPath"
}
 
# Read the XML locally and send the content to each node.
$XmlContent = Get-Content -LiteralPath $XmlPath -Raw
 
$ClusterNodes = @(
    Get-ClusterNode |
        Select-Object -ExpandProperty Name
)
 
$ScriptBlock = {
    param(
        [Parameter(Mandatory)]
        [string]$XmlContent
    )
 
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
 
    function ConvertTo-NormalizedVersion {
        param(
            [AllowNull()]
            [AllowEmptyString()]
            [string]$Version
        )
 
        if ([string]::IsNullOrWhiteSpace($Version)) {
            return $null
        }
 
        # Extract up to four numeric version sections.
        if ($Version -match '\d+(?:\.\d+){1,3}') {
            try {
                return [version]$Matches[0]
            }
            catch {
                return $null
            }
        }
 
        return $null
    }
 
    function Get-InfDriverVersion {
        param(
            [Parameter(Mandatory)]
            [string]$InfPath
        )
 
        try {
            $DriverVerLine = Select-String `
                -LiteralPath $InfPath `
                -Pattern '^\s*DriverVer\s*=' `
                -ErrorAction Stop |
                Select-Object -First 1
 
            if (-not $DriverVerLine) {
                return $null
            }
 
            # Examples:
            # DriverVer = 01/01/2025,1.2.3.4
            # DriverVer=1.2.3.4
            $Value = ($DriverVerLine.Line -split '=', 2)[1].Trim()
 
            if ($Value -match ',\s*([^,\s]+)\s*$') {
                return $Matches[1].Trim()
            }
 
            if ($Value -match '\d+(?:\.\d+){1,3}') {
                return $Matches[0]
            }
 
            return $null
        }
        catch {
            return $null
        }
    }
 
    [xml]$Xml = $XmlContent
 
    $Components = @(
        $Xml.PlatformComponent.Components.Component
    )
 
    # Build one index of all INF files on the node.
    # This is much faster than running Get-ChildItem -Recurse
    # separately for every XML component.
    $InfFiles = @(
        Get-ChildItem `
            -LiteralPath 'C:\Windows\System32\DriverStore\FileRepository' `
            -Filter '*.inf' `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue
 
        Get-ChildItem `
            -LiteralPath 'C:\Windows\INF' `
            -Filter '*.inf' `
            -File `
            -ErrorAction SilentlyContinue
    )
 
    $InfIndex = @{}
 
    foreach ($InfFile in $InfFiles) {
        $Key = $InfFile.Name.ToLowerInvariant()
 
        if (-not $InfIndex.ContainsKey($Key)) {
            $InfIndex[$Key] = [System.Collections.Generic.List[object]]::new()
        }
 
        $InfIndex[$Key].Add($InfFile)
    }
 
    foreach ($Component in $Components) {
        $FriendlyName  = [string]$Component.FriendlyName
        $TargetVersion = [string]$Component.TargetVersion
        $TargetPath    = [string]$Component.TargetPath
 
        if ([string]::IsNullOrWhiteSpace($FriendlyName) -or
            [string]::IsNullOrWhiteSpace($TargetVersion) -or
            [string]::IsNullOrWhiteSpace($TargetPath)) {
 
            continue
        }
 
        $InfFileName = [System.IO.Path]::GetFileName($TargetPath)
 
        if ([string]::IsNullOrWhiteSpace($InfFileName) -or
            $InfFileName -notmatch '\.inf$') {
 
            continue
        }
 
        $InfKey = $InfFileName.ToLowerInvariant()
 
        # Discard XML components whose INF was not found.
        if (-not $InfIndex.ContainsKey($InfKey)) {
            continue
        }
 
        $VersionsFound = foreach ($FoundInf in $InfIndex[$InfKey]) {
            $Version = Get-InfDriverVersion -InfPath $FoundInf.FullName
 
            if (-not [string]::IsNullOrWhiteSpace($Version)) {
                $Version
            }
        }
 
        $VersionsFound = @(
            $VersionsFound |
                Sort-Object -Unique
        )
 
        # Discard components where the INF exists but DriverVer
        # could not be obtained.
        if ($VersionsFound.Count -eq 0) {
            continue
        }
 
        $TargetComparable =
            ConvertTo-NormalizedVersion -Version $TargetVersion
 
        foreach ($FoundVersion in $VersionsFound) {
            $FoundComparable =
                ConvertTo-NormalizedVersion -Version $FoundVersion
 
            # User requested any difference to display as NEEDS UPDATE.
            if ($TargetComparable -and $FoundComparable) {
                $Status = if ($FoundComparable -eq $TargetComparable) {
                    'MATCH'
                }
                else {
                    'NEEDS UPDATE'
                }
            }
            else {
                $Status = if (
                    $FoundVersion.Trim() -eq $TargetVersion.Trim()
                ) {
                    'MATCH'
                }
                else {
                    'NEEDS UPDATE'
                }
            }
 
            [pscustomobject]@{
                FriendlyName  = $FriendlyName
                TargetVersion = $TargetVersion
                FoundVersion  = $FoundVersion
                Status        = $Status
            }
        }
    }
}
 
foreach ($Node in $ClusterNodes) {
    Write-Host "`nResults from $Node" -ForegroundColor Cyan
 
    try {
        $NodeResults = @(
            Invoke-Command `
                -ComputerName $Node `
                -ScriptBlock $ScriptBlock `
                -ArgumentList $XmlContent `
                -ErrorAction Stop
        )
 
        if ($NodeResults.Count -eq 0) {
            Write-Host 'No matching driver components were found.' `
                -ForegroundColor DarkYellow
 
            continue
        }
 
        $FriendlyWidth = 58
        $TargetWidth   = 22
        $FoundWidth    = 22
        $StatusWidth   = 15
 
        $Header = (
            "{0,-$FriendlyWidth}" +
            "{1,-$TargetWidth}" +
            "{2,-$FoundWidth}" +
            "{3,-$StatusWidth}"
        ) -f @(
            'FriendlyName',
            'TargetVersion',
            'FoundVersion',
            'Status'
        )
 
        Write-Host $Header -ForegroundColor Yellow
 
        Write-Host (
            '-' * (
                $FriendlyWidth +
                $TargetWidth +
                $FoundWidth +
                $StatusWidth
            )
        )
 
        foreach ($Result in (
            $NodeResults |
                Sort-Object FriendlyName, FoundVersion
        )) {
            $Line = (
                "{0,-$FriendlyWidth}" +
                "{1,-$TargetWidth}" +
                "{2,-$FoundWidth}" +
                "{3,-$StatusWidth}"
            ) -f @(
                $Result.FriendlyName,
                $Result.TargetVersion,
                $Result.FoundVersion,
                $Result.Status
            )
 
            if ($Result.Status -eq 'MATCH') {
                Write-Host $Line -ForegroundColor Green
            }
            else {
                Write-Host $Line -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Warning (
            'Unable to query {0}: {1}' -f
            $Node,
            $_.Exception.Message
        )
    }
}
###end
