# HLSL Developer Environment (Windows)

Windows counterpart to [hlsl-dev](https://github.com/Icohedron/hlsl-dev) -- a developer environment for working on LLVM's HLSL features and Microsoft's DirectXShaderCompiler (DXC). Uses PowerShell and Visual Studio instead of Nix.

Unlike hlsl-dev, Windows has no Nix equivalent, so this repo cannot offer the same reproducibility guarantees. It relies on system-installed toolchains managed by Visual Studio and winget.

## Prerequisites

- **PowerShell 5.1+** -- ships with Windows 10/11. PowerShell 7 also works but is not required.
  - Your execution policy must allow running scripts. If it doesn't, set it with:
    ```powershell
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
    ```
- **Visual Studio 2026** (or 2022/2019) with the following workloads and components:
  - Desktop Development with C++ (`Microsoft.VisualStudio.Workload.NativeDesktop`)
  - MSVC x86/x64 build tools (`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`)
  - C++ CMake tools for Windows (`Microsoft.VisualStudio.Component.VC.CMake.Project`) -- provides CMake and Ninja
  - C++ Clang tools for Windows (`Microsoft.VisualStudio.Component.VC.Llvm.Clang`) -- provides clang-cl
  - C++ Clang-cl MSBuild toolset (`Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset`)
  - C++ ATL for latest build tools (`Microsoft.VisualStudio.Component.VC.ATL`)
  - Windows 11 SDK 10.0.26100 (`Microsoft.VisualStudio.Component.Windows11SDK.26100`)
  - Windows Driver Kit (`Component.Microsoft.Windows.DriverKit`) -- includes TAEF (`TE.exe`) for DXC tests. The WDK does not put TAEF on PATH by default (it ships side-by-side x86/x64/arm64 builds and is normally consumed via MSBuild's `$(KitsRoot10)`); `install-deps.ps1` adds the host-architecture `Testing\Runtimes\TAEF\<arch>` directory to the machine PATH so `TE.exe` is directly runnable.
- **Python 3.x** (`pip install pyyaml` for LIT tests)
- **Git** -- Git-for-Windows' unix tools (`usr\bin`: bash, grep, sed, diff, etc.) must be on PATH for LLVM LIT tests. `install-deps.ps1` configures this automatically.
- **Vulkan SDK** (<https://vulkan.lunarg.com/sdk/home>)
- **Graphics Tools** -- Windows optional feature providing the D3D12 debug layer. `install-deps.ps1` enables this automatically, or install via Settings > System > Optional Features > Graphics Tools.

Optional:
- **sccache** (`winget install Mozilla.sccache`) -- compiler caching for faster rebuilds

You can install everything automatically by running `.\install-deps.ps1` in an **administrator** PowerShell session.

Run `.\hlsl-dev.ps1 check-prereqs` to verify your setup.

## Quickstart

```powershell
# Open a Visual Studio Developer PowerShell (for Ninja builds)
# or a regular PowerShell (for VS generator builds)

.\hlsl-dev.ps1 check-prereqs
.\hlsl-dev.ps1 setup

# Build DXC
.\hlsl-dev.ps1 configure-dxc
.\hlsl-dev.ps1 build-dxc

# Build LLVM with HLSL support
.\hlsl-dev.ps1 configure-llvm
.\hlsl-dev.ps1 build-llvm
```

## Commands

| Command | Description |
|---------|-------------|
| `check-prereqs` | Verify required tools are installed |
| `setup` | Initialize submodules (shallow clone, depth 2) |
| `configure-llvm` | Configure LLVM with CMake |
| `build-llvm` | Build LLVM (auto-configures if needed) |
| `configure-dxc` | Configure DXC with CMake |
| `build-dxc` | Build DXC (auto-configures if needed) |
| `fetch-history` | Fetch full git history for a submodule |
| `truncate-history` | Truncate submodule history to depth 2 |
| `update-submodules` | Update all submodules to latest upstream |
| `download-d3d` | Download the latest WARP + Agility SDK preview from NuGet |

## Parameters

| Parameter | Values | Default |
|-----------|--------|---------|
| `-BuildType` | `Debug`, `Release`, `RelWithDebInfo`, `MinSizeRel` | `RelWithDebInfo` |
| `-Generator` | `Ninja`, `VS2026`, `VS2022`, `VS2019` | `Ninja` |
| `-Target` | Any CMake target (e.g., `clang`, `dxc`, `check-all`, `check-hlsl`) | (all) |
| `-Repo` | Submodule name (for `fetch-history`/`truncate-history`) | |

## Examples

```powershell
# Debug build of DXC with Ninja
.\hlsl-dev.ps1 configure-dxc -BuildType Debug
.\hlsl-dev.ps1 build-dxc -BuildType Debug

# Generate a Visual Studio solution for DXC
.\hlsl-dev.ps1 configure-dxc -Generator VS2026
# Then open DirectXShaderCompiler\build\LLVM.sln

# Build only the dxc target
.\hlsl-dev.ps1 build-dxc -Target dxc

# Run HLSL tests in LLVM
.\hlsl-dev.ps1 build-llvm -Target check-hlsl

# Run all DXC tests
.\hlsl-dev.ps1 build-dxc -Target check-all

# Fetch full history for a submodule (for rebasing, PRs, etc.)
.\hlsl-dev.ps1 fetch-history -Repo llvm-project

# Truncate it back to save disk space
.\hlsl-dev.ps1 truncate-history -Repo llvm-project
```

## Updating WARP and the Agility SDK

Some tests need a newer software rasterizer or Direct3D 12 runtime than ships
with Windows. The `download-d3d` task fetches the latest **preview (prerelease)**
builds of both [WARP](https://www.nuget.org/packages/Microsoft.Direct3D.WARP)
(the Windows Advanced Rasterization Platform software renderer) and the
[Direct3D 12 Agility SDK](https://www.nuget.org/packages/Microsoft.Direct3D.D3D12)
directly from NuGet:

```powershell
.\hlsl-dev.ps1 download-d3d
```

This requires only internet access -- no extra tooling. The task uses built-in
PowerShell (`Invoke-RestMethod` / `Invoke-WebRequest` / `Expand-Archive`) to:

1. Query the NuGet flat-container index for each package and select the newest
   prerelease version.
2. Download the `.nupkg`, extract the binaries for your host architecture
   (`x64`, `arm64`, or `win32`), and place them under `direct3d-preview\`:
   - `direct3d-preview\WARP\d3d10warp.dll`
   - `direct3d-preview\D3D12\D3D12Core.dll` (plus `d3d12SDKLayers.dll`, etc.)

Re-run the task at any time to update to the newest preview. The
`direct3d-preview\` directory is git-ignored. Point your tests at these binaries
as needed (e.g., copy `d3d10warp.dll` next to your test executable, or set the
Agility SDK path to the `direct3d-preview\D3D12` folder).

## Ninja vs Visual Studio Generator

**Ninja** (default): Faster builds, single-config. Requires running from a Visual Studio Developer PowerShell so MSVC is on PATH.

**VS2026/VS2022/VS2019**: Generates an `LLVM.sln` solution file. Multi-config (switch Debug/Release in IDE). Best for debugging in Visual Studio.

## Differences from the Nix Version

| Nix (Linux) | Windows |
|-------------|---------|
| Clang + LLD toolchain | MSVC (via Visual Studio) |
| `nix develop` manages all deps | `.\install-deps.ps1` or manual install |
| `mask` task runner | `.\hlsl-dev.ps1` PowerShell script |
| sccache always available | sccache optional (auto-detected) |
| `-DLLVM_ENABLE_LLD=ON` | Not set (MSVC uses its own linker) |
| vkd3d-proton, vulkan-loader | Not included (Windows has native D3D12) |
