# Builds and runs the Windows host tests with MSVC.
#
# core_link links zig-out\lib\zslice.lib, so run build-core.ps1 first. An
# ARM64 test program builds on an x64 machine and does not run there.
#
# Usage: pwsh windows/build-tests.ps1 [-Platform x64|ARM64]
param(
    [ValidateSet('x64', 'ARM64')]
    [string]$Platform = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' })
)
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path "$PSScriptRoot\..").Path
$out = Join-Path $PSScriptRoot "test\out\$Platform"
New-Item -ItemType Directory -Force $out | Out-Null

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'no Visual Studio with the C++ tools' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
# vcvarsall calls vswhere by name.
$env:PATH = "$(Split-Path $vswhere);$env:PATH"

$hostArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$targetArch = $Platform.ToLowerInvariant()
$arch = if ($hostArch -eq $targetArch) { $targetArch } else { "${hostArch}_$targetArch" }

$source = Join-Path $PSScriptRoot 'test\core_link.c'
$exe = Join-Path $out 'core_link.exe'
$include = Join-Path $repo 'zig-out\include'
$lib = Join-Path $repo 'zig-out\lib\zslice.lib'
$compile = "cl /nologo /W3 /O2 /MD /utf-8 /I`"$include`" /Fo`"$out\\`" /Fe`"$exe`" `"$source`" " +
    "/link `"$lib`" ntdll.lib ws2_32.lib advapi32.lib bcrypt.lib userenv.lib"

& cmd /c "`"$vcvars`" $arch >nul && $compile"
if ($LASTEXITCODE -ne 0) { throw "core_link failed to build ($LASTEXITCODE)" }

if ($hostArch -ne $targetArch) {
    Write-Host "built $exe. It does not run on this machine."
    exit 0
}
& $exe
if ($LASTEXITCODE -ne 0) { throw "core_link failed ($LASTEXITCODE)" }
