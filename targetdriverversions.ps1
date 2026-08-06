 ## SBE Target Driver Match

<#
    Script Name : SBE Target Match
    Description : Compares SBE DriverComponents.xml target versions against
                  drivers currently assigned to PnP devices.

    Driver identification:
      1. Win32_PnPSignedDriver identifies the driver currently assigned
         to each device.
      2. Get-WindowsDriver maps the published oemXX.inf name back to the
         original vendor INF name.
      3. The original INF name is compared with TargetPath from
         DriverComponents.xml.

    Status:
      NEEDS UPDATE       Target version is greater than current version
      MATCH              Target version equals current version
      NEWER THAN TARGET  Current version is greater than target version
      NOT CURRENTLY USED Matching package exists but is not assigned
      NOT FOUND          No matching package or current device found
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

        # Extract a numeric version containing up to four sections.
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

    function Get-DriverComparisonStatus {
        param(
            [Parameter(Mandatory)]
            [string]$TargetVersion,

            [Parameter(Mandatory)]
            [string]$CurrentVersion
        )

        $TargetComparable =
            ConvertTo-NormalizedVersion -Version $TargetVersion

        $CurrentComparable =
            ConvertTo-NormalizedVersion -Version $CurrentVersion

        if ($TargetComparable -and $CurrentComparable) {
            if ($TargetComparable -gt $CurrentComparable) {
                return 'NEEDS UPDATE'
            }

            if ($TargetComparable -eq $CurrentComparable) {
                return 'MATCH'
            }

            return 'NEWER THAN TARGET'
        }

        # String fallback if either value cannot be converted to [version].
        if ($TargetVersion.Trim() -eq $CurrentVersion.Trim()) {
            return 'MATCH'
        }

        return 'UNABLE TO COMPARE'
    }

    function Get-OriginalInfName {
        param(
            [AllowNull()]
            [AllowEmptyString()]
            [string]$OriginalFileName
        )

        if ([string]::IsNullOrWhiteSpace($OriginalFileName)) {
            return $null
        }

        try {
            return [System.IO.Path]::GetFileName(
                $OriginalFileName
            ).ToLowerInvariant()
        }
        catch {
            return $null
        }
    }

    [xml]$Xml = $XmlContent

    $Components = @(
        $Xml.PlatformComponent.Components.Component
    )

    # Get driver packages known to Windows.
    #
    # Driver           = published name, normally oemXX.inf
    # OriginalFileName = original vendor INF path/name
    # Version          = package version
    $WindowsDrivers = @(
        Get-WindowsDriver -Online -All -ErrorAction Stop |
            ForEach-Object {
                $OriginalInfName =
                    Get-OriginalInfName -OriginalFileName $_.OriginalFileName

                [pscustomobject]@{
                    PublishedInfName = if ($_.Driver) {
                        ([string]$_.Driver).ToLowerInvariant()
                    }
                    else {
                        $null
                    }

                    OriginalInfName = $OriginalInfName
                    PackageVersion  = [string]$_.Version
                    ProviderName    = [string]$_.ProviderName
                    ClassName       = [string]$_.ClassName
                    OriginalPath    = [string]$_.OriginalFileName
                }
            }
    )

    # Index packages by their published oemXX.inf name.
    $PackageByPublishedInf = @{}

    foreach ($Package in $WindowsDrivers) {
        if ([string]::IsNullOrWhiteSpace($Package.PublishedInfName)) {
            continue
        }

        $Key = $Package.PublishedInfName

        if (-not $PackageByPublishedInf.ContainsKey($Key)) {
            $PackageByPublishedInf[$Key] =
                [System.Collections.Generic.List[object]]::new()
        }

        $PackageByPublishedInf[$Key].Add($Package)
    }

    # Index staged packages by original vendor INF name.
    $PackageByOriginalInf = @{}

    foreach ($Package in $WindowsDrivers) {
        if ([string]::IsNullOrWhiteSpace($Package.OriginalInfName)) {
            continue
        }

        $Key = $Package.OriginalInfName

        if (-not $PackageByOriginalInf.ContainsKey($Key)) {
            $PackageByOriginalInf[$Key] =
                [System.Collections.Generic.List[object]]::new()
        }

        $PackageByOriginalInf[$Key].Add($Package)
    }

    # Win32_PnPSignedDriver represents drivers assigned to PnP devices.
    $CurrentPnPDrivers = @(
        Get-CimInstance `
            -ClassName Win32_PnPSignedDriver `
            -ErrorAction Stop |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.InfName) -and
            -not [string]::IsNullOrWhiteSpace($_.DriverVersion)
        } |
        ForEach-Object {
            $PublishedInfName =
                ([string]$_.InfName).ToLowerInvariant()

            $MappedPackages = @()

            if ($PackageByPublishedInf.ContainsKey($PublishedInfName)) {
                $MappedPackages = @(
                    $PackageByPublishedInf[$PublishedInfName]
                )
            }

            # Normally there will be one package for each published INF.
            if ($MappedPackages.Count -gt 0) {
                foreach ($Package in $MappedPackages) {
                    [pscustomobject]@{
                        DeviceName       = [string]$_.DeviceName
                        DeviceID         = [string]$_.DeviceID
                        CurrentVersion   = [string]$_.DriverVersion
                        PublishedInfName = $PublishedInfName
                        OriginalInfName  = $Package.OriginalInfName
                        ProviderName     = [string]$_.DriverProviderName
                        DeviceClass      = [string]$_.DeviceClass
                        IsSigned         = $_.IsSigned
                    }
                }
            }
            else {
                # Preserve the active device even when DISM mapping
                # is unavailable.
                [pscustomobject]@{
                    DeviceName       = [string]$_.DeviceName
                    DeviceID         = [string]$_.DeviceID
                    CurrentVersion   = [string]$_.DriverVersion
                    PublishedInfName = $PublishedInfName
                    OriginalInfName  = $null
                    ProviderName     = [string]$_.DriverProviderName
                    DeviceClass      = [string]$_.DeviceClass
                    IsSigned         = $_.IsSigned
                }
            }
        }
    )

    # Index currently used drivers by original INF name.
    $CurrentByOriginalInf = @{}

    foreach ($Driver in $CurrentPnPDrivers) {
        if ([string]::IsNullOrWhiteSpace($Driver.OriginalInfName)) {
            continue
        }

        $Key = $Driver.OriginalInfName.ToLowerInvariant()

        if (-not $CurrentByOriginalInf.ContainsKey($Key)) {
            $CurrentByOriginalInf[$Key] =
                [System.Collections.Generic.List[object]]::new()
        }

        $CurrentByOriginalInf[$Key].Add($Driver)
    }

    foreach ($Component in $Components) {
        $FriendlyName  = [string]$Component.FriendlyName
        $TargetVersion = [string]$Component.TargetVersion
        $TargetPath    = [string]$Component.TargetPath

        if (
            [string]::IsNullOrWhiteSpace($FriendlyName) -or
            [string]::IsNullOrWhiteSpace($TargetVersion) -or
            [string]::IsNullOrWhiteSpace($TargetPath)
        ) {
            continue
        }

        $TargetInfName =
            [System.IO.Path]::GetFileName($TargetPath)

        if (
            [string]::IsNullOrWhiteSpace($TargetInfName) -or
            $TargetInfName -notmatch '\.inf$'
        ) {
            continue
        }

        $TargetInfKey = $TargetInfName.ToLowerInvariant()

        $CurrentMatches = @()

        # Normal matching method: XML original INF to mapped original INF.
        if ($CurrentByOriginalInf.ContainsKey($TargetInfKey)) {
            $CurrentMatches = @(
                $CurrentByOriginalInf[$TargetInfKey]
            )
        }

        # Also allow XML to contain a published oemXX.inf name.
        if (
            $CurrentMatches.Count -eq 0 -and
            $PackageByPublishedInf.ContainsKey($TargetInfKey)
        ) {
            $PublishedPackages = @(
                $PackageByPublishedInf[$TargetInfKey]
            )

            $PublishedNames = @(
                $PublishedPackages |
                    Select-Object -ExpandProperty PublishedInfName -Unique
            )

            $CurrentMatches = @(
                $CurrentPnPDrivers |
                    Where-Object {
                        $_.PublishedInfName -in $PublishedNames
                    }
            )
        }

        if ($CurrentMatches.Count -gt 0) {
            # Group identical current versions together. This prevents
            # four identical NICs from producing four unnecessary rows.
            $VersionGroups = @(
                $CurrentMatches |
                    Group-Object CurrentVersion
            )

            foreach ($VersionGroup in $VersionGroups) {
                $CurrentVersion = [string]$VersionGroup.Name

                $Devices = @(
                    $VersionGroup.Group |
                        Select-Object -ExpandProperty DeviceName -Unique |
                        Sort-Object
                )

                $PublishedInfs = @(
                    $VersionGroup.Group |
                        Select-Object `
                            -ExpandProperty PublishedInfName `
                            -Unique |
                        Sort-Object
                )

                $Status = Get-DriverComparisonStatus `
                    -TargetVersion $TargetVersion `
                    -CurrentVersion $CurrentVersion

                [pscustomobject]@{
                    FriendlyName  = $FriendlyName
                    TargetInf     = $TargetInfName
                    PublishedInf  = $PublishedInfs -join ', '
                    TargetVersion = $TargetVersion
                    CurrentVersion = $CurrentVersion
                    Status        = $Status
                    DeviceName    = $Devices -join '; '
                    InUse         = $true
                }
            }

            continue
        }

        # No active PnP device is using this original INF.
        # Determine whether a matching package is at least staged.
        $StagedPackages = @()

        if ($PackageByOriginalInf.ContainsKey($TargetInfKey)) {
            $StagedPackages = @(
                $PackageByOriginalInf[$TargetInfKey]
            )
        }
        elseif ($PackageByPublishedInf.ContainsKey($TargetInfKey)) {
            $StagedPackages = @(
                $PackageByPublishedInf[$TargetInfKey]
            )
        }

        if ($StagedPackages.Count -gt 0) {
            $StagedVersions = @(
                $StagedPackages |
                    Select-Object -ExpandProperty PackageVersion -Unique |
                    Sort-Object
            )

            $PublishedInfs = @(
                $StagedPackages |
                    Select-Object -ExpandProperty PublishedInfName -Unique |
                    Sort-Object
            )

            [pscustomobject]@{
                FriendlyName   = $FriendlyName
                TargetInf      = $TargetInfName
                PublishedInf   = $PublishedInfs -join ', '
                TargetVersion  = $TargetVersion
                CurrentVersion = $StagedVersions -join ', '
                Status         = 'NOT CURRENTLY USED'
                DeviceName     = ''
                InUse          = $false
            }
        }
        else {
            [pscustomobject]@{
                FriendlyName   = $FriendlyName
                TargetInf      = $TargetInfName
                PublishedInf   = ''
                TargetVersion  = $TargetVersion
                CurrentVersion = ''
                Status         = 'NOT FOUND'
                DeviceName     = ''
                InUse          = $false
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
            Write-Host `
                'No matching driver components were found in the XML.' `
                -ForegroundColor DarkYellow

            continue
        }

        $FriendlyWidth = 52
        $InfWidth      = 23
        $TargetWidth   = 18
        $CurrentWidth  = 18
        $StatusWidth   = 21

        $Header = (
            "{0,-$FriendlyWidth}" +
            "{1,-$InfWidth}" +
            "{2,-$TargetWidth}" +
            "{3,-$CurrentWidth}" +
            "{4,-$StatusWidth}"
        ) -f @(
            'FriendlyName',
            'TargetInf',
            'TargetVersion',
            'CurrentVersion',
            'Status'
        )

        Write-Host $Header -ForegroundColor Yellow

        Write-Host (
            '-' * (
                $FriendlyWidth +
                $InfWidth +
                $TargetWidth +
                $CurrentWidth +
                $StatusWidth
            )
        )

        foreach ($Result in (
            $NodeResults |
                Sort-Object FriendlyName, CurrentVersion
        )) {
            $Line = (
                "{0,-$FriendlyWidth}" +
                "{1,-$InfWidth}" +
                "{2,-$TargetWidth}" +
                "{3,-$CurrentWidth}" +
                "{4,-$StatusWidth}"
            ) -f @(
                $Result.FriendlyName,
                $Result.TargetInf,
                $Result.TargetVersion,
                $Result.CurrentVersion,
                $Result.Status
            )

            switch ($Result.Status) {
                'MATCH' {
                    Write-Host $Line -ForegroundColor Green
                }

                'NEEDS UPDATE' {
                    Write-Host $Line -ForegroundColor Red
                }

                'NEWER THAN TARGET' {
                    Write-Host $Line -ForegroundColor Cyan
                }

                'NOT CURRENTLY USED' {
                    Write-Host $Line -ForegroundColor DarkYellow
                }

                'NOT FOUND' {
                    Write-Host $Line -ForegroundColor Yellow
                }

                default {
                    Write-Host $Line -ForegroundColor Magenta
                }
            }
        }

        # Additional device detail lets you verify exactly which hardware
        # is using each reported current driver.
        $ActiveDeviceDetails = @(
            $NodeResults |
                Where-Object InUse |
                Select-Object `
                    FriendlyName,
                    TargetInf,
                    PublishedInf,
                    CurrentVersion,
                    DeviceName
        )

        if ($ActiveDeviceDetails.Count -gt 0) {
            Write-Host "`nCurrently assigned device details:" `
                -ForegroundColor Cyan

            $ActiveDeviceDetails |
                Format-Table -AutoSize |
                Out-String -Width 300 |
                Write-Host
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
