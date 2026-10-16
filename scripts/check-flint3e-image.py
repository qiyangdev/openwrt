#!/usr/bin/env python3
"""Validate the actual GL-BE6500 sysupgrade payload before delivery."""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile


REQUIRED = '''kmod-ath12k ath12k-firmware-ipq5332 ath12k-firmware-qcn9274
    ipq-wifi-glinet_gl-be6500 kmod-rtl837x-dsa kmod-qcom-ppe kmod-hwmon-pwmfan
    fancontrol luci-app-fancontrol luci-app-homeproxy sing-box ucode-mod-math
    dnsmasq-full ip-full adguardhome'''.split()

def require(condition, message):
    if not condition:
        raise ValueError(message)


def fdt_properties(blob):
    magic, _, start, strings = struct.unpack_from('>4I', blob)
    require(magic == 0xd00dfeed, 'Invalid FIT/DTB magic')
    offset, nodes, properties = start, [], {}
    while True:
        token = struct.unpack_from('>I', blob, offset)[0]
        offset += 4
        if token == 1:
            end = blob.index(b'\0', offset)
            nodes.append(blob[offset:end].decode())
            offset = (end + 4) & ~3
        elif token == 2:
            nodes.pop()
        elif token == 3:
            size, name_offset = struct.unpack_from('>2I', blob, offset)
            offset += 8
            end = blob.index(b'\0', strings + name_offset)
            name = blob[strings + name_offset:end].decode()
            properties[('/'.join(nodes), name)] = blob[offset:offset + size]
            offset = (offset + size + 3) & ~3
        elif token == 9:
            return properties
        else:
            require(token == 4, 'Invalid FDT token')


def main():
    directory = Path(sys.argv[1] if len(sys.argv) > 1 else 'bin/targets/qualcommbe/ipq53xx')
    host = Path(os.environ.get('FLINT3E_HOST_BIN', 'staging_dir/host/bin')).resolve()
    prefix = 'openwrt-qualcommbe-ipq53xx-glinet_gl-be6500'
    image = directory / (prefix + '-squashfs-sysupgrade.bin')
    manifest = (directory / (prefix + '.manifest')).read_text()
    packages = {line.split(' - ')[0]: line.split(' - ')[1] for line in manifest.splitlines() if ' - ' in line}
    require(set(REQUIRED) <= packages.keys(), 'Missing packages: ' + ', '.join(sorted(set(REQUIRED) - packages.keys())))
    require(packages['sing-box'].startswith('1.12.'), 'Review HomeProxy compatibility before upgrading sing-box')
    with tempfile.TemporaryDirectory(prefix='flint3e-check-') as temp:
        temp = Path(temp)
        metadata = temp / 'metadata.json'
        subprocess.run([str(host / 'fwtool'), '-i', str(metadata), str(image)], check=True)
        info = json.loads(metadata.read_text())
        require('gl.inet,gl-be6500' in info['supported_devices'], 'Wrong supported device')
        require(info['version']['target'] == 'qualcommbe/ipq53xx', 'Wrong platform')
        with tarfile.open(image) as archive:
            kernel = archive.extractfile('sysupgrade-glinet_gl-be6500/kernel').read()
            root = archive.extractfile('sysupgrade-glinet_gl-be6500/root').read()
        require(len(kernel) <= 6096 * 1024, 'Kernel exceeds device limit')
        fit = fdt_properties(kernel)
        dtbs = [fit[(path, 'data')] for (path, name), value in fit.items()
                if name == 'type' and value == b'flat_dt\0']
        require(len(dtbs) == 1, 'Expected one embedded board DTB')
        dtb = fdt_properties(dtbs[0])
        require(b'gl.inet,gl-be6500\0' in dtb[('', 'compatible')], 'Wrong kernel DTB')
        require(not any(name == 'cooling-levels' or 'fan-active-' in path
                        for path, name in dtb), 'Kernel still controls fan')
        for name, temperature, kind in [('cpu-passive', 105000, b'passive\0'),
                                        ('cpu-top-critical', 115000, b'critical\0')]:
            path = '/thermal-zones/cpu-top-thermal/trips/' + name
            require(dtb[(path, 'temperature')] == struct.pack('>I', temperature)
                    and dtb[(path, 'type')] == kind, 'CPU thermal protection changed')
        root_file = temp / 'root.squashfs'
        root_file.write_bytes(root)
        required_files = ['lib/firmware/ath12k/IPQ5332/hw1.0/q6_fw0.mdt',
                          'lib/firmware/ath12k/IPQ5332/hw1.0/q6_fw0.b04',
                          'lib/firmware/ath12k/IPQ5332/hw1.0/board-2.bin',
                          'lib/firmware/ath12k/QCN9274/hw2.0/firmware-2.bin',
                          'lib/firmware/ath12k/QCN9274/hw2.0/board-2.bin',
                          'usr/lib/ucode/math.so', 'usr/bin/fancontrol', 'usr/bin/sing-box',
                          'usr/bin/AdGuardHome', 'etc/init.d/adguardhome',
                          'etc/config/fancontrol',
                          'etc/board.d/02_network']
        for entry in required_files:
            result = subprocess.run([str(host / 'unsquashfs4'), '-cat', str(root_file), entry],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            require(result.returncode == 0 and result.stdout, 'Missing image payload: ' + entry)
            if entry == 'etc/config/fancontrol':
                for option, value in [('enabled', '1'), ('thermal_zone', 'cpu-top-thermal'),
                                      ('fan_hwmon', 'pwmfan'), ('fail_safe_speed', '255'),
                                      ('exit_speed', '255')]:
                    require(f"option {option} '{value}'".encode() in result.stdout,
                            'Wrong fancontrol default: ' + option)
            if entry == 'etc/board.d/02_network':
                require(b'ucidef_set_interface "lan" ipaddr "192.168.8.1"' in result.stdout,
                        'Missing board LAN default')
        listing = subprocess.run([str(host / 'unsquashfs4'), '-ll', str(root_file),
                                  'etc/rc.d/S99fancontrol'],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
        require(b'S99fancontrol -> ../init.d/fancontrol' in listing.stdout,
                'fancontrol is not enabled at boot')
    print('PASS: device, packages, wireless payload, math module and fan/thermal DTB')
    print(hashlib.sha256(image.read_bytes()).hexdigest(), image.name)


if __name__ == '__main__':
    try:
        if len(sys.argv) > 1 and sys.argv[1] == '--config':
            config = Path(sys.argv[2]).read_text().splitlines()
            symbols = ['CONFIG_TARGET_qualcommbe', 'CONFIG_TARGET_qualcommbe_ipq53xx',
                       'CONFIG_TARGET_qualcommbe_ipq53xx_DEVICE_glinet_gl-be6500']
            symbols += ['CONFIG_PACKAGE_' + name for name in REQUIRED]
            missing = [symbol for symbol in symbols if symbol + '=y' not in config]
            require(not missing, 'Missing configuration: ' + ', '.join(missing))
            print('PASS: GL-BE6500 target and all required packages selected')
        else:
            main()
    except (ValueError, KeyError, OSError, struct.error, subprocess.CalledProcessError) as error:
        sys.exit('FAIL: ' + str(error))
