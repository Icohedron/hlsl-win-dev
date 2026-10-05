#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs all HLSL Developer Environment dependencies via Chocolatey.

.DESCRIPTION
    Uses Chocolatey to install every prerequisite for building LLVM (with
    HLSL support) and DirectXShaderCompiler on Windows.  Chocolatey itself is
    installed first if it is not already present, then all remaining
    packages are installed system-wide.

    Must be run from an elevated (Administrator) PowerShell session.

    After installation completes the script refreshes PATH from the registry
    so that newly-installed tools (e.g. Python) are available immediately for
    post-install steps such as pip-installing pyyaml.  Other terminal windows
    may still need to be restarted for PATH changes to take effect.

.EXAMPLE
    # Run from an elevated PowerShell:
    .\install-deps.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Ensure Chocolatey is installed
# -----------------------------------------------------------------------------
$choco = Get-Command choco -ErrorAction SilentlyContinue
if (-not $choco) {
    Write-Host "Chocolatey not found -- installing Chocolatey..." -ForegroundColor Cyan
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

    # Refresh PATH so the newly-installed choco.exe is visible in this session.
    $MachinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $UserPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path    = "$MachinePath;$UserPath"

    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if (-not $choco) {
        throw "Chocolatey installation failed -- choco is still not available."
    }
}

$chocoVer = (& choco --version 2>&1)
Write-Host "Using Chocolatey $chocoVer" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# Package list
# -----------------------------------------------------------------------------
# Visual Studio workloads and individual components to install via setup.exe modify.
$VSComponents = @(
    "Microsoft.VisualStudio.Workload.NativeDesktop",              # Desktop Development with C++ (includes MSVC)
    "Microsoft.VisualStudio.Component.VC.CMake.Project",          # C++ CMake tools for Windows (CMake, Ninja)
    "Microsoft.VisualStudio.Component.VC.Llvm.Clang",             # C++ Clang tools for Windows
    "Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset",      # MSBuild support for LLVM (clang-cl) toolset
    "Microsoft.VisualStudio.Component.VC.ATL",                    # C++ ATL for x64/x86 (Latest MSVC)
    "Microsoft.VisualStudio.Component.VC.ATL.ARM64",              # C++ ATL for ARM64 (Latest MSVC)
    "Component.Microsoft.Windows.DriverKit"                       # Windows Driver Kit (includes TAEF)
)

$Packages = @(
    @{ Id = "git";                   Name = "Git" },
    @{ Id = "vulkan-sdk";             Name = "Vulkan SDK" },
    @{ Id = "python314";              Name = "Python 3.14" },
    @{ Id = "sccache";                Name = "sccache" },
    @{ Id = "windowsdriverkit11";     Name = "Windows Driver Kit 11" }
)

# -----------------------------------------------------------------------------
# Install each package
# -----------------------------------------------------------------------------
Write-Host "`n=== Installing HLSL Dev Dependencies ===" -ForegroundColor Cyan

$Failed = @()

# -----------------------------------------------------------------------------
# Visual Studio 2026 Community (with required workloads and components)
# -----------------------------------------------------------------------------
Write-Host "`n--- Visual Studio 2026 Community (with workloads) ---" -ForegroundColor Cyan

# Step 1: Ensure VS Community is installed (no component overrides -- let
#          winget handle the base install cleanly).
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsSetup = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"

$vsInstallPath = $null
if (Test-Path $vswhere) {
    $vsInstallPath = & $vswhere -latest -products * -property installationPath
}

if (-not $vsInstallPath) {
    Write-Host "  Installing Visual Studio 2026 Community..." -ForegroundColor DarkGray
    & choco install visualstudio2026community -y --no-progress
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [FAILED] Visual Studio 2026 Community -- choco exited with code $LASTEXITCODE" -ForegroundColor Red
        $Failed += "Visual Studio 2026 Community"
    }

    # Re-detect after install
    if (Test-Path $vswhere) {
        $vsInstallPath = & $vswhere -latest -products * -property installationPath
    }
}

