# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Menu-bar app for macOS 14+ that shows Claude (and Grok) usage: live sessions, cost, account quota and history. It is a plain SwiftPM executable (swift-tools 6.0, no Xcode project, no dependencies) living in `macos/`. UI strings are in Brazilian Portuguese; keep new user-facing text in pt-BR.

## Commands

All from `macos/`:

- Build: `swift build`
- Run app: `swift run ClaudeStatusBar`
- All tests: `swift test` (Swift Testing framework, `@Test` / `#expect`, not XCTest)
- Single test: `swift test --filter ClaudeStatusBarTests/<testName>` (e.g. `--filter limitsSupersedeFixedOpusAndSonnet`)
- Headless check: `swift run ClaudeStatusBar --dump` prints sessions, totals, history and live quota to stdout and exits. Use it to verify data-layer changes against real local data and the live API without opening the UI.
- Debug trace: the running app writes `/tmp/claude-status-bar.log` (`Trace` in `ClaudeStatusBarApp.swift`), reset on each launch.

From the repo root: `make app` builds `macos/build/ClaudeStatusBar.app` (`macos/scripts/build-app.sh`: release build, `Resources/Info.plist`, icon drawn by `scripts/make-icon.swift`, signed with the first "Apple Development" identity or ad-hoc). `make install` replaces `/Applications/ClaudeStatusBar.app` and relaunches it. A stable signature matters: the Keychain "Always Allow" for `Claude Code-credentials` is tied to it, so ad-hoc rebuilds re-prompt.

There is no linter configured.

## Architecture

Entry point `Bootstrap` (`ClaudeStatusBarApp.swift`) has no SwiftUI `App` scene, on purpose (a `Settings` scene opened a stray window). It sets `.accessory` activation policy and hands off to `StatusBarController`, an `NSApplicationDelegate` that owns:
- an `NSStatusItem` whose button hosts the SwiftUI `MenuBarLabel` (not `MenuBarExtra`, which flattens the label to a template image and loses the Liquid Glass look);
- a borderless floating `NSPanel` hosting `PopoverView`, positioned manually under the status item and closed by a global outside-click monitor;
- right-click opens a temporary Quit menu (attached only for the popup so it doesn't swallow left-click).

`AppModel` (`@MainActor @Observable`) is the single state object. It runs two loops:
- sessions loop every 10s: off-main `Task.detached` gathers local data;
- usage loop every 5/15/30 min (`pollingMinutes`, persisted in `UserDefaults`): hits the quota API.

Data sources (all local except the quota):
- `ProcessProbe`/`Shell`: `ps` snapshot to detect running Claude/Xcode/Grok processes (output goes through a temp file, not a pipe, to avoid a deadlock on huge command lines).
- `~/.claude/metrics/costs.jsonl` (`CostLog`, `SessionLogic`): written by the ECC cost-tracker Stop hook. **Each row is the session's running total**, never a delta: take the latest row for a session's cost, subtract the previous row for per-period numbers (`HistoryLog.claudeEvents`, `CostLog.spentUSD`).
- `~/.claude/stats-cache.json` (`StatsCache`): the file Claude Code's `/stats` reads, internal format, parsed defensively. It covers days up to `lastComputedDate`; everything after comes from the transcripts. This is what makes the history match `/stats`.
- `~/.claude/projects/**/*.jsonl` (`TranscriptScan`/`TranscriptState`): incremental, offset-based parse of transcripts touched since the stats cutoff plus open sessions' files. Usage is deduped by `message.id` (streamed lines repeat it). Gives today's history and, per live session, context % (last turn's input + cache, window 200k or 1M if bigger), tokens and last activity. A process without `--resume` or an open `.jsonl` gets the newest unclaimed transcript of its cwd folder (`SessionLogic.guessTranscripts`; folder name = cwd with non-alphanumerics → `-`).
- `~/.grok/sessions` (`GrokSessions`): Grok sessions and tokens.
- `~/.claude/.usd_brl`: USD→BRL rate (`Money`, with fallback).
- `SessionScanner.swift`: joins processes + costs into `LiveSession`s. `Harness` is `claude | xcode | grok`; `SessionSide` groups them into the Claude/Grok tabs. Totals dedupe on `usageKey`.
- `HistoryRollup.swift`: every source becomes a `HistoryInput` (per-day `HistoryDay`s, optional exact all-time per-model split, session marks); `HistoryLog.snapshot(input:range:now:)` turns it into what `HistoryChartView` draws (the `/stats` Overview and Models tabs). `TokenSplit.unsplit` holds per-day totals that came without input/output split, so the UI hides the split instead of inventing it.
- `UsageClient`/`OAuthFlow` (`UsageClient.swift`): quota from `api.anthropic.com/api/oauth/usage` with the `oauth-2025-04-20` beta header. `UsageModels.swift` decodes it; `perModelWeekly()` merges the fixed `seven_day_*` fields with the newer `limits[]` array (limits supersede), and `ModelMatch.pinLive` pins models currently in use.

Auth (`KeychainStore.swift`, `AppModel.refreshUsage`) has two credential sources, tried in order:
1. `.app`: the token this app obtained via its own PKCE OAuth flow (user pastes `code#state`), stored in a file (`appTokenURL`), refreshable.
2. `.claudeCode`: read-only from the Keychain item `Claude Code-credentials`. This app must never refresh or write it: rotating it would log Claude Code out (`OAuthFlow.refresh` refuses non-`.app` sources).

`LoginLaunch` implements "open at login": inside the `.app` it uses `SMAppService.mainApp`; under `swift run` it writes a LaunchAgent plist (`com.cesar.claude-status-bar`) and deliberately doesn't `launchctl load` it, since that would start a second menu-bar icon.

## Tests

`macos/Tests/ClaudeStatusBarTests/` has a single test file plus `fixtures/` (`usage-limits.json`, `costs-snippet.jsonl`), loaded through `Bundle.module`. Parsing functions take data/URLs as arguments (e.g. `parseClaudeCode`, `parseApp`, `SessionLogic.parseCosts`) so they can be tested without Keychain, network or real home directory.
