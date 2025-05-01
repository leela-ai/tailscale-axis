# Tailscale ACAP for Axis Cameras

An optimized version of Tailscale VPN for Axis Cameras via a custom Tailscale build from source. This results in up to 25% smaller size than the official builds. Containing both tailscale and tailscaled, the app has an unpacked size of less than 35MB.

## Supported architectures

- armv7hf
- aarch64

### Releases

Releases are available for download from the [Releases](https://github.com/leela-ai/axis-tailscale/releases) page. We auto-build the latest stable version of Tailscale against armv7hf and aarch64, and produce two builds:

- Root user build (uses kernel-space networking)
- Non-root user build (uses user-space networking with `--tun=userspace-networking` passed to tailscaled)

Pick the build that matches your use case.

## Building

```
./build.sh -a <arch> -u <user> [-s <sdk_ver>] [-t "<ts_opts>"] [-T <ts_version>] [-v] [-h]
```

Builds an Axis ACAP Tailscale package (.eap) with specified parameters.

**Required arguments:**
  - `-a <arch>`     Target architecture: 'arm' (ARMv7 32-bit) or 'aarch64' (ARM 64-bit).
  - `-u <user>`     (Optional) Username that will own the Tailscale process inside the package. If omitted, no explicit user/group will be added to the manifest.

**Optional arguments:**
  - `-s <sdk_ver>`  Axis ACAP Native SDK version to use (Default: "1.15").
  - `-t "<ts_opts>"` Tailscale startup options passed to 'tailscale up'. Quote the options if they contain spaces (Default: '--accept-routes'). Example: `"--ssh --accept-routes --authkey=tskey-xxxxx"`
  - `-T <ts_version>` Specify the Tailscale version tag to build (e.g., 'v1.80.0'). If omitted, the Dockerfile will attempt to use the latest stable tag.
  - `-v`            Enable verbose mode (set -x). Prints commands as they execute.
  - `-h`            Show this help message and exit.

**Examples:**

```bash
# Minimal build (ARMv7, SDK 1.15, user 'root', default 'up' options, latest Tailscale)
./build.sh -a arm -u root

# 64-bit build, custom SDK, custom 'up' options, user 'admin', specific Tailscale version
./build.sh -a aarch64 -s 1.4 -u admin -t "--ssh --accept-routes" -T v1.80.0
```

## Acknowledgements

This repository is based on [Mo3he's](https://github.com/Mo3he/Axis_Cam_Tailscale) original work on bringing Tailscale to Axis cameras.

Tailscale is a trademark of Tailscale Inc.  
Axis is a trademark of Axis Communications AB.

Leela AI is not affiliated with Tailscale Inc or Axis Communications AB. This package is not officially endorsed or supported by either company, and is provided on an "as is" basis by Leela AI, Inc. We provide no warranty or guarantee of any kind, express or implied.

## License

Tailscale is licensed under the [BSD 3-Clause License](https://github.com/tailscale/tailscale/blob/main/LICENSE).
