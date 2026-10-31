# PolySRV iOS — status, handoff and TODOs

Working notes for continuing this work on another machine. Everything here is on
the `polysrv` branch of `https://github.com/roon9e/polysrv-ios`; the design
rationale for the overlay pipeline itself is in
[`build-system/polysrv/README.md`](../build-system/polysrv/README.md), and the
repo's general rules are in [`CLAUDE.md`](../CLAUDE.md) and
[`AGENTS.md`](../AGENTS.md).

Last updated: 2026-10-30 (later), on top of upstream
`TelegramMessenger/Telegram-iOS@279f89e4d4` (**13.1.2**). The device findings and
the fixes for them are in §0b below.

## 0. Where the branch is now

* **Rebased onto upstream `master`.** The branch had been sitting on upstream
  `fb0e62ba8a` (13.1.1); the 27 `polysrv` commits were replayed on top of
  upstream `279f89e4d4`, which brings in three upstream "Cherry-pick fixes"
  commits (MediaPlayer/TelegramCore/Wallet/WebUI/SiriIntents, `Account.swift`'s
  `AccountStateManager` gain an `ignoresShortSentMessages` argument,
  `SharedAccountContext.makeCreateBotScreen` gains `viaDeeplink:`) plus upstream's
  **Bump version → 13.1.2**. `versions.json` is now `13.1.2`, so the next CI
  build ships `PolySRV 13.1.2 (<build_number>)`. The overlay touches no upstream
  source file, so the rebase was conflict-free and every anchored edit still
  found its text (checked by applying `apply_polysrv.py` to the rebased tree).
* **The branch is pushed with a force-push** (a rebase rewrites the previous 8
  commits). Any other checkout of `polysrv` has to be reset to `origin/polysrv`.
* **Two defects from the never-compiled picker commit (`2ee34b7f88`) are fixed:**
  1. `fe860ffc67` — the delete confirmation called
     `strongSelf.present(_:in:)` on the `AuthorizationSequenceController`, which
     is a `NavigationController` (`UINavigationController`), **not** a
     `ViewController`; it has no `present(_:in:)`. AuthorizationUI did not
     compile (run `41061455746`/`41063018132`).
  2. `d071b6178f` — the add/edit form and the delete confirmation were presented
     at `.window(.root)`, a **local** overlay, which `NavigationController`
     renders *below* the global overlay containers, i.e. below the picker that
     opened them. They now go to the window's global overlay.

## 0b. Device findings (2026-10-30) and the fixes

A device run on the published build (13.1.2 / 3732) showed three defects; the
on-device file log (`Documents/polysrv-logs`, forced by the overlay) pinned the
first two exactly. Nothing here comes from an unverified guess.

**A custom-server login did not survive (the "back at the first server" bug).**
The log shows the account is bound to the picked server, then `reset datacenter
state for scope telegram` at login, connections to the official datacenters, and
`401 AUTH_KEY_UNREGISTERED` → `logoutFromAccount`. Cause: the overlay's own
"prune dead bindings" call ran while the account was still authorizing, with a
keep-set of *authorized* accounts only, so it deleted the binding (and applied
scope) of the account whose login was in flight. `PolySrvServers.pruneAccounts`
was correct; the call site was not.

- Fixed: the keep-set now also keeps `currentAuth?.id`.
- Hardened: a pending server choice is now **owned** by the account it was made
  for (`setPendingServer(id:forAccount:)` / `pendingServerOwner`), so
  `server(forAccount:)` can never hand a pending custom server to a different
  account that has no binding of its own (the official cloud's), which would have
  re-scoped and wiped *its* keys.

**The same number could not be signed in to Telegram and a custom server.**
Two upstream rules key on the user id / phone number alone:

- the phone-entry "already authorized" guard
  (`AuthorizationSequencePhoneEntryController.nextPressed`);
- the account de-duplication by `(peerId, isTestingEnvironment)`
  (`SharedAccountContext`), which deletes one of two records for one user id.

- Fixed: both now include the account's **bound server scope**. The same number
  on two servers is two accounts and both are kept; the same number on one server
  still collapses/asks as before. `PolySrvServers.boundScope(forAccount:)` is the
  binding-only scope used for identity (no pending fallback).

**The account menu.** With the two bugs above, the second account never survived,
so the Settings account list (which only lists *other* accounts) looked empty.

- The native Settings account list is now **grouped by server**, with the server's
  name as the group header and the official cloud first — the same shape the
  Android and Windows clients use.
- A second entry, **"All Accounts"**, always present in Settings ▸ Accounts, opens
  the overlay's own screen listing every account from every server (switch, add,
  log out). It is reachable even with a single account.

