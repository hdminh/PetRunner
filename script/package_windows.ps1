$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Native = Join-Path $Root "windows/native"
$Installer = Join-Path $Root "windows/installer/PetRunner.iss"
$StoreManifest = Join-Path $Root "windows/store/AppxManifest.xml.in"
$Version = node -p "require('./package.json').version"
$Build = Join-Path $Root ".build/windows-native-x64"
$InstallerOutput = Join-Path $Root "dist/installer"
$MsixOutput = Join-Path $Root "dist/msix"

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { throw "CMake 3.25+ is required." }
if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) { throw "Ninja is required. Install Visual Studio Build Tools with Desktop development with C++." }
if (-not $env:VCPKG_ROOT) { throw "VCPKG_ROOT must point to a vcpkg installation." }

$Iscc = @(
    (Get-Command iscc -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $Iscc) { throw "Inno Setup 6 is required to create the Windows installer." }

$MakeAppx = Get-Command MakeAppx.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
if (-not $MakeAppx) {
    $MakeAppx = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter MakeAppx.exe -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $MakeAppx) { throw "MakeAppx.exe from the Windows 10 SDK is required to create the Microsoft Store package." }

if (Test-Path $Build) { Remove-Item $Build -Recurse -Force }
if (Test-Path $InstallerOutput) { Remove-Item $InstallerOutput -Recurse -Force }
if (Test-Path $MsixOutput) { Remove-Item $MsixOutput -Recurse -Force }
New-Item -ItemType Directory -Path $InstallerOutput | Out-Null
New-Item -ItemType Directory -Path $MsixOutput | Out-Null

Push-Location $Native
try {
    cmake --preset release-x64
    cmake --build --preset release-x64
    ctest --preset release-x64
}
finally {
    Pop-Location
}

$Exe = Join-Path $Build "bin/PetRunner.exe"
if (-not (Test-Path $Exe)) { throw "PetRunner.exe was not produced" }
& $Iscc "/DMyAppVersion=$Version" "/DMyAppArchitecture=x64" "/DMyAppExecutable=$Exe" "/DMyOutputDir=$InstallerOutput" $Installer
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }

$Setup = Join-Path $InstallerOutput "PetRunner-$Version-windows-x64-setup.exe"
if (-not (Test-Path $Setup)) { throw "Windows installer was not produced" }
$Hash = (Get-FileHash $Setup -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$Setup.sha256", "$Hash  $(Split-Path -Leaf $Setup)`n", [System.Text.Encoding]::ASCII)
Write-Output $Setup

$MsixVersion = node -p "const parts = require('./package.json').version.split(/[.-]/); [parts[0], parts[1], parts[2], 0].join('.')"
$MsixLayout = Join-Path $Build "msix-layout"
if (Test-Path $MsixLayout) { Remove-Item $MsixLayout -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $MsixLayout "Assets") | Out-Null
Copy-Item $Exe (Join-Path $MsixLayout "PetRunner.exe")

Add-Type -AssemblyName System.Drawing
function Write-StoreLogo([int]$Pixels, [string]$Name) {
    $Source = [System.Drawing.Image]::FromFile((Join-Path $Root "Assets/AppIcon.png"))
    $Bitmap = New-Object System.Drawing.Bitmap $Pixels, $Pixels
    $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
    $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $Graphics.DrawImage($Source, 0, 0, $Pixels, $Pixels)
    $Bitmap.Save((Join-Path $MsixLayout "Assets/$Name"), [System.Drawing.Imaging.ImageFormat]::Png)
    $Graphics.Dispose(); $Bitmap.Dispose(); $Source.Dispose()
}
Write-StoreLogo 50 "StoreLogo.png"
Write-StoreLogo 44 "Square44x44Logo.png"
Write-StoreLogo 150 "Square150x150Logo.png"
(Get-Content -LiteralPath $StoreManifest -Raw).Replace("__VERSION__", $MsixVersion) |
    Set-Content -LiteralPath (Join-Path $MsixLayout "AppxManifest.xml") -Encoding utf8

$Msix = Join-Path $MsixOutput "PetRunner-$Version-windows-x64-store.msix"
& $MakeAppx pack /o /h SHA256 /d $MsixLayout /p $Msix
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Msix)) { throw "MSIX package was not produced" }
$MsixHash = (Get-FileHash $Msix -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$Msix.sha256", "$MsixHash  $(Split-Path -Leaf $Msix)`n", [System.Text.Encoding]::ASCII)
Write-Output $Msix
