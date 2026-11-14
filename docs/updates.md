# Automatic updates

Since v0.1.11 nanomon uses the same shared nanoui updater and quiet-restart
API as nanolight (the same pinned nanoui revision), rather than keeping a
separate updater implementation in the app.

## macOS

A Developer-ID-signed release installed in a permanent `.app` location checks
GitHub's latest release after 20 seconds, then every six hours. It downloads
only newer versions, verifies the manifest's SHA-256, verifies the staged
bundle's signature and matching signing team, and checks its bundle version.
Unsigned/ad-hoc, wrong-team, wrong-version and corrupt candidates are refused.
Source builds and copies on a disk image or App Translocation cannot update.

Once ready, it restarts after ten seconds out of sight (not active, no key
window, every window hidden/minimized/covered), or after five minutes with no
user input. The relaunch stays in the background when it was in the background;
windows return to their previous positions/states. Nothing polls rapidly:
visibility notifications and one slow away timer drive this behavior.

Page, graph range, process filters/sort, search and menu-bar choices survive.
A closed main window stays closed. Process identities, pending signals and
sample history are **not** persisted; fresh native samples repopulate graphs.
An automatic restart is deferred during paused monitoring, pending quit
confirmation/marked processes, agent setup or a running graff request.
Very long searches also defer it so the restore record stays bounded.

The sidebar offers **Check for updates** and **Restart to update**. Explicit
restart, or quitting normally with a verified update waiting, can install it
without waiting for the quiet period.

**v0.1.9 was ad-hoc signed: manually install a signed v0.1.10+ once.** v0.1.10
checks/offers updates and installs them on quit; v0.1.11 adds quiet restarts.

## Linux

Official release archives embed their update version and choose the matching
arm64/x86_64 archive. The updater verifies HTTPS-delivered manifest checksums
and runs the staged binary's headless `--version` before installing it on quit
or an explicit restart. It needs `curl`, `tar`, and a user-writable install
location; it does not request elevation to replace a system-owned binary.
Unlike macOS there is no Developer ID signature check or quiet auto-restart.
The GUI closes/exits normally on Linux, installing a waiting update then.

Ordinary `zig build` binaries have portable updates **off**. Packaging opts in
with `-Dupdate-version=X.Y.Z`; this prevents replacing a developer's build.
Windows monitoring/releases are not currently supported.

`nanomon mcp` and its setup/version CLI commands never start the GUI updater,
fetch releases, restart themselves or rewrite agent configs on startup. An
already-running MCP process continues on its current version; restart that
client's server when you want the installed binary's new version.

## Release safety

Releases remain drafts until all platform archives exist and verification
passes: checksums, the multi-platform manifest, Developer ID team,
notarization/stapled tickets, offscreen bundle launch and MCP version.
The real shared updater is also exercised against temporary copies of the
previous signed release: a valid candidate installs, while bad checksums,
wrong versions and other signing teams are refused. These checks never open
windows, send input, replace `/Applications` apps or touch user preferences.

The release workflow promotes only a verified draft to `latest`. Missing
signing credentials cannot silently publish an ad-hoc build into the feed.
CI signs when `MACOS_CERT_P12` and `MACOS_CERT_PASSWORD` are configured, and
notarizes with `AC_API_KEY_P8`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`.
Alternatively, sign locally with the existing Developer ID, upload assets to
a draft, run the workflow's `notarize_release` dispatch, then push the release
tag. CI retains those signed assets, adds Linux archives and verifies/promotes
them. The signing private key need not leave the developer's machine.

```sh
zig build test
python3 tools/test-update-manifest.py
zig build update-check-bin
# Signed draft/release verification, all files in a temporary directory:
python3 tools/verify-release.py v0.1.11 --require-linux-manifest \
  --update-check zig-out/bin/nanomon-update-check
```