**Per-server cache separation.** Verified rather than changed: every account owns
its `Postbox` under `account-<recordId>`, and therefore its own media cache
(`Postbox.mediaBox`) and its own `AnimationCache`; emoji/sticker/gift catalogs are
engine data in that postbox. A new account on a new server therefore starts empty
and fetches *that* server's catalogs. The one shared cache,
`SharedAccountContext.accountManager.mediaBox`, holds only themes, wallpapers and
service backgrounds — account-independent UI resources, not server content — so
it is deliberately not per-server. No process-wide cache keyed on a server id was
found.

## 1. Recent CI runs, and what each one actually failed on

| run | commit | outcome | reason |
|---|---|---|---|
| `41043831134` | reset DC state on server switch | **green**, published | — |
| `41055722576` | golden seeds the branded tree | build green; **publish failed** | `publish` 403, §6 |
| `41056618263` | add-account server picker | build green; **publish failed** | `publish` 403, §6 |
| `41058779109` | CI: parallel builds | **green**, published | — |
| `41061455746` | picker add/edit/delete | **build failed** | AuthorizationUI `present(_:in:)`, §0.1 |
| `41063018132` | docs handoff | **build failed** | same AuthorizationUI error |
| `40490244318` | weekly `master` keepalive | **failed** | not this branch: the scheduled `master` workflow's keepalive looks for `ios-v13-golden-*` entries that do not exist on this fork and its final `[ -d "$dir" ] && rm` returns 1 under `bash -e`. Ignore it; it is upstream's workflow, not `.github/workflows/build.yml`. |

Nothing else has been built: the rebase, the rebase's upstream commits and the
two fixes above have **not** been compiled yet. That is the next CI run.

## 2. Fixed since the previous handoff, and still to verify on a device

**Compile** — `fe860ffc67` (`presentOverlay` on the auth controller) fixes the
only error CI reported: `AuthorizationSequenceController.swift:164` (in the
applied tree) `extra argument 'in' in call / missing argument for parameter
'animated' / cannot infer contextual base in reference to member 'window'`.
Swift only ever offered `NavigationController.present(_:animated:completion:)`.

**Layering** — `d071b6178f`. `Display/NavigationController` inserts its local
`overlayContainers` *below* `globalOverlayContainerParent`
(`NavigationController.swift`, the `overlayContainers` loop just after the
`globalOverlayContainers` loop). The picker is a global overlay, so a form the
picker presented at `.window(.root)` (→ `WindowContent.present(…, on: .root)` →
`presentOverlay(inGlobal: false)`) was a local overlay rendered behind it. Both
the form and the confirmation now use the global overlay
(`presentInGlobalOverlay` / `presentOverlay(inGlobal: true)`), so they stack
above the picker in list order.

Neither of these is verified visually. `AGENTS.md` is explicit that a green
build says nothing about what is drawn; when a machine with a simulator and the
installed build is available, record the picker → Add / swipe Edit / swipe
Delete → Save / Cancel sequence and judge the frames. The specific things to
look for: the form appears *above* the list (not behind it), the keyboard does
not cover the RSA-key field, and the confirmation appears above the form.

## 3. Behaviour now implemented

* **Server picker before adding an account.** `SharedAccountContextImpl.beginNewAuth`
  offers the picker first when a primary account already exists; the choice is
  recorded as the pending selection and `PolySrvServers.bindPendingIfNeeded`
  binds it to the new account's first network. The first run keeps its own path
  (its splash already offers the picker).
* **Your own servers, editable in place.** Sections `Official` / `Your servers` /
  `Published`; the last row of `Your servers` adds one; swipe a custom row to
  Edit/Delete. Published servers are read-only. The add/edit form validates like
  desktop's box and refuses to move a server's address or key while an account is
  bound to it.
