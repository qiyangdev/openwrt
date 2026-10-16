# Flint 3E build profile

This profile targets Flint 3E **GL.iNet GL-BE6500** on
`qualcommbe/ipq53xx`, matching the device-reported board name
`gl.inet,gl-be6500`. GL-MT3600BE / mediatek images are for a different
device and must not be flashed to GL-BE6500.

## Packages

- `luci-ssl`: LuCI administration over HTTPS, including the package manager.
- `CONFIG_LUCI_LANG_zh_Hans`: simplified Chinese translations for selected LuCI packages.
- `fancontrol` and `luci-app-fancontrol`: temperature-based PWM control and its LuCI interface, from https://github.com/JiaY-shi/fancontrol.
- `htop`: CPU, memory and process inspection.
- `ethtool-full`: Ethernet link and driver diagnostics.
- `lm-sensors`: inspect hwmon temperatures and fan RPM with `sensors`.
- `luci-app-homeproxy`: proxy node/subscription management and transparent routing, with simplified Chinese translations.
- `adguardhome`: DNS filtering with its built-in web interface, from the existing packages feed.
- `sing-box`: HomeProxy-compatible core with QUIC, uTLS, Clash API and WireGuard support; TUN uses the system stack.

The fancontrol feed follows the upstream default branch in `feeds.conf.default`.
Running `./scripts/feeds update fancontrol` obtains its latest commit.
HomeProxy also follows its upstream default branch; the remaining feeds retain
the repository defaults. The image keeps the device's PWM fan, ath12k Wi-Fi
firmware and calibration data, RTL837x DSA switch, Qualcomm PPE and USB drivers.

## Build and network defaults

Run `./scripts/bootstrap-flint3e.sh` from a complete checkout to prepare the
host, update feeds, build and validate the firmware. Use `--help` for options.
If `feeds.conf` exists, ensure it contains the fancontrol and HomeProxy feeds;
it overrides `feeds.conf.default`.

The GL-BE6500 board network definition generates LAN at `192.168.8.1`.
Existing LAN configurations are preserved during upgrades. An upstream using
`192.168.8.0/24` still requires a different LAN subnet.

## Fan control

The personal GL-BE6500 device tree leaves fan PWM entirely to fancontrol:
fan cooling levels and active fan trips/maps are removed. The CPU thermal
zone remains enabled with its inherited passive (105°C) and critical (115°C)
trips. Existing CPU cooling bindings, if present, are not removed. The PWM
fan driver starts at full duty until userspace takes over.

The image supplies `/etc/config/fancontrol` directly, enabling the service,
selecting `cpu-top-thermal` and
`pwmfan` by name, and retaining full-duty sensor-failure and service-exit values.
Keep the repository’s `files/` overlay in the build checkout. Retained
configurations take precedence during sysupgrade; no UCI-defaults script
rewrites network or fancontrol settings.
The usual 45–85°C curve and 500 ms startup kick remain configurable in LuCI.
Use this profile with its device-tree changes; do not apply these defaults
alone to a kernel which still controls the fan. A sudden daemon crash can
leave the last PWM until procd restarts it; normal exit fallback does not
cover every failure or fan stall.

After booting, inspect hardware without changing fan speed:

```sh
sensors
for zone in /sys/class/thermal/thermal_zone*; do
    echo "$zone: $(cat "$zone/type") $(cat "$zone/temp")"
done
for hwmon in /sys/class/hwmon/hwmon*; do
    echo "$hwmon: $(cat "$hwmon/name")"
    for node in "$hwmon"/pwm* "$hwmon"/fan*_input; do
        [ ! -f "$node" ] || echo "$node: $(cat "$node")"
    done
done
```

Use the Fan Control page in LuCI to inspect settings. The upstream defaults
select the sensor and PWM output automatically, start at 45°C with PWM 64,
reach PWM 255 at 85°C, apply 3°C hysteresis, and use a 500 ms startup kick.
Sensor read failures and normal daemon shutdown request full PWM. These are
software defaults, not measured fan thresholds for this board. Verify sensor
selection, reliable starting RPM, and kernel/userspace ownership on hardware
before enabling the service. A daemon crash or undetected fan stall is not
covered by the sensor-read fallback alone.