# Step 2: Add required workloads and components via the VS Installer.
if ($vsInstallPath -and (Test-Path $vsSetup)) {
    Write-Host "  Adding components to $vsInstallPath ..." -ForegroundColor DarkGray
    Write-Host "  Components: $($VSComponents -join ', ')" -ForegroundColor DarkGray

    $modifyArgs = @("modify", "--installPath", "`"$vsInstallPath`"")
    foreach ($comp in $VSComponents) {
        $modifyArgs += "--add"
        $modifyArgs += $comp
    }
    $modifyArgs += "--passive"
    $modifyArgStr = $modifyArgs -join " "

    Write-Host "  $vsSetup $modifyArgStr" -ForegroundColor DarkGray
    $proc = Start-Process -FilePath $vsSetup -ArgumentList $modifyArgStr -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Host "  [FAILED] VS Installer modify exited with code $($proc.ExitCode)" -ForegroundColor Red
        $Failed += "Visual Studio 2026 Community (components)"
    }
    else {
        Write-Host "  [OK] Visual Studio 2026 Community" -ForegroundColor Green
    }
}
elseif (-not $vsInstallPath) {
    Write-Host "  [FAILED] Visual Studio not found after install attempt" -ForegroundColor Red
    $Failed += "Visual Studio 2026 Community"
}
else {
    Write-Host "  [FAILED] VS Installer (setup.exe) not found -- cannot add components" -ForegroundColor Red
    $Failed += "Visual Studio 2026 Community (components)"
}

# -----------------------------------------------------------------------------
# Remaining packages (simple choco installs)
# -----------------------------------------------------------------------------
foreach ($pkg in $Packages) {
    Write-Host "`n--- $($pkg.Name) ($($pkg.Id)) ---" -ForegroundColor Cyan

    # choco install is idempotent (it no-ops with exit code 0 when the same
    # version is already installed), so there is no need to pre-check state.
    & choco install $pkg.Id -y --no-progress

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [FAILED] $($pkg.Name) -- choco exited with code $LASTEXITCODE" -ForegroundColor Red
        $Failed += $pkg.Name
    }
    else {
        Write-Host "  [OK] $($pkg.Name)" -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# Refresh PATH from the registry so newly-installed tools are visible
# -----------------------------------------------------------------------------
Write-Host "`nRefreshing PATH from registry..." -ForegroundColor DarkGray

$MachinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$UserPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
$env:Path    = "$MachinePath;$UserPath"

# -----------------------------------------------------------------------------
# Post-install: Add Git-for-Windows unix tools to the system PATH
# -----------------------------------------------------------------------------
# LLVM's lit test runner needs a bash that understands native Windows paths.
# Git-for-Windows ships compatible bash, grep, sed, diff, etc. under
# <GitInstall>\usr\bin.  WSL's bash.exe (in System32) does NOT work because
# it expects /mnt/c/... style paths.  We add the Git usr\bin directory to the
# machine PATH (if not already present) so that the correct bash is found
# *before* any WSL bash.
Write-Host "`n--- Git for Windows Unix tools (bash, grep, sed, diff) ---" -ForegroundColor Cyan

$GitBashDir = $null

# Strategy 1: locate via the GitForWindows registry key (most reliable).
$regPaths = @(
    "HKLM:\SOFTWARE\GitForWindows",
    "HKLM:\SOFTWARE\WOW6432Node\GitForWindows",
    "HKCU:\SOFTWARE\GitForWindows"
)
foreach ($rp in $regPaths) {
    if (Test-Path $rp) {
        $candidate = (Get-ItemProperty $rp).InstallPath
        if ($candidate -and (Test-Path (Join-Path $candidate "usr\bin\bash.exe"))) {
            $GitBashDir = Join-Path $candidate "usr\bin"
            break
        }
    }
}

# Strategy 2: derive from git.exe location (e.g. C:\Program Files\Git\cmd\git.exe).
if (-not $GitBashDir) {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCmd.Source)
        $candidate = Join-Path $gitRoot "usr\bin\bash.exe"
        if (Test-Path $candidate) {
            $GitBashDir = Join-Path $gitRoot "usr\bin"
        }
    }
}

