#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 RustDesk 的桌面首页替换成控制端界面（含独立窗口的屏幕墙）。

用法: python patch_client_ui.py <rustdesk 源码根目录>

做四件事：
1. 把 client_home_page.dart / screen_wall_page.dart / settings_page.dart /
   address_book_page.dart 复制到 flutter/lib/desktop/pages/；
2. main.dart：补 import、把 `? const DesktopTabPage()` 换成 `? const ClientHomePage()`；
3. main.dart / consts.dart：新增 WindowType.ScreenWall 分支，让屏幕墙跑在独立子窗口里；
4. utils/multi_window_manager.dart：补枚举、窗口列表、`newScreenWall()`。

第 3、4 步是纯文本插入，锚点找不到会直接报错退出（宁可构建失败，也不要悄悄出一个
「屏幕墙还是盖住首页」的包）。
"""

import os
import re
import shutil
import sys

IMPORT_LINE = "import 'package:flutter_hbb/desktop/pages/client_home_page.dart';"
WALL_IMPORT_LINE = "import 'package:flutter_hbb/desktop/pages/screen_wall_page.dart';"

PAGES = [
    'client_home_page.dart',
    'screen_wall_page.dart',
    'settings_page.dart',
    'address_book_page.dart',
    'file_transfer_page.dart',
]

SCREEN_WALL_APP_TYPE = 'kAppTypeScreenWall'
SCREEN_WALL_APP_TYPE_VALUE = 'const String kAppTypeScreenWall = "screen wall";'


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def write(path, src):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)


def replace_once(src, old, new, what):
    """替换且要求唯一命中；已存在 new 时视为已打过补丁。"""
    if new in src:
        print('  skip (already patched): %s' % what)
        return src
    if src.count(old) != 1:
        raise SystemExit('patch anchor not unique for %s (found %d)'
                         % (what, src.count(old)))
    print('  patch: %s' % what)
    return src.replace(old, new, 1)


def insert_after(src, anchor, addition, what):
    if addition.strip() and addition.strip() in src:
        print('  skip (already patched): %s' % what)
        return src
    if src.count(anchor) != 1:
        raise SystemExit('patch anchor not unique for %s (found %d)'
                         % (what, src.count(anchor)))
    print('  patch: %s' % what)
    return src.replace(anchor, anchor + addition, 1)


def patch_consts(root):
    path = os.path.join(root, 'flutter', 'lib', 'consts.dart')
    src = read(path)
    src = insert_after(
        src,
        'const String kAppTypeDesktopTerminal = "terminal";',
        '\n' + SCREEN_WALL_APP_TYPE_VALUE,
        'consts.dart: kAppTypeScreenWall',
    )
    write(path, src)


def patch_multi_window_manager(root):
    path = os.path.join(root, 'flutter', 'lib', 'utils', 'multi_window_manager.dart')
    src = read(path)

    # 1) 枚举：插在 Unknown 前面，保证已有索引不变
    src = replace_once(
        src,
        '  PortForward,\n  Terminal,\n  Unknown\n}',
        '  PortForward,\n  Terminal,\n  ScreenWall,\n  Unknown\n}',
        'multi_window_manager.dart: WindowType.ScreenWall',
    )

    # 2) int -> WindowType
    src = replace_once(
        src,
        '      case 5:\n        return WindowType.Terminal;\n      default:',
        '      case 5:\n        return WindowType.Terminal;\n'
        '      case 6:\n        return WindowType.ScreenWall;\n      default:',
        'multi_window_manager.dart: index 6 -> ScreenWall',
    )

    # 3) 窗口 id 列表
    src = insert_after(
        src,
        '  final List<int> _terminalWindows = List.empty(growable: true);',
        '\n  final List<int> _screenWallWindows = List.empty(growable: true);',
        'multi_window_manager.dart: _screenWallWindows',
    )

    # 4) 按类型查窗口
    src = insert_after(
        src,
        '      case WindowType.Terminal:\n        return _terminalWindows;',
        '\n      case WindowType.ScreenWall:\n        return _screenWallWindows;',
        'multi_window_manager.dart: _findWindowsByType',
    )

    # 5) 清理（顺手补上 Terminal 分支漏掉的 break，否则会串到屏幕墙）
    src = replace_once(
        src,
        '      case WindowType.Terminal:\n'
        '        _terminalWindows.clear();\n'
        '      case WindowType.Unknown:\n'
        '        break;',
        '      case WindowType.Terminal:\n'
        '        _terminalWindows.clear();\n'
        '        break;\n'
        '      case WindowType.ScreenWall:\n'
        '        _screenWallWindows.clear();\n'
        '        break;\n'
        '      case WindowType.Unknown:\n'
        '        break;',
        'multi_window_manager.dart: clearWindowType',
    )

    # 6) 创建屏幕墙窗口
    new_screen_wall = '''
  /// 打开屏幕墙独立窗口。已开着就直接提到前台，避免点两次开出两个墙。
  Future<int> newScreenWall() async {
    // 关掉的窗口不会自己从 _screenWallWindows 里消失，而 WindowController.fromWindowId()
    // 对已销毁的 id 不会抛错，show()/focus() 静默失败——表现就是「关一次以后再也打不开」。
    // 先按子窗口真实列表把死 id 清掉，再决定是复用还是新建。
    try {
      final alive = await getAllSubWindowIds();
      _screenWallWindows.removeWhere((id) => !alive.contains(id));
    } catch (e) {
      debugPrint('getAllSubWindowIds failed, reset wall windows: $e');
      _screenWallWindows.clear();
    }
    for (final windowId in List<int>.from(_screenWallWindows)) {
      try {
        final wc = WindowController.fromWindowId(windowId);
        await wc.show();
        await wc.focus();
        registerActiveWindow(windowId);
        return windowId;
      } catch (e) {
        debugPrint('screen wall window $windowId is gone: $e');
        _screenWallWindows.remove(windowId);
      }
    }
    final msg = jsonEncode({'type': WindowType.ScreenWall.index});
    final windowController = await DesktopMultiWindow.createWindow(msg);
    if (isWindows) {
      windowController.setInitBackgroundColor(const Color(0xFF0F1115));
    }
    final windowId = windowController.windowId;
    windowController.setTitle(getWindowName());
    windowController.setFrame(const Offset(0, 0) & const Size(1360, 860));
    windowController.center();
    if (isMacOS) {
      Future.microtask(() => windowController.show());
    }
    registerActiveWindow(windowId);
    _screenWallWindows.add(windowId);
    return windowId;
  }

'''
    anchor = '  moveTabToNewWindow('
    if 'Future<int> newScreenWall()' in src:
        print('  skip (already patched): multi_window_manager.dart: newScreenWall()')
    else:
        if src.count(anchor) != 1:
            raise SystemExit('patch anchor not unique: newScreenWall()')
        print('  patch: multi_window_manager.dart: newScreenWall()')
        src = src.replace(anchor, new_screen_wall.lstrip('\n') + anchor, 1)

    write(path, src)


def patch_main_dart(root):
    path = os.path.join(root, 'flutter', 'lib', 'main.dart')
    src = read(path)

    # 1) import
    if WALL_IMPORT_LINE in src and IMPORT_LINE in src:
        print('  skip (already patched): main.dart: wall import')
    else:
        if IMPORT_LINE in src:
            if WALL_IMPORT_LINE not in src:
                src = src.replace(IMPORT_LINE, IMPORT_LINE + '\n' + WALL_IMPORT_LINE, 1)
        else:
            m = re.search(
                r"^import 'package:flutter_hbb/desktop/pages/[^']+';\s*$",
                src, re.M)
            if not m:
                raise SystemExit('patch failed: no insert point for wall import')
            add = '\n' + IMPORT_LINE
            if WALL_IMPORT_LINE not in src:
                add += '\n' + WALL_IMPORT_LINE
            src = src[:m.end()] + add + src[m.end():]
        print('  patch: main.dart: wall import')

    # 2) 首页替换
    replaced = src.count('const DesktopTabPage()')
    src = src.replace('const DesktopTabPage()', 'const ClientHomePage()')
    if 'const ClientHomePage()' not in src:
        raise SystemExit('patch failed: DesktopTabPage call site not found')
    print('  patched main.dart, replaced %d call site(s)' % replaced)

    # 3) 窗口类型分支（顺带给 Terminal 补 break：上游漏了，不补会顺延进屏幕墙分支，
    #    开终端时 runMultiWindow 会被调两次）
    terminal_case = (
        '      case WindowType.Terminal:\n'
        '        desktopType = DesktopType.terminal;\n'
        '        runMultiWindow(\n'
        '          argument,\n'
        '          kAppTypeDesktopTerminal,\n'
        '        );'
    )
    src = replace_once(
        src,
        terminal_case,
        terminal_case + '\n'
        '        break;\n'
        '\n'
        '      case WindowType.ScreenWall:\n'
        '        runMultiWindow(\n'
        '          argument,\n'
        '          %s,\n'
        '        );\n'
        '        break;' % SCREEN_WALL_APP_TYPE,
        'main.dart: WindowType.ScreenWall case',
    )

    # 4) runMultiWindow 选择 widget
    src = insert_after(
        src,
        '    case kAppTypeDesktopTerminal:\n'
        '      widget = DesktopTerminalScreen(\n'
        '        params: argument,\n'
        '      );\n'
        '      break;',
        '\n'
        '    case %s:\n'
        '      widget = const ScreenWallPage();\n'
        '      break;' % SCREEN_WALL_APP_TYPE,
        'main.dart: runMultiWindow widget',
    )

    # 5) runMultiWindow 恢复窗口位置
    src = insert_after(
        src,
        '    case kAppTypeDesktopTerminal:\n'
        '      await restoreWindowPosition(WindowType.Terminal, windowId: kWindowId!);\n'
        '      break;',
        '\n'
        '    case %s:\n'
        '      await restoreWindowPosition(WindowType.ScreenWall,\n'
        '          windowId: kWindowId!);\n'
        '      break;' % SCREEN_WALL_APP_TYPE,
        'main.dart: runMultiWindow restore position',
    )

    write(path, src)


def patch_common_tab_label(root):
    """远程会话标签：重命名过的设备只显示设备名，不拼「@主机名」。

    上游 getDesktopTabLabel：label = alias 为空 ? peerId : alias，
    然后只要 hostname 不在 label 里就再拼 "@hostname"。用户把设备改名后，
    标签仍显示「名字@win-xxx」，和列表里的设备名对不上。
    """
    path = os.path.join(root, 'flutter', 'lib', 'common.dart')
    src = read(path)
    old = ("String getDesktopTabLabel(String peerId, String alias) {\n"
           "  String label = alias.isEmpty ? peerId : alias;")
    new = ("String getDesktopTabLabel(String peerId, String alias) {\n"
           "  // 已重命名的设备：标签与设备名严格一致，不再拼 @主机名\n"
           "  if (alias.trim().isNotEmpty) return alias.trim();\n"
           "  String label = alias.isEmpty ? peerId : alias;")
    src = replace_once(src, old, new, 'common.dart: tab label uses device name')
    write(path, src)


def patch_video_quality_default(root):
    """远程画质默认值：custom 档未配置时 50 -> 70（v1.5.46）。

    上游 client.rs get_option_message：image_quality == "custom" 且
    custom_image_quality 为空时按 50 发（quality<<8 即码率档）。50 明显
    偏低、画面发糊。默认提到 70：直连/自建服务器不受公共服务器 100 上限
    约束。用户在设置里手动选过画质则完全不受影响（只在未配置时生效）。
    """
    path = os.path.join(root, 'src', 'client.rs')
    src = read(path)
    old = ("            let quality = if config.custom_image_quality.is_empty() {\n"
           "                50\n")
    new = ("            let quality = if config.custom_image_quality.is_empty() {\n"
           "                70\n")
    src = replace_once(src, old, new,
                       'client.rs: default custom quality 50 -> 70')
    write(path, src)


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

    patch_consts(root)
    patch_multi_window_manager(root)
    patch_main_dart(root)
    patch_common_tab_label(root)
    # 画质：默认码率档 50 -> 70（v1.5.46）
    patch_video_quality_default(root)


if __name__ == '__main__':
    main()
