# Builds and runs the Windows host tests with MSVC.
#
# The tests link the core of the platform in zig-out\windows-x64 or
# zig-out\windows-arm64, so run build-core.ps1 first. An ARM64 test program
# builds on an x64 machine and does not run there.
#
# core_link     calls the C API, and opens a file by a UTF-8 path.
# view_offscreen draws a model with Direct3D 12 and checks the pixels.
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

$core = Join-Path $repo "zig-out\windows-$targetArch"
$include = Join-Path $core 'include'
$lib = Join-Path $core 'lib\zslice.lib'
if (-not (Test-Path $lib)) { throw "no core at $lib. Run build-core.ps1 -Platform $Platform first." }

foreach ($name in 'core_link', 'view_offscreen') {
    $source = Join-Path $PSScriptRoot "test\$name.c"
    $exe = Join-Path $out "$name.exe"
    $compile = "cl /nologo /W3 /O2 /MD /utf-8 /I`"$include`" /Fo`"$out\\`" /Fe`"$exe`" `"$source`" " +
        "/link `"$lib`" ntdll.lib ws2_32.lib advapi32.lib bcrypt.lib userenv.lib"
    & cmd /c "`"$vcvars`" $arch >nul && $compile"
    if ($LASTEXITCODE -ne 0) { throw "$name failed to build ($LASTEXITCODE)" }
    if ($hostArch -ne $targetArch) {
        Write-Host "built $exe. It does not run on this machine."
        continue
    }
    & $exe
    if ($LASTEXITCODE -ne 0) { throw "$name failed ($LASTEXITCODE)" }
}

# net_link tests the printer connections against stub servers on 127.0.0.1.
# It contacts no real printer, and it starts no print.
$src = Join-Path $PSScriptRoot 'src'
$netOut = Join-Path $out 'net'
New-Item -ItemType Directory -Force $netOut | Out-Null
$sources = @(Join-Path $PSScriptRoot 'test\net_link.cpp') +
    (Get-ChildItem (Join-Path $src 'net\*.cpp')).FullName +
    (Get-ChildItem (Join-Path $src 'prefs\*.cpp')).FullName +
    @(Join-Path $src 'model\zs_model.cpp')
$quoted = ($sources | ForEach-Object { "`"$_`"" }) -join ' '
$exe = Join-Path $out 'net_link.exe'
$compile = "cl /nologo /W3 /O2 /MD /EHsc /std:c++20 /utf-8 /I`"$include`" /I`"$src\net`" /I`"$src\prefs`" /I`"$src\model`" " +
    "/Fo`"$netOut\\`" /Fe`"$exe`" $quoted /link `"$lib`" ntdll.lib ws2_32.lib advapi32.lib bcrypt.lib userenv.lib " +
    "winhttp.lib crypt32.lib secur32.lib ncrypt.lib shell32.lib ole32.lib user32.lib mfuuid.lib"
& cmd /c "`"$vcvars`" $arch >nul && $compile"
if ($LASTEXITCODE -ne 0) { throw "net_link failed to build ($LASTEXITCODE)" }
if ($hostArch -ne $targetArch) {
    Write-Host "built $exe. It does not run on this machine."
} else {
    & $exe
    if ($LASTEXITCODE -ne 0) { throw "net_link failed ($LASTEXITCODE)" }
}