if ($GitBashDir) {
    # Check whether the directory is already on the machine PATH.
    $machPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $normalizedEntries = $machPath -split ";" | ForEach-Object { $_.TrimEnd("\").ToLowerInvariant() }
    $normalizedGitBash = $GitBashDir.TrimEnd("\").ToLowerInvariant()

    if ($normalizedEntries -contains $normalizedGitBash) {
        Write-Host "  [OK] $GitBashDir already on system PATH" -ForegroundColor Green
    }
    else {
        # Prepend so it is found before any WSL bash in System32.
        $newMachPath = "$GitBashDir;$machPath"
        [System.Environment]::SetEnvironmentVariable("Path", $newMachPath, "Machine")
        Write-Host "  [OK] Added $GitBashDir to system PATH (before System32)" -ForegroundColor Green
    }

    # Also update the current session's PATH so later steps see it.
    $env:Path = "$GitBashDir;$env:Path"
}
else {
    Write-Host "  [FAILED] Could not locate Git for Windows bash." -ForegroundColor Red
    Write-Host "           Install Git first (winget install Microsoft.Git) and re-run this script." -ForegroundColor Red
    $Failed += "Git Bash (unix tools)"
}

# -----------------------------------------------------------------------------
# Post-install: Add Windows Driver Kit TAEF (TE.exe) to the system PATH
# -----------------------------------------------------------------------------
# The DXC HLSL test suite drives TAEF via TE.exe, which ships with the Windows
# Driver Kit under <KitsRoot10>\Testing\Runtimes\TAEF\<arch>\TE.exe.  The WDK
# installer deliberately leaves this off PATH (it expects MSBuild integration
# via $(KitsRoot10) to pick a per-project architecture), so we add the host
# architecture's TAEF directory here for direct command-line use.
Write-Host "`n--- Windows Driver Kit TAEF (TE.exe) ---" -ForegroundColor Cyan

$TAEFDir = $null

# Locate the Windows Kits root via the standard "Installed Roots" registry key.
$kitsRootKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots"
)
$KitsRoot10 = $null
foreach ($krk in $kitsRootKeys) {
    if (Test-Path $krk) {
        $candidate = (Get-ItemProperty $krk -ErrorAction SilentlyContinue).KitsRoot10
        if ($candidate -and (Test-Path $candidate)) {
            $KitsRoot10 = $candidate
            break
        }
    }
}

# Fall back to the default install location if the registry lookup failed.
if (-not $KitsRoot10) {
    $defaultRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10"
    if (Test-Path $defaultRoot) {
        $KitsRoot10 = $defaultRoot
    }
}

if ($KitsRoot10) {
    # Pick the TAEF subdirectory matching the OS architecture.  TAEF ships
    # x86 (top-level), x64, and arm64 builds; HLSL tests run as native
    # processes so match the OS, not the PowerShell process bitness.
    $osArch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $osArch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($osArch) {
        "AMD64" { $taefArch = "x64" }
        "ARM64" { $taefArch = "arm64" }
        "x86"   { $taefArch = "x86" }
        default { $taefArch = "x64" }
    }

    $candidate = Join-Path $KitsRoot10 "Testing\Runtimes\TAEF\$taefArch"
    if (Test-Path (Join-Path $candidate "TE.exe")) {
        $TAEFDir = $candidate
    }
    else {
        # Fall back to the top-level TAEF directory (x86) shipped with the WDK.
        $candidate = Join-Path $KitsRoot10 "Testing\Runtimes\TAEF"
        if (Test-Path (Join-Path $candidate "TE.exe")) {
            $TAEFDir = $candidate
        }
    }
}

if ($TAEFDir) {
    $machPath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $normalizedEntries = $machPath -split ";" | ForEach-Object { $_.TrimEnd("\").ToLowerInvariant() }
    $normalizedTAEF = $TAEFDir.TrimEnd("\").ToLowerInvariant()

    if ($normalizedEntries -contains $normalizedTAEF) {
        Write-Host "  [OK] $TAEFDir already on system PATH" -ForegroundColor Green
    }
    else {
        $newMachPath = "$machPath;$TAEFDir"
        [System.Environment]::SetEnvironmentVariable("Path", $newMachPath, "Machine")
        Write-Host "  [OK] Added $TAEFDir to system PATH" -ForegroundColor Green
    }

    # Also update the current session's PATH so later steps see TE.exe.
    $env:Path = "$env:Path;$TAEFDir"
}
else {
    Write-Host "  [FAILED] Could not locate TE.exe under the Windows Driver Kit." -ForegroundColor Red
    Write-Host "           Ensure the Windows Driver Kit installed successfully and re-run this script." -ForegroundColor Red
    $Failed += "Windows Driver Kit TAEF (TE.exe)"
}

# -----------------------------------------------------------------------------
# Post-install: pyyaml (needed by LLVM LIT tests)
# -----------------------------------------------------------------------------
Write-Host "`n--- pyyaml (pip) ---" -ForegroundColor Cyan

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    & python -m pip install pyyaml
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [FAILED] pyyaml -- pip exited with code $LASTEXITCODE" -ForegroundColor Red
        $Failed += "pyyaml"
    }
    else {
        Write-Host "  [OK] pyyaml" -ForegroundColor Green
    }
}
else {
    Write-Host "  [SKIPPED] Python not yet on PATH -- restart your terminal, then run: pip install pyyaml" -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# Post-install: Graphics Tools optional Windows feature
# -----------------------------------------------------------------------------
Write-Host "`n--- Graphics Tools (Windows optional feature) ---" -ForegroundColor Cyan

$d3d12LayersDll = Join-Path $env:SystemRoot "System32\d3d12SDKLayers.dll"
if (Test-Path $d3d12LayersDll) {
    Write-Host "  [OK] Graphics Tools already installed" -ForegroundColor Green
}
else {
    & dism /Online /Add-Capability /CapabilityName:Tools.Graphics.DirectX~~~~0.0.1.0 /NoRestart
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [FAILED] Graphics Tools -- dism exited with code $LASTEXITCODE" -ForegroundColor Red
        $Failed += "Graphics Tools"
    }
    else {
        Write-Host "  [OK] Graphics Tools" -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
Write-Host "`n=== Summary ===" -ForegroundColor Cyan

if ($Failed.Count -eq 0) {
    Write-Host "All dependencies installed successfully." -ForegroundColor Green
}
else {
    Write-Host "The following items failed to install:" -ForegroundColor Red
    foreach ($name in $Failed) {
        Write-Host "  - $name" -ForegroundColor Red
    }
}

Write-Host @"

Next steps:
  1. Open a new terminal so PATH entries take effect in other shells.
  2. Run .\hlsl-dev.ps1 check-prereqs to verify everything is ready.

"@ -ForegroundColor White

if ($Failed.Count -gt 0) {
    exit 1
}
