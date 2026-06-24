#Requires -Version 5.1
<#
.SYNOPSIS
    HLSL Developer Environment for Windows - mirrors the Nix-based hlsl-dev setup.

.DESCRIPTION
    This script provides a task-runner interface (similar to `mask`) for
    configuring and building both LLVM (with HLSL support) and DirectXShaderCompiler
    (DXC) on Windows using Visual Studio, Ninja, or both.

    It is the Windows equivalent of https://github.com/Icohedron/hlsl-dev

.PARAMETER Command
    The task to run. One of:
        check-prereqs, setup, configure-llvm, build-llvm, configure-dxc,
        build-dxc, fetch-history, truncate-history, update-submodules,
        download-d3d, run-exec-tests, help

.PARAMETER BuildType
    CMake build type. Defaults to RelWithDebInfo.
    Valid: Debug, Release, RelWithDebInfo, MinSizeRel

.PARAMETER Target
    Optional build target (e.g., clang, dxc, check-all, check-hlsl).

.PARAMETER Generator
    CMake generator. Defaults to Ninja.
    Valid: Ninja, VS2026, VS2022, VS2019

.PARAMETER Compiler
    C/C++ compiler to use. Defaults to cl.
    Valid: clang-cl, cl

.PARAMETER Repo
    Submodule name for fetch-history / truncate-history commands.

.PARAMETER WarpDll
    For run-exec-tests: path to the WARP d3d10warp.dll passed as the TAEF
    WARP_DLL parameter. Defaults to the copy fetched by download-d3d.

.PARAMETER D3D12SDKPath
    For run-exec-tests: path to the D3D12 Agility SDK bin directory passed as
    the TAEF D3D12SDKPath parameter. Defaults to the copy fetched by download-d3d.

.PARAMETER D3D12SDKVersion
    For run-exec-tests: value passed as the TAEF D3D12SDKVersion parameter.
    Defaults to 1 (auto-detect, fail if the version cannot be used).

.PARAMETER TaefArgs
    For run-exec-tests: remaining arguments forwarded verbatim to TE.exe, e.g.
    /p:"ExperimentalShaders=*" or /select:"@Name='ExecutionTest::*'".

.EXAMPLE
    .\hlsl-dev.ps1 check-prereqs
    .\hlsl-dev.ps1 setup
    .\hlsl-dev.ps1 configure-dxc
    .\hlsl-dev.ps1 build-dxc
    .\hlsl-dev.ps1 configure-llvm -BuildType Debug
    .\hlsl-dev.ps1 build-llvm -Target check-hlsl
    .\hlsl-dev.ps1 build-dxc -Generator VS2026
    .\hlsl-dev.ps1 configure-llvm -Compiler cl
    .\hlsl-dev.ps1 fetch-history -Repo llvm-project
    .\hlsl-dev.ps1 download-d3d
    .\hlsl-dev.ps1 run-exec-tests /p:"ExperimentalShaders=*"
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        "check-prereqs", "setup",
        "configure-llvm", "build-llvm",
        "configure-dxc", "build-dxc",
        "fetch-history", "truncate-history", "update-submodules",
        "download-d3d", "run-exec-tests",
        "help"
    )]
    [string]$Command = "help",

    [ValidateSet("Debug", "Release", "RelWithDebInfo", "MinSizeRel")]
    [string]$BuildType = "RelWithDebInfo",

    [string]$Target = "",

    [ValidateSet("Ninja", "VS2026", "VS2022", "VS2019")]
    [string]$Generator = "Ninja",

    [ValidateSet("clang-cl", "cl")]
    [string]$Compiler = "cl",

    [ValidateSet("", "llvm-project", "DirectXShaderCompiler", "offload-test-suite", "offload-golden-images")]
    [string]$Repo = "",

    # run-exec-tests: override the WARP d3d10warp.dll, the D3D12 Agility SDK
    # directory, and the requested Agility SDK version passed to TAEF. When
    # empty, WarpDll/D3D12SDKPath default to the binaries fetched by download-d3d.
    [string]$WarpDll = "",
    [string]$D3D12SDKPath = "",
    [string]$D3D12SDKVersion = "1",

    # run-exec-tests: any remaining arguments are forwarded verbatim to TE.exe,
    # e.g. /p:"ExperimentalShaders=*" /select:"@Name='ExecutionTest::*'"
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TaefArgs = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Project Paths (relative to this script's location)
# -----------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LLVMDir   = Join-Path $ScriptDir "llvm-project"
$DXCDir    = Join-Path $ScriptDir "DirectXShaderCompiler"
$OffloadTestDir   = Join-Path $ScriptDir "offload-test-suite"
$GoldenImagesDir  = Join-Path $ScriptDir "offload-golden-images"
$Direct3DPreviewDir = Join-Path $ScriptDir "direct3d-preview"

# -----------------------------------------------------------------------------
# Git-for-Windows Bash / Unix Tools
# -----------------------------------------------------------------------------
# LLVM's lit test runner requires a bash that understands native Windows paths.
# WSL's bash.exe (in System32) does NOT work.  This function locates the Git
# for Windows usr\bin directory (which contains bash, grep, sed, diff, etc.)
# and prepends it to the *process* PATH so it is found before any WSL bash.
function Initialize-GitBashPath {
    # Already have a Windows-path-compatible bash?
    $existing = Get-Command bash -ErrorAction SilentlyContinue
    if ($existing) {
        $bashDir = Split-Path -Parent $existing.Source
        # Reject WSL bash (lives under System32 or WindowsApps).
        $sys32  = [System.Environment]::GetFolderPath("System").ToLowerInvariant()
        $winApps = (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps").ToLowerInvariant()
        $bashDirLower = $bashDir.ToLowerInvariant()
        if ($bashDirLower -ne $sys32 -and -not $bashDirLower.StartsWith($winApps)) {
            return  # Good bash already on PATH -- nothing to do.
        }
    }

    $gitBashDir = $null

    # Strategy 1: GitForWindows registry key.
    foreach ($hive in @("HKLM", "HKCU")) {
        foreach ($subKey in @("SOFTWARE\GitForWindows", "SOFTWARE\WOW6432Node\GitForWindows")) {
            $regPath = "${hive}:\${subKey}"
            if (Test-Path $regPath) {
                $installPath = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).InstallPath
                if ($installPath -and (Test-Path (Join-Path $installPath "usr\bin\bash.exe"))) {
                    $gitBashDir = Join-Path $installPath "usr\bin"
                    break
                }
            }
        }
        if ($gitBashDir) { break }
    }

    # Strategy 2: derive from git.exe on PATH.
    if (-not $gitBashDir) {
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCmd) {
            $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCmd.Source)
            $candidate = Join-Path $gitRoot "usr\bin\bash.exe"
            if (Test-Path $candidate) {
                $gitBashDir = Join-Path $gitRoot "usr\bin"
            }
        }
    }

    if ($gitBashDir) {
        $env:Path = "$gitBashDir;$env:Path"
    }
}

