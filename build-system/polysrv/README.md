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

## What the edits do

| File | Change |
|---|---|
| `TelegramCore/Sources/Network/Network.swift` | seed every datacenter from the selected server; set the custom public key and the DC lock on the api environment before the `MTContext` is built |
| `TelegramCore/Sources/Account/Account.swift` | a fresh account starts on the server's main datacenter; `UnauthorizedAccount.polySrvApplyServer` binds and rebuilds the network |
| `MtProtoKit/.../MTApiEnvironment.h/.m` | new `customServerPublicKey` and `datacenterOptionsLocked` fields, carried through every `withUpdated*` |
| `MtProtoKit/.../MTDatacenterAuthMessageService.m` | a non-CDN datacenter uses the custom key when one is set |
| `MtProtoKit/.../MTContext.m` | with `datacenterOptionsLocked`, `help.getConfig` and added addresses cannot rewrite the seeds, and the seeds win over the keychain |
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