The upstream test suite uses a fake sysfs tree to check sensor/PWM discovery,
the control curve, hysteresis, sensor-read failure and rejection of cooling
state indices as PWM outputs. Passing these tests and producing a firmware
image does not verify actual fan speed or device boot behavior.

## HomeProxy compatibility and setup

HomeProxy follows https://github.com/immortalwrt/homeproxy on its default branch.
Its current configuration generator uses legacy inbound fields, including
`sniff`, and a `block` outbound. These were removed in sing-box 1.13, so the
OpenWrt packages feed's sing-box 1.14 cannot be used unchanged with this UI.

`package/network/services/sing-box/` is a local compatibility recipe for
sing-box 1.12.25. Its source archive version and SHA256 match the current
ImmortalWrt packages recipe. It takes precedence over the packages feed recipe;
do not force-install the latter with `scripts/feeds install -f sing-box`.
Review compatibility before upgrading this core or HomeProxy. If it is already
installed from the packages feed in another checkout, run
`./scripts/feeds uninstall sing-box` before installing HomeProxy. The two
recipe locations must not be installed together.

The recipe uses the existing OpenWrt Go build infrastructure. On this Mac,
Homebrew Go is used as the bootstrap to avoid building several bootstrap Go
versions. After loading the profile, set these in `.config` before `defconfig`:

```text
CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="<Homebrew prefix>/opt/go/libexec"
# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set
```

The DNS/DHCP service uses `dnsmasq-full` with nftset support, replacing the
base dnsmasq package. HomeProxy writes nftset directives in GFWList mode and
for custom proxy domains. `ip-full` supplies the `ip tuntap` commands required
by TUN mode, in addition to IPv4/IPv6 policy routing. The profile explicitly
includes `ucode-mod-math`, required by the client generator but missing from
the upstream package dependency list. HomeProxy brings in firewall4,
`kmod-nft-tproxy`, `kmod-tun`, and `ucode-mod-digest` through dependencies.
Its default `main_node=nil`, disabled server, and disabled subscription updates
leave proxying unconfigured. The separate sing-box init service also remains
disabled; HomeProxy starts its own core instance after a node is selected.

After booting, open Services → HomeProxy in LuCI, import your own subscription
or configure a node, choose the main node and routing mode, and apply changes.
Do not enable the standalone sing-box init service alongside HomeProxy.
For TUN mode choose the **system** stack; this profile does not build gVisor or
Tailscale support. Confirm the selected node's transport is built into the core
before using it; optional standard gRPC, ACME and DHCP features are not enabled
by this profile.

For troubleshooting on the device:

```sh
/usr/bin/sing-box version
logread -e homeproxy
cat /var/run/homeproxy/homeproxy.log
# After HomeProxy has generated a client configuration:
sing-box check -c /var/run/homeproxy/sing-box-c.json
```

Compile and configuration validation do not verify a subscription, actual
proxy connectivity, DNS behavior, IPv6 routing, or firewall rules on hardware.

### Integration validation

The GL-BE6500 `qualcommbe/ipq53xx` full image build completed.
The sysupgrade metadata includes `gl.inet,gl-be6500` and the correct target.
The manifest includes ath12k firmware/calibration, RTL837x DSA, PWM fan,
fancontrol, HomeProxy, sing-box 1.12.25, dnsmasq-full and ip-full.
The kernel is 6,136,864 bytes (below the 6,242,304-byte kernel limit),
the SquashFS root is about 23.7 MB, and the sysupgrade archive is about 29.9 MB.
Use each build's `sha256sums` to verify its images; feed updates can change them.
The device recipe does not check the complete archive against IMAGE_SIZE.
The tested device's MTD rootfs partition is 492 MiB; UBI supplies 1,959
logical eraseblocks of 253,952 bytes (474.4 MiB). The new kernel needs 25
LEBs and rootfs needs 94 LEBs. Keeping the one-LEB provisioning volume
leaves 1,839 LEBs (about 445.4 MiB) for rootfs_data. Capacity is sufficient.
Zero currently available UBI LEBs means the existing volumes occupy the
space; the NAND upgrade script removes and recreates kernel, rootfs and
rootfs_data before writing. No manual volume deletion is needed.
The corrected userspace-fancontrol image has booted on hardware; both AP
bands started after the deleted 5 GHz interface was recreated.

