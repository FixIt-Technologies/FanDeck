#!/usr/bin/env bun
//
// uninstall.ts — remove the .app, the CLI symlink, and (if installed) the
// privileged helper daemon. One sudo prompt for everything.
//

import { $ } from "bun"
import { existsSync, rmSync } from "node:fs"

const APP_PATH = "/Applications/GenesisFanControl.app"
const CLI_LINK = "/usr/local/bin/fans"

console.log(`▸ removing ${APP_PATH}`)
if (existsSync(APP_PATH)) rmSync(APP_PATH, { recursive: true, force: true })

// /usr/local/bin/fans + helper daemon both need root. One prompt.
const script = [
    `rm -f '${CLI_LINK}'`,
    `launchctl bootout system /Library/LaunchDaemons/dev.foltyn.genesis-fan-control.helper.plist 2>/dev/null || true`,
    `rm -f /Library/LaunchDaemons/dev.foltyn.genesis-fan-control.helper.plist`,
    `rm -f /usr/local/sbin/genesis-fan-control-helper`,
    `rm -f /var/run/genesis-fan-control.sock`,
    `launchctl bootout system /Library/LaunchDaemons/dev.foltyn.macsfancontrol.helper.plist 2>/dev/null || true`,
    `rm -f /Library/LaunchDaemons/dev.foltyn.macsfancontrol.helper.plist`,
    `rm -f /usr/local/sbin/macsfancontrol-helper`,
    `rm -f /var/run/macsfancontrol.sock`,
].join(" && ")

console.log(`▸ sudo: remove CLI symlink, helper daemon, legacy daemon`)
await $`osascript -e ${`do shell script "${script}" with administrator privileges`}`

console.log(`✓ uninstalled`)
