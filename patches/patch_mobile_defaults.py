# -*- coding: utf-8 -*-
"""安卓端默认值补丁（HyDesk 2026-11-10）

用户要求：安卓端默认开启 UDP 打洞开关。

背景：上游把 enable-udp-punch 当「本地选项」处理，没写过时手机上设置里
显示为关（mainGetLocalBoolOptionSync 对空值返回 false），现场看到的就是
「UDP 打洞默认没开」。这里在两处兜底：

1. mobile/pages/home_page.dart —— 首页 initState 里，若本地没写过该选项，
   补写 Y（一次），保证用户进设置前连接就已经按「开」走；
2. mobile/pages/settings_page.dart —— 构造时同规则兜底并让开关显示为开，
   避免「实际开着、界面显示关」的错位。

只动安卓构建（windows.yml 不应用本脚本），幂等。
"""
import os
import sys

K = 'enable-udp-punch'
MARK_HOME = 'HyDesk 安卓默认开启 UDP 打洞'
MARK_SETTINGS = 'HyDesk 设置页兜底：UDP 打洞默认开'


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


def write(p, s):
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(s)


def patch_home(root):
    p = os.path.join(root, 'flutter', 'lib', 'mobile', 'pages', 'home_page.dart')
    if not os.path.isfile(p):
        raise SystemExit('home_page.dart not found: %s' % p)
    src = read(p)
    if MARK_HOME in src:
        print('mobile home_page.dart udp default already patched')
        return
    old = ('  void initState() {\n'
           '    super.initState();\n')
    if old not in src:
        raise SystemExit('patch failed: mobile initState anchor not found')
    new = ('  void initState() {\n'
           '    super.initState();\n'
           '    // 【HyDesk】' + MARK_HOME + '：本地没写过就补 Y（只写一次）\n'
           '    try {\n'
           "      if ((bind.mainGetLocalOption(key: '" + K + "') ?? '')\n"
           '          .trim()\n'
           '          .isEmpty) {\n'
           "        bind.mainSetLocalOption(key: '" + K + "', value: 'Y');\n"
           '      }\n'
           '    } catch (_) {}\n')
    src = src.replace(old, new, 1)
    write(p, src)
    print('patched mobile home_page.dart: udp punch default on')


def patch_settings(root):
    p = os.path.join(root, 'flutter', 'lib', 'mobile', 'pages', 'settings_page.dart')
    if not os.path.isfile(p):
        raise SystemExit('mobile settings_page.dart not found: %s' % p)
    src = read(p)
    if MARK_SETTINGS in src:
        print('mobile settings_page.dart udp default already patched')
        return
    old = '    _enableUdpPunch = mainGetLocalBoolOptionSync(kOptionEnableUdpPunch);\n'
    if old not in src:
        raise SystemExit('patch failed: _enableUdpPunch anchor not found')
    new = ('    // 【HyDesk】' + MARK_SETTINGS + '\n'
           '    final hyUdpRaw =\n'
           "        (bind.mainGetLocalOption(key: kOptionEnableUdpPunch) ?? '')\n"
           '            .trim();\n'
           '    if (hyUdpRaw.isEmpty) {\n'
           '      mainSetLocalBoolOption(kOptionEnableUdpPunch, true);\n'
           '      _enableUdpPunch = true;\n'
           '    } else {\n'
           '      _enableUdpPunch = mainGetLocalBoolOptionSync(kOptionEnableUdpPunch);\n'
           '    }\n')
    src = src.replace(old, new, 1)
    write(p, src)
    print('patched mobile settings_page.dart: udp punch shown on by default')


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    patch_home(root)
    patch_settings(root)


if __name__ == '__main__':
    main()
