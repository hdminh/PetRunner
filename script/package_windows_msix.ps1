[CmdletBinding()]
param(
    [string]$IdentityName,
    [string]$Publisher,
    [string]$PublisherDisplayName,
    [string]$DisplayName = "PetRunner",
    [string]$Version,
    [string[]]$Runtime = @("win-x64", "win-arm64"),
    [switch]$SkipTests,
    [switch]$Bundle,
    [string]$CertPath,
    [string]$CertPassword
)

$ErrorActionPreference = "Stop"

foreach ($requiredParameter in @("IdentityName", "Publisher", "PublisherDisplayName")) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $requiredParameter -ValueOnly))) {
        throw "-$requiredParameter is required. Use the value assigned by Partner Center for this package."
    }
}

if ($env:OS -ne "Windows_NT") {
    throw "package_windows_msix.ps1 must run on Windows (or a Windows VM such as Parallels)."
}

$Root = Split-Path -Parent $PSScriptRoot
$Tests = Join-Path $Root "windows/PetRunner.Tests/PetRunner.Tests.csproj"
$App = Join-Path $Root "windows/PetRunner.Windows/PetRunner.Windows.csproj"
$PackageDir = Join-Path $Root "windows/PetRunner.Package"
$ManifestTemplate = Join-Path $PackageDir "Package.appxmanifest"
$PackageAssets = Join-Path $PackageDir "Assets"
$DistRoot = Join-Path $Root "dist/msix"

function Find-SdkTool([string]$Name) {
    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (-not (Test-Path $kitsRoot)) {
        throw "Windows SDK not found at '$kitsRoot'. Install the Windows 10/11 SDK (MakeAppx)."
    }

    $candidates = Get-ChildItem -Path $kitsRoot -Directory |
        Sort-Object Name -Descending |
        ForEach-Object {
            @(
                (Join-Path $_.FullName "x64\$Name"),
                (Join-Path $_.FullName "arm64\$Name")
            )
        }

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "Could not locate $Name under '$kitsRoot'."
}

function Get-ProjectVersion([string]$ProjectPath) {
    $match = Select-String -Path $ProjectPath -Pattern '<Version>([^<]+)</Version>' | Select-Object -First 1
    if (-not $match) {
        throw "Could not read <Version> from $ProjectPath"
    }
    return $match.Matches[0].Groups[1].Value.Trim()
}

function ConvertTo-MsixVersion([string]$RawVersion) {
    $parts = $RawVersion.Split(".")
    while ($parts.Count -lt 4) {
        $parts += "0"
    }
    if ($parts.Count -gt 4) {
        throw "MSIX version must have at most 4 parts (got '$RawVersion')."
    }
    foreach ($part in $parts) {
        if ($part -notmatch '^\d+$') {
            throw "MSIX version parts must be integers (got '$RawVersion')."
        }
    }
    return ($parts -join ".")
}

function Get-ProcessorArchitecture([string]$RuntimeIdentifier) {
    switch ($RuntimeIdentifier) {
        "win-x64" { return "x64" }
        "win-arm64" { return "arm64" }
        "win-x86" { return "x86" }
        default { throw "Unsupported runtime '$RuntimeIdentifier' for MSIX packaging." }
    }
}

function Resolve-DotNet {
    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    # Fresh installs often update the user/machine PATH, but this PowerShell
    # session still has the old PATH until it is restarted.
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machinePath, $userPath) -ne $null -join ";"

    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:ProgramFiles "dotnet\dotnet.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "dotnet\dotnet.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\dotnet\dotnet.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            $dir = Split-Path -Parent $candidate
            if ($env:Path -notlike "*${dir}*") {
                $env:Path = "$dir;$env:Path"
            }
            return $candidate
        }
    }

    return $null
}

$DotNet = Resolve-DotNet
if (-not $DotNet) {
    throw @"
.NET SDK not found on PATH (and not under Program Files\dotnet).
Install the Windows .NET 10 SDK inside this VM from:
  https://dotnet.microsoft.com/download/dotnet/10.0
Then close and reopen PowerShell, and verify with:
  dotnet --list-sdks
"@
}

Write-Host "Using dotnet: $DotNet"
$sdkList = & $DotNet --list-sdks
if ($LASTEXITCODE -ne 0) {
    throw "dotnet failed to run from '$DotNet'."
}
if (-not ($sdkList | Where-Object { $_ -match '^10\.' })) {
    throw @"
Found dotnet at '$DotNet', but no .NET 10 SDK is installed.
Installed SDKs:
$($sdkList -join "`n")
Install .NET 10 SDK from https://dotnet.microsoft.com/download/dotnet/10.0
"@
}


if (-not (Test-Path $ManifestTemplate)) {
    throw "Missing manifest template: $ManifestTemplate"
}

$requiredAssets = @(
    "StoreLogo.png",
    "Square44x44Logo.png",
    "Square71x71Logo.png",
    "Square150x150Logo.png",
    "Square310x310Logo.png",
    "Wide310x150Logo.png",
    "SplashScreen.png"
)
foreach ($asset in $requiredAssets) {
    $path = Join-Path $PackageAssets $asset
    if (-not (Test-Path $path)) {
        throw "Missing package asset: $path"
    }
}

if (-not $Version) {
    $Version = Get-ProjectVersion $App
}
$MsixVersion = ConvertTo-MsixVersion $Version

