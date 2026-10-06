#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs all HLSL Developer Environment dependencies.

.DESCRIPTION
    Uses winget and NuGet to install every prerequisite for building LLVM
    (with HLSL support) and DirectXShaderCompiler on Windows.  Packages are
    installed machine-wide.

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
# Verify winget is available
# -----------------------------------------------------------------------------
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    throw "winget is not available. Install App Installer from the Microsoft Store or update Windows."
}

$wingetVer = (& winget --version 2>&1)
Write-Host "Using winget $wingetVer" -ForegroundColor Cyan

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
    "Component.Microsoft.Windows.DriverKit"                       # Windows Driver Kit VS integration
)

$Packages = @(
    @{ Id = "Microsoft.Git";                        Name = "Git" },
    @{ Id = "KhronosGroup.VulkanSDK";               Name = "Vulkan SDK" },
    @{ Id = "Python.Python.3.14";                   Name = "Python 3.14" },
    @{ Id = "Mozilla.sccache";                      Name = "sccache" }
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
    & winget install --id Microsoft.VisualStudio.Community --scope machine `
        --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [FAILED] Visual Studio 2026 Community -- winget exited with code $LASTEXITCODE" -ForegroundColor Red
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
# Remaining packages (simple winget installs)
# -----------------------------------------------------------------------------
foreach ($pkg in $Packages) {
    Write-Host "`n--- $($pkg.Name) ($($pkg.Id)) ---" -ForegroundColor Cyan

    # Check if the package is already installed before attempting install.
    # Some installers (e.g. Vulkan SDK) return non-zero when the same version
    # is already present, which winget reports as a failure.
    & winget list --id $pkg.Id --exact --accept-source-agreements 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] $($pkg.Name) (already installed)" -ForegroundColor Green
        continue
    }

    & winget install --id $pkg.Id --scope machine --accept-source-agreements --accept-package-agreements

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [FAILED] $($pkg.Name) -- winget exited with code $LASTEXITCODE" -ForegroundColor Red
        $Failed += $pkg.Name
    }
    else {
        Write-Host "  [OK] $($pkg.Name)" -ForegroundColor Green
    }
}

$osArch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $osArch = $env:PROCESSOR_ARCHITEW6432 }

switch ($osArch) {
    "AMD64" { $taefArch = "x64" }
    "ARM64" { $taefArch = "arm64" }
    default { throw "Unsupported host architecture '$osArch'. TAEF supports x64 and ARM64 hosts." }
}

$NuGetMirror = "https://packagefeedproxy.microsoft.io/nuget/v3/index.json"
$NuGetToolsDir = Join-Path $env:ProgramData "hlsl-win-dev\tools"
$NuGetExe = Join-Path $NuGetToolsDir "nuget.exe"
$NuGetPackagesDir = Join-Path $env:ProgramData "hlsl-win-dev\packages"