* **Deleting** a custom server asks first, logs out every account bound to it
  (`accountsBound(toScope:)` → `logoutFromAccount`), then removes it. The picker
  gets that ability as a `PolySrvServerPickerEnvironment` from whoever presents it.
* **Scope and reset.** A server's scope is its address, `host:port`; the official
  cloud is the reserved scope `telegram`. When an account's scope changes, the
  network drops the previous server's persisted datacenter keys/addresses/schemes/
  tokens (`datacenterStateReset` → `MTContext.setKeychain:`).
* **Remote list lifecycle.** A published `{"servers": []}` is an answer (the list
  empties); a server bound to an account survives being unpublished and is marked
  "no longer published"; once nothing is bound to it, it is dropped.
* **Account cap** `min(premiumCount + 20, 50)` — desktop's policy, not the
  official cloud's 3-or-4.
* **Naming.** The Debug Settings version footer is branded `<app name> for iOS`;
  `versions.json` is now 13.1.2. The session name in Telegram's *Devices* list is
  the api_id's registered app title, **not** client-controlled (the client sends
  no name: `initConnection` carries apiId/deviceModel/systemVersion/appVersion
  only) — set it at my.telegram.org.

## 4. Environment

* Branch `polysrv`, remote `origin` = `https://github.com/roon9e/polysrv-ios`,
  and `upstream` = `https://github.com/TelegramMessenger/Telegram-iOS`.
* Git identity used for commits here: `roon9e <44918054+roon9e@users.noreply.github.com>`.
* **`gh` CLI is authenticated as `roon9e`** (repo scope):
  ```sh
  gh run list --branch polysrv --limit 6
  gh run view <run-id>                        # job and step outcomes
  gh run view --job=<job-id>                  # one job's steps
  gh run view --log-failed=<job-id> | grep -E ": error:|ERROR:"   # the failure
  gh run rerun <run-id> --failed
  ```
* **No Swift toolchain on the Windows box this is written on.** Validate non-Swift
  things locally instead:
  ```sh
  python -c "import ast; ast.parse(open('build-system/polysrv/edits.py').read())"
  python build-system/polysrv/apply_polysrv.py .            # then --revert: it patches the tree
  python build-system/polysrv/bazel_action_stats.py <bazel-log>   # report only
  ```
  `apply_polysrv.py` is the real anchor check: run it on a pristine checkout and
  demand no `MISSING ANCHOR`; `--revert` restores the tree (it git-checkouts the
  edited files and deletes the overlay copies).
* **Secrets** (repo → Settings → Secrets and variables → Actions):
  `TELEGRAM_API_ID`, `TELEGRAM_API_HASH` (read by `Inject API credentials`).
  Repo → Settings → Actions → Workflow permissions must stay **Read and write**
  for `publish` to create a release (§6).
* Build = `.github/workflows/build.yml`, on a push to `polysrv` (and
  `workflow_dispatch` for a cache seed or a probe); macOS runners cap at 5
  concurrent jobs. Pushes build **in parallel**; only the `golden` seed is
  serialized.
* On-device logs: the overlay forces file logging and enables file sharing, so
  **Files app → PolySRV → `polysrv-logs`**.

## 5. Immediate next steps

1. **Watch the CI run for the pushed tip.** It is the first compile of the
   picker's add/edit/delete (the overlay sources, `edits.py`'s new helper block)
   and of the rebase. On failure: `gh run view --log-failed <id>`.
2. **Seed the cache once** — `workflow_dispatch` with `seed_cache: true`. Until
   then every build pays the branding cost. The reporter warns above 300
   cacheable misses; after a branded seed expect `worker` and `misses` near zero.
3. **Device-test the flows** on the next IPA (artifacts are on the run page even
   if publish fails), and record the animations/frames per `AGENTS.md`:
   * Settings → Add Account → the picker appears first; log line
     `PolySRV new account on server <id> (<host:port>)`.
   * Add a server by hand → it appears under Your servers → tapping it signs in.
     **The form must be visible over the picker** (§2).
   * Swipe a custom row → Edit / Delete; deleting a bound server names the
     accounts and logs them out, with the confirmation above the picker.
   * Remove a server from `gh-pages/servers.json` → it disappears from Published,
     unless an account is bound to it (then it stays, marked).
   * On a server switch: `reset datacenter state for scope <host:port>` then
     `preparing reqPq` / `completeWithAuthKey` — the `-404` fix.
   * Adding a 5th+ account is now allowed (cap 20).

