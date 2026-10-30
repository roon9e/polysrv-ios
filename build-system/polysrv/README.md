# PolySRV multiserver overlay

This directory is the whole multiserver feature for the iOS client. Upstream
sources stay pristine; everything here is applied at build time, so merging a new
upstream release never conflicts with it.

## How it fits together

- `apply_polysrv.py` — copies `overlay/**` into the tree and applies the anchored
  edits in `edits.py`. Same contract as `build-system/apply_branding.py`: a
  missing upstream anchor is a hard failure. Flags: `--check` (report, change
  nothing) and `--revert` (restore the tree).
- `edits.py` — the small search/replace changes the runtime hook needs in
  upstream files (see the table below).
- `servers.json` — the bundled fallback: the official Telegram server only.
  The additional servers are published on the `gh-pages` branch and fetched at
  runtime (see below); they are deliberately not bundled.
- `overlay/` — the new sources, copied into the tree:
  - `submodules/TelegramCore/Sources/PolySrv/` — the server model and the
    registry (`PolySrvServer`, `PolySrvServers`, `PolySrvRemote`).
  - `submodules/TelegramCore/Tests/PolySrv/` — the registry's unit tests (picked
    up by the existing `//submodules/TelegramCore:TelegramCoreTests`).
  - `submodules/AuthorizationUI/Sources/PolySrv/` — the pre-login server picker.
  - `PolySrvDefaultServers.swift` is generated from `servers.json` by
    `apply_polysrv.py` (base64-embedded), never edited by hand.

## Build

`apply_branding.py` first (branding cosmetics), then `apply_polysrv.py`:

```sh
python3 build-system/apply_branding.py build-system/branding/branding.json
python3 build-system/polysrv/apply_polysrv.py
```

The fork's own API credentials are **not committed**. `.github/workflows/build.yml`
overwrites `api_id`/`api_hash` in `build-system/appstore-configuration.json` from
the `TELEGRAM_API_ID` / `TELEGRAM_API_HASH` repository secrets in the build's copy
of the tree (the committed values stay Telegram's public ones). The credentials
are still compiled into the IPA, so a published IPA contains them.

## The golden build cache

`.github/workflows/build.yml` moves bazel's `--disk_cache` and `--repository_cache`
between runners as the `ios-polysrv-golden-*` cache entries; only the `golden` job
(the `seed_cache` dispatch) writes them and the build job empties the paths before
its post-job steps, so a build can never shadow a generation.

The seed compiles **the same tree the build compiles** - branding, this overlay
and the regenerated provisioning profiles applied - so a branded build reuses its
whole graph. Seeding a generic tree only made sense for a builder that branded a
different app on every run. The API credentials are deliberately left out of the
seed: they reach only `BuildConfig`'s copts, so the cost is about three actions
and the api_hash stays out of the retained entry.

`bazel_action_stats.py` reads bazel's closing `N processes: ...` line and reports
the reuse: `internal` actions are uncacheable and excluded, so a *cacheable miss*
is a cacheable action that actually ran. The build job warns above 300 misses -
the golden no longer matches the tree, dispatch `seed_cache`. That is the same
signal ccache's miss count gives the desktop CI.

## Server switches reset the account's datacenter state

An account's MTProto keys, addresses and tokens persist in its keychain, and they
belong to the **server** they were made against. Without a reset, picking another
server kept the previous server's permanent key, the handshake presented it and
the new server answered `-404` — with `checkIfLoggedOut:` disabled for a locked
server nothing ever replaced it, so the account retried forever.

A server's scope is its address, `host:port` (lowercased host; the official cloud
is the reserved scope `telegram`), so two ports of one host are two servers and
the same address under two ids is one server. `PolySrvServers` records the scope
each account's network was last built against; `initializedNetwork` marks the api
environment with `datacenterStateReset` when it changes, and `MTContext`
`setKeychain:` drops `datacenterAuthInfoById`, `datacenterAddressSetById`,
`datacenterManuallySelectedSchemeById_v1`, `authTokenById` and
`transportSchemeStats_v1` before it loads. This is the reset desktop's
`restoreServer` performs.

## What the edits do

| File | Change |
|---|---|
| `TelegramCore/Sources/Network/Network.swift` | seed every datacenter from the selected server; set the custom public key and the DC lock on the api environment before the `MTContext` is built; mark `datacenterStateReset` when the account's server scope changed |
| `TelegramCore/Sources/Account/Account.swift` | a fresh account starts on the server's main datacenter; `UnauthorizedAccount.polySrvApplyServer` binds and rebuilds the network |
| `MtProtoKit/.../MTApiEnvironment.h/.m` | new `customServerPublicKey`, `datacenterOptionsLocked` and `datacenterStateReset` fields, carried through every `withUpdated*` |
| `MtProtoKit/.../MTDatacenterAuthMessageService.m` | a non-CDN datacenter uses the custom key when one is set |
| `MtProtoKit/.../MTContext.m` | with `datacenterOptionsLocked`, `help.getConfig` and added addresses cannot rewrite the seeds, and the seeds win over the keychain; with `datacenterStateReset`, the previous server's persisted datacenter state is dropped before it is loaded |
| `MTProtoRustEngine/.../RustNetworkEngine.swift` | the Rust engine gets the custom key through its existing `serverPublicKeys` parameter |
| `AuthorizationUI/.../AuthorizationSequenceController.swift` | "Start Messaging" offers the server picker on a first run, then proceeds to phone entry |

## The published server list (gh-pages)

The servers the app offers beyond the built-in Telegram one live on the
`gh-pages` branch, exactly as in `polysrv-desktop`: the branch holds `index.html`
(the servers page), `servers.json` and `update.json`, and is maintained by hand
(web UI or `gh api`). There is no workflow that writes it. The app fetches

```
https://roon9e.github.io/polysrv-ios/servers.json
```

(falling back to `raw.githubusercontent.com/roon9e/polysrv-ios/gh-pages/servers.json`).
Adding a server there makes it appear in the picker on the next launch; nothing
needs rebuilding.

## Not in this milestone

Adding/editing servers from the UI, per-account identity scoping on the same
numeric id across two servers, account-switcher grouping, `srv://` inbound links,
and remote polling of `servers.json`.