$MakeAppx = Find-SdkTool "makeappx.exe"
$SignTool = $null
if ($CertPath) {
    if (-not (Test-Path $CertPath)) {
        throw "Certificate not found: $CertPath"
    }
    $SignTool = Find-SdkTool "signtool.exe"
}

if (-not $SkipTests) {
    Write-Host "Running Windows tests..."
    & $DotNet run --configuration Release --project $Tests
    if ($LASTEXITCODE -ne 0) {
        throw "Windows tests failed with exit code $LASTEXITCODE"
    }
}

if (Test-Path $DistRoot) {
    Remove-Item $DistRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $DistRoot | Out-Null

$builtPackages = @()

foreach ($RuntimeIdentifier in $Runtime) {
    $architecture = Get-ProcessorArchitecture $RuntimeIdentifier
    $publishDir = Join-Path $DistRoot "publish-$RuntimeIdentifier"
    $layoutDir = Join-Path $DistRoot "layout-$RuntimeIdentifier"
    $packagePath = Join-Path $DistRoot "PetRunner-$MsixVersion-$architecture.msix"

    Write-Host "Publishing $RuntimeIdentifier..."
    if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }
    & $DotNet publish $App `
        --configuration Release `
        --runtime $RuntimeIdentifier `
        --self-contained true `
        -p:PublishSingleFile=false `
        -p:IncludeNativeLibrariesForSelfExtract=false `
        --output $publishDir
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed for $RuntimeIdentifier with exit code $LASTEXITCODE"
    }

    $exe = Join-Path $publishDir "PetRunner.exe"
    if (-not (Test-Path $exe)) {
        throw "PetRunner.exe was not produced for $RuntimeIdentifier"
    }

    if (Test-Path $layoutDir) { Remove-Item $layoutDir -Recurse -Force }
    New-Item -ItemType Directory -Path $layoutDir | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $layoutDir "Assets") | Out-Null

    Copy-Item -Path (Join-Path $publishDir "*") -Destination $layoutDir -Recurse -Force
    Copy-Item -Path (Join-Path $PackageAssets "*") -Destination (Join-Path $layoutDir "Assets") -Force

    $manifest = Get-Content -LiteralPath $ManifestTemplate -Raw
    $manifest = $manifest.
        Replace("__IDENTITY_NAME__", $IdentityName).
        Replace("__PUBLISHER__", $Publisher).
        Replace("__VERSION__", $MsixVersion).
        Replace("__ARCHITECTURE__", $architecture).
        Replace("__DISPLAY_NAME__", $DisplayName).
        Replace("__PUBLISHER_DISPLAY_NAME__", $PublisherDisplayName)
    $manifestPath = Join-Path $layoutDir "AppxManifest.xml"
    # UTF-8 without BOM — MakeAppx rejects a BOM on AppxManifest.xml.
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($manifestPath, $manifest, $utf8NoBom)

    Write-Host "Packing $packagePath..."
    & $MakeAppx pack /o /d $layoutDir /p $packagePath
    if ($LASTEXITCODE -ne 0) {
        throw "MakeAppx failed for $RuntimeIdentifier with exit code $LASTEXITCODE"
    }

    if ($SignTool) {
        Write-Host "Signing $packagePath..."
        $signArgs = @(
            "sign",
            "/fd", "SHA256",
            "/a",
            "/f", $CertPath,
            $packagePath
        )
        if ($CertPassword) {
            $signArgs = @(
                "sign",
                "/fd", "SHA256",
                "/f", $CertPath,
                "/p", $CertPassword,
                $packagePath
            )
        }
        & $SignTool @signArgs
        if ($LASTEXITCODE -ne 0) {
            throw "signtool failed for $packagePath with exit code $LASTEXITCODE"
        }
    }

    $hash = (Get-FileHash $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        "$packagePath.sha256",
        "$hash  $(Split-Path -Leaf $packagePath)`n",
        [System.Text.Encoding]::ASCII
    )
    $builtPackages += $packagePath
    Write-Output $packagePath
}

if ($Bundle -and $builtPackages.Count -gt 1) {
    $bundleDir = Join-Path $DistRoot "bundle-input"
    New-Item -ItemType Directory -Path $bundleDir | Out-Null
    foreach ($package in $builtPackages) {
        Copy-Item $package $bundleDir
    }
    $bundlePath = Join-Path $DistRoot "PetRunner-$MsixVersion.msixbundle"
    Write-Host "Creating bundle $bundlePath..."
    & $MakeAppx bundle /o /d $bundleDir /p $bundlePath
    if ($LASTEXITCODE -ne 0) {
        throw "MakeAppx bundle failed with exit code $LASTEXITCODE"
    }
    if ($SignTool) {
        $signArgs = @(
            "sign",
            "/fd", "SHA256",
            "/a",
            "/f", $CertPath,
            $bundlePath
        )
        if ($CertPassword) {
            $signArgs = @(
                "sign",
                "/fd", "SHA256",
                "/f", $CertPath,
                "/p", $CertPassword,
                $bundlePath
            )
        }
        & $SignTool @signArgs
        if ($LASTEXITCODE -ne 0) {
            throw "signtool failed for $bundlePath with exit code $LASTEXITCODE"
        }
    }
    $hash = (Get-FileHash $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        "$bundlePath.sha256",
        "$hash  $(Split-Path -Leaf $bundlePath)`n",
        [System.Text.Encoding]::ASCII
    )
    Write-Output $bundlePath
}

Write-Host ""
Write-Host "MSIX output is under $DistRoot"
Write-Host "Package identity values were supplied through -IdentityName, -Publisher, and -PublisherDisplayName."
