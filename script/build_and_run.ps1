[CmdletBinding()]
param(
    [string]$PetsDir
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$App = Join-Path $Root "windows/PetRunner.Windows/PetRunner.Windows.csproj"

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw ".NET 10 SDK is required. Install it from https://dotnet.microsoft.com/download/dotnet/10.0"
}

$Existing = Get-Process -Name "PetRunner" -ErrorAction SilentlyContinue
if ($Existing) {
    $Existing | Stop-Process
}

$RunArguments = @(
    "run",
    "--project", $App,
    "-p:SelfContained=false",
    "-p:PublishSingleFile=false"
)

if ($PetsDir) {
    $ResolvedPetsDir = (Resolve-Path -LiteralPath $PetsDir).Path
    $RunArguments += @("--", "--pets-dir", $ResolvedPetsDir)
}

Push-Location $Root
try {
    & dotnet @RunArguments
    if ($LASTEXITCODE -ne 0) {
        throw "PetRunner exited with code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}
