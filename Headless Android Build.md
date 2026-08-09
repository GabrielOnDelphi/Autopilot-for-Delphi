# Headless Android Build

**What this is:** instructions for a future-Claude session to build, package, install, and launch the Autopilot FMX demo APK on an Android device from the command line — no human, no IDE. Generic toolchain: see the master doc.

Goal: let the AI compile, package, install, and launch the Autopilot FMX demo on a connected Android device with **zero IDE interaction** — no F9, no button presses. The Windows side already runs headless through the `light-compiler` agent; this file is the Android counterpart.

Status (2026-06-16): **device-verified.** The headless loop below ran end-to-end on the OnePlus Nord (Android bring-up complete 2026-06-12; `DemoFmx\DeployAndroid.cmd` is the committed entry point). The generic toolchain mechanism — the `.deployproj` import chain, the per-stage map, signing — now lives in the master doc (`c:\Projects\FMX\Compiling FMX projects for cross-platform targets\` → Stage 3); this file keeps only the Autopilot-specific bits.

## The whole loop in one place

```bat
:: Package step — the single blessed MSBuild entry point (prints the .apk path on success):
cmd /c "DemoFmx\DeployAndroid.cmd"
:: DeployAndroid.cmd prints the produced .apk path; else glob DemoFmx\Autopilot.DemoFmx\bin\*.apk
adb install -r "DemoFmx\Autopilot.DemoFmx\bin\Autopilot.DemoFmx.apk"
adb -d shell am start -a android.intent.action.MAIN -n com.embarcadero.Autopilot.DemoFmx/com.embarcadero.firemonkey.FMXNativeActivity
```

Then the bridge bring-up, which is already AI-ownable today (adb only, no MSBuild): `adb shell pidof` → `adb forward tcp:<port> localabstract:Autopilot.<pid>` → MCP server `--target adb:<port>`. The Plan 05 checklist owns that tail.

## What each stage does

The generic six-stage toolchain (rsvars → dccaarm64/ld.lld → `/t:Deploy` packaging → adb install → am start) is mapped in the master — `Compiling FMX projects for cross-platform targets\` → Stage 3 + Stage 4. Autopilot-specific specifics:

- **Compile** produces `libAutopilot.DemoFmx.so`. This is exactly what the `light-compiler` agent already does for Android64 — for compile-only checks, no new tooling is needed.
- **Package** (`/t:Deploy`) is the stage `delphi-compiler.exe` does NOT do (see "Project-rules reconciliation").
- **Locate the APK:** `DemoFmx\Autopilot.DemoFmx\bin\Autopilot.DemoFmx.apk` — the deploy-staging folder, NOT `Android64_Debug` (that holds only `.dcu`/`.o`). The APK folder, filename, and `com.embarcadero.Autopilot.DemoFmx` package id all use the dotted project name; only the bundled native library is underscore-sanitized (`libAutopilot_DemoFmx.so`). `DeployAndroid.cmd` prints the path on success; else glob `DemoFmx\Autopilot.DemoFmx\bin\*.apk`.
- **Launch:** the package is `com.embarcadero.Autopilot.DemoFmx` (from the dproj `package=` key) — confirm after install with `adb shell pm list packages | findstr embarcadero`.

## The one IDE dependency: `.deployproj`

The mechanism (why CLI deploy needs a `<ProjectName>.deployproj`, the dproj→deployproj→`CodeGear.Deployment.targets` import chain, GenDeployProj) is in the master — `Compiling FMX projects for cross-platform targets\` → Stage 3 "Getting the first `.deployproj`".

**Status for this project:** `Autopilot.DemoFmx.deployproj` now EXISTS beside the dproj (generated once from the IDE per the decision below), so `/t:Make;Deploy` runs headless. **Decided (2026-06-12): generate the `.deployproj` once from the IDE (Android64 + Debug, Project ▸ Deploy), then reuse it.** GenDeployProj not pursued. Re-open the IDE only when the deployment set itself changes (a new bundled resource or library).

## Signing

Debug builds self-sign with the SDK debug key (the dproj already pins `BT_BuildType=Debug` for Android64), so the `.apk` installs over adb as-is. Release-keystore details: `Compiling FMX projects for cross-platform targets\` → Stage 3 "Signing".

## Project-rules reconciliation (read before you automate this)

The global and project CLAUDE.md say: **never hand-invoke MSBuild or dcc32; compile only through the `light-compiler` agent**, whose wrapper `delphi-compiler.exe` does not support Android64. That rule and this pipeline collide at exactly one stage, `/t:Deploy`.

**Decided (2026-06-12): a committed `DemoFmx\DeployAndroid.cmd`** is the single blessed entry point for that one MSBuild step (`rsvars` + `msbuild /t:Make;Deploy /p:Platform=Android64`); it prints the produced `.apk` path on success. This is the same raw-MSBuild path the Android *compile* already takes through the agent, so it adds no new rule exception — it version-controls the one that already existed.

Extending `delphi-compiler.exe` was considered and **rejected**: it is JavierusTk's MIT-with-Commons-Clause tool, tracked for monthly upstream updates (`check-upstream-update.cmd`). An Android-Deploy branch would become a local fork patch to re-apply on every update — a cost the wrapper's compile-only, structured-JSON purpose does not justify (Deploy emits no compiler diagnostics to parse).

The **adb half** (install, launch, forward) is not MSBuild. The AI runs adb directly — the byte-exact push round-trip on 2026-06-11 proved the link — so no wrapper is needed there.

## Verified vs not

- **Verified (device, 2026-06-12):** the full headless loop on the OnePlus Nord — `DemoFmx\DeployAndroid.cmd` (`/t:Make;Deploy`) → `adb install -r` → `am start`, then the bridge bring-up and a full tool drive. The `.deployproj` was generated once from the IDE (F9). Target/parameter syntax cross-checked against DocWiki, Brian Long, and the Embarcadero blog.
- **Not pursued:** GenDeployProj (zero-IDE `.deployproj` generation) — the IDE-once path made it unnecessary.

## Sources

- Embarcadero DocWiki — Building a Project Using an MSBuild Command: https://docwiki.embarcadero.com/RADStudio/Alexandria/en/Building_a_Project_Using_an_MSBuild_Command
- Brian Long — Delphi build/install/launch Android from the command-line (2017): http://blog.blong.com/2017/10/delphi-buildinstall-to-android-from.html
- DelphiWorlds — GenDeployProj: https://github.com/DelphiWorlds/GenDeployProj
- Embarcadero blog — Command-line Compilation of Delphi Projects: https://blogs.embarcadero.com/command-line-compilation-of-delphi-projects-real-life-examples/
- Android Developers — adb (install / am start): https://developer.android.com/tools/adb