# Run early so every command in this script (configure, build, check-prereqs)
# sees the correct bash.
Initialize-GitBashPath

# -----------------------------------------------------------------------------
# Generator Mapping
# -----------------------------------------------------------------------------
function Get-CMakeGenerator {
    switch ($Generator) {
        "Ninja"  { return "Ninja" }
        "VS2026" { return "Visual Studio 18 2026" }
        "VS2022" { return "Visual Studio 17 2022" }
        "VS2019" { return "Visual Studio 16 2019" }
    }
}

function Test-IsMultiConfigGenerator {
    return $Generator -like "VS*"
}

# -----------------------------------------------------------------------------
# MSVC x64 Environment Bootstrapping
# -----------------------------------------------------------------------------
function Initialize-VCEnvironment {
    <#
    .SYNOPSIS
        Ensures the MSVC x64 toolchain is on PATH. When the current Developer
        Command Prompt targets x86 (or no VS environment is loaded at all),
        this function sources vcvarsall.bat for the amd64 host/target so that
        cl.exe, link.exe, and the Windows SDK libraries all resolve to their
        x64 variants.

        For Visual Studio generators this is unnecessary because CMake selects
        the platform through -A, but for single-config generators like Ninja
        the environment must match the desired target architecture.
    #>

    # Nothing to do for multi-config (VS) generators -- CMake handles arch.
    if (Test-IsMultiConfigGenerator) { return }

    # If the user chose clang-cl, the MSVC linker environment is still needed
    # but the detection below (looking for cl.exe) works because the VS
    # Developer Command Prompt always puts cl.exe on PATH too.

    # Quick check: is the current cl.exe already targeting x64?
    $cl = Get-Command cl -ErrorAction SilentlyContinue
    if ($cl) {
        $clOutput = (cmd /c "`"$($cl.Source)`" 2>&1")
        $clBanner = $clOutput -join " "
        if ($clBanner -match 'for (x64|AMD64)') {
            # Already in an x64 environment -- nothing to do.
            return
        }
    }

    # Locate vcvarsall.bat through vswhere
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        if (-not $cl) {
            throw "cl.exe not found and vswhere is not installed. Run from a Visual Studio x64 Developer PowerShell."
        }
        Write-Host "  [env] Warning: vswhere not found; using current (non-x64) environment as-is." -ForegroundColor Yellow
        return
    }

    $vsInstallPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $vsInstallPath) {
        if (-not $cl) {
            throw "No Visual Studio installation with C++ tools found."
        }
        Write-Host "  [env] Warning: could not find a VS install with C++ tools; using current environment." -ForegroundColor Yellow
        return
    }

    $vcvarsall = Join-Path $vsInstallPath "VC\Auxiliary\Build\vcvarsall.bat"
    if (-not (Test-Path $vcvarsall)) {
        Write-Host "  [env] Warning: vcvarsall.bat not found at expected path; using current environment." -ForegroundColor Yellow
        return
    }

    Write-Host "  [env] Current toolchain is not x64 -- sourcing vcvarsall.bat amd64 ..." -ForegroundColor Yellow

    # Run vcvarsall in a child cmd, then dump the resulting environment so we
    # can import it into this PowerShell session.
    $envDump = & cmd.exe /c "`"$vcvarsall`" amd64 >nul 2>&1 && set" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "vcvarsall.bat amd64 failed (exit code $LASTEXITCODE)."
    }

    foreach ($line in $envDump) {
        if ($line -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
        }
    }

    Write-Host "  [env] x64 MSVC environment loaded." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Compiler Selection
# -----------------------------------------------------------------------------
function Get-CompilerCMakeFlags {
    <#
    .SYNOPSIS
        Returns CMake flags for CMAKE_C_COMPILER and CMAKE_CXX_COMPILER
        based on the -Compiler parameter (clang-cl or cl).
    #>

    # Ensure the x64 MSVC environment is active before resolving the compiler.
    Initialize-VCEnvironment

    switch ($Compiler) {
        "clang-cl" {
            $clangCl = Get-Command clang-cl -ErrorAction SilentlyContinue
            if (-not $clangCl) {
                throw "clang-cl not found on PATH. Install LLVM/Clang (winget install LLVM.LLVM) or switch to -Compiler cl."
            }
            $compilerPath = $clangCl.Source
            Write-Host "  [compiler] Using clang-cl ($compilerPath)" -ForegroundColor Green
            return @(
                "-DCMAKE_C_COMPILER=$compilerPath",
                "-DCMAKE_CXX_COMPILER=$compilerPath"
            )
        }
        "cl" {
            $cl = Get-Command cl -ErrorAction SilentlyContinue
            if (-not $cl) {
                throw "cl.exe not found on PATH. Run from a Visual Studio Developer PowerShell or set up vcvarsall.bat."
            }
            $compilerPath = $cl.Source
            Write-Host "  [compiler] Using cl ($compilerPath)" -ForegroundColor Green
            return @(
                "-DCMAKE_C_COMPILER=$compilerPath",
                "-DCMAKE_CXX_COMPILER=$compilerPath"
            )
        }
    }
}

# -----------------------------------------------------------------------------
# CMake Flag Definitions
# -----------------------------------------------------------------------------
function Get-LLVMCMakeFlags {
    $flags = @(
        "-DLLVM_ENABLE_ASSERTIONS=ON",
        "-DLLVM_OPTIMIZED_TABLEGEN=OFF",
        "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",

        # Offload Test Suite & DXC Integration
        "-DHLSL_ENABLE_OFFLOAD_DISTRIBUTION=ON"
        "-DLLVM_EXTERNAL_PROJECTS=OffloadTest",
        "-DLLVM_EXTERNAL_OFFLOADTEST_SOURCE_DIR=$OffloadTestDir",
        "-DGOLDENIMAGE_DIR=$GoldenImagesDir",
        "-DOFFLOADTEST_TEST_CLANG=ON",
        "-DDXC_DIR=$(Join-Path $DXCDir 'build\bin')",

        "-C", (Join-Path $LLVMDir "clang\cmake\caches\HLSL.cmake"),

        # Embed debug info into each .obj (/Z7) instead of writing it to a
        # shared per-target PDB (/Zi). This avoids MSVC's LNK1140
        # "limit exceeded for program database" error when linking very large
        # binaries like clang.exe and AllClangUnitTests.exe, because no merged
        # PDB is produced at link time. Side benefits: /Z7 is also required
        # for sccache to cache MSVC builds (avoids .pdb file-lock contention).
        "-DCMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded"
    )

    # Use sccache if available
    $sccache = Get-Command sccache -ErrorAction SilentlyContinue
    if ($sccache) {
        $sccachePath = $sccache.Source
        $flags += "-DCMAKE_C_COMPILER_LAUNCHER=$sccachePath"
        $flags += "-DCMAKE_CXX_COMPILER_LAUNCHER=$sccachePath"
        # Note: CMAKE_MSVC_DEBUG_INFORMATION_FORMAT=Embedded is already set
        # unconditionally above, which is also what sccache needs to work
        # with cl.exe (/Zi writes to a shared .pdb and breaks file locking).
        Write-Host "  [sccache] Found at $sccachePath - enabling compiler caching" -ForegroundColor Green
    }
    else {
        Write-Host "  [sccache] Not found on PATH - builds will not be cached" -ForegroundColor Yellow
        Write-Host "            Install with: winget install Mozilla.sccache" -ForegroundColor Yellow
    }

    return $flags
}

function Get-DXCCMakeFlags {
    return @(
        "-C", (Join-Path $DXCDir "cmake\caches\PredefinedParams.cmake"),
        "-DHLSL_DISABLE_SOURCE_GENERATION=ON"
    )
}

# -----------------------------------------------------------------------------
# Required Visual Studio Components
# -----------------------------------------------------------------------------
# Each entry maps a vswhere-queryable component ID to a human-readable name.
# These must stay in sync with $VSComponents in install-deps.ps1.
$RequiredVSComponents = @(
    @{ Id = "Microsoft.VisualStudio.Component.VC.Tools.x86.x64";   Name = "MSVC x86/x64 build tools" },
    @{ Id = "Microsoft.VisualStudio.Component.VC.CMake.Project";    Name = "C++ CMake tools for Windows" },
    @{ Id = "Microsoft.VisualStudio.Component.VC.Llvm.Clang";      Name = "C++ Clang tools for Windows" },
    @{ Id = "Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset"; Name = "C++ Clang-cl MSBuild toolset" },
    @{ Id = "Microsoft.VisualStudio.Component.VC.ATL";              Name = "C++ ATL for latest build tools" },
    @{ Id = "Microsoft.VisualStudio.Component.Windows11SDK.26100";  Name = "Windows 11 SDK (10.0.26100)" },
    @{ Id = "Component.Microsoft.Windows.DriverKit";                Name = "Windows Driver Kit" }
)

# -----------------------------------------------------------------------------
# Prerequisite Checking
# -----------------------------------------------------------------------------
function Test-Prerequisites {
    Write-Host "`n=== Checking Prerequisites ===" -ForegroundColor Cyan

    $allGood = $true

    # Git
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitVer = & git --version
        Write-Host "  [OK] $gitVer" -ForegroundColor Green
    }
    else {
        Write-Host "  [MISSING] git - install from https://git-scm.com/downloads" -ForegroundColor Red
        $allGood = $false
    }

    # Bash (Windows-path-compatible -- needed by LLVM lit tests)
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if ($bash) {
        # Validate that this bash understands native Windows paths.
        # WSL's bash.exe lives in System32 and requires /mnt/c/... paths.
        $bashExe = $bash.Source
        $testResult = & $bashExe -c "[[ -f `"$($bashExe.Replace('\','\\'))`" ]]" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] bash ($bashExe)" -ForegroundColor Green
        }
        else {
            Write-Host "  [BAD] bash found at $bashExe but it cannot handle Windows paths (WSL?)" -ForegroundColor Red
            Write-Host "        Re-run install-deps.ps1 to add Git-for-Windows bash to PATH" -ForegroundColor Red
            $allGood = $false
        }
    }
    else {
        Write-Host "  [MISSING] bash (Windows-path-compatible) - needed by LLVM lit tests" -ForegroundColor Red
        Write-Host "            Re-run install-deps.ps1 or install Git for Windows" -ForegroundColor Red
        $allGood = $false
    }

    # CMake
    $cmake = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmake) {
        $cmakeVer = (& cmake --version | Select-Object -First 1)
        Write-Host "  [OK] $cmakeVer" -ForegroundColor Green
    }
    else {
        Write-Host "  [MISSING] cmake >= 3.17.2 - run from a VS Developer PowerShell, or install the C++ CMake tools VS component" -ForegroundColor Red
        $allGood = $false
    }

    # Ninja
    $ninja = Get-Command ninja -ErrorAction SilentlyContinue
    if ($ninja) {
        $ninjaVer = & ninja --version
        Write-Host "  [OK] ninja $ninjaVer" -ForegroundColor Green
    }
    else {
        Write-Host "  [MISSING] ninja - run from a VS Developer PowerShell, or install the C++ CMake tools VS component" -ForegroundColor Red
        $allGood = $false
    }

    # Python
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $pyVer = & python --version 2>&1
        Write-Host "  [OK] $pyVer" -ForegroundColor Green

        # Check for pyyaml
        $pyyaml = & python -c "import yaml; print(yaml.__version__)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] pyyaml $pyyaml" -ForegroundColor Green
        }
        else {
            Write-Host "  [MISSING] pyyaml - install with: pip install pyyaml" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "  [MISSING] python 3.x - https://www.python.org/downloads/" -ForegroundColor Red
        $allGood = $false
    }

    # Visual Studio and required components
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        # Check for any VS install with the base C++ workload
        $vsDisplayName = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Workload.NativeDesktop `
            -property displayName
        if ($vsDisplayName) {
            Write-Host "  [OK] $vsDisplayName" -ForegroundColor Green
        }
        else {
            Write-Host "  [MISSING] Visual Studio with 'Desktop Development with C++' workload" -ForegroundColor Red
            $allGood = $false
        }

        # Check each required component individually
        foreach ($comp in $RequiredVSComponents) {
            $found = & $vswhere -latest -products * `
                -requires $comp.Id `
                -property installationPath
            if ($found) {
                Write-Host "  [OK] VS component: $($comp.Name)" -ForegroundColor Green
            }
            else {
                Write-Host "  [MISSING] VS component: $($comp.Name) ($($comp.Id))" -ForegroundColor Red
                $allGood = $false
            }
        }
    }
    else {
        Write-Host "  [MISSING] Visual Studio - https://visualstudio.microsoft.com/downloads/" -ForegroundColor Red
        $allGood = $false
    }

    # Graphics Tools (optional Windows feature - needed for D3D12 debug layer)
    $d3d12LayersDll = Join-Path $env:SystemRoot "System32\d3d12SDKLayers.dll"
    if (Test-Path $d3d12LayersDll) {
        Write-Host "  [OK] Graphics Tools (D3D12 debug layer present)" -ForegroundColor Green
    }
    else {
        Write-Host "  [MISSING] Graphics Tools optional feature (D3D12 debug layer)" -ForegroundColor Red
        Write-Host "            Enable via: Settings > System > Optional Features > Graphics Tools" -ForegroundColor Red
        Write-Host "            Or run (admin): Add-WindowsCapability -Online -Name Tools.Graphics.DirectX~~~~0.0.1.0" -ForegroundColor Red
        $allGood = $false
    }

    # Vulkan SDK
    $vulkanSdkPath = $env:VULKAN_SDK
    if ($vulkanSdkPath -and (Test-Path $vulkanSdkPath)) {
        # Extract version from the path (typically C:\VulkanSDK\<version>)
        $vulkanVer = Split-Path -Leaf $vulkanSdkPath
        Write-Host "  [OK] Vulkan SDK $vulkanVer ($vulkanSdkPath)" -ForegroundColor Green
    }
    else {
        # Fall back to scanning the default install location
        $vulkanDefault = "C:\VulkanSDK"
        if (Test-Path $vulkanDefault) {
            $latestVulkan = Get-ChildItem $vulkanDefault -Directory | Sort-Object Name -Descending | Select-Object -First 1
            if ($latestVulkan) {
                Write-Host "  [WARN] Vulkan SDK found at $($latestVulkan.FullName) but VULKAN_SDK env var is not set" -ForegroundColor Yellow
                Write-Host "         You may need to restart your terminal or re-run the Vulkan SDK installer" -ForegroundColor Yellow
            }
            else {
                Write-Host "  [MISSING] Vulkan SDK - https://vulkan.lunarg.com/sdk/home" -ForegroundColor Red
                $allGood = $false
            }
        }
        else {
            Write-Host "  [MISSING] Vulkan SDK - https://vulkan.lunarg.com/sdk/home" -ForegroundColor Red
            $allGood = $false
        }
    }

    # Optional: sccache
    $sccache = Get-Command sccache -ErrorAction SilentlyContinue
    if ($sccache) {
        $sccacheVer = (& sccache --version 2>&1 | Select-Object -First 1)
        Write-Host "  [OK] $sccacheVer (optional)" -ForegroundColor Green
    }
    else {
        Write-Host "  [INFO] sccache not found (optional, speeds up rebuilds)" -ForegroundColor Yellow
        Write-Host "         Install with: winget install Mozilla.sccache" -ForegroundColor Yellow
    }

    Write-Host ""
    if ($allGood) {
        Write-Host "All required prerequisites found." -ForegroundColor Green
    }
    else {
        Write-Host "Some prerequisites are missing. Please install them before building." -ForegroundColor Red
    }
    Write-Host ""
}

# -----------------------------------------------------------------------------
# Submodule Management (mirrors mask setup / update-submodules / fetch-history)
# -----------------------------------------------------------------------------
function Invoke-Setup {
    Write-Host "`n=== Initializing Submodules (shallow, depth 2) ===" -ForegroundColor Cyan
    Push-Location $ScriptDir
    try {
        & git submodule update --init --recursive --depth 2
        if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }
        Write-Host "Submodules initialized." -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}

