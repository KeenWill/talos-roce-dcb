# talos-roce-dcb

A [Talos Linux](https://www.talos.dev/) system extension that configures every
Mellanox `mlx5_core` interface on a node for lossless RoCE and keeps it that
way. It ships as the extension service `ext-roce-dcb` and is published as
`ghcr.io/keenwill/roce-dcb`.

## What it does

RoCE (RDMA over Converged Ethernet) needs a lossless traffic class end to end.
The switch and every NIC must agree on which 802.1p priority carries RDMA,
enable Priority Flow Control (PFC) on exactly that priority, and classify RDMA
packets into it from their DSCP marking. Talos has no persistent host shell, so
this extension does the NIC side on every boot and re-applies it periodically
in case the driver, firmware, or a link flap resets it.

For each interface whose driver is `mlx5_core` the service runs `dcb` from
iproute2 to:

- enable PFC on the RoCE priority and disable it on all others
  (`dcb pfc set ... prio-pfc all:off 3:on`);
- install DSCP-to-priority application mappings, by default DSCP 26 (AF31) to
  priority 3 for RDMA traffic and DSCP 48 (CS6) to priority 6 for control
  traffic (`dcb app replace ... dscp-prio 26:3 48:6`);
- set the application trust order to `dscp pcp` when the NIC exposes
  `apptrust`, so DSCP decides the priority ahead of any VLAN PCP bits.

It then validates the result (priority-to-traffic-class mapping, PFC state, and
the DSCP table as reported by the NIC) and counts the configured ports against
an expected number so a missing or renamed NIC is an error rather than a silent
no-op. After the first pass the service sleeps and repeats; a failed first pass
exits so Talos restarts the service and logs the failure, later failures are
retried in place until the configuration validates again.

The switch side (PFC on the same priority, DSCP trust or an equivalent
classifier, and ideally ECN) is out of scope but required for this to be useful.

## Configuration

All knobs are environment variables with these defaults:

| Variable                            | Default     | Meaning                                                                                   |
| ----------------------------------- | ----------- | ----------------------------------------------------------------------------------------- |
| `ROCE_DCB_EXPECTED_MLX5_PORTS`      | `1`         | Number of `mlx5_core` interfaces that must be found and configured; any other count fails. |
| `ROCE_DCB_REAPPLY_INTERVAL_SECONDS` | `60`        | Seconds between successful re-application passes.                                          |
| `ROCE_DCB_RETRY_INTERVAL_SECONDS`   | `15`        | Seconds between retries after a pass fails.                                                |
| `ROCE_DCB_PFC_PRIORITY`             | `3`         | The single 802.1p priority (0-7) to enable PFC on; all others are disabled.                |
| `ROCE_DCB_DSCP_PRIO_MAP`            | `26:3 48:6` | Space-separated `DSCP:PRIO` pairs installed with `dcb app replace` and then validated.     |
| `ROCE_DCB_DCB_BIN`                  | `dcb`       | Path to the `dcb` binary inside the service rootfs.                                        |

Validation is derived from the same values: it checks that `ROCE_DCB_PFC_PRIORITY`
maps to the traffic class of the same number, that PFC is `on` for it, and that
every pair in `ROCE_DCB_DSCP_PRIO_MAP` appears in `dcb -N app show ... dscp-prio`.

The service definition (`roce-dcb.yaml`) bakes in the defaults for the first
two. To change any of them without rebuilding the image, add an
`ExtensionServiceConfig` document to the node's machine config; its
`environment` entries are passed to the service:

```yaml
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: roce-dcb
environment:
  - ROCE_DCB_EXPECTED_MLX5_PORTS=2
  - ROCE_DCB_DSCP_PRIO_MAP=26:3
```

Verify the exact `ExtensionServiceConfig` semantics against the Talos docs for
your version.

## Using it

### Get the image

Pull a released image (tags follow this repo's `v*` tags) or build it locally:

```sh
docker pull ghcr.io/keenwill/roce-dcb:v0.1.0

# or
./build.sh                      # loads ghcr.io/keenwill/roce-dcb:<manifest version> into docker
IMAGE=ghcr.io/you/roce-dcb:dev PUSH=true ./build.sh   # pushes and prints the digest-pinned reference
```

The image is a plain single-platform `linux/amd64` image (no provenance
attestations), which is what Talos expects for extension images. Always refer
to it by digest when building Talos images.

### Add it to Talos

Custom extension images are not available through the hosted Image Factory
(`factory.talos.dev` only serves the official `siderolabs/*` extensions), so
build the installer or disk image yourself with the Talos `imager`, passing
this image and every other extension the node needs as
`--system-extension-image`:

```sh
mkdir -p _out
docker run --rm -t --privileged -v "${PWD}/_out:/out" \
  ghcr.io/siderolabs/imager:v1.12.6 installer --arch amd64 \
  --system-extension-image ghcr.io/siderolabs/iscsi-tools:<version>@sha256:<digest> \
  --system-extension-image ghcr.io/keenwill/roce-dcb:v0.1.0@sha256:<digest>

# _out/installer-amd64.tar -> push it to a registry the nodes can reach
crane push _out/installer-amd64.tar ghcr.io/you/talos-installer:v1.12.6-roce-dcb
```

Then install or upgrade nodes from that installer image, one at a time:

```sh
talosctl upgrade --nodes <node> --image ghcr.io/you/talos-installer:v1.12.6-roce-dcb@sha256:<digest>
```

Use the `metal` profile instead of `installer` to produce a bootable disk image
for fresh installs. Extensions are only applied at install or upgrade time, not
by a live machine config apply. Check the imager and Image Factory docs for your
Talos version in case custom extension support has changed.

### Verify on a node

```sh
talosctl -n <node> get extensions            # lists roce-dcb with its version
talosctl -n <node> service ext-roce-dcb      # state should be Running
talosctl -n <node> logs ext-roce-dcb
```

A healthy first pass logs the configuration and the resulting PFC, ETS, and
DSCP state for each interface, for example:

```text
Configuring RoCE DCB settings on enp1s0f0np0
Configured DCB app trust order on enp1s0f0np0: dscp pcp
Resulting DCB PFC state for enp1s0f0np0:
pfc-cap 8 prio-pfc 0:off 1:off 2:off 3:on 4:off 5:off 6:off 7:off delay 0
Resulting DCB ETS state for enp1s0f0np0:
prio-tc 0:0 1:1 2:2 3:3 4:4 5:5 6:6 7:7
Resulting DCB app state for enp1s0f0np0:
dscp-prio AF31:3 CS6:6
```

Subsequent passes are silent unless they fail. To look at the live NIC state
from Kubernetes, run `dcb` in a host-network debug pod:

```sh
kubectl debug node/<node> -it --profile=sysadmin --image=alpine -- \
  sh -c 'apk add -q iproute2 iproute2-rdma && dcb pfc show dev <if> && dcb app show dev <if>'
```

## Requirements and caveats

- Mellanox ConnectX NICs using the in-tree `mlx5_core` driver. Other drivers
  are ignored (and do not count towards `ROCE_DCB_EXPECTED_MLX5_PORTS`).
- The NIC must accept host-side DCB configuration. If the firmware owns DCBX
  (for example LLDP-driven DCBX enabled in `mlxconfig`), host changes may be
  overridden or rejected; the service log will show the failing `dcb` command.
- One PFC priority only. Multiple lossless priorities are not supported.
- The service needs `writeableSysfs` and runs in its own minimal rootfs
  (busybox plus iproute2's `dcb` and `rdma`); it does not touch the host
  filesystem.

## Compatibility

Built and tested against Talos v1.12.x; the manifest declares
`compatibility.talos.version: ">= v1.12.0"`. The image version is the manifest
`metadata.version`, which must match the git tag when releasing (the workflow
checks this).

## Layout

| File                          | Purpose                                                   |
| ----------------------------- | --------------------------------------------------------- |
| `manifest.yaml`               | Talos extension manifest (name, version, compatibility).  |
| `roce-dcb.yaml`               | Extension service definition installed as `ext-roce-dcb`. |
| `configure-roce-dcb`          | POSIX sh service script.                                  |
| `Dockerfile`                  | Builds the extension image from Alpine's iproute2.        |
| `build.sh`                    | Local build/push helper.                                  |
| `.github/workflows/image.yml` | Builds on PRs; builds and pushes on `v*` tags.            |

## License

[MIT](LICENSE)
