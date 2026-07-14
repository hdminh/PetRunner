$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Output = Join-Path $Root "dist/windows-x64"
$Tests = Join-Path $Root "windows/PetRunner.Tests/PetRunner.Tests.csproj"
$App = Join-Path $Root "windows/PetRunner.Windows/PetRunner.Windows.csproj"

dotnet run --configuration Release --project $Tests
if (Test-Path $Output) { Remove-Item $Output -Recurse -Force }
dotnet publish $App `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    --output $Output

$Exe = Join-Path $Output "PetRunner.exe"
if (-not (Test-Path $Exe)) { throw "PetRunner.exe was not produced" }
$Hash = (Get-FileHash $Exe -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -Path "$Exe.sha256" -Value "$Hash  PetRunner.exe" -Encoding ascii
Write-Output $Exe