function Invoke-UpdateSubmodules {
    Write-Host "`n=== Updating Submodules to Latest ===" -ForegroundColor Cyan
    Push-Location $ScriptDir
    try {
        & git submodule update --init --recursive --depth 2
        if ($LASTEXITCODE -ne 0) { throw "git submodule update --init failed" }
        & git submodule update --remote --depth 2
        if ($LASTEXITCODE -ne 0) { throw "git submodule update --remote failed" }
        Write-Host "Submodules updated." -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}

function Invoke-FetchHistory {
    param([string]$RepoName)
    if (-not $RepoName) {
        Write-Host "Error: -Repo parameter required. Example: .\hlsl-dev.ps1 fetch-history -Repo llvm-project" -ForegroundColor Red
        return
    }
    $repoPath = Join-Path $ScriptDir $RepoName
    if (-not (Test-Path $repoPath)) {
        Write-Host "Error: Submodule directory '$RepoName' not found at $repoPath" -ForegroundColor Red
        return
    }
    Write-Host "`n=== Fetching Full History for $RepoName ===" -ForegroundColor Cyan
    Push-Location $repoPath
    try {
        & git fetch --unshallow 2>$null
        if ($LASTEXITCODE -ne 0) {
            # Already unshallowed or other issue -- fall back to a normal fetch
            & git fetch --all
            if ($LASTEXITCODE -ne 0) { throw "git fetch --all failed for $RepoName" }
        }
        Write-Host "Full history fetched for $RepoName." -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}

function Invoke-TruncateHistory {
    param([string]$RepoName)
    if (-not $RepoName) {
        Write-Host "Error: -Repo parameter required. Example: .\hlsl-dev.ps1 truncate-history -Repo llvm-project" -ForegroundColor Red
        return
    }
    $repoPath = Join-Path $ScriptDir $RepoName
    if (-not (Test-Path $repoPath)) {
        Write-Host "Error: Submodule directory '$RepoName' not found at $repoPath" -ForegroundColor Red
        return
    }
    Write-Host "`n=== Truncating History for $RepoName (depth 2) ===" -ForegroundColor Cyan
    Push-Location $repoPath
    try {
        & git fetch --depth 2
        if ($LASTEXITCODE -ne 0) { throw "git fetch --depth 2 failed" }

        # Prune local history so disk space is actually reclaimed
        & git reflog expire --expire=now --all
        if ($LASTEXITCODE -ne 0) { throw "git reflog expire failed" }
        & git gc --prune=now
        if ($LASTEXITCODE -ne 0) { throw "git gc --prune=now failed" }

        Write-Host "History truncated for $RepoName." -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}

# -----------------------------------------------------------------------------
# Configure & Build: LLVM
# -----------------------------------------------------------------------------
function Invoke-ConfigureLLVM {
    $sourceDir = Join-Path $LLVMDir "llvm"
    $buildDir  = Join-Path $LLVMDir "build"

    if (-not (Test-Path $sourceDir)) {
        Write-Host "Error: LLVM source not found at $sourceDir. Run '.\hlsl-dev.ps1 setup' first." -ForegroundColor Red
        return
    }

    Write-Host "`n=== Configuring LLVM ($BuildType, $(Get-CMakeGenerator), $Compiler) ===" -ForegroundColor Cyan

    $cmakeArgs = @(
        "-S", $sourceDir,
        "-B", $buildDir,
        "-G", (Get-CMakeGenerator)
    )

    if (-not (Test-IsMultiConfigGenerator)) {
        $cmakeArgs += "-DCMAKE_BUILD_TYPE=$BuildType"
    }

    $cmakeArgs += Get-CompilerCMakeFlags
    $cmakeArgs += Get-LLVMCMakeFlags

    Write-Host "  cmake $($cmakeArgs -join ' ')" -ForegroundColor DarkGray
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "LLVM CMake configuration failed" }
    Write-Host "LLVM configured at $buildDir" -ForegroundColor Green
}

function Invoke-BuildLLVM {
    $buildDir = Join-Path $LLVMDir "build"

    # Auto-configure if build directory is missing
    if (-not (Test-Path (Join-Path $buildDir "CMakeCache.txt"))) {
        Write-Host "Build directory not configured. Running configure-llvm first..." -ForegroundColor Yellow
        Invoke-ConfigureLLVM
    }

    Write-Host "`n=== Building LLVM ===" -ForegroundColor Cyan

    $cmakeArgs = @("--build", $buildDir)

    if (Test-IsMultiConfigGenerator) {
        $cmakeArgs += @("--config", $BuildType)
    }

    if ($Target) {
        $cmakeArgs += @("--target", $Target)
        Write-Host "  Target: $Target" -ForegroundColor DarkGray
    }

    Write-Host "  cmake $($cmakeArgs -join ' ')" -ForegroundColor DarkGray
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "LLVM build failed" }
    Write-Host "LLVM build succeeded." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Configure & Build: DXC
# -----------------------------------------------------------------------------
function Invoke-ConfigureDXC {
    if (-not (Test-Path $DXCDir)) {
        Write-Host "Error: DXC source not found at $DXCDir. Run '.\hlsl-dev.ps1 setup' first." -ForegroundColor Red
        return
    }

    $buildDir = Join-Path $DXCDir "build"

    Write-Host "`n=== Configuring DXC ($BuildType, $(Get-CMakeGenerator), $Compiler) ===" -ForegroundColor Cyan

    $cmakeArgs = @(
        "-S", $DXCDir,
        "-B", $buildDir,
        "-G", (Get-CMakeGenerator)
    )

    if (-not (Test-IsMultiConfigGenerator)) {
        $cmakeArgs += "-DCMAKE_BUILD_TYPE=$BuildType"
    }

    $cmakeArgs += Get-CompilerCMakeFlags
    $cmakeArgs += Get-DXCCMakeFlags

    Write-Host "  cmake $($cmakeArgs -join ' ')" -ForegroundColor DarkGray
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "DXC CMake configuration failed" }
    Write-Host "DXC configured at $buildDir" -ForegroundColor Green
}

function Invoke-BuildDXC {
    $buildDir = Join-Path $DXCDir "build"

    # Auto-configure if build directory is missing
    if (-not (Test-Path (Join-Path $buildDir "CMakeCache.txt"))) {
        Write-Host "Build directory not configured. Running configure-dxc first..." -ForegroundColor Yellow
        Invoke-ConfigureDXC
    }

    Write-Host "`n=== Building DXC ===" -ForegroundColor Cyan

    $cmakeArgs = @("--build", $buildDir)

    if (Test-IsMultiConfigGenerator) {
        $cmakeArgs += @("--config", $BuildType)
    }

    if ($Target) {
        $cmakeArgs += @("--target", $Target)
        Write-Host "  Target: $Target" -ForegroundColor DarkGray
    }

    Write-Host "  cmake $($cmakeArgs -join ' ')" -ForegroundColor DarkGray
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "DXC build failed" }
    Write-Host "DXC build succeeded." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# Direct3D Preview Download (WARP + Agility SDK from NuGet)
# -----------------------------------------------------------------------------
# The newest preview builds of WARP (the Windows Advanced Rasterization
# Platform software renderer) and the Direct3D 12 Agility SDK are published to
# NuGet as prerelease packages, ahead of any stable release. The download-d3d
# task fetches the latest prerelease of each, extracts the binaries for the
# host architecture, and lays them out under direct3d-preview\ so tests can run
# against bleeding-edge WARP and the Agility SDK runtime.

# Map the host processor architecture onto the NuGet package's bin\<arch> name.
function Get-HostNuGetArch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($arch.ToUpperInvariant()) {
        "AMD64" { return "x64" }
        "ARM64" { return "arm64" }
        "X86"   { return "win32" }
        default { throw "Unsupported host architecture for Direct3D NuGet packages: $arch" }
    }
}

