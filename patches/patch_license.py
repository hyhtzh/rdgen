#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给客户端挂启动门禁：没激活只能看到激活页。

用法：
  python patch_license.py <rustdesk 根目录> desktop
  python patch_license.py <rustdesk 根目录> android

desktop 模式要放在 patch_client_ui.py 之后跑（那边已经把 DesktopTabPage 换成了
ClientHomePage）。android 模式直接改 home 分支里的 HomePage()。

锚点找不到会直接退出，宁可构建失败，也不要悄悄出一个没门禁的包。
"""

import os
import re
import shutil
import sys

FILES = ['license_page.dart', 'license_client.dart']
IMPORT_LINE = "import 'package:flutter_hbb/desktop/pages/license_page.dart';"

# 桌面：main.dart 里 home 的三元分支
DESKTOP_OLD = '? const ClientHomePage()'
DESKTOP_NEW = '? LicenseGate(child: const ClientHomePage())'

# 安卓：同一处的 else 分支（缩进取实际的层级，别写死空格数）
ANDROID_RE = re.compile(r'\n(\s*): HomePage\(\),')


# 安卓：设置页「设置」分组顶部插入「授权详情」入口（弹窗本体在 license_page.dart）
MOBILE_SETTINGS_REL = os.path.join('flutter', 'lib', 'mobile', 'pages',
                                   'settings_page.dart')
MOBILE_SETTINGS_IMPORT = \
    "import 'package:flutter_hbb/desktop/pages/license_page.dart';"
MOBILE_SETTINGS_ANCHOR = \
    'SettingsSection(title: Text(translate("Settings")), tiles: ['
MOBILE_SETTINGS_TILE = '''          SettingsTile(
              title: Text('授权详情'),
              leading: Icon(Icons.verified_user),
              onPressed: (context) {
                showMobileLicenseDetail(context);
              }),'''


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


def write(p, s):
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(s)


def patch_mobile_license_entry(root):
    """安卓设置页加「授权详情」入口；找不到锚点直接报错，别出静默缺功能的包。"""
    mp = os.path.join(root, MOBILE_SETTINGS_REL)
    if not os.path.isfile(mp):
        raise SystemExit('mobile settings page not found: %s' % mp)
    s = read(mp)
    if "showMobileLicenseDetail" in s:
        print('skip mobile license entry (already patched)')
        return
    if MOBILE_SETTINGS_IMPORT not in s:
        lines = s.split('\n')
        idx = max(i for i, l in enumerate(lines) if l.strip().startswith('import '))
        lines.insert(idx + 1, MOBILE_SETTINGS_IMPORT)
        s = '\n'.join(lines)
    if s.count(MOBILE_SETTINGS_ANCHOR) != 1:
        raise SystemExit('mobile settings anchor not unique: %d'
                         % s.count(MOBILE_SETTINGS_ANCHOR))
    s = s.replace(MOBILE_SETTINGS_ANCHOR,
                  MOBILE_SETTINGS_ANCHOR + '\n' + MOBILE_SETTINGS_TILE, 1)
    write(mp, s)
    print('patch: mobile settings license entry')


def main():
    if len(sys.argv) < 2:
        raise SystemExit('usage: patch_license.py <rustdesk root> [desktop|android]')
    root = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else 'desktop'
    here = os.path.dirname(os.path.abspath(__file__))

    pages = os.path.join(root, 'flutter', 'lib', 'desktop', 'pages')
    if not os.path.isdir(pages):
        raise SystemExit('pages dir not found: %s' % pages)

    for name in FILES:
        src = os.path.join(here, 'ui', name)
        if not os.path.isfile(src):
            src = os.path.join(here, name)
        if not os.path.isfile(src):
            raise SystemExit('%s not found' % name)
        shutil.copyfile(src, os.path.join(pages, name))
        print('copied %s' % name)

    main_dart = os.path.join(root, 'flutter', 'lib', 'main.dart')
    src = read(main_dart)

    if IMPORT_LINE in src:
        print('skip import (already patched)')
    else:
        lines = src.split('\n')
        idx = max(i for i, l in enumerate(lines) if l.strip().startswith('import '))
        lines.insert(idx + 1, IMPORT_LINE)
        src = '\n'.join(lines)
        print('patch: main.dart import')

    if mode == 'desktop':
        if DESKTOP_NEW in src:
            print('skip home wrapper (already patched)')
        else:
            if src.count(DESKTOP_OLD) != 1:
                raise SystemExit('anchor not unique: %r found %d times'
                                 % (DESKTOP_OLD, src.count(DESKTOP_OLD)))
            src = src.replace(DESKTOP_OLD, DESKTOP_NEW, 1)
            print('patch: home -> LicenseGate (desktop)')
    else:
        if 'LicenseGate(child: HomePage())' in src:
            print('skip home wrapper (already patched)')
        else:
            src, n = ANDROID_RE.subn(r'\n\1: LicenseGate(child: HomePage()),', src)
            if n != 1:
                raise SystemExit('android anchor matched %d times, expected 1' % n)
            print('patch: home -> LicenseGate (android)')
        patch_mobile_license_entry(root)

    write(main_dart, src)
    print('license gate applied (%s)' % mode)


if __name__ == '__main__':
    main()
