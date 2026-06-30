#!/usr/bin/env bun
//
// install.ts — build + install GenesisFanControl into the user's machine
//
// Idempotent. First run prompts once for the admin password (to drop a
// symlink for the `fans` CLI into /usr/local/bin). Every subsequent run
// is build + kill + relaunch; no password.
//
// Layout produced:
//   /Applications/GenesisFanControl.app/Contents/
//     Info.plist
//     MacOS/
//       GenesisFanControl  → symlink → <repo>/.build/release/GenesisFanControl
//       genesis-fan-control-helper → symlink → .build/release/genesis-fan-control-helper
//   /usr/local/bin/fans     → symlink → <repo>/.build/release/fans
//
// The helper daemon itself is still installed separately via the GUI's
// "Install Helper" button (that's the one that actually needs root).
//

import { $ } from "bun"
import {
    mkdirSync,
    writeFileSync,
    existsSync,
    rmSync,
    symlinkSync,
    readlinkSync,
    chmodSync,
    copyFileSync,
} from "node:fs"
import { resolve } from "node:path"

const APP_NAME = "GenesisFanControl"
const APP_BUNDLE_ID = "dev.foltyn.genesis-fan-control"
const APP_PATH = `/Applications/${APP_NAME}.app`
const MACOS_DIR = `${APP_PATH}/Contents/MacOS`
const RESOURCES_DIR = `${APP_PATH}/Contents/Resources`
const CLI_LINK = "/usr/local/bin/fans"

const debug = process.argv.includes("--debug")
const config = debug ? "debug" : "release"
const repoRoot = resolve(import.meta.dir, "..")
const buildDir = resolve(repoRoot, ".build", config)

const guiBinary  = `${buildDir}/${APP_NAME}`
const helperBin  = `${buildDir}/genesis-fan-control-helper`
const fansBinary = `${buildDir}/fans`

// ─── 1) build ──────────────────────────────────────────────────────────

console.log(`▸ swift build (${config})`)
await $`swift build -c ${config}`.cwd(repoRoot)

for (const bin of [guiBinary, helperBin, fansBinary]) {
    if (!existsSync(bin)) {
        console.error(`× build artifact missing: ${bin}`)
        process.exit(1)
    }
}

// ─── 2) .app bundle ────────────────────────────────────────────────────

console.log(`▸ ${APP_PATH}`)
mkdirSync(MACOS_DIR, { recursive: true })
mkdirSync(RESOURCES_DIR, { recursive: true })

// Icon — re-render if missing, then drop into the bundle's Resources.
const icnsSrc = resolve(import.meta.dir, "AppIcon.icns")
if (!existsSync(icnsSrc)) {
    console.log(`▸ rendering AppIcon.icns from fanblades.fill`)
    await $`swift scripts/build-icon.swift`.cwd(repoRoot)
}
copyFileSync(icnsSrc, `${RESOURCES_DIR}/AppIcon.icns`)

const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>${APP_BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>Genesis Fan Control</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
`
writeFileSync(`${APP_PATH}/Contents/Info.plist`, plist)

function relink(dest: string, target: string) {
    if (existsSync(dest)) {
        try {
            const cur = readlinkSync(dest)
            if (cur === target) return // already correct
        } catch {} // existed but not a symlink
        rmSync(dest, { force: true })
    }
    symlinkSync(target, dest)
}

relink(`${MACOS_DIR}/${APP_NAME}`, guiBinary)
relink(`${MACOS_DIR}/genesis-fan-control-helper`, helperBin)

// ─── 3) /usr/local/bin/fans ───────────────────────────────────────────

const needsCLIInstall = (() => {
    if (!existsSync(CLI_LINK)) return true
    try {
        return readlinkSync(CLI_LINK) !== fansBinary
    } catch {
        return true
    }
})()

if (needsCLIInstall) {
    console.log(`▸ /usr/local/bin/fans → symlink (one-time sudo prompt)`)
    const script = [
        `mkdir -p /usr/local/bin`,
        `ln -sf '${fansBinary}' '${CLI_LINK}'`,
    ].join(" && ")
    await $`osascript -e ${`do shell script "${script}" with administrator privileges`}`
} else {
    console.log(`▸ /usr/local/bin/fans (already linked)`)
}

// ─── 4) kill + relaunch ───────────────────────────────────────────────
//
// CRITICAL: `pkill -x GenesisFanControl` does NOT work — Darwin truncates
// the process `comm` name to 16 chars (MAXCOMLEN), and "GenesisFanControl"
// is 17, so the exact-match never fires and the old instance survives.
// Worse, `open` on an already-running .app just ACTIVATES the stale
// instance instead of restarting it — so a rebuild's new binary never
// actually runs (the in-memory process keeps executing old code). This
// silently defeated dozens of rebuild-test cycles. Match on the full
// executable path instead (pkill -f), which is reliable and won't hit
// the lowercase `genesis-fan-control-helper` daemon.
console.log(`▸ killing existing instance (if any)`)
// Match `release/GenesisFanControl` — appears in BOTH the symlinked
// `.build/release/...` path and the resolved `.build/arm64-apple-macosx/
// release/...` path the process actually runs from. CamelCase so it can't
// match the lowercase `genesis-fan-control-helper` daemon.
const killPattern = `release/${APP_NAME}`
await $`pkill -f ${killPattern}`.quiet().nothrow()
// Wait for the process to actually exit before reopening, else `open`
// re-activates the dying instance.
for (let i = 0; i < 25; i++) {
    const still = await $`pgrep -f ${killPattern}`.quiet().nothrow()
    if (still.exitCode !== 0) break // no match => gone
    await Bun.sleep(100)
}

console.log(`▸ open ${APP_PATH} (fresh launch)`)
// -n forces a NEW instance even if LaunchServices thinks one exists.
await $`open -n ${APP_PATH}`

console.log(``)
console.log(`✓ ${APP_NAME} launched from ${APP_PATH}`)
console.log(`✓ \`fans\` CLI available at ${CLI_LINK}`)
console.log(``)
console.log(`Every \`bun run start\` rebuilds and restarts; symlinks pick up`)
console.log(`the new binaries automatically — no further sudo prompts.`)
