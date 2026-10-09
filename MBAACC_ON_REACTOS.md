# Melty Blood Actress Again: Current Code on ReactOS

How *Melty Blood Actress Again: Current Code* (Trial Rev.10, "MBAACC") was made to run on ReactOS in a VMware virtual machine. This document covers four things:

- the original issue;
- the exact reasons the game did not run;
- the workarounds and source changes made on the `mbaacc-fix` branch;
- the scripts and tools used to find and verify them.

Base revision: `f06eace89e1` (ReactOS `0.4.17-dev-966`, master as of October 2026).

---

## Table of contents

1. [Summary](#1-summary)
2. [The original issue](#2-the-original-issue)
3. [The Direct3D stack in ReactOS](#3-the-direct3d-stack-in-reactos)
4. [Why the game did not run: root causes](#4-why-the-game-did-not-run-root-causes)
   1. [Direct3D needs GLSL; ReactOS OpenGL has none, with or without PR #6726](#41-direct3d-needs-glsl-reactos-opengl-has-none-with-or-without-pr-6726)
   2. [FAT32 data loss: truncated cluster chains (Cache Manager)](#42-fat32-data-loss-truncated-cluster-chains-cache-manager)
   3. [JIT code 500x slower: pages become uncached after VirtualProtect (Memory Manager)](#43-jit-code-500x-slower-pages-become-uncached-after-virtualprotect-memory-manager)
   4. [Out of memory on loading: the 1 GB buffer](#44-out-of-memory-on-loading-the-1-gb-buffer)
5. [Changes on the `mbaacc-fix` branch](#5-changes-on-the-mbaacc-fix-branch)
6. [Workarounds and required configuration](#6-workarounds-and-required-configuration)
7. [Building the ISO](#7-building-the-iso)
8. [Test environment and scripts](#8-test-environment-and-scripts)
9. [Measurements](#9-measurements)
10. [Known remaining issues](#10-known-remaining-issues)
11. [References](#11-references)

---

## 1. Summary

| | Before | After |
|---|---|---|
| Game start | *"ReactOS DirectX Needs at least OpenGL 2.0"*, then *"Direct3D initialization failed"* | Starts; caution screen, logos, title, menus |
| Game data (263 MB `0000.p`) after a reboot | Corrupt; kernel `STATUS_FILE_CORRUPT_ERROR`; assertion in Debug builds | Intact (verified byte for byte) |
| Rendering speed with software OpenGL | ~0.07 fps (one frame every ~15 s) | 10–30 fps (single vCPU, Debug build) |
| Battle | Unreachable | Playable; sprites, stages, HUD and effects render correctly |

Four independent problems stopped the game:

1. **No shader-capable OpenGL.** ReactOS's Direct3D implementation (wined3d, synced to Wine 10.1) needs OpenGL with GLSL 1.20. Neither the built-in software OpenGL nor the Mesa restored by PR #6726 provides it.
2. **Kernel Cache Manager bug.** Copying a large file to a FAT32 volume lost FAT updates. After a reboot, the game's 263 MB data file was truncated at 123 MB.
3. **Kernel Memory Manager bug.** Every `VirtualProtect` call made the affected pages *uncached*. JIT-compiled code, including Mesa's llvmpipe shaders, ran about 500 times slower.
4. **Memory.** The game commits and touches a 1 GB buffer while loading. ReactOS cannot page out such memory, so the VM needs at least 3 GB of RAM.

Problems 2 and 3 are general ReactOS bugs. They affect far more than this game.

---

## 2. The original issue

### 2.1 Report

- Building ReactOS with RosBE + Visual Studio 2019 (`configure`, `cd output-vs-i386`, `ninja bootcd`) and running MBAACC Trial Rev.10 crashed or failed with graphical issues.
- Similar to [CORE-15408](https://jira.reactos.org/browse/CORE-15408) ("Regression: VBox WineD3D fake window: Application Error in Games").
- The proposed starting point was [PR #6726](https://github.com/reactos/reactos/pull/6726), *"[MESA] Upgrade MESA again"*. It was closed without merging and contains four commits:

| Commit | Description |
|---|---|
| `bd8ca4e` | Revert "[MESA] Change reported OpenGL version to 1.1.0 (#5675)" |
| `2f37bce` | Revert "[OPENGL32][MESA] Downgrade Mesa library to version 2.6" |
| `c2cc102` | [MESA] Fix build |
| `e531bce` | [MESA] Report the correct version (2.0) |

- Goal: the game runs in VMware from a freshly built ISO, with no graphical issues.

### 2.2 Symptoms observed during reproduction

| Stage | Symptom | Source |
|---|---|---|
| Start, built-in OpenGL | `Required extension ARB_fragment_shader is not supported`, message box *"ReactOS DirectX Needs at least OpenGL 2.0 or better"*, game message *"Direct3D initialization failed"* (Japanese) | wined3d `adapter_gl.c` |
| Loading, after reinstall or reboot | `IoRaiseInformationalHardError: c0000102, '\MBAACC\0000.p'`, `Assertion failed: ErrorStatus != STATUS_FILE_CORRUPT_ERROR` (KDB break) | fastfat → `ntoskrnl/io/iomgr/error.c` |
| Running with Mesa llvmpipe | 100% CPU, about one frame per 15 s, input appears dead, window "Not Responding" | llvmpipe JIT code |
| Loading, 1 GB VM | `Running low on pages: 0 remaining`, `We are back at the start, abort!` (balancer), system thrashes | `ntoskrnl/mm/balance.c` |

---

## 3. The Direct3D stack in ReactOS

MBAACC imports `d3d9.dll` (`Direct3DCreate9`) and `d3dx9_36.dll` (`D3DXCreateEffect`, textures, fonts). On ReactOS the call chain is:

```
MBAA.exe
  └─ d3d9.dll                (Wine d3d9)
      └─ d3dwine.dll         (Wine wined3d 10.1, OpenGL backend)
          └─ opengl32.dll    (ReactOS)
              ├─ display driver ICD   (only if the display driver provides one, e.g. VirtualBox)
              └─ built-in software implementation (dll/opengl/mesa)   <- VMware/VBE without guest drivers
```

In VMware without guest 3D drivers, the display driver is the generic VBE driver, which offers no OpenGL ICD. Every Direct3D call therefore lands in the built-in software OpenGL.

---

## 4. Why the game did not run: root causes

### 4.1 Direct3D needs GLSL; ReactOS OpenGL has none, with or without PR #6726

**Evidence (serial debug log on the unmodified build):**

```
fixme:(dll/directx/wine/wined3d/adapter_gl.c:2006) No card selector available for card vendor 0000
      (using GL_RENDERER "ReactOS Software Implementation").
err:(dll/directx/wine/wined3d/adapter_gl.c:5171) Required extension ARB_fragment_shader is not supported.
err:(win32ss/user/user32/windows/messagebox.c:1048) MessageBox: L"ReactOS DirectX Needs at least OpenGL 2.0 or better ..."
```

**Why:** wined3d was synced to Wine 10.1 (`media/doc/WINESYNC.txt`). That version removed the ARB-assembly and fixed-function GL backends. `wined3d_adapter_gl_init` hard-requires:

```c
static const struct { enum wined3d_gl_extension extension; const char *string; } required_extensions[] =
{
    {ARB_FRAGMENT_SHADER,      "ARB_fragment_shader"},
    {ARB_SHADING_LANGUAGE_100, "ARB_shading_language_100"},
    {ARB_VERTEX_SHADER,        "ARB_vertex_shader"},
    {EXT_FRAMEBUFFER_OBJECT,   "EXT_framebuffer_object"},
};
/* ... and later: */
if (gl_info->glsl_version < MAKEDWORD_VERSION(1, 20)) { /* fail */ }
```

**Why PR #6726 does not change that:** the PR replaces the Mesa 2.6 based software renderer with a Mesa 8.0.4 snapshot. ReactOS stripped that snapshot down before. It ships only `main/`, `math/`, `swrast/`, `swrast_setup/`, `tnl/`, `vbo/` and `drivers/`, with **no `program/` or `glsl/` directory**. It has no shader compiler, no FBO and no GLSL; its extension list tops out at OpenGL 1.x level. Commit `e531bce` only changes the *reported* version string to 2.0. Advertising 2.0 without the matching entry points makes clients call through NULL pointers, which is the kind of crash the earlier wined3d tweaks guard against.

**Conclusion:** in current ReactOS, no amount of tuning the built-in Mesa makes Direct3D 9 work in a VM without a 3D driver. A GLSL-capable OpenGL implementation is required.

**Fix:** ReactOS's own answer is the RAPPS package *"Mesa3D Graphics Library"* 17.0.1: Gallium plus llvmpipe, providing OpenGL 3.0 with GLSL 1.30, packaged as an OpenGL **ICD** (`mesa32.dll`). The branch makes opengl32 use it automatically as a fallback when the display driver has no ICD (see [5.6](#56-opengl32bootdata-software-fallback-icd)). With it, wined3d initializes:

```
err:(dll/opengl/opengl32/icdload.c) ... Mesa3D
fixme:(.../adapter_gl.c:2006) No card selector ... (using GL_RENDERER "Gallium 0.4 on llvmpipe (LLVM 3.4, 128 bits)").
```

One effect still fails to compile; see [10](#10-known-remaining-issues).

---

### 4.2 FAT32 data loss: truncated cluster chains (Cache Manager)

**Evidence.** After Direct3D worked, the game stopped while loading:

```
(ntoskrnl/io/iomgr/error.c:714) IoRaiseInformationalHardError: c0000102, '\mbaacc\0000.p'
*** Assertion failed: ErrorStatus != STATUS_FILE_CORRUPT_ERROR
***   Source File: /ntoskrnl/io/iomgr/error.c, line 716
```

KDB backtrace:

```
ntoskrnl  IoRaiseInformationalHardError          (io/iomgr/error.c:716)
fastfat   FatPopUpFileCorrupt                    (fatdata.c:1572)
fastfat   FatLookupFileAllocationSize            (allocsup.c:1734)   <- FileSize > AllocationSize
fastfat   FatQueryStandardInfo                   (fileinfo.c:1210)
fastfat   FatCommonQueryInformation / FatFsdQueryInformation
ntoskrnl  NtQueryInformationFile
MBAA.exe
```

**On-disk analysis.** `fatcheck.py` reads the FAT32 volume straight from the VMDK on the host. It showed:

```
first=599268 size=263267378 needs 64275 clusters; chain has 31492, terminator=0xfffffff
runs: 1 [(599268, 31492)]
chain ends early at cluster #31492 (cl 630759), FAT[630759]=0xfffffff, FAT2=0xfffffff
next clusters FAT values: [(630760, '0x0'), (630761, '0x0'), ...]
content match up to 128991232 of 263267378
```

The directory entry has the full 263 MB size. The FAT chain is a single contiguous run that ends after 31,492 of 64,275 clusters, and the following clusters are free. The data that *is* reachable matches the original byte for byte. FAT entries 630759 (end of chain) and 630760 (free) are 4 bytes apart **in the same 4 KB page** of the FAT. So that page was written once, mid-copy, and the later extension of the chain inside the same page was **never written**: not by the lazy writer over several minutes, and not at a clean shutdown. This reproduced 3 times out of 3 (hard power-off, and clean `shutdown -r`).

**Exact reason:**

1. fastfat updates the FAT through the Cache Manager's pin interface. `FatPrepareWriteVolumeFile` pins the FAT range and calls `CcSetDirtyPinnedData` **first**; the caller then writes the new FAT entries into the pinned buffer. fastfat's own comment: *"using prepare write marks the bcb pre-dirty"*.
2. ReactOS's `CcSetDirtyPinnedData` marks the section pages dirty (`MmMakeSegmentDirty`) and the VACB dirty at that moment.
3. ReactOS's Mm tracks dirtiness **only** in the section-segment entries (`IS_DIRTY_SSE`). `MmFlushSegment` / `MmCheckDirtySegment` never harvest the hardware *dirty* bits of the PTEs that map the page.
4. If the lazy writer flushes the range between step 1 and the actual FAT write, it writes the old contents and clears the dirty flag. The new FAT entries written afterwards through the mapping are invisible to Mm, so the page is never written again.

Windows doesn't hit this because its Mm collects PTE dirty bits on flush, and dirty pinned BCBs are written only after they are unpinned.

**Fix** ([5.4](#54-ntoscc-re-dirty-pinned-data-when-the-bcb-is-released)): remember that a BCB was set dirty, and mark its range dirty again when the BCB is unpinned. That way the final contents always reach the disk.

**Verification:** after the fix, copying the file, rebooting cleanly and several *hard* resets left the chain complete:

```
first=524290 size=263267378 needs 64275 clusters; chain has 64275, terminator=0xfffffff
content match up to 263267378 of 263267378
```

A related open ticket is [CORE-17172](https://jira.reactos.org/browse/CORE-17172) (FAT32 filesystem corruption). The debug assertion is the one added for [CORE-17587](https://jira.reactos.org/browse/CORE-17587).

---

### 4.3 JIT code 500x slower: pages become uncached after VirtualProtect (Memory Manager)

**Evidence.** With llvmpipe the game ran at about **0.07 fps** at 100% CPU. A frame contained only a Clear and four `DrawIndexedPrimitiveUP` calls of 4 vertices each, which is trivial work. A step-by-step bisection followed:

1. **Is the game or wined3d the problem?** `gltest.exe`, a bare OpenGL program drawing a 640×480 window, needed **53–57 s for one frame** of ten textured quads, and **~420 ms for one untextured triangle** after shader compilation. So it isn't wined3d.
2. **Is Mesa itself slow?** `icdtest.exe` loads `mesa32.dll` directly as an ICD (`DrvSetPixelFormat`, `DrvCreateContext`, `DrvSetContext`) and times clear + triangle + `glFinish`:

   | Environment | Iteration 0 (compile) | Iterations 1–3 |
   |---|---|---|
   | Windows 11 host | 94 ms | **0 ms** |
   | ReactOS VM, same DLL, same harness | 614 ms | **405–435 ms** |

   Same binary, so the slowdown comes from the environment.
3. **Where is the time spent?** `prof.exe`, a sampling profiler, showed 991 of 994 samples inside one ~2 KB block of **anonymous memory**: an LLVM-generated fragment shader. It had 15 s of user time and ~0 kernel time, so there's no trap storm. The disassembly is ordinary SSE code with a 4-iteration loop, yet it took tens of thousands of cycles per pixel.
4. **Is the CPU slow in the VM?** `cpubench.exe` measured integer, x87, SSE, and SSE run from `PAGE_EXECUTE_READWRITE` memory. All matched the host within 10%.
5. **Page-protection test** (`prot.exe`): the same loop copied into freshly allocated memory, under different protection sequences:

   | Case | Windows host | ReactOS (before) | ReactOS (after fix) |
   |---|---|---|---|
   | code in the EXE image | 47 ms | 75 ms | 75 ms |
   | `VirtualAlloc(PAGE_EXECUTE_READWRITE)` | 63 ms | 75 ms | 60 ms |
   | `VirtualAlloc(RW)` → `VirtualProtect(RX)` | 78 ms | **40 472 ms** | 60 ms |
   | `VirtualAlloc(RW)` → `VirtualProtect(X)` | 62 ms | **41 417 ms** | 59 ms |
   | `VirtualAlloc(RW)` → `VirtualProtect(RWX)` | 63 ms | **41 356 ms** | 60 ms |
   | `VirtualAlloc(RWX)` → `VirtualProtect(RX)` | 62 ms | **40 757 ms** | 75 ms |

   **Any** `VirtualProtect` on committed private pages made code in them run about 540× slower. That matches instruction fetch from uncached memory. LLVM allocates JIT code as RW and then protects it RX, which is exactly the slow path.

**Exact reason:**

- `NtProtectVirtualMemory` → `MiProtectVirtualMemory` → for valid PTEs, `MiFlushTbAndCapture` (`mm/ARM3/section.c`) rebuilds the PTE and decides cacheability from the **PFN's** `CacheAttribute`:

  ```c
  else if (Pfn1->u3.e1.CacheAttribute == MiNonCached)
  {
      if ((ProtectionMask & (MM_NOCACHE | MM_NOACCESS)) != MM_NOCACHE)
      {
          RebuildPte = TRUE;
          ProtectionMask &= ~MM_NOACCESS;
          ProtectionMask |= MM_NOCACHE;      /* -> PTE gets cache-disable bit */
      }
  }
  ```
- At boot, `mm/ARM3/mminit.c` puts free pages on the free list with `CacheAttribute = MiNonCached`. `MiRemoveAnyPage`/`MiRemovePageByColor` preserve that attribute.
- `MiInitializePfn`, `MiInitializePfnForOtherProcess` and `MiInitializePfnAndMakePteValid`, which turn a free page into ordinary in-use memory, **never set `MiCached`**. Windows sets it at that point.
- The PTE created by the page fault is cached regardless of the PFN field, so normal memory is fast **until** someone calls `VirtualProtect` on it. From then on the page is uncached.

The bug hits every program that changes page protection on its own memory: JIT compilers (LLVM/Mesa, .NET, Java, JavaScript engines), self-unpacking executables, and anything that applies protection after writing code.

**Fix** ([5.5](#55-ntosmm-mark-the-pfn-of-regular-memory-as-cached)): set `CacheAttribute = MiCached` when a page is initialized as regular memory, deriving it from the PTE in `MiInitializePfnAndMakePteValid`.

**Result:** llvmpipe matches the host (0 ms per triangle after compilation), and the game runs at 10–30 fps.

---

### 4.4 Out of memory on loading: the 1 GB buffer

**Evidence.** In a 1 GB VM, physical memory ran out seconds after the game's settings dialog was closed:

```
(ntoskrnl/mm/ARM3/pfnlist.c:113) Running low on pages: 0 remaining
(ntoskrnl/mm/balance.c:273) We are back at the start, abort!
```

`mem.exe` walks the game's address space with `VirtualQueryEx` every 2 s:

```
MEM t=40 avail=722708K ...  vm: private=143588K  biggest_private=131076K
MEM t=42 avail=69352K  ...  vm: private=1071612K biggest_private=1048580K   <- 1 GB region committed
MEM t=44 avail=444K    ...
```

The game commits a single **1 GB + 4 KB** private region on start-up. Its main thread then spends its time in a system call that touches the pages: 0 ms user, kernel time only. A `ReadFile` into the buffer probes every page of the requested length, as Windows does (`ProbeForWrite`).

**Why it's fatal on ReactOS:** ARM3 cannot page out private (VAD) memory to the page file. The balancer finds nothing to trim, so a process that touches more memory than the machine has exhausts physical memory, and the whole system stalls.

**Workaround:** give the VM **at least 3 GB of RAM**. A 256 MB or 1 GB VM is not enough for this game. A proper fix means implementing paging of ARM3 private memory, which is out of scope here.

---

## 5. Changes on the `mbaacc-fix` branch

```
aa38355fc3a [OPENGL32][BOOTDATA] Use a software fallback ICD when the display driver has none
c14868e9918 [NTOS:MM] Mark the PFN of regular memory as cached
522c8cfae38 [NTOS:CC] Re-dirty pinned data when the BCB is released
785e99dc961 [WINED3D] Clamp GL version to callable entry points, use CS_OWNDC for the fake window
60c58a775e8 [NETCFGX][FREETYPE] Fix GCC 13 (RosBE) build warnings
28b0c64861d [MESA][OPENGL32] Apply PR #6726 (Upgrade Mesa) on current master
f06eace89e1 (base) [MMC_NEW] Display menu item information in the status bar
```

### 5.1 [MESA][OPENGL32] Apply PR #6726 on current master

- **Files:** `dll/opengl/mesa/**` (~440 files: Mesa 2.6 removed, Mesa 8.0.4 snapshot restored), `dll/opengl/mesa/CMakeLists.txt`, `dll/opengl/opengl32/{CMakeLists.txt,glfuncs.h,swimpl.c}`, `dll/opengl/mesa/main/version.c`.
- The four PR commits were ported onto current master instead of cherry-picked onto the PR's 2024 base. Master's later opengl32 changes are kept (`icdload.c` `OPENGL_GETINFO_DRVNAME`, `wgl.c`, the NT `rtlfuncs.h` list helpers).
- `dll/opengl/mesa/CMakeLists.txt` adds `-Wno-array-parameter` for GCC.
- `version.c` reports **OpenGL 1.1**, not the PR's 2.0. This Mesa build lacks shader, query, buffer-object and FBO code, and the software opengl32 exposes no entry points above 1.1. Reporting 2.0 makes clients call through NULL pointers.
- **Effect on the game:** none. Direct3D needs GLSL, which this Mesa cannot provide ([4.1](#41-direct3d-needs-glsl-reactos-opengl-has-none-with-or-without-pr-6726)). The PR is applied because it was requested.

### 5.2 [NETCFGX][FREETYPE] Fix GCC 13 (RosBE) build warnings

The build uses `-Werror`, so these warnings broke it:

- `dll/win32/netcfgx/tcpipconf_notify.c`: misleading indentation (a tab-indented `TRACE`).
- `sdk/lib/3rdparty/freetype/src/base/ftlcdfil.c`: the `FT_Library_SetLcdGeometry` stub was declared with `FT_Vector sub[3]` but defined with `FT_Vector* sub`.

### 5.3 [WINED3D] Clamp GL version to callable entry points, use CS_OWNDC

Kept from an earlier investigation; harmless with the fixed stack.

- `dll/directx/wine/wined3d/adapter_gl.c` (`#ifdef __REACTOS__`): after `load_gl_funcs`, check that the core entry points of each claimed GL version exist (`glTexImage3D` 1.2, `glActiveTexture` 1.3, `glBlendColor` 1.4, `glGetQueryiv`/`glBindBuffer` 1.5, `glCreateShader` 2.0). If any is missing, lower `gl_version` instead of promoting extensions and calling NULL.
- `dll/directx/wine/wined3d/wined3d_main.c`: the fake window class used for GL capability probing gets `CS_OWNDC`.

### 5.4 [NTOS:CC] Re-dirty pinned data when the BCB is released

- **Files:** `ntoskrnl/cc/pin.c`, `ntoskrnl/include/internal/cc.h`.
- **Root cause:** [4.2](#42-fat32-data-loss-truncated-cluster-chains-cache-manager).

```diff
 typedef struct _INTERNAL_BCB
 {
     ...
     LIST_ENTRY BcbEntry;
+    BOOLEAN Dirty; /* CcSetDirtyPinnedData was called on this BCB */
 } INTERNAL_BCB, *PINTERNAL_BCB;
```

- New `CcpMarkBcbDirty()` holds the code previously inlined in `CcSetDirtyPinnedData` (`MmMakeSegmentDirty` on the BCB range plus `CcRosMarkDirtyVacb`).
- `CcSetDirtyPinnedData` sets `iBcb->Dirty = TRUE`, then calls `CcpMarkBcbDirty`.
- New `CcpRedirtyBcbOnRelease()` calls `CcpMarkBcbDirty` if `Bcb->Dirty`. It's called from:
  - `CcUnpinDataForThread` (and therefore `CcUnpinData`), before the BCB is released;
  - `CcUnpinRepinnedBcb`, **before** the optional write-through `CcFlushCache`, so the write-through writes the final data.
- The new field is appended at the end of `INTERNAL_BCB`, so the existing offsets that kmtests check stay unchanged.

### 5.5 [NTOS:MM] Mark the PFN of regular memory as cached

- **File:** `ntoskrnl/mm/ARM3/pfnlist.c`.
- **Root cause:** [4.3](#43-jit-code-500x-slower-pages-become-uncached-after-virtualprotect-memory-manager).

```diff
@@ MiInitializePfn
     Pfn1->u3.e1.PageLocation = ActiveAndValid;
+    /* This is regular cached memory. Free pages are initialized as non-cached,
+     * which would otherwise make MiFlushTbAndCapture (NtProtectVirtualMemory)
+     * rebuild the PTE as uncached. */
+    Pfn1->u3.e1.CacheAttribute = MiCached;

@@ MiInitializePfnAndMakePteValid
     Pfn1->u3.e1.PageLocation = ActiveAndValid;
+    Pfn1->u3.e1.CacheAttribute = TempPte.u.Hard.CacheDisable ? MiNonCached : MiCached;

@@ MiInitializePfnForOtherProcess
     Pfn1->u3.e1.PageLocation = ActiveAndValid;
+    Pfn1->u3.e1.CacheAttribute = MiCached;
```

I audited all callers: page faults, process and page-table creation, pools, sections, session space, special pool, and the system loader. All of them map ordinary cached memory. Non-cached and write-combined allocations (`MmAllocateNonCachedMemory`, `MmAllocateContiguousMemorySpecifyCache`, `MmAllocatePagesForMdl`) set the attribute themselves and don't go through these functions.

### 5.6 [OPENGL32][BOOTDATA] Software fallback ICD

- **Files:** `dll/opengl/opengl32/icdload.c`, `boot/bootdata/hivesft.inf`, `boot/bootdata/packages/reactos.dff.in`.
- **Root cause:** [4.1](#41-direct3d-needs-glsl-reactos-opengl-has-none-with-or-without-pr-6726).

**opengl32 (`icdload.c`):**

- New `IntQueryRegisteredIcd()` reads `Version`/`DriverVersion` of an ICD registered under `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\OpenGLDrivers\<name>`.
- New `IntGetFallbackIcdInfo()` reads the name from `HKLM\SOFTWARE\ReactOS\OpenGL`, value **`SoftwareFallbackICD`**. It's queried once per process.
- In `IntGetIcdData()`, when the display driver does **not** support the `OPENGL_GETINFO` escape (no hardware ICD), the fallback ICD is used instead of returning `NULL`:

```c
if(ret <= 0)
{
    /* Driver doesn't support opengl, use the software fallback ICD if there is one */
    pDrvInfo = IntGetFallbackIcdInfo();
    if (!pDrvInfo)
        return NULL;
}
else
{
    /* Query for the ICD DLL name and version (unchanged) */
}
```

Precedence is unchanged otherwise:

1. A per-user override (`HKCU\Software\ReactOS\OpenGL`, default value: an ICD name, or `"ReactOS Software Implementation"`) still wins.
2. A display driver ICD (VirtualBox, VMware SVGA, real GPUs) is still used when present.
3. If the fallback DLL is missing, `LoadLibraryW` fails, `IntGetIcdData` returns `NULL`, and the built-in software implementation is used as before.

**Registry defaults (`hivesft.inf`):**

```ini
HKLM,"SOFTWARE\Microsoft\Windows NT\CurrentVersion\OpenGLDrivers\Mesa3D","Dll",0x00000000,"mesa32"
HKLM,"SOFTWARE\Microsoft\Windows NT\CurrentVersion\OpenGLDrivers\Mesa3D","Version",0x00010001,0x00000002
HKLM,"SOFTWARE\Microsoft\Windows NT\CurrentVersion\OpenGLDrivers\Mesa3D","DriverVersion",0x00010001,0x00000001
HKLM,"SOFTWARE\Microsoft\Windows NT\CurrentVersion\OpenGLDrivers\Mesa3D","Flags",0x00010001,0x00000001
HKLM,"SOFTWARE\ReactOS\OpenGL","SoftwareFallbackICD",0x00000000,"Mesa3D"
```

**Packaging (`reactos.dff.in`):**

```
"modules/optional/mesa32.dll"                         2  optional
```

The `2` destination means `system32`. Optional files are silently skipped when absent.

---

## 6. Workarounds and required configuration

### 6.1 The Mesa ICD binary (not in git)

`modules/optional/` is git-ignored, so `mesa32.dll` is **not** in the repository. Before building, place it there:

1. Download the official RAPPS package: `https://svn.reactos.org/packages/mesa3d_setup.exe` (the "Mesa3D Graphics Library" 17.0.1 entry in [rapps-db `mesagallium.txt`](https://github.com/reactos/rapps-db/blob/master/mesagallium.txt)). Expected SHA-1: `4c0d42844ff3693612edfdac51799fd7c63dcafd`.
2. It's an NSIS installer. Extract `$SYSDIR/mesa32.dll` with 7-Zip:
   ```
   7z x mesa3d_setup.exe -oextracted
   copy "extracted\$SYSDIR\mesa32.dll" <source>\modules\optional\mesa32.dll
   ```
   SHA-1 of the extracted `mesa32.dll`: `3bb7e66ad3762cd6aee62433c38be5ed9d7f09ea`.
3. Rebuild `bootcd`.

**Alternative on an existing installation:** install "Mesa3D Graphics Library" from the Applications Manager (RAPPS) and select it as the OpenGL driver. That's equivalent, but needs network access and per-user setup.

### 6.2 VMware virtual machine settings

| Setting | Value | Why |
|---|---|---|
| Memory | **≥ 3 GB** (`memsize = "3072"`) | The game commits and touches 1 GB; ReactOS can't page that out ([4.4](#44-out-of-memory-on-loading-the-1-gb-buffer)) |
| Processors | 1 | The ReactOS SMP kernel (`ntkrnlmp.exe` + `halmacpi.dll`) hangs during boot on this revision |
| Guest OS type | Windows XP Professional (`winxppro`) | Gives XP-compatible default devices |
| Display | default (VBE) | No guest 3D driver needed; Direct3D runs on llvmpipe |
| Disk | IDE, ≥ 8 GB, FAT32 (installer default) | |

### 6.3 Game-side notes

- **Keys:** `C` confirms (Start/A on the default keyboard layout); arrow keys move.
- The launcher dialog and in-game Japanese text show as `???` or mojibake unless the system locale is Japanese. The same happens on non-Japanese Windows. See [10](#10-known-remaining-issues).

---

## 7. Building the ISO

These steps were tested with RosBE (MinGW/GCC 13, **Debug**). Visual Studio 2019 was not available on the build machine; `configure` + `ninja bootcd` from the VS2019 x86 Developer Command Prompt works the same way and uses `output-vs-i386`.

```bat
git clone https://github.com/<you>/reactos.git source
cd source
git switch mbaacc-fix
:: place modules\optional\mesa32.dll (section 6.1)

:: RosBE command prompt (or set PATH=C:\RosBE\bin;C:\RosBE\i386\bin;%PATH%)
configure
cd output-MinGW-i386
ninja bootcd
:: -> output-MinGW-i386\bootcd.iso
```

Install it in a VM configured as in [6.2](#62-vmware-virtual-machine-settings), copy the game folder to the disk (for example to `C:\MBAACC`), and start `MBAA.exe`.

---

## 8. Test environment and scripts

All verification was automated against a separate VMware Workstation 17 VM, `ReactOS-MBAACC-Test`. The scripts live in `E:\ReactOS\testvm` on the build machine and are not part of the ReactOS tree.

### 8.1 Test VM and unattended installation

| File | Purpose |
|---|---|
| `mbtest.vmx` | VM definition: 1 vCPU, 1 GB → 3 GB RAM, IDE disk, two CD drives (test ISO + "payload" ISO), COM1 → named pipe `\\.\pipe\mbdbg`, built-in VNC server on port 5911 (`RemoteDisplay.vnc.enabled`) |
| `unattend.inf` | Copy of `boot/bootdata/bootcdregtest/unattend.inf`: fully unattended install, 1024×768×32, and `[GuiRunOnce]` copies the game from the CD to `C:\MBAACC` on first logon |
| `freeldr.ini` | Copy of `boot/bootdata/bootcd.ini` with `DefaultOS=Setup_Debug` and `TimeOut=1`, so the CD goes straight into setup with COM1 debug output |
| `make_test_iso.py` | Reads the build's `boot/bootcd.Debug.lst`, swaps in the two files above, adds the game folder as `MBAACC/` plus a `g.cmd` launcher, and runs the build's own `mkisofs` with the same El Torito options as `ninja bootcd` → `test.iso` |
| `payload/` → `payload.iso` | Second CD with test binaries and batch files. Hot-swapped while the VM runs (`vmrun disconnectNamedDevice ide1:1`, rebuild the ISO, `connectNamedDevice`) |

### 8.2 Remote control and debugging

| File | Purpose |
|---|---|
| `vnc.py` | Drives the guest through VMware's VNC server (vncdotool): `shot` (screenshot), `type` (reliable typing with explicit Shift handling and pacing to avoid auto-repeat), `keys`, `hold <s> <key>` (held keys for DirectInput polling), `click`, `run "<cmd>"` (Win+R → `cmd /k …`) |
| `serbridge.py` | Single-threaded bridge for the COM1 named pipe (`PeekNamedPipe` polling, because synchronous pipe handles serialize reads and writes). Appends all guest debug output to `serial.log`, and sends any text appended to `kdbcmd.txt` to KDB (for example `bt`, `cont`, `i`) |
| `sample.py` | "Poor man's profiler": sends Tab+K over VNC (the i8042prt KDB hotkey), runs `bt`, then `cont` |

### 8.3 Analysis tools (`prof/`, built with RosBE GCC)

| Tool | What it does | Used for |
|---|---|---|
| `fatcheck.py` | Reads a monolithicSparse VMDK (grain directory/tables), the MBR and the FAT32 boot sector, walks a file's cluster chain, prints runs and the end-of-chain value, and compares the content with a reference file | [4.2](#42-fat32-data-loss-truncated-cluster-chains-cache-manager) root cause and fix verification |
| `prof.exe <exe> <s>` | Sampling profiler: suspends each thread of the target every ~5 ms, records EIP (plus an EBP-chain stack), prints per-thread user/kernel time, per-module histogram and top addresses, and hex-dumps the hottest anonymous (JIT) code page through `OutputDebugString` (to the serial log) | Locating the JIT hot loop |
| `mem.exe <exe> <s>` | Every 2 s: system performance information (available pages, pools, cache) plus the target's working set and a `VirtualQueryEx` walk (committed private, mapped and image memory, largest private region) | [4.4](#44-out-of-memory-on-loading-the-1-gb-buffer) |
| `gltest.exe` | Minimal OpenGL window: initial viewport and timings of clear, triangle, swap; fps over N quads | Separating Mesa from wined3d |
| `icdtest.exe <icd>` | Drives an ICD directly through `DrvDescribePixelFormat`/`DrvSetPixelFormat`/`DrvCreateContext`/`DrvSetContext` and the returned dispatch table, so the same test runs on Windows and ReactOS | Showing it's an environment problem |
| `cpubench.exe` | Integer, x87 and SSE loops, and SSE executed from RWX memory | Ruling out general CPU or VM slowness |
| `prot.exe` | Same loop executed after the different `VirtualAlloc`/`VirtualProtect` sequences | [4.3](#43-jit-code-500x-slower-pages-become-uncached-after-virtualprotect-memory-manager) root cause and fix verification |
| `fpstate.exe`, `daz.exe` | MXCSR/x87 control word persistence across context switches, and denormal cost | Found the DAZ loss ([10](#10-known-remaining-issues)); ruled it out as the slowdown |

### 8.4 Game test scripts (on the payload CD)

| Script | Content |
|---|---|
| `mesa.cmd` + `mesa.reg` | Manually install `mesa32.dll` and register it (used before the fallback ICD existed) |
| `t0.cmd` … `t7.cmd` | Start the game with `GALLIUM_HUD=fps` plus one experiment each: `LP_NUM_THREADS=0`, `LP_PERF=no_tex,no_blend,no_depth,no_alphatest`, `WINE_D3D_CONFIG=csmt=0`, `DEBUGCHANNEL=trace+d3d9`, `WGL_SWAP_INTERVAL=0` |
| `ab_orig.cmd`, `ab_fix.cmd`, `ab_mp.cmd` + `fl_*.ini` | A/B kernel testing: copy alternative kernels (`ntkorig.exe`, `ntkfix.exe`, `ntkmp.exe` + `halmacpi.dll`) to `system32` and boot them with FreeLoader's `/KERNEL=` and `/HAL=` options |

### 8.5 Temporary instrumentation (not committed)

`dll/directx/wine/d3dcompiler_43/compiler.c` temporarily logged every compile request and dumped the failing HLSL source line by line. That's how the game's bloom effect and its `texture = <targetTex0>;` construct were found. It was removed before the final build.

---

## 9. Measurements

All figures are from the VMware test VM: 1 vCPU (i7-7500U host), 3 GB RAM, Debug build.

| Scenario | Before | After |
|---|---|---|
| `icdtest` clear + triangle (after compile) | 405–435 ms | 0 ms |
| `prot` RW→RX code, 50 M iterations | 40 472 ms | 60 ms |
| MBAACC caution screen | ~0.07 fps | 20–28 fps |
| MBAACC main menu / character select | n/a | 8–20 fps |
| MBAACC battle | n/a | 9–13 fps |
| `0000.p` FAT chain after reboot | 31 492 / 64 275 clusters | 64 275 / 64 275 |

Clean-install check of the final ISO: unattended install → first logon (the game is copied by RunOnce) → `MBAA.exe` → caution screen → logos → title → main menu → arcade → character select → VS screen → *"Round 1 — Standby OK?"*. No manual configuration; wined3d picks up `Gallium 0.4 on llvmpipe` automatically.

---

## 10. Known remaining issues

| Issue | Cause | Possible fix |
|---|---|---|
| Low frame rate (10–30 fps, so the fixed-60 Hz game runs in slow motion) | Software rendering on a single core, Debug build; the profile shows the game thread busy only about 60% of the time, so some waiting remains | Release build; get the SMP kernel booting so llvmpipe can use several rasterizer threads; investigate the remaining waits; a VMware SVGA 3D ICD |
| SMP kernel hangs at boot | `ntkrnlmp.exe` + `halmacpi.dll` stop right after the ARC paths are printed (1, 2 and 4 vCPUs) | Separate investigation |
| Missing bloom/glow effect (`TecSakuraBloom`) | `D3DXCreateEffect` → vkd3d-shader 1.14 rejects the legacy FX syntax `texture = <targetTex0>;` inside `sampler_state` (`E5000: syntax error, unexpected '<'`). Even when parsed, vkd3d's fx_2 writer reports *"Writing fx_2_0 sampler objects initializers is not implemented"*. Upstream vkd3d has the same gap | Implement the angle-bracket state value in `hlsl.y` and fx_2 sampler-state output in `fx.c` |
| Opening movie not shown, black title background | quartz: *"Failed to create filter for MPEG-I Stream Splitter / AVI Splitter / Wave Parser"* | An MPEG-1 splitter and decoder for ReactOS DirectShow |
| Japanese text as `???` or mojibake (launcher, "Information" box) | Shift-JIS strings rendered with a Western ANSI code page | Japanese system locale (code page 932) and a CJK font, as on Windows |
| No sound | No ReactOS driver for VMware's default Ensoniq ES1371 | Another virtual sound device, or a driver |
| MXCSR DAZ bit lost across context switches (`0x9fc0` → `0x9fb2`) | Kernel FPU state save/restore path | Separate investigation; measured not to be the cause of the slowdown |
| Large allocations exhaust RAM | ARM3 cannot page out private memory | Implement it; meanwhile use ≥ 3 GB RAM |

---

## 11. References

- PR #6726 "[MESA] Upgrade MESA again": <https://github.com/reactos/reactos/pull/6726>
- CORE-15408 "Regression: VBox WineD3D fake window: Application Error in Games": <https://jira.reactos.org/browse/CORE-15408>
- CORE-17587 "FileSystem corruption on FAT32 right after 3rd stage bootup": <https://jira.reactos.org/browse/CORE-17587>
- CORE-17172 "FAT32 filesystem corruption in 3rd stage": <https://jira.reactos.org/browse/CORE-17172>
- RAPPS "Mesa3D Graphics Library" entry: <https://github.com/reactos/rapps-db/blob/master/mesagallium.txt>
- ReactOS wiki, OpenGL: <https://reactos.org/wiki/OpenGL.dll>
- Building ReactOS: <https://reactos.org/wiki/Building_ReactOS>
- MBAACC Trial Rev.10 (archived): <https://web.archive.org/web/20160624031207/http://meltyblood.info/uploadtrial/MBAACC107TrialRev10.zip>
