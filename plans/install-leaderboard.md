# Install Leaderboard Plan: Timing Tower (pending agreed name)

## Goal

Give the install time an official home. The ISO already races: the dashboard ends on "Installed Omarchy in 0m 43s", people photograph that screen, and records circulate as posts. This plan turns that number into a result that can be classed, compared across releases, and submitted — only when the person who ran the install chooses to.

Product brief (DHH, 27 August 2026): full integration; different classes; store the log on install; after first network, check whether the run is a top 10 in its class and offer to submit; attach fastfetch hardware data; only ever check servers and submit on user approval; consider signing results with a key created at install.

Three surfaces, three repositories. This plan owns the installer half and states the contract the other two depend on.

- `omarchy-iso` (this repo): produce a versioned, classed, signed timing artifact on the target. Show the lap time.
- `basecamp/omarchy`: `omarchy leaderboard status|preview|check|submit`, one quiet post-install offer, menu entry.
- A small Rails app (home pending, see below; `omarchy-plugin-registry` is the closest sibling): per-release class boards, sector bests, machine pages, review queue.

## Current State (August 2026)

- `orchestrator/phases.py` `run()` records 14 phases with `time.time()` and writes `/run/omarchy-install/state.json` after each one; `omarchy-install-dashboard` polls it every 0.5s. On success the same dict is copied atomically to the target as `/var/log/omarchy-install-timing.json`.
- The document holds `started_at`, `finished_at`, `target`, `phases[] {name, status, elapsed}` (float seconds), `installed_packages`, `expected_packages`. No schema version, no run ID, no ISO identity, no hardware, no class, no signature. Root can rewrite it.
- The finish screen (`render_finish`) prints whole seconds: `(finished_at - started_at) | round`, formatted `Xm Ys`. Then a single `Reboot Now` button. Deferred-provisioning installs skip the screen.
- Install mode is already a fact (`InstallContext.mode`: `full_disk` or `protected`). Encryption for class purposes is `_provision_install_encrypted` in `phases_impl.py`, not the configurator flag. The install is always offline (`make_mirror_handler(offline=True)`, bind-mounted `/var/cache/omarchy/mirror/offline`).
- ISO identity on the medium is `/root/omarchy_iso_ref` and `/root/omarchy_mirror` from `builder/build-iso.sh` (production ISOs: `quattro` + `stable`). Every published ISO has a `.sha256` sidecar.
- `.automated_script.sh` `warm_offline_mirror` pre-reads the offline mirror into the page cache during the configurator, budgeted at `MemAvailable/2`, disabled by `OMARCHY_NO_PREFETCH=1`. The advantage is real and uneven across RAM sizes.
- OpenSSL is on the live ISO (the configurator uses `openssl passwd -6`).
- In `basecamp/omarchy`, nothing contacts a server without a user action: first-run `wifi.sh` only asks NetworkManager locally; `omarchy-debug` uploads to logs.omarchy.org after a `gum choose`; `omarchy-upload-log` already collects `fastfetch --pipe`. Those are the idioms to reuse.

## Architecture

```text
live ISO                                    target disk                          installed Omarchy
--------                                    -----------                          -----------------
orchestrator.run()                          /var/log/omarchy-install-timing.json omarchy leaderboard status
  phases -> state.json (unchanged)   --->     schema 1, ns, run_id, class,       omarchy leaderboard preview
  keypair via openssl, key on stdin           hardware                           omarchy leaderboard check   (GET public top10)
  sign the file on disk, key discarded      /var/lib/omarchy/leaderboard/        omarchy leaderboard submit  (preview, confirm, POST)
                                              timing.json, timing.sig,           offer service: one toast, once
                                              install.pub; @factory copy of all three
```

The timing file is the only contract between repositories. Its schema is versioned so the CLI can refuse to interpret a v0 file as anything more than seconds.

## Timing artifact (schema 1)

Additive on the live `state.json` — the dashboard keeps its float `started_at`, `finished_at`, `elapsed` and display names. The target document adds:

- `schema: 1`, `run_id` (UUIDv4 minted before phase 1), and `iso: {ref, mirror, offline_db_sha256, build}` (the hash is of the medium's offline database; the server allow-lists published values) plus `release` (the omarchy package version on the target) and `live` (kernel and uptime of the live session).
- `phases[]` gain `id` (a stable identifier such as `arch_install_system`, from the callable name) and `elapsed_ns` from `time.monotonic_ns()`. `total_elapsed_ns` is the sum of phase `elapsed_ns`, and the competitive total is that sum, not wall clock.
- `class`: `{mode, encrypted, virt, warm}` — mode from `InstallContext.mode`, encryption from `_provision_install_encrypted`, `virt` from `systemd-detect-virt`, `warm` from `OMARCHY_NO_PREFETCH`. The install is always offline, so there is no seed axis.
- `hardware`: DMI vendor, product, product version and board, `/proc/cpuinfo` model name and CPU count, `MemTotal`, and the disk behind the target and behind the install medium (model, transport, rotational, size; walking dm-crypt and partitions with `lsblk -s`). Never hostname, serials, MAC addresses, disk UUIDs, or usernames.
- `seal: {algorithm, public_key}` and `attestation: null`, a slot reserved for a hardware-backed witness once measured boot of the live medium is something a server can check.
- Every probe is best-effort: a failed one leaves `null` in its slot and the document is still written and sealed. Nothing in it fails an install.

Class is what the installer observed, never a label the user picks. "Official" is decided server-side from the tuple plus the ISO allow-list; the client never asserts it.

## Signing

The keypair is generated in the live environment after the phase loop succeeds (Ed25519, `openssl genpkey`). The document is written to `/var/lib/omarchy/leaderboard/timing.json` and to the timing log, same bytes in both, and the signature is made over the file on disk (`openssl pkeyutl -sign -rawin`, the private key fed on stdin) so the bytes sealed are the bytes a reader finds. `timing.sig` and `install.pub` land beside the document. The private key is never written anywhere and is gone at reboot. If openssl or the signature fails, the document is written without a seal and the install log says so.

That makes the result sealed at the finish line: editing the file after install breaks the signature and no key exists to re-sign it. It does not make the result true. Someone can fabricate a document and a keypair on any machine. Copy and docs say tamper-evident, never verified or cheat-proof. Anti-cheat is class isolation, plausibility checks, and review on the server (below). TPM or Secure Boot attestation is a later tier and depends on `plans/consumer-secure-boot.md`.

All three files are also copied into the `@factory` snapshot (remount rw, copy, restore ro), so a factory reset keeps the original result. This happens after the last phase, not as a phase of its own, and is a no-op on a target that is not btrfs.

## Finish screen

`Installed Omarchy in 1:40.557  #bf95d41d`: minutes, seconds and thousandths from `total_elapsed_ns`, and the first eight characters of `run_id` dimmed beside it. `Reboot Now` stays the only action. The run code lets a photo or video of this screen be matched to a submission later, which is the cheapest witness there is. A hint line pointing at `omarchy leaderboard` comes with the command itself, not before.

## Installed system (basecamp/omarchy)

- `omarchy leaderboard status` and `preview` are offline: print the artifact, its class in words, six sector times aggregated from the 14 phases (Setup, Packages, System, Boot, User, Validate), and the 14 phases. `preview --json` prints exactly the document `submit` would send.
- `submit`: collect a sanitised fastfetch snapshot (`/etc/fastfetch/leaderboard.jsonc`: host, CPU, GPU, disk, memory, kernel; no hostname, IP, or user), print the payload, `gum confirm --default=false`, POST. Because the install key is gone, the payload wraps the sealed artifact plus unsigned metadata; the server verifies the inner signature and cross-checks the install-time hardware against fastfetch.
- `check`: GET the public per-release `top10.json`, compare locally, print the position.
- Offer: a user unit after `graphical-session.target` waits for `nm-online`, then shows one low-urgency notification, once, latched with `omarchy-done`. Default `OMARCHY_LEADERBOARD_CHECK=prompt`: the notification asks whether to check, and the GET happens on click. `OMARCHY_LEADERBOARD_CHECK=auto`: the public GET runs first and the notification appears only for a top-10 run. Either way nothing about the machine is sent before the submit confirmation. Never auto-submit, never a second notification, never a critical toast beside the existing Wi-Fi and update ones.
- Files split per `docs/file-layout.md`: binaries in `omarchy`; the unit, sudoers drop-in for the sign helper, fastfetch config, and `/etc/omarchy/leaderboard.conf` in `omarchy-settings`. Existing installs get a migration that enables the unit without starting it.

## Leaderboard service

Rails 8, Hotwire, SQLite, Kamal — the shape of `omarchy-plugin-registry`. Public `GET /r/:release/top10.json` (cacheable, no parameters) and `POST /api/v1/results` (verify signature over the raw inner bytes, reject duplicate `run_id`, 3 submissions per public key per day). Boards per release and class; sector bests; pages per CPU and machine; run pages with the phase waterfall.

Integrity is three tiers: Standard (automated checks passed), Reviewed (a maintainer looked), Witnessed (finish-screen footage with the run code). Every result enters as provisional and unlisted until it passes structure, class, hardware cross-check, and a plausibility floor (phase 3 reads about 3 GB from the medium; a total that implies impossible throughput is held). Rank 1 in the official class is always held for a human before it shows as the record.

## Phases

1. Lap time and run code (#177): `elapsed_ns`, `total_elapsed_ns`, phase `id`, `run_id`, `schema`, and the finish screen in lap-time format. Unit tests assert the sum and that existing fields are untouched. Useful on its own and independent of how the packages get onto the disk.
2. Classed, sealed artifact (#178, stacked on #177): ISO identity, release, class tuple, hardware snapshot, Ed25519 seal, factory copy. Unit tests assert the signature verifies with openssl, a one-byte edit breaks it, and no private key exists on the target. The class and hardware fields describe how the install was done, so the root-image installers (#113, #145) may need a small follow-up here.
3. `basecamp/omarchy`: status and preview; then submit with sign helper and fastfetch config; then menu entry; then the offer unit and migration.
4. Service: skeleton and schema; API; boards; review queue and ISO allow-list ingest from `omarchy-iso-release`.
5. First stable ISO that writes schema 1 becomes the first scored release. Earlier runs stay posts.

Each phase is one PR and is useful without the ones after it. Phases 1 and 2 are the ISO side and the Quattro RS scope; they improve the timing data and the finish screen even if the board never ships.

## Pending decisions

Decided: no handle identity in v1. A result is a machine and a time, not a person; names can come later behind a sign-in if wanted.

1. Name and hostname. Timing Tower and `tower.omarchy.org` are placeholders; open to anything.
2. Where the service lives and who builds it. Offered: built in the contributor's account and transferred into `omacom` when wanted, or started in-org from day one. Either way the ISO and CLI phases do not depend on it.
3. Default for `OMARCHY_LEADERBOARD_CHECK`: `prompt` (no unprompted network call on first boot, matching the rest of Omarchy) or `auto` (the brief's literal reading; the notification only appears for top-10 runs).
4. Whether page-cache warm should become a class axis once the data shows how much it moves results, and whether a RAM bucket is needed.