# Query the NuGet flat-container index for a package and return its newest
# prerelease (preview) version. NuGet returns versions in ascending SemVer
# order, so the last prerelease entry is the latest.
function Get-LatestNuGetPrerelease {
    param([string]$PackageId)

    $idLower = $PackageId.ToLowerInvariant()
    $indexUrl = "https://api.nuget.org/v3-flatcontainer/$idLower/index.json"
    try {
        $index = Invoke-RestMethod -Uri $indexUrl
    }
    catch {
        throw "Failed to query NuGet for $PackageId ($indexUrl): $($_.Exception.Message)"
    }

    $prerelease = @($index.versions | Where-Object { $_ -match '-' })
    if (-not $prerelease -or $prerelease.Count -eq 0) {
        throw "No prerelease (preview) versions found on NuGet for $PackageId."
    }
    return $prerelease[-1]
}

# Download a NuGet package, extract its build\native\bin\<arch> binaries, and
# copy them into $DestDir (which is recreated fresh on each run).
function Install-Direct3DNuGetPackage {
    param(
        [string]$PackageId,
        [string]$Version,
        [string]$DestDir,
        [string]$NuGetArch
    )

    $idLower  = $PackageId.ToLowerInvariant()
    $nupkgUrl = "https://api.nuget.org/v3-flatcontainer/$idLower/$Version/$idLower.$Version.nupkg"

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("direct3d-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        $nupkg = Join-Path $staging "$idLower.zip"
        Write-Host "  [nuget] Downloading $PackageId $Version ..." -ForegroundColor DarkGray
        Invoke-WebRequest -Uri $nupkgUrl -OutFile $nupkg

        $extracted = Join-Path $staging "extracted"
        Expand-Archive -Path $nupkg -DestinationPath $extracted -Force

        $archDir = Join-Path $extracted "build\native\bin\$NuGetArch"
        if (-not (Test-Path $archDir)) {
            throw "$PackageId $Version does not contain binaries for '$NuGetArch' (expected build\native\bin\$NuGetArch)."
        }

        if (Test-Path $DestDir) { Remove-Item -Recurse -Force $DestDir }
        New-Item -ItemType Directory -Path $DestDir | Out-Null
        Copy-Item -Path (Join-Path $archDir "*") -Destination $DestDir -Recurse -Force
    }
    finally {
        Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    }
}

