#!/bin/bash
# From Finder, open this file on the Mac after connecting and unlocking the iPhone.
set -e
cd "$(dirname "$0")"
if [[ ! -f SideA-0.7.3-iPhone.ipa ]]; then
    echo '请把安装工具和 SideA-0.7.3-iPhone.ipa 放在同一个文件夹，再打开安装工具。'
    exit 1
fi
/usr/bin/python3 - <<'PY'
import json, plistlib, pathlib, subprocess, sys, tempfile

def run(*args, **opts):
    return subprocess.run(list(args), check=True, **opts)
def plist(ptr):
    return plistlib.loads(ptr.read_bytes())
with tempfile.TemporaryDirectory(prefix='sidea-install-') as work:
    dest = pathlib.Path(work)
    run('/usr/bin/ditto', '-x', '-k', 'SideA-0.7.3-iPhone.ipa', work)
    app = dest/'Payload'/'SideA.app'
    info = plist(app/'Info.plist')
    if info.get('CFBundleIdentifier') != 'studio.sidea.personalplayer' or info.get('CFBundleShortVersionString') != '0.7.3':
        sys.exit('安装文件与 Side A 0.7.3 不匹配。')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    profile = plistlib.loads(run('/usr/bin/security', 'cms', '-D', '-i', str(app/'embedded.mobileprovision'), stdout=subprocess.PIPE).stdout)
    registered = {s.lower() for s in profile.get('ProvisionedDevices', [])}
    if not registered:
        sys.exit('这个安装包没有可用的设备签名。')
    devices = dest/'devices.json'
    print('正在寻找已连接的 iPhone…', flush=True)
    run('/usr/bin/xcrun','devicectl','--timeout','20','list','devices','--json-output',str(devices),stdout=subprocess.DEVNULL)
    available = []
    for item in json.loads(devices.read_text())['result']['devices']:
        hw = item.get('hardwareProperties',{})
        uid = hw.get('udid','')
        if hw.get('reality') == 'physical' and uid.lower() in registered and item.get('connectionProperties',{}).get('tunnelState') != 'unavailable':
            available.append((uid, item.get('deviceProperties',{}).get('name','iPhone')))
    if not available:
        sys.exit('未找到可安装的 iPhone。请用数据线连接这台 Mac，解锁 iPhone，按手机提示信任后重新打开本工具。')
    choice = 0
    if len(available) > 1:
        for i, (_, name) in enumerate(available, 1): print(i, name)
        print('请从列表中输入要更新的设备编号：', flush=True)
        with open('/dev/tty') as tty: answer = tty.readline().strip()
        if not answer.isdigit() or not 1 <= int(answer) <= len(available): sys.exit('没有选择设备，安装已取消。')
        choice = int(answer)-1
    print('正在把 Side A 0.7.3 安装到“'+available[choice][1]+'”…',flush=True)
    run('/usr/bin/xcrun','devicectl','--timeout','90','device','install','app','--device',available[choice][0],str(app))
    print('安装完成。请在 iPhone 上打开 Side A，点首页的搜索。',flush=True)
PY
