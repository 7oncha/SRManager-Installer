param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$Output = (Join-Path $PSScriptRoot "..\artifacts\SRManager")
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$project = Join-Path $repoRoot "src\SRManager\SRManager.csproj"

dotnet publish $project `
    -c $Configuration `
    -r $Runtime `
    --self-contained true `
    -o $Output

$exe = Join-Path $Output "SRManager.exe"
if (-not (Test-Path $exe)) {
    throw "Publish completed, but SRManager.exe was not found at: $exe"
}

Write-Host "Published: $exe"