For an existing OpenWrt installation, upload the **sysupgrade.bin** image
and run `sysupgrade -T /tmp/firmware.bin` first. Do not force compatibility
with `-F`. Back up configuration before an upgrade.

In a temporary mock UCI/ubus environment, the upstream client generator produced
TProxy, TUN and mixed configurations, plus Shadowsocks, VLESS, Trojan and
Hysteria2 examples and bypass-mainland/GFWList routing examples. They were
accepted by a native sing-box 1.12.25 built with the same feature tags. The
Linux-only `routing_mark` fields were removed **only from the macOS check
copies**; the real firmware generator and Linux configuration are unchanged.
This checks configuration format, not kernel routing or real connectivity.

The final rebuilt SquashFS was inspected directly: `/usr/lib/ucode/math.so`
was present alongside the previous LAN initialization script. Subsequent
builds use the board network default and direct fancontrol configuration. On the running router,
installing the same math package fixed configuration generation; moving LAN
to 192.168.8.1 resolved the WAN/LAN overlap. Both HomeProxy BaiDu and Google
connection checks passed. These checks establish this version and network
setup; revalidate dependency and sing-box compatibility after feed updates.

## Required build gates

Use `scripts/build-flint3e.sh` from a checkout of the personal firmware branch.
It checks the selected target and every required package after defconfig, then
checks the actual sysupgrade archive after compilation. Failure returns a
nonzero exit status. Do not upload an image from a failed build or bypass the
checker. Direct `gmake` alone does not run these profile-specific checks.

The checker verifies device metadata, kernel size, embedded DTB compatibility,
fan ownership and CPU thermal trips, as well as wireless firmware, board data,
math module and first-boot defaults inside SquashFS. Package-manifest entries
alone are insufficient. Use the same checkout for source and build; if copying
source is unavoidable, exclusions must be rooted (e.g. `/firmware/` for output),
never `firmware`, which would also omit `package/firmware/`.

The corrected firmware was booted on GL-BE6500: both 2.4 GHz and 5 GHz APs
started, fancontrol reported temperature/RPM without faults, and the CPU thermal
zone had no fan cooling bindings. Wi-Fi interfaces deleted from saved user
configuration must still be recreated; preserving config does not restore them.

## AdGuard Home

The profile includes the official packages-feed `adguardhome` package and
its built-in web interface. No additional feed or LuCI wrapper is required.
Package inclusion does not configure DNS filtering: the existing dnsmasq and
HomeProxy DNS settings remain unchanged. Use the initial setup interface
(on port 3000 by upstream default) after booting to configure authentication.

For integration, retain dnsmasq for DHCP, local names and HomeProxy's nftset
rules. A candidate chain is clients → AdGuard Home on port 53 → dnsmasq on
127.0.0.1:5353 → HomeProxy on 127.0.0.1:5333 where its routing rules require it.
AdGuard Home's default upstream must point to dnsmasq, not the reverse, to
avoid a forwarding loop. Keep AdGuard Home DHCP disabled. Check HomeProxy
DNS interception rules, local name resolution, IPv6 and both direct and
proxied domains on hardware before enabling this chain.

The upstream work directory is `/var/lib/adguardhome` (volatile on OpenWrt).
Review query log retention and filter storage before moving it to persistent
flash. Preserve `/etc/adguardhome/` during upgrades. The image checker requires
the package and executable; functional DNS integration needs a separate
on-device check.
