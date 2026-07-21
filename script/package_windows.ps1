$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Tests = Join-Path $Root "windows/PetRunner.Tests/PetRunner.Tests.csproj"
$App = Join-Path $Root "windows/PetRunner.Windows/PetRunner.Windows.csproj"

dotnet run --configuration Release --project $Tests

foreach ($Runtime in @("win-x64", "win-arm64")) {
    $Output = Join-Path $Root "dist/$Runtime"
    if (Test-Path $Output) { Remove-Item $Output -Recurse -Force }
    dotnet publish $App `
        --configuration Release `
        --runtime $Runtime `
        --self-contained true `
        -p:PublishSingleFile=true `
        --output $Output

    $Exe = Join-Path $Output "PetRunner.exe"
    if (-not (Test-Path $Exe)) { throw "PetRunner.exe was not produced for $Runtime" }
    $Hash = (Get-FileHash $Exe -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText("$Exe.sha256", "$Hash  PetRunner.exe`n", [System.Text.Encoding]::ASCII)
    Write-Output $Exe
}