## 6. The publish 403

Two runs (`41055722576`, `41056618263`) failed **only** in the `publish` job:
`HTTP 403: Resource not accessible by integration` on `POST /releases`. The
token in those logs already carries `Contents: write` — the workflow has had
`permissions: contents: write` on `publish` all along, and the run between them
(`41058779109`, same workflow, same job) published fine. The cause recorded at
the previous handoff was the repository's *default* Actions permission being set
to read-only (`roon9e/polysrv-ios` `default_workflow_permissions: "read"` while
`polysrv-desktop` was `"write"`), changed outside the workflow and since
re-enabled. It is currently `"write"` (checked with
`gh api repos/roon9e/polysrv-ios/actions/permissions/workflow`). If it regresses:
publish with a fine-grained PAT (`PUBLISH_TOKEN`, Contents: read and write) in
the publish job's `GH_TOKEN` rather than loosening the repo setting, or just
`gh run rerun <id> --failed` the publish job.

## 7. TODOs, by file

* `build-system/polysrv/overlay/.../PolySrv/PolySrvServerSelectController.swift`
  * Nav bar: the header is still hand-rolled (title + left button + Add). A real
    `navigationBarPresentationData` needs the picker to be presented inside a
    `NavigationController`; that was deliberately avoided (the earlier crash was
    a blocked UIKit `present`). The left button already reads **Back** in the
    pre-login flow and **Cancel** when adding an account.
  * Details: the plan had a per-server details screen (main DC, multi-DC, key
    fingerprint, description) reached from an info button. Not built.
  * The TCP "ping" measures the tunnel when a system VPN is in use — replace with
    an MTProto-level check, or drop the number.
* `build-system/polysrv/overlay/.../PolySrv/PolySrvServerEditController.swift`
  * Logo picker. The model (`logoPath`), the store and the picker's avatar all
    already carry it; only the choosing UI (photo picker → a saved file path) is
    missing. `apply_build`'s `has_custom_icon()` already switches the app icon
    when `build-system/branding/logo.png` exists.
* Not started: `srv://` inbound links (desktop has `addserver`/host-routed links),
  account-switcher grouping per server, per-account identity scoping for the same
  numeric user id on two servers, polling `servers.json` beyond the picker's
  appearance (1 h TTL).
* `submodules/TelegramCore/Tests/PolySrv/PolySrvServersTests.swift` (overlay):
  CI only *builds*, it never runs tests. `Tests/AllTests` is broken upstream (see
  `CLAUDE.md`), so run the target directly:
  `Make.py test --target //submodules/TelegramCore:TelegramCoreTests`.