function Invoke-DownloadDirect3D {
    Write-Host "`n=== Downloading Latest Direct3D Preview (WARP + Agility SDK) from NuGet ===" -ForegroundColor Cyan

    $nugetArch = Get-HostNuGetArch
    Write-Host "  Host architecture: $nugetArch" -ForegroundColor DarkGray

    $packages = @(
        @{ Id = "Microsoft.Direct3D.WARP";  Label = "WARP";        Dest = (Join-Path $Direct3DPreviewDir "WARP");  Key = "d3d10warp.dll" },
        @{ Id = "Microsoft.Direct3D.D3D12"; Label = "Agility SDK"; Dest = (Join-Path $Direct3DPreviewDir "D3D12"); Key = "D3D12Core.dll" }
    )

    foreach ($pkg in $packages) {
        $version = Get-LatestNuGetPrerelease -PackageId $pkg.Id
        Write-Host "  [$($pkg.Label)] Latest preview: $($pkg.Id) $version" -ForegroundColor Green
        Install-Direct3DNuGetPackage -PackageId $pkg.Id -Version $version -DestDir $pkg.Dest -NuGetArch $nugetArch
    }

    Write-Host ""
    Write-Host "Direct3D preview binaries downloaded to $Direct3DPreviewDir" -ForegroundColor Green
    foreach ($pkg in $packages) {
        $keyPath = Join-Path $pkg.Dest $pkg.Key
        if (Test-Path $keyPath) {
            Write-Host "  $($pkg.Label): $keyPath" -ForegroundColor Green
        }
        else {
            Write-Host "  $($pkg.Label): $($pkg.Key) not found under $($pkg.Dest)" -ForegroundColor Yellow
        }
    }
}

