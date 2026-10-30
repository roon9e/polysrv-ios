# PolySRV iOS

PolySRV is a [Telegram iOS][telegram_ios] fork that lets you sign in to **more
than one server** from a single application, alongside the official Telegram
network.

It keeps the upstream Telegram iOS feature set, the same
[MTProto][telegram_proto] transport and the same update model, and adds:

* **A server picker before sign-in.** Adding an account starts on the server
  list: choose the official Telegram network, or point the client at a
  self-hosted MTProto backend. The account is created already bound to the
  server you chose.
* **Your own servers, editable in place.** Add, edit and delete self-hosted
  servers from the picker — name, description, address, port, home data center
  and public key. The published servers stay read-only.
* **One client, many servers.** Well past the official cloud's three accounts:
  the client holds `min(premium accounts + 20, 50)`, the same policy as PolySRV
  Desktop. Every account keeps its own server binding, so switching servers
  resets the keys, addresses and tokens the previous server's session had made
  instead of presenting them to the new one.
* **One published server list.** The servers offered beyond the built-in
  Telegram one live on the `gh-pages` branch and are fetched at runtime, so
  adding or withdrawing a server needs no new build. A server an account is
  signed in to survives being withdrawn; once nothing is bound to it, it is
  gone.

The multi-server design is inspired by the
[owpengram](https://github.com/owpengram/owpengram-desktop-client) desktop
client, with a number of its rough edges fixed, and it is deliberately the same
feature set as [PolySRV Desktop](https://github.com/roon9e/polysrv-desktop).
PolySRV is not affiliated with Telegram FZ-LLC or with owpengram; Telegram
itself remains a separate project with its own clients and its own releases.

## Building

The upstream set-up — creating your own application, installing Xcode, the
configuration files — is the upstream guide in
[TelegramMessenger/Telegram-iOS][telegram_ios]. This repository's own notes, the
exact Bazel invocation and the simulator workflow are in [`CLAUDE.md`](CLAUDE.md).

Two things are applied to a checkout **before** it is built, so upstream sources
stay pristine and a new upstream release can be merged without conflicts:

```sh
python3 build-system/apply_branding.py build-system/branding/branding.json
python3 build-system/polysrv/apply_polysrv.py
```

* `build-system/branding/` — the product name, the bundle identifier, the URL
  scheme and the host. Renaming the build means editing `branding.json` and
  re-running the script.
* `build-system/polysrv/` — the whole multi-server feature: the server registry,
  the picker and the add/edit form, the anchored edits that hook them into the
  network, the account and MtProtoKit, and the bundled fallback server list.

The API credentials are **not committed**: CI overwrites `api_id` / `api_hash`
in `build-system/appstore-configuration.json` from repository secrets while it
builds, and a local build has to do the same. `.github/workflows/build.yml` is
the whole build — pushing to the `polysrv` branch builds the IPA and publishes
it, and a manual run with `seed_cache` rebuilds the shared Bazel cache.

## Releases

Builds are published as GitHub releases by that workflow — the official Telegram
version plus this repository's build number, e.g. `PolySRV 13.1.2 (3732)`. The
server list the picker offers is at

```
https://roon9e.github.io/polysrv-ios/servers.json
```

on the `gh-pages` branch, maintained by hand (web UI or `gh api`); the same
branch mirrors PolySRV Desktop's, so one published list serves both.

The IPA is built with placeholder signing, because no Apple developer account is
involved: re-sign it with your own certificate and provisioning profile, or
install it with your own sideloading tooling, before it will run on a device.

## Telegram's requirements

Telegram asks every client built on their API to do the following, and this
project does:

* Use **your own api_id**, obtained from
  [my.telegram.org](https://core.telegram.org/api/obtaining_api_id).
* Do not call the app "Telegram", and make sure users understand it is
  unofficial.
* Do not use Telegram's logo (the white paper plane in a blue circle).
* Read the [security guidelines](https://core.telegram.org/mtproto/security_guidelines)
  and take care of your users' data and privacy.
* Publish your own source code, to comply with the licences.

## License

The source code is published under the same license as upstream Telegram iOS,
available [here][license].

[telegram_ios]: https://github.com/TelegramMessenger/Telegram-iOS
[telegram_proto]: https://core.telegram.org/mtproto
[license]: https://github.com/TelegramMessenger/Telegram-iOS/blob/master/LICENSE
