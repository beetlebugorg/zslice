# Builds the Zig core for the Windows shell, with the MSVC ABI.
#
# The result is zig-out\lib\zslice.lib and the headers in zig-out\include.
# A Release core is ReleaseFast. For a target that is not the architecture
# of this machine, Zig does not find the MSVC and SDK libraries, so this
# script gives it a libc file with their paths.
#
# The form of this script follows Lookout Marine. See
# docs/references/libraries.md.
#
# Usage: pwsh windows/build-core.ps1 [-Configuration Debug|Release]
#                                    [-Platform x64|ARM64]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }),
    [string]$Zig = 'zig'
)
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path "$PSScriptRoot\..").Path
$opt = if ($Configuration -eq 'Debug') { 'Debug' } else { 'ReleaseFast' }
$zigTarget = if ($Platform -eq 'x64') { 'x86_64-windows-msvc' } else { 'aarch64-windows-msvc' }
$hostDir = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$targetDir = $Platform.ToLowerInvariant()

$buildArgs = @('lib', "-Dtarget=$zigTarget", "-Doptimize=$opt", '-Dcompiler-rt=true')

$libcFile = $null
if ($hostDir -ne $targetDir) {
    $native = & $Zig libc
    if ($LASTEXITCODE -ne 0) { throw "zig libc failed ($LASTEXITCODE)" }
    $lines = $native | ForEach-Object {
        if ($_ -match '^(crt_dir|msvc_lib_dir|kernel32_lib_dir)=') {
            $_ -replace "\\$hostDir(\\?)$", "\$targetDir`$1"
        }
        else { $_ }
    }
    $libcFile = Join-Path ([IO.Path]::GetTempPath()) "zslice-libc-$targetDir.txt"
    Set-Content -Path $libcFile -Value $lines -Encoding ascii
    $buildArgs += @('--libc', $libcFile)
}

Push-Location $repo
try {
    Write-Host "zig build $($buildArgs -join ' ')"
    & $Zig build @buildArgs
    if ($LASTEXITCODE -ne 0) { throw "zig build failed ($LASTEXITCODE)" }
}
finally {
    Pop-Location
    if ($libcFile) { Remove-Item $libcFile -Force -ErrorAction SilentlyContinue }
}

Write-Host "core ready: $repo\zig-out\lib\zslice.lib ($Platform, $opt)"
