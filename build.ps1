param(
    [switch]$Test,
    [switch]$DebugBuild
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'imgMan currently supports Windows only.' }
$odin = (Get-Command odin -ErrorAction Stop).Source
$outputDirectory = Join-Path $PSScriptRoot 'bin'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
Push-Location $PSScriptRoot
try {
    if ($Test) {
        & $odin test fat12 '-out:bin/fat12-tests.exe'
        if ($LASTEXITCODE -ne 0) { throw 'FAT12 tests failed.' }
        & $odin test src '-out:bin/host-tests.exe'
        if ($LASTEXITCODE -ne 0) { throw 'Windows file-operation tests failed.' }
        & $odin run tests/fixtures '-out:bin/fixtures.exe'
        if ($LASTEXITCODE -ne 0) { throw 'Image fixture generation failed.' }
        & python tests/check_images.py --fixtures
        if ($LASTEXITCODE -ne 0) { throw 'Independent image verification failed.' }
    }
    $buildOptions = @('build', 'src', '-out:bin/imgMan.exe', '-subsystem:windows', '-resource:src/imgMan.rc')
    if ($DebugBuild) { $buildOptions += '-debug' } else { $buildOptions += '-o:speed' }
    & $odin @buildOptions
    if ($LASTEXITCODE -ne 0) { throw 'imgMan build failed.' }
    Write-Host "Built $(Join-Path $outputDirectory 'imgMan.exe')"
} finally {
    Pop-Location
}