if (-not (Test-Path $NuGetExe)) {
    New-Item -ItemType Directory -Path $NuGetToolsDir -Force | Out-Null

    try {
        Write-Host "  Downloading NuGet CLI..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" `
            -OutFile $NuGetExe -UseBasicParsing
    }
    catch {
        Write-Host "  Primary NuGet CLI download failed; bootstrapping from the Microsoft mirror..." -ForegroundColor Yellow

        $mirrorIndex = Invoke-RestMethod -Uri $NuGetMirror -UseBasicParsing
        $searchResource = $mirrorIndex.resources |
            Where-Object { $_.'@type' -like "SearchQueryService*" } |
            Select-Object -First 1 -ExpandProperty '@id'
        $packageBaseResource = $mirrorIndex.resources |
            Where-Object { $_.'@type' -eq "PackageBaseAddress/3.0.0" } |
            Select-Object -First 1 -ExpandProperty '@id'

        if (-not $searchResource -or -not $packageBaseResource) {
            throw "The Microsoft NuGet mirror does not expose the resources needed to download the NuGet CLI."
        }

        $queryUri = "${searchResource}?q=NuGet.CommandLine&prerelease=false&semVerLevel=2.0.0&take=20"
        $nugetMetadata = (Invoke-RestMethod -Uri $queryUri -UseBasicParsing).data |
            Where-Object { $_.id -eq "NuGet.CommandLine" } |
            Select-Object -First 1
        if (-not $nugetMetadata) {
            throw "NuGet.CommandLine was not found on the Microsoft NuGet mirror."
        }

        $nugetVersion = $nugetMetadata.version.ToLowerInvariant()
        $nugetPackage = Join-Path $env:TEMP "nuget.commandline.$nugetVersion.nupkg"
        $nugetArchive = "$nugetPackage.zip"
        $nugetExtractDir = Join-Path $env:TEMP "nuget.commandline.$nugetVersion"
        $packageUri = "${packageBaseResource}nuget.commandline/$nugetVersion/nuget.commandline.$nugetVersion.nupkg"

        Invoke-WebRequest -Uri $packageUri -OutFile $nugetPackage -UseBasicParsing
        Copy-Item $nugetPackage $nugetArchive -Force
        if (Test-Path $nugetExtractDir) {
            Remove-Item -Path $nugetExtractDir -Recurse -Force
        }
        Expand-Archive -Path $nugetArchive -DestinationPath $nugetExtractDir -Force
        Copy-Item (Join-Path $nugetExtractDir "tools\NuGet.exe") $NuGetExe -Force
        Remove-Item -Path $nugetPackage, $nugetArchive, $nugetExtractDir -Recurse -Force
    }
}

# -----------------------------------------------------------------------------
# TAEF (TE.exe)
# -----------------------------------------------------------------------------
Write-Host "`n--- TAEF (NuGet) ---" -ForegroundColor Cyan

$TaefPackageId = "Microsoft.Taef"
$TaefPackageSource = "https://pkgs.dev.azure.com/shine-oss/microsoft-ui-xaml/_packaging/WinUI-Dependencies/nuget/v3/index.json"

New-Item -ItemType Directory -Path $NuGetPackagesDir -Force | Out-Null
& $NuGetExe install $TaefPackageId -OutputDirectory $NuGetPackagesDir `
    -Source $TaefPackageSource -NonInteractive -DirectDownload -NoHttpCache

if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAILED] TAEF -- NuGet exited with code $LASTEXITCODE" -ForegroundColor Red
    $Failed += "TAEF ($TaefPackageId)"
}
else {
    Write-Host "  [OK] TAEF ($TaefPackageId)" -ForegroundColor Green
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
# Post-install: Add TAEF (TE.exe) to the system PATH
# -----------------------------------------------------------------------------
# The DXC HLSL test suite drives TAEF via TE.exe.  The Microsoft.Taef NuGet
# package ships architecture-specific binaries under build\Binaries, so add
# the host architecture's directory for direct command-line use.
Write-Host "`n--- TAEF PATH (TE.exe) ---" -ForegroundColor Cyan

$TAEFDir = $null

$taefPackages = Get-ChildItem -Path $NuGetPackagesDir -Directory -Filter "$TaefPackageId.*" -ErrorAction SilentlyContinue |
    Sort-Object {
        [version]$_.Name.Substring("$TaefPackageId.".Length)
    } -Descending
foreach ($taefPackage in $taefPackages) {
    $candidate = Join-Path $taefPackage.FullName "build\Binaries\$taefArch"
    if (Test-Path (Join-Path $candidate "TE.exe")) {
        $TAEFDir = $candidate
        break
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
    Write-Host "  [FAILED] Could not locate TE.exe under the installed Microsoft.Taef package." -ForegroundColor Red
    Write-Host "           Ensure the TAEF NuGet package installed successfully and re-run this script." -ForegroundColor Red
    $Failed += "TAEF (TE.exe)"
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
