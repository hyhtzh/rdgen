#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 RustDesk 的桌面首页替换成极简被控端页面。

用法: python patch_simple_ui.py <rustdesk 源码根目录>

做两件事：
1. 在 main.dart 里补一行 import；
2. 把 `? const DesktopTabPage()` 换成 `? const SimpleHostPage()`，
   这样整个桌面窗口就是自绘的 ID/密码面板，侧栏、连接入口、帮助卡片全部消失。
"""

import os
import re
import sys

IMPORT_LINE = "import 'package:flutter_hbb/desktop/pages/simple_host_page.dart';"


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    main_dart = os.path.join(root, 'flutter', 'lib', 'main.dart')
    page_dart = os.path.join(root, 'flutter', 'lib', 'desktop', 'pages',
                             'simple_host_page.dart')

    if not os.path.isfile(main_dart):
        raise SystemExit('main.dart not found: %s' % main_dart)
    if not os.path.isfile(page_dart):
        raise SystemExit('simple_host_page.dart not found: %s' % page_dart)

    with open(main_dart, encoding='utf-8') as f:
        src = f.read()

    if IMPORT_LINE not in src:
        m = re.search(
            r"^import 'package:flutter_hbb/desktop/pages/desktop_tab_page\.dart';\s*$",
            src, re.M)
        if m:
            src = src[:m.end()] + '\n' + IMPORT_LINE + src[m.end():]
        else:
            # 兜底：插到最后一条 import 之后
            idx = src.rfind('\nimport ')
            end = src.find('\n', idx + 1)
            src = src[:end + 1] + IMPORT_LINE + '\n' + src[end + 1:]

    replaced = src.count('const DesktopTabPage()')
    src = src.replace('const DesktopTabPage()', 'const SimpleHostPage()')

    if 'const SimpleHostPage()' not in src:
        raise SystemExit('patch failed: DesktopTabPage call site not found')

    with open(main_dart, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)

    print('patched main.dart, replaced %d call site(s)' % replaced)


if __name__ == '__main__':
    main()
