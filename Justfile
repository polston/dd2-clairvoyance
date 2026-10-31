set shell := ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]

default:
    @just --list

# Verify the local toolchain and game paths.
doctor:
    & './scripts/dev.ps1' doctor

# Run the complete repository gate with isolated Windows temp files.
check:
    & './scripts/dev.ps1' check

# Run the complete gate, then install the mod into the game.
deploy:
    & './scripts/dev.ps1' deploy

# Reload REFramework scripts without moving the physical mouse.
reset-scripts:
    & './scripts/dev.ps1' reset-scripts

# Run one guarded live probe. Example: just probe tools/probe/objective_phase0.lua 30
probe chunk timeout="12":
    & './scripts/dev.ps1' probe -Chunk {{ quote(chunk) }} -Timeout {{ timeout }}

# Fail unless the live focused-objective projection has converged to targets and routes.
accept-routes:
    & './scripts/dev.ps1' probe -Chunk 'tools/probe/objective_acceptance.lua' -Timeout 30

# Capture the game window into a local scratch image.
shot output=".tmp-tests/shot.png":
    & './scripts/dev.ps1' shot -Output {{ quote(output) }}

# Compare every deployed source file with the current checkout.
verify-install:
    & './scripts/dev.ps1' verify-install
