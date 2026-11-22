# Draws the package logos in windows\Assets from assets\icon. Run it after a
# change of the icon, and commit the files that it writes.
#
# Usage: pwsh windows/make-logos.ps1
#
# SPDX-License-Identifier: AGPL-3.0-or-later
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path "$PSScriptRoot\..").Path
$out = Join-Path $PSScriptRoot 'test\out\logos'
$assets = Join-Path $PSScriptRoot 'Assets'
New-Item -ItemType Directory -Force $out, $assets | Out-Null

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'no Visual Studio with the C++ tools' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
# vcvarsall calls vswhere by name.
$env:PATH = "$(Split-Path $vswhere);$env:PATH"
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

$source = Join-Path $PSScriptRoot 'test\make_logos.cpp'
$exe = Join-Path $out 'make_logos.exe'
$compile = "cl /nologo /W3 /O2 /MD /EHsc /utf-8 /Fo`"$out\\`" /Fe`"$exe`" `"$source`" " +
    '/link d2d1.lib windowscodecs.lib shlwapi.lib ole32.lib'
& cmd /c "`"$vcvars`" $arch >nul && $compile"
if ($LASTEXITCODE -ne 0) { throw "make_logos failed to build ($LASTEXITCODE)" }

& $exe (Join-Path $repo 'assets\icon\zslice.svg') (Join-Path $repo 'assets\icon\zslice-small.svg') $assets
if ($LASTEXITCODE -ne 0) { throw "make_logos failed ($LASTEXITCODE)" }
