# Tailscale ACAP for Axis Cameras

Tailscale VPN for Axis cameras, built from source as a single combined binary with unused features stripped out. Roughly 60% smaller than shipping Tailscale's own `tailscale` and `tailscaled`, or 90% smaller with UPX.

## Releases

Download from the [Releases](https://github.com/leela-ai/tailscale-axis/releases) page. The latest stable Tailscale is built for armv7hf and aarch64, four flavours each:

| Suffix       | Networking                                      | Binary         |
| ------------ | ----------------------------------------------- | -------------- |
| `-root`      | Kernel-space (TUN)                              | Standard       |
| _(none)_     | User-space (`--tun=userspace-networking`)       | Standard       |
| `-root-upx`  | Kernel-space (TUN)                              | UPX-compressed |
| `-upx`       | User-space (`--tun=userspace-networking`)       | UPX-compressed |

Use `-root` if the camera lets the app run as root, otherwise the userless build. Use `-upx` only if disk space is tight; see [UPX compression](#upx-compression).

## Size comparison

| Build                                            | On camera | `.eap`   |
| ------------------------------------------------ | --------- | -------- |
| Tailscale's own `tailscale` + `tailscaled`       | 46.8 MiB  | –        |
| Combined binary, no feature stripping            | 39.3 MiB  | –        |
| Combined binary, features stripped               | 18.5 MiB  | 7.0 MiB  |
| ... plus UPX                                     | 4.8 MiB   | 4.8 MiB  |

v1.102.2 on aarch64.

## How the binary is built

### One binary instead of two

The package contains a single `tailscaled` built with the `ts_include_cli` tag, which links the CLI into the daemon. It acts as the CLI when invoked as `tailscale` or with `TS_BE_CLI=1`, and as the daemon otherwise. A `lib/tailscale` symlink is shipped for interactive use, but the start script and status CGI both use `TS_BE_CLI`, so they work even if the installer drops symlinks.

### Feature selection

Features are stripped with Tailscale's own `cmd/featuretags`. `TS_FEATURES` in the [Dockerfile](Dockerfile) lists what to keep; everything else gets a `ts_omit_*` tag. Dependencies resolve automatically, so keeping `ssh` also keeps `c2n`, `dbus` and `netstack`.

| Feature                                  | Why                                                       |
| ---------------------------------------- | --------------------------------------------------------- |
| `cli`                                    | Combined binary                                           |
| `ipnbus`                                 | Required; without it `tailscale up` silently does nothing |
| `netstack`                               | User-space networking; also needed by `ssh`               |
| `osrouter`, `iptables`                   | Kernel-space networking (root build)                      |
| `dns`                                    | MagicDNS, `--accept-dns`                                  |
| `useroutes`, `useexitnode`               | `--accept-routes`, `--exit-node`                          |
| `advertiseroutes`, `advertiseexitnode`   | Camera as subnet router or exit node                      |
| `ssh`                                    | `--ssh`                                                   |
| `health`                                 | Health warnings on the settings page                      |
| `portmapper`, `listenrawdisco`           | NAT traversal                                             |
| `cachenetmap`                            | Faster reconnect after a reboot                           |
| `gro`                                    | User-space throughput                                     |
| `bakedroots`                             | Fallback CA roots if the camera's trust store is stale    |
| `tailnetlock`                            | Required to join a Tailnet-Lock-enabled tailnet           |
| `doctor`, `cliconndiag`                  | Diagnostics                                               |
| `unixsocketidentity`                     | Otherwise any local user gets full LocalAPI access        |
| `linkspeed`, `tundevstats`               | Linux TUN integration                                     |

Omitted: `logtail` and `netlog` (no log upload, so no `tailscale bugreport` — the app log is the only diagnostic channel), `taildrop`, `serve`/`funnel`/`webclient`, `useproxy`, `relayserver`, `clientupdate`, `syspolicy`, `qrcodes`, and platform integrations that do not apply to Axis firmware.

Override with `-F`. Unknown names abort the build rather than being ignored:

```bash
./build.sh -a aarch64 -u root -F "cli,ipnbus,netstack,osrouter,iptables,dns,useroutes,ssh,health"
```

### UPX compression

`-U` packs the binary with `upx --lzma --best`. About 75% smaller on disk, but the whole binary becomes resident in RAM, decompression is paid on every invocation (including each CLI call the status watcher makes), and it needs W^X relaxed. Off by default, published as a separate asset.

## UI

The app has a settings page showing connection state, login URL and app log. It reads from the app's `status.cgi`, which relays the daemon's own status.

## Building

```
./build.sh -a <arch> [-u <user>] [-s <sdk_ver>] [-t "<ts_opts>"] [-T <ts_version>] [-F "<features>"] [-U] [-v] [-h]
```

- `-a <arch>` — **required.** `arm` (ARMv7 32-bit) or `aarch64`.
- `-u <user>` — user that owns the Tailscale process. Omit for a user-space build (`--tun=userspace-networking`, no explicit user in the manifest).
- `-s <sdk_ver>` — ACAP Native SDK version (default `1.15`).
- `-t "<ts_opts>"` — options for `tailscale up` (default `--accept-routes`). No auth key here: it would be baked into the start script and echoed into the app log, which the settings page shows to any admin. Use [Deploying to a fleet](#deploying-to-a-fleet) instead.
- `-T <ts_version>` — Tailscale tag to build, e.g. `v1.80.0` (default: latest stable).
- `-F "<features>"` — features to keep. See [Feature selection](#feature-selection).
- `-U` — pack the binary with UPX.
- `-v` — verbose (`set -x`).
- `-h` — help.

```bash
./build.sh -a arm -u root
./build.sh -a aarch64 -s 1.15 -u admin -t "--ssh --accept-routes" -T v1.80.0
./build.sh -a aarch64 -U
```

### Verifying a package

`smoke-test.sh` unpacks a `.eap`, checks its layout, and runs the binary under qemu to confirm it starts, reports the stamped version, dispatches to the CLI both by `argv[0]` and by `TS_BE_CLI`, has the flags its feature set implies, and answers the status query the CGI makes. Needs qemu/binfmt emulation, which Docker Desktop provides. CI runs it for every variant.

```bash
./smoke-test.sh tailscale-v1.102.2-aarch64-root-sdk1.15.eap

# an injected package against the base it came from
./smoke-test.sh --injected-from base.eap base-warehouse-cam-01.eap

# how the start script merges build-time options, injected options and a key
./tools/start-script-test.sh
```

## Deploying to a fleet

Build once, then stamp a per-camera auth key into a copy of the package so each camera authenticates itself on first start. Every build ships empty `tailscale_up_opts.txt` and `tailscale_authkey` members and injection only rewrites those, so it is seconds per camera rather than a rebuild each.

**1. Describe the fleet.** Copy `tools/fleet-plan.example.csv` and fill in the first three columns. Semicolon-delimited, so commas stay usable inside `tags`:

```
hostname;tags;extra_opts;key_id;authkey
warehouse-cam-01;tag:camera,tag:warehouse;;;
warehouse-cam-02;tag:camera,tag:warehouse;--ssh;;
```

**2. Issue the keys.**

```bash
export TS_API_KEY=tskey-api-...   # or TS_OAUTH_CLIENT_ID + TS_OAUTH_CLIENT_SECRET
./tools/fleet-keys.sh fleet.plan.csv
```

Fills in `key_id` and `authkey`. Also takes `--dry-run`, `--expiry-days <n>` and `--revoke`.

**3. Build one package per camera.**

```bash
./build.sh -a aarch64 -u root
./tools/fleet-build.sh -e tailscale-v1.102.2-aarch64-root-sdk1.15.eap \
                       -p fleet.plan.csv -O "--accept-routes"
```

Writes `fleet-eaps/<base>-<hostname>.eap` per camera, plus a `deployment.csv` listing hostname, filename, tags, key ID and SHA-256. Upload each package to its camera; it connects on its own.

For one package without a plan:

```bash
./tools/eap-inject.sh -e base.eap -n spare-cam -o "--hostname=spare-cam" -K key.txt
```

The key is optional here, which makes this a way to add e.g. `--ssh` to a release build without rebuilding it.

### Notes

- Tags are required. Tagged nodes have key expiry disabled, so cameras do not drop off the tailnet when a node key would expire. Your ACL must grant the tags to whichever credential you use.
- Keys are single-use, pre-authorized and non-ephemeral. Ephemeral nodes are removed whenever they go offline, and a camera rebooting cannot reuse a spent single-use key.
- Re-running `fleet-keys.sh` skips rows that already have a key, so a partial failure does not burn keys.
- A filled-in plan is a secret: the script sets it to mode 600 and `.gitignore` covers `*.plan.csv`. `deployment.csv` holds no keys.
- The key is passed as `--auth-key=file:`, keeping it out of the process arguments and the app log. It does sit at rest in `/usr/local/packages/Tailscale/tailscale_authkey` after install; being single-use it is spent once the camera connects, and `--revoke` invalidates any that were never redeemed.
- Needs `curl` and `jq` to issue keys, and `tar` to inject (GNU tar, or macOS bsdtar). Each injected package is compared against its base before being written.

## Acknowledgements

Based on [Mo3he's](https://github.com/Mo3he/Axis_Cam_Tailscale) original work on bringing Tailscale to Axis cameras, with the feature-stripping approach inspired by [tiny-tailscale](https://github.com/iamromulan/tiny-tailscale).

Tailscale is a trademark of Tailscale Inc.  
Axis is a trademark of Axis Communications AB.

Leela AI is not affiliated with Tailscale Inc or Axis Communications AB. This package is not officially endorsed or supported by either company, and is provided on an "as is" basis by Leela AI, Inc. We provide no warranty or guarantee of any kind, express or implied.

## License

Tailscale is licensed under the [BSD 3-Clause License](https://github.com/tailscale/tailscale/blob/main/LICENSE).
