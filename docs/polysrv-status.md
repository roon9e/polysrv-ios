# PolySRV iOS — status, handoff and TODOs

Working notes for continuing this work on another machine. Everything here is on
the `polysrv` branch of `https://github.com/roon9e/polysrv-ios`; the design
rationale for the overlay pipeline itself is in
[`build-system/polysrv/README.md`](../build-system/polysrv/README.md), and the
repo's general rules are in [`CLAUDE.md`](../CLAUDE.md) and
[`AGENTS.md`](../AGENTS.md).

Last updated: 2026-10-30, at HEAD `b1fdde6e7d`.

## 1. Commits and what each one does

| commit | what | build |
|---|---|---|
| `51371c8331` | **the `-404` fix**: reset an account's datacenter state when its server scope changes | run #37 green, published |
| `8ef8947a19` | golden seeds the *branded* tree; `bazel_action_stats.py` reports cacheable misses; icon step guarded on `logo.png`; Debug footer brands to `<app name> for iOS`; **API credentials injected from secrets** | run #38 build green (publish 403, see §6) |
| `9e181bd543` | adding an account starts on the server picker; the choice is bound to the new account on its first network | pending at handoff |
| `bcd1128046` | store/model/remote-list lifecycle: whole custom record incl. `logoPath`, an empty `servers.json` accepted, bound-but-unpublished servers retained, `canEditIdentity`, `accountsBound(toScope:)` | pending at handoff |
| `a637c6b3a0` | account cap `min(premium + 20, 50)` (desktop's numbers) in the three places that read it; prune dead bindings | pending at handoff |
| `9b4671f01a` | CI: builds in parallel, only the golden job serialized | pending at handoff |
| `b1fdde6e7d` | picker sections + add/edit/delete + the add/edit form; branded root `README.md` | **not compiled yet** |

**Unverified at handoff:** the Swift of `b1fdde6e7d` (the picker and the add/edit
form) has never been compiled — there is no Swift toolchain on the Windows box
this was written on, so CI is the only compile check. Runs #39, #40 and #41 were
still building. **First job on the new machine: read run #41's build log.**

## 2. Behaviour now implemented

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
* **Naming.** The Debug Settings version footer is branded `<app name> for iOS`.
  The session name in Telegram's *Devices* list is the api_id's registered app
  title, **not** client-controlled (the client sends no name: `initConnection`
  carries apiId/deviceModel/systemVersion/appVersion only) — set it at
  my.telegram.org.

## 3. Environment on the new machine

* Branch `polysrv`, remote `origin` = `https://github.com/roon9e/polysrv-ios`.
* Git identity used for commits here: `roon9e <44918054+roon9e@users.noreply.github.com>`
  (already the repo's `user.name`/`user.email`).
* **`gh` CLI is authenticated as `roon9e`** (repo scope) — the fastest way to
  inspect builds:
  ```sh
  gh run list --branch polysrv --limit 6
  gh run view <run-id>                        # job and step outcomes
  gh run view --job=<job-id>                  # one job's steps
  gh run view --log --job=<job-id> | grep ... # the numbers / the failure
  gh run rerun <run-id> --failed
  ```
* **No Swift toolchain here.** Validate non-Swift things locally:
  ```sh
  python3 -c "import ast; ast.parse(open('build-system/polysrv/edits.py').read())"
  python3 build-system/polysrv/bazel_action_stats.py <some-bazel-log>   # report only
  # every anchored edit must still find its upstream text:
  python3 build-system/polysrv/apply_polysrv.py --check                 # on a PRISTINE tree
  ```
* **Secrets** (repo → Settings → Secrets and variables → Actions):
  `TELEGRAM_API_ID`, `TELEGRAM_API_HASH` (read by the `Inject API credentials`
  step). They are **not** committed; the committed
  `build-system/appstore-configuration.json` keeps Telegram's public placeholder.
* Build = `.github/workflows/build.yml`, triggered by a push to `polysrv` (and
  `workflow_dispatch` for a cache seed or a probe). macOS runners cap at 5
  concurrent jobs.
* On-device logs: the overlay forces file logging and enables file sharing, so
  **Files app → PolySRV → `polysrv-logs`**.

## 4. Immediate next steps

1. **Check run #41** (`Picker: add, edit and delete servers in place`) — the
   first compile of the picker/add/edit form. On failure:
   `gh run view --log-failed <run-id>` and fix; the likely classes are a missing
   import, a wrong Display/ASDisplayNode API, or a `theme.list.*` member that does
   not exist.
2. **Seed the cache once** — `workflow_dispatch` with `seed_cache: true`. Until
   then every build pays the branding cost (measured on #38, *before* the change:
   `9660 actions: 6851 disk cache hit, 1735 internal, 588 worker, 486 local` →
   `6851/7925 cacheable served (86%), 1074 misses`; after a branded seed expect
   `worker` and `misses` near zero). The reporter warns above 300 misses.
3. **Device-test the new flows** on the next IPA (artifacts are on the run page
   even if publish fails):
   * Settings → Add Account → the picker appears first; log line
     `PolySRV new account on server <id> (<host:port>)`.
   * Add a server by hand → it appears under Your servers → tapping it signs in.
   * Swipe a custom row → Edit / Delete; deleting a bound server names the
     accounts and logs them out.
   * Remove a server from `gh-pages/servers.json` → it disappears from Published,
     unless an account is bound to it (then it stays, marked).
   * On a server switch: `reset datacenter state for scope <host:port>` then
     `preparing reqPq` / `completeWithAuthKey` — the `-404` fix.
   * Adding a 5th+ account is now allowed (cap 20).

## 5. TODOs, by file

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
* Optional: publish with a fine-grained PAT (`PUBLISH_TOKEN`, Contents: read and
  write) and set the publish job's `GH_TOKEN` to it, so the repo can keep
  read-only workflow permissions (see §6).

## 6. The publish 403 (fixed at handoff)

`publish` failed with `HTTP 403: Resource not accessible by integration` on
`POST /releases`. The repository's Actions default was read-only:

```
roon9e/polysrv-ios      default_workflow_permissions: "read"
roon9e/polysrv-desktop  default_workflow_permissions: "write"
```

No commit of ours touched the publish job (`git diff 51371c8331..HEAD --
.github/workflows/build.yml` shows no publish/permissions lines), and #33–#37
published fine earlier the same day, so the setting changed outside the workflow.
The owner has since re-enabled *Read and write permissions*. If it regresses
again, use the PAT option in §5 instead of loosening the repo setting.

## 7. Landmines worth remembering

* **Never edit upstream files in the working tree.** The feature lives in
  `build-system/polysrv/overlay/**` and `build-system/polysrv/edits.py`, applied
  by `apply_polysrv.py` at build time. A missing anchor is a hard failure (good).
* **A `count: "all"` edit is not idempotent against an already-patched tree:** its
  `old` anchor still matches after the first application, so re-applying to a
  patched tree duplicates lines. Always start from a pristine checkout (CI does).
* **Every new `MTApiEnvironment` field must be carried in every `withUpdated*`**
  — that is what the `count: "all"` edit on `result.accessHostOverride = …` does;
  a field that is dropped there is silently lost when the app data updates.
* **Scope is `host:port`, lowercased**, and the reset is per account, so the same
  host on two ports is two servers and the same address under two ids is one.
* **Keep the golden cache key as `versions.json` + `.bazelrc`.** Adding branding
  or the overlay to it would throw away the third-party prefix on every branding
  edit; the disk cache is content-addressed, so a change simply misses until the
  next seed.
* **The seed deliberately does not inject credentials** (they reach only
  `BuildConfig`'s copts, ~3 actions) so the retained cache never holds the
  api_hash.
* **Criticalities of the original bug** (so it is not re-derived): the app makes
  Telegram permanent keys for the default DCs *before* the picker is even shown;
  a custom server then presented one of those keys, the server answered
  `protocol error -404` / `missing key <id> selector 0 … canResetAuthData: false`,
  and `MTProto.m`'s `default:` branch calls `checkIfLoggedOut:`, which the overlay
  disables for a locked server — so nothing ever replaced the key. The reset in
  §2 is the fix.
