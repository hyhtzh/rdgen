#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""安卓端屏幕墙接线：把桌面版的墙页面挂进手机主界面。

用法（在 rustdesk 检出根目录跑，和 patch_license.py 同一层）：
  python3 patch_wall_mobile.py <rustdesk 根目录>

做三件事：
  1. screen_wall_page.dart / address_book_page.dart 拷进
     flutter/lib/desktop/pages/（安卓构建里本来没有这两个文件；
     它们 import 的东西全是跨平台的，dart:io 只用了 Platform/exit 且
     已按平台守卫，desktop_multi_window 的调用全部包在
     _windowId != null 分支里 —— 安卓上 kWindowId 恒 null，
     页面自动走「主窗口压栈」形态，行为等同桌面端的降级路径）。
  2. flutter/lib/mobile/pages/home_page.dart 给 ConnectionPage 的
     AppBar 加一个「屏幕墙」按钮（网格图标），点击压栈进 ScreenWallPage。
  3. 手机端档位限制在 wall 页内部完成（_kCapacities=[4,9]、
     _kMaxLive=4），本脚本不用管。

锚点找不到直接报错退出——宁可构建失败，也不出缺入口的包。
"""

import os
import shutil
import sys

WALL_FILE = 'screen_wall_page.dart'
AB_FILE = 'address_book_page.dart'

HOME_REL = os.path.join('flutter', 'lib', 'mobile', 'pages', 'home_page.dart')
WALL_IMPORT = \
    "import 'package:flutter_hbb/desktop/pages/screen_wall_page.dart';"

# 只认 initPages 里这一处（WebHomePage 里那个 ConnectionPage 不带换行，
# 不会匹配到）
HOME_ANCHOR = """      _pages.add(ConnectionPage(
        appBarActions: [],
      ));"""

HOME_NEW = """      _pages.add(ConnectionPage(
        appBarActions: [
          IconButton(
            tooltip: '屏幕墙',
            icon: const Icon(Icons.grid_view_rounded),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const ScreenWallPage(),
              fullscreenDialog: true,
            )),
          ),
        ],
      ));"""


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


def write(p, s):
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(s)


def copy_pages(root, here):
    pages = os.path.join(root, 'flutter', 'lib', 'desktop', 'pages')
    if not os.path.isdir(pages):
        raise SystemExit('pages dir not found: %s' % pages)
    for name in (WALL_FILE, AB_FILE):
        src = os.path.join(here, name)
        if not os.path.isfile(src):
            raise SystemExit('%s not found next to script: %s' % (name, src))
        shutil.copyfile(src, os.path.join(pages, name))
        print('copied %s' % name)


def patch_home(root):
    hp = os.path.join(root, HOME_REL)
    if not os.path.isfile(hp):
        raise SystemExit('mobile home page not found: %s' % hp)
    s = read(hp)
    if 'ScreenWallPage' in s:
        print('skip home wall entry (already patched)')
        return
    if WALL_IMPORT not in s:
        lines = s.split('\n')
        idx = max(i for i, l in enumerate(lines) if l.strip().startswith('import '))
        lines.insert(idx + 1, WALL_IMPORT)
        s = '\n'.join(lines)
    n = s.count(HOME_ANCHOR)
    if n != 1:
        raise SystemExit('home anchor matched %d times, expected 1' % n)
    s = s.replace(HOME_ANCHOR, HOME_NEW, 1)
    write(hp, s)
    print('patch: mobile home -> screen wall entry')


# 会话标签名缓存：桌面端由 patch_client_ui.py 注入 common.dart，安卓端没跑
# 那个脚本，但 address_book_page.dart 的 _publishTabAliases() 会调用
# hySetTabAlias —— 不补齐就会在 kernel_snapshot 阶段报
#   "The method 'hySetTabAlias' isn't defined for the class 'AddressBookStore'"
# （run 46090196544 三个架构同时失败）。这里注入与 Windows 侧完全一致的实现，
# 只补顶层符号，不改 getDesktopTabLabel 行为：安卓没有桌面会话标签页。
TAB_ALIAS_CACHE_DART = '''
// 【HyDesk】会话标签名缓存（安卓端补齐顶层符号，2026-11-28）
final Map<String, String> hyTabAliasCache = <String, String>{};

void hySetTabAlias(String peerId, String alias) {
  final k = peerId.replaceAll(' ', '').trim();
  if (k.isEmpty) return;
  final v = alias.trim();
  if (v.isEmpty) {
    hyTabAliasCache.remove(k);
  } else {
    hyTabAliasCache[k] = v;
  }
}

String hyTabAliasOf(String peerId) =>
    hyTabAliasCache[peerId.replaceAll(' ', '').trim()] ?? '';
'''


def patch_common_tab_alias(root):
    """补齐 address_book_page.dart 依赖的 common.dart 顶层符号。"""
    p = os.path.join(root, 'flutter', 'lib', 'common.dart')
    if not os.path.isfile(p):
        raise SystemExit('common.dart not found: %s' % p)
    s = read(p)
    if 'hySetTabAlias' in s:
        print('skip common.dart tab alias (already patched)')
        return
    # 追加到文件末尾：Dart 顶层声明与顺序无关，零锚点风险
    write(p, s.rstrip() + '\n\n' + TAB_ALIAS_CACHE_DART.strip() + '\n')
    print('patch: common.dart -> hySetTabAlias / hyTabAliasOf')


def main():
    if len(sys.argv) < 2:
        raise SystemExit('usage: patch_wall_mobile.py <rustdesk root>')
    root = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    # android.yml 里脚本和下载的 dart 文件放在同一目录
    copy_pages(root, here)
    patch_common_tab_alias(root)
    patch_home(root)
    print('screen wall (android) applied')


if __name__ == '__main__':
    main()