# -----------------------------------------------------------------------------
# DXC Execution Tests (ExecHLSLTests.dll via TAEF / TE.exe)
# -----------------------------------------------------------------------------
# Runs the DirectXShaderCompiler execution test suite (ExecHLSLTests.dll) under
# the TAEF runner (TE.exe, supplied by the Windows Driver Kit). WARP_DLL and the
# Agility SDK default to the preview binaries fetched by download-d3d, and any
# extra TE.exe arguments (e.g. /p:"ExperimentalShaders=*", /select:..., /name:...)
# are forwarded verbatim. See README "Running the DXC execution tests" for the
# full list of supported /p: runtime parameters.
function Invoke-RunExecTests {
    $binDir  = Join-Path $DXCDir "build\bin"
    $testDll = Join-Path $binDir "ExecHLSLTests.dll"

    if (-not (Test-Path $testDll)) {
        Write-Host "Error: $testDll not found." -ForegroundColor Red
        Write-Host "       Build it first: .\hlsl-dev.ps1 build-dxc -Target ExecHLSLTests" -ForegroundColor Red
        return
    }

    # Locate the TAEF runner. install-deps.ps1 adds the WDK's host-architecture
    # TAEF directory to PATH so TE.exe is directly runnable.
    $te = Get-Command te.exe -ErrorAction SilentlyContinue
    if (-not $te) {
        throw "te.exe (TAEF) not found on PATH. Re-run install-deps.ps1 to add the Windows Driver Kit's TAEF directory to PATH."
    }

    # Resolve WARP_DLL / D3D12SDKPath, defaulting to the download-d3d binaries.
    $warpDllPath = $WarpDll
    if (-not $warpDllPath) {
        $candidate = Join-Path $Direct3DPreviewDir "WARP\d3d10warp.dll"
        if (Test-Path $candidate) { $warpDllPath = $candidate }
    }

    $sdkPath = $D3D12SDKPath
    if (-not $sdkPath) {
        $candidate = Join-Path $Direct3DPreviewDir "D3D12"
        if (Test-Path $candidate) { $sdkPath = $candidate }
    }

    Write-Host "`n=== Running DXC Execution Tests (ExecHLSLTests.dll) ===" -ForegroundColor Cyan
    Write-Host "  te.exe:    $($te.Source)" -ForegroundColor DarkGray
    Write-Host "  Test DLL:  $testDll" -ForegroundColor DarkGray

    $teArgs = @($testDll)

    if ($warpDllPath) {
        Write-Host "  WARP_DLL:        $warpDllPath" -ForegroundColor DarkGray
        $teArgs += "/p:WARP_DLL=$warpDllPath"
    }
    else {
        Write-Host "  WARP_DLL:        (not set -- using system WARP; run download-d3d to fetch the preview)" -ForegroundColor Yellow
    }

    if ($sdkPath) {
        Write-Host "  D3D12SDKPath:    $sdkPath" -ForegroundColor DarkGray
        Write-Host "  D3D12SDKVersion: $D3D12SDKVersion" -ForegroundColor DarkGray
        $teArgs += "/p:D3D12SDKPath=$sdkPath"
        $teArgs += "/p:D3D12SDKVersion=$D3D12SDKVersion"
    }
    else {
        Write-Host "  D3D12SDKPath:    (not set -- using inbox D3D12; run download-d3d to fetch the Agility SDK)" -ForegroundColor Yellow
    }

    # Most execution tests need HlslDataDir to find their shader/data files.
    # Provide the in-tree default unless the caller already supplied one.
    if (($TaefArgs -join ' ') -notmatch 'HlslDataDir') {
        $hlslDataDir = Join-Path $DXCDir "tools\clang\unittests\HLSLExec"
        if (Test-Path $hlslDataDir) {
            $teArgs += "/p:HlslDataDir=$hlslDataDir"
        }
    }

    if ($TaefArgs -and $TaefArgs.Count -gt 0) {
        Write-Host "  Extra args:      $($TaefArgs -join ' ')" -ForegroundColor DarkGray
        $teArgs += $TaefArgs
    }

    # Run from the bin directory (and prepend it to PATH) so the test DLL's
    # dependencies -- dxcompiler.dll, dxil.dll, etc. -- resolve.
    $exit = 0
    Push-Location $binDir
    try {
        $env:Path = "$binDir;$env:Path"
        Write-Host "  te.exe $($teArgs -join ' ')" -ForegroundColor DarkGray
        & $te.Source @teArgs
        $exit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($exit -ne 0) {
        Write-Host "`nExecution tests reported failures (te.exe exit code $exit)." -ForegroundColor Red
    }
    else {
        Write-Host "`nExecution tests passed." -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------
function Show-Help {
    Write-Host @"

HLSL Developer Environment for Windows
=======================================
Windows equivalent of https://github.com/Icohedron/hlsl-dev

Commands:
  check-prereqs       Check that required tools are installed
  setup               Initialize submodules (shallow clone, depth 2)
  configure-llvm      Configure LLVM with HLSL support
  build-llvm          Build LLVM (auto-configures if needed)
  configure-dxc       Configure DirectXShaderCompiler
  build-dxc           Build DXC (auto-configures if needed)
  fetch-history       Fetch full git history for a submodule
  truncate-history    Truncate submodule history back to depth 2
  update-submodules   Update all submodules to latest upstream
  download-d3d        Download the latest WARP + Agility SDK preview from NuGet
  run-exec-tests      Run ExecHLSLTests.dll execution tests under TAEF (TE.exe)
  help                Show this help message

Parameters:
  -BuildType          Debug | Release | RelWithDebInfo (default) | MinSizeRel
  -Generator          Ninja (default) | VS2026 | VS2022 | VS2019
  -Compiler           cl (default) | clang-cl
  -Target             Specific build target (e.g., clang, dxc, check-all)
  -Repo               Submodule name (for fetch-history / truncate-history)
  -WarpDll            run-exec-tests: WARP_DLL path (default: download-d3d copy)
  -D3D12SDKPath       run-exec-tests: Agility SDK dir (default: download-d3d copy)
  -D3D12SDKVersion    run-exec-tests: D3D12SDKVersion value (default: 1)
  <extra args>        run-exec-tests: forwarded to TE.exe (e.g. /p:"..." /select:"...")

Examples:
  .\hlsl-dev.ps1 check-prereqs
  .\hlsl-dev.ps1 setup
  .\hlsl-dev.ps1 configure-dxc
  .\hlsl-dev.ps1 build-dxc
  .\hlsl-dev.ps1 configure-llvm -BuildType Debug
  .\hlsl-dev.ps1 build-llvm -Target check-hlsl
  .\hlsl-dev.ps1 build-dxc -Generator VS2026
  .\hlsl-dev.ps1 configure-llvm -Compiler cl
  .\hlsl-dev.ps1 fetch-history -Repo llvm-project
  .\hlsl-dev.ps1 truncate-history -Repo DirectXShaderCompiler
  .\hlsl-dev.ps1 download-d3d
  .\hlsl-dev.ps1 run-exec-tests /p:"ExperimentalShaders=*"
  .\hlsl-dev.ps1 run-exec-tests /select:"@Name='ExecutionTest::BasicTriangleTest'"

Quickstart:
  1. .\hlsl-dev.ps1 check-prereqs
  2. .\hlsl-dev.ps1 setup
  3. .\hlsl-dev.ps1 configure-dxc
  4. .\hlsl-dev.ps1 build-dxc
  5. .\hlsl-dev.ps1 configure-llvm
  6. .\hlsl-dev.ps1 build-llvm

Note: For Ninja builds, run this from a Visual Studio Developer PowerShell
      (or run vcvarsall.bat first) so MSVC is on PATH.
      For VS generator builds (-Generator VS2026), this is not required.

"@ -ForegroundColor White
}

# -----------------------------------------------------------------------------
# Main Dispatch
# -----------------------------------------------------------------------------
switch ($Command) {
    "check-prereqs"     { Test-Prerequisites }
    "setup"             { Invoke-Setup }
    "configure-llvm"    { Invoke-ConfigureLLVM }
    "build-llvm"        { Invoke-BuildLLVM }
    "configure-dxc"     { Invoke-ConfigureDXC }
    "build-dxc"         { Invoke-BuildDXC }
    "fetch-history"     { Invoke-FetchHistory -RepoName $Repo }
    "truncate-history"  { Invoke-TruncateHistory -RepoName $Repo }
    "update-submodules" { Invoke-UpdateSubmodules }
    "download-d3d"      { Invoke-DownloadDirect3D }
    "run-exec-tests"    { Invoke-RunExecTests }
    "help"              { Show-Help }
}
