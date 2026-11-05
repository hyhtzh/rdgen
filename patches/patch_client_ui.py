#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 RustDesk 的桌面首页替换成控制端界面（含屏幕墙）。

用法: python patch_client_ui.py <rustdesk 源码根目录>

做三件事：
1. 把 client_home_page.dart / screen_wall_page.dart 复制到 flutter/lib/desktop/pages/；
2. 在 main.dart 里补一行 import；
3. 把 `? const DesktopTabPage()` 换成 `? const ClientHomePage()`。
"""

import os
import re
import shutil
import sys

IMPORT_LINE = "import 'package:flutter_hbb/desktop/pages/client_home_page.dart';"

PAGES = [
    'client_home_page.dart',
    'screen_wall_page.dart',
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    main_dart = os.path.join(root, 'flutter', 'lib', 'main.dart')
    dest_dir = os.path.join(root, 'flutter', 'lib', 'desktop', 'pages')
    src_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ui')

    if not os.path.isfile(main_dart):
        raise SystemExit('main.dart not found: %s' % main_dart)
    if not os.path.isdir(dest_dir):
        raise SystemExit('pages dir not found: %s' % dest_dir)

    for name in PAGES:
        src = os.path.join(src_dir, name)
        if not os.path.isfile(src):
            # 兼容放到 patches/ 根目录的情况
            src = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
        if not os.path.isfile(src):
            raise SystemExit('%s not found' % name)
        shutil.copyfile(src, os.path.join(dest_dir, name))
        print('copied %s' % name)

    with open(main_dart, encoding='utf-8') as f:
        src = f.read()

    if IMPORT_LINE not in src:
        m = re.search(
            r"^import 'package:flutter_hbb/desktop/pages/desktop_tab_page\.dart';\s*$",
            src, re.M)
        if m:
            src = src[:m.end()] + '\n' + IMPORT_LINE + src[m.end():]
        else:
            idx = src.rfind('\nimport ')
            end = src.find('\n', idx + 1)
            src = src[:end + 1] + IMPORT_LINE + '\n' + src[end + 1:]

    replaced = src.count('const DesktopTabPage()')
    src = src.replace('const DesktopTabPage()', 'const ClientHomePage()')

    if 'const ClientHomePage()' not in src:
        raise SystemExit('patch failed: DesktopTabPage call site not found')

    with open(main_dart, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)

    print('patched main.dart, replaced %d call site(s)' % replaced)


if __name__ == '__main__':
    main()