* Dormant, not urgent: if Telegram ever answers `RECAPTCHA_CHECK_…`, this fork
  cannot solve it (the reCAPTCHA Enterprise site key it returns is bound to
  Telegram's own bundle id → `errorInvalidPackageName`). Normal logins do not hit
  it; a web-view reCAPTCHA flow would be the fix.

## 8. Landmines worth remembering

* **A failed golden seed used to delete the golden.** On 2026-10-30 the 13.1.2
  seed's cold compile failed on `provisioning profile ExpirationDate
  (2026-10-30T17:06:30) is in the past` — the committed
  `build-system/fake-codesigning/profiles/*.mobileprovision` are real Apple
  profiles whose fixed expiry had passed, and `RegenerateProfilesForBundleId.py`
  only rewrote the bundle id. The save steps are gated on
  `steps.compile.outcome == 'success'`, so nothing was saved; the golden job's
  own "Retire superseded golden entries" step then deleted the previous
  generation (the current keys were absent), leaving **zero caches** and every
  build compiling from scratch. Fixed: the regenerated profiles get a fixed
  far-future `ExpirationDate`, and the retire step is gated on the save condition
  and deletes nothing unless the current keys are present.

* **Never edit upstream files in the working tree.** The feature lives in
  `build-system/polysrv/overlay/**` and `build-system/polysrv/edits.py`, applied
  by `apply_polysrv.py` at build time. A missing anchor is a hard failure (good).
* **The picker and the server form are *pushed*, not overlays.** Swipe-to-go-back
  is `NavigationContainer`'s pop and it needs `controllers.count > 1`, so the
  picker and the form are pushed onto the presenter's navigation controller and
  get the app's navigation bar; the form is pushed *on top of the picker*, so its
  back swipe returns to the picker. An overlay container has no pan recogniser at
  all, which is why the earlier overlay/window presentation had neither a back
  swipe nor a bar. Anything that must appear **over** a pushed screen is a global
  overlay (`ViewController.presentInGlobalOverlay`, or
  `NavigationController.presentOverlay(inGlobal: true)`); `.window(.root)` is a
  local overlay and renders **below** the global containers.
* **`AuthorizationSequenceController` is a `NavigationController`, not a
  `ViewController`** — it has `presentOverlay`/`currentWindow` but no
  `present(_:in:)`. `Display.NavigationController` also traps on a UIKit-style
  `present(_:animated:)` from a non-UIKit context; push, or present through the
  overlay. Its stack is rebuilt from the auth state on every state change, so a
  pushed screen is removed by `setViewControllers` when the state moves on (which
  is why the pre-login picker passes `dismissOnSelect: false` rather than popping
  itself, which would flash the splash first).
* **A `count: "all"` edit is not idempotent against an already-patched tree:** its
  `old` anchor still matches after the first application, so re-applying to a
  patched tree duplicates lines. Always start from a pristine checkout (CI does).
* **Every new `MTApiEnvironment` field must be carried in every `withUpdated*`**
  — that is what the `count: "all"` edit on `result.accessHostOverride = …` does;
  a field that is dropped there is silently lost when the app data updates.
* **Scope is `host:port`, lowercased**, and the reset is per account, so the same
  host on two ports is two servers and the same address under two ids is one.
* **Keep the golden cache key as `versions.json` + `.bazelrc`.** The version bump
  to 13.1.2 changes that hash, so the next build is a *cold* one (all misses)
  until the new key is seeded — expected, not a regression.
* **The picker's dot is the app's own connection state, not a probe.** A TCP
  connect to a Telegram DC completes behind a DPI block (the handshake is not what
  gets cut), so a probe dot showed green for a server the app could not actually
  use. The dot now reads `network.connectionStatus` of the account bound to that
  server (green `.online`, amber `.connecting`/`.updating`, red
  `.waitingForNetwork`, **grey with no account**), fed from
  `SharedAccountContext.activeAccountsWithInfo`; the TCP probe is gone.
* **A row's animation cache and sticker resolution must be the row's own
  account's.** `AccountContext.animationCache` is per account
  (`DCTAnimationCacheImpl(basePath: engine.resources.mediaBasePath + "/animation-cache")`)
  and `resolveInlineStickers` resolves through one account's network and postbox.
  The accounts list built its row context from the *presenting* screen's account,
  so an emoji or gift status belonging to another account (one on another server)
  resolved against the wrong store and drew nothing - the gift's particle effect
  showed while its model never did. Use `peerAccountContext`, not `context`.
* **A bar button item's image is not tinted by the bar.** `navigationBarButton`
  only applies the bar colour when `image.renderingMode == .alwaysTemplate`, and
  an SF Symbol from `UIImage(systemName:)` does not come through as one here, so
  it falls back to the window's accent (blue). Bake the colour in with
  `withTintColor(NavigationBarTheme(rootControllerTheme: theme).buttonColor, renderingMode: .alwaysOriginal)`.
* **The seed deliberately does not inject credentials** (they reach only
  `BuildConfig`'s copts, ~3 actions) so the retained cache never holds the
  api_hash.
* **Criticalities of the original `-404` bug** (so it is not re-derived): the app
  makes Telegram permanent keys for the default DCs *before* the picker is even
  shown; a custom server then presented one of those keys, the server answered
  `protocol error -404` / `missing key <id> selector 0 … canResetAuthData: false`,
  and `MTProto.m`'s `default:` branch calls `checkIfLoggedOut:`, which the overlay
  disables for a locked server — so nothing ever replaced the key. The reset in
  §3 is the fix.
