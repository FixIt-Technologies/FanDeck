#!/usr/bin/env bun
//
// dev.ts — watch mode. Equivalent to `vite dev` for this Swift package.
//
// Watches Sources/ for *.swift changes via Bun's built-in fs.watch
// (which uses FSEvents on macOS — same primitive watchexec uses), then
// on each change runs `bun run start` which does:
//   swift build (debug) → refresh /Applications/GenesisFanControl.app
//   symlinks → kill old instance → relaunch
//
// First save after a long pause does a clean swift-build (~2 s);
// subsequent ones are incremental (~200 ms).
//

import { $ } from "bun"
import { watch } from "node:fs"
import { resolve } from "node:path"

const repoRoot = resolve(import.meta.dir, "..")
const watchDirs = ["Sources", "Package.swift"]

let busy = false
let pending = false
let lastTrigger = 0
const DEBOUNCE_MS = 200

async function rebuild(reason: string) {
    if (busy) { pending = true; return }
    busy = true
    console.log(`\n▸ change detected: ${reason}`)
    try {
        // Always use debug for dev — much faster compile.
        await $`bun run scripts/install.ts -- --debug`.cwd(repoRoot)
    } catch (e) {
        console.error(`× build failed:`, e)
    } finally {
        busy = false
        if (pending) {
            pending = false
            void rebuild("queued change while building")
        }
    }
}

console.log(`▸ watching ${watchDirs.join(", ")} for *.swift changes`)
console.log(`▸ Ctrl-C to stop`)

// Initial build so the app is in /Applications before we start watching.
await rebuild("initial")

for (const dir of watchDirs) {
    const fullPath = resolve(repoRoot, dir)
    watch(fullPath, { recursive: true }, (event, filename) => {
        if (!filename) return
        if (!filename.endsWith(".swift") && filename !== "Package.swift") return
        const now = Date.now()
        if (now - lastTrigger < DEBOUNCE_MS) return
        lastTrigger = now
        void rebuild(filename)
    })
}

// Keep alive
await new Promise(() => {})
