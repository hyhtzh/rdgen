#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""【HyDesk】受控端体验补丁（2026-11-09 晚）。

用法: python patch_host_toast.py <rustdesk 源码根目录>

内容：
1. 挂载 src/hy_toast.rs（原生右下角半透明气泡 + 任务栏闪烁，winapi 实现）
   并给 Cargo.toml 的 winapi 加 wingdi/libloaderapi feature；
2. ui_cm_interface.rs：
   - 收到聊天消息 → 原生气泡（连接管理器窗口不再被拉起，配合 3）；
   - 有人连入（Data::Login）→ 任务栏闪烁 + 气泡提示；
3. chat_model.dart：receive() 里被控端收到文字聊天不再 showCmWindow /
   windowOnTop / 展开聊天侧栏（消息仍进历史 + 未读计数）；
4. connection.rs：on_remote_authorized 不再移除桌面壁纸（用户要求保留）。
"""

import os
import sys

MARK = 'hy_host_toast'


def read(p):
    with open(p, encoding='utf-8-sig') as f:
        return f.read()


def write(p, src):
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)


def here(name):
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), name)


def patch_cargo(root):
    p = os.path.join(root, 'Cargo.toml')
    src = read(p)
    if '"wingdi"' in src:
        print('Cargo.toml winapi features already patched')
        return
    old = 'winapi = { version = "0.3", features = [\n    "winuser",'
    if old not in src:
        raise SystemExit('patch failed: winapi features anchor not found')
    new = ('winapi = { version = "0.3", features = [\n'
           '    "winuser",\n    "wingdi",\n    "libloaderapi",')
    src = src.replace(old, new, 1)
    write(p, src)
    print('patched Cargo.toml (winapi +wingdi +libloaderapi)')


def patch_lib_rs(root):
    p = os.path.join(root, 'src', 'lib.rs')
    src = read(p)
    if 'mod hy_toast;' in src:
        print('lib.rs already has hy_toast module')
        return
    old = 'mod bridge_generated;'
    if old not in src:
        raise SystemExit('patch failed: bridge_generated mod anchor not found')
    src = src.replace(old, old + '\nmod hy_toast; // 【HyDesk】原生气泡/任务栏提示', 1)
    write(p, src)
    # 拷贝模块源文件
    dst = os.path.join(root, 'src', 'hy_toast.rs')
    src_rs = here('hy_toast.rs')
    if not os.path.isfile(src_rs):
        raise SystemExit('hy_toast.rs not found next to patch script')
    body = read(src_rs)
    write(dst, body)
    print('patched lib.rs + src/hy_toast.rs')


def patch_cm_interface(root):
    p = os.path.join(root, 'src', 'ui_cm_interface.rs')
    src = read(p)
    if MARK in src:
        print('ui_cm_interface.rs already patched')
        return

    # 1) 桌面路径（start_ipc 的 IpcTaskRunner）：聊天气泡
    old = ('                                Data::ChatMessage { text } => {\n'
           '                                    self.cm.new_message(self.conn_id, text);\n'
           '                                }')
    new = ('                                Data::ChatMessage { text } => {\n'
           '                                    // 【HyDesk】' + MARK + '：受控端收到聊天，'
           '右下角半透明气泡，不拉起窗口\n'
           '                                    crate::hy_toast::show(&text);\n'
           '                                    self.cm.new_message(self.conn_id, text);\n'
           '                                }')
    if old not in src:
        raise SystemExit('patch failed: chat anchor (ipc runner) not found')
    src = src.replace(old, new, 1)

    # 2) 桌面路径：有人连入 → 任务栏闪烁 + 气泡
    old = ('                                    self.conn_id = id;\n'
           '                                    #[cfg(target_os = "windows")]\n')
    new = ('                                    self.conn_id = id;\n'
           '                                    // 【HyDesk】' + MARK + '：有人连入，'
           '任务栏闪烁提示\n'
           '                                    crate::hy_toast::flash_taskbar();\n'
           '                                    #[cfg(target_os = "windows")]\n')
    if old not in src:
        raise SystemExit('patch failed: login anchor (ipc runner) not found')
    src = src.replace(old, new, 1)

    # 3) 通用路径（start_listen，安卓等）：聊天气泡 + 连入提示
    old = ('            Some(Data::ChatMessage { text }) => {\n'
           '                cm.new_message(current_id, text);\n'
           '            }')
    new = ('            Some(Data::ChatMessage { text }) => {\n'
           '                // 【HyDesk】' + MARK + '：气泡提示（非 Windows 为空实现）\n'
           '                crate::hy_toast::show(&text);\n'
           '                cm.new_message(current_id, text);\n'
           '            }')
    if old not in src:
        raise SystemExit('patch failed: chat anchor (start_listen) not found')
    src = src.replace(old, new, 1)

    old = ('                current_id = id;\n'
           '                cm.add_connection(')
    new = ('                current_id = id;\n'
           '                // 【HyDesk】' + MARK + '：连入提示（非 Windows 为空实现）\n'
           '                crate::hy_toast::flash_taskbar();\n'
           '                cm.add_connection(')
    if old not in src:
        raise SystemExit('patch failed: login anchor (start_listen) not found')
    src = src.replace(old, new, 1)

    write(p, src)
    print('patched ui_cm_interface.rs (chat toast + login flash)')


def patch_chat_model(root):
    p = os.path.join(root, 'flutter', 'lib', 'models', 'chat_model.dart')
    src = read(p)
    if MARK in src:
        print('chat_model.dart already patched')
        return

    # 1) 不再 showCmWindow
    old = ("    if (text.isEmpty) return;\n"
           "    if (desktopType == DesktopType.cm) {\n"
           "      await showCmWindow();\n"
           "    }")
    new = ("    if (text.isEmpty) return;\n"
           "    // 【HyDesk】" + MARK + "：被控端收到文字聊天不拉起连接窗口，\n"
           "    // 改由 Rust 侧原生气泡提示（ui_cm_interface.rs 同名补丁）。\n"
           "    final hyServerChat = desktopType == DesktopType.cm;")
    if old not in src:
        raise SystemExit('patch failed: showCmWindow anchor not found')
    src = src.replace(old, new, 1)

    # 2) 不展开聊天侧栏（那会把窗口拉起来并改尺寸）
    old = ("    // show chat page\n"
           "    await showChatPage(messagekey);")
    new = ("    // show chat page（被控端跳过：不展开聊天侧栏，消息仍进历史+未读）\n"
           "    if (!hyServerChat) {\n"
           "      await showChatPage(messagekey);\n"
           "    }")
    if old not in src:
        raise SystemExit('patch failed: showChatPage anchor not found')
    src = src.replace(old, new, 1)

    # 3) 不置顶窗口
    old = ("      if (isDesktop) {\n"
           "        windowOnTop(null);")
    new = ("      if (isDesktop) {\n"
           "        if (!hyServerChat) windowOnTop(null);")
    if old not in src:
        raise SystemExit('patch failed: windowOnTop anchor not found')
    src = src.replace(old, new, 1)

    write(p, src)
    print('patched chat_model.dart (incoming chat no longer raises window)')


def patch_connection(root):
    p = os.path.join(root, 'src', 'server', 'connection.rs')
    src = read(p)
    if 'hy_keep_wallpaper' in src:
        print('connection.rs already patched (wallpaper)')
        return
    old = ('    fn on_remote_authorized(&self) {\n'
           '        self.update_codec_on_login();\n'
           '        #[cfg(any(target_os = "windows", target_os = "linux"))]\n'
           '        if config::option2bool(\n')
    new = ('    fn on_remote_authorized(&self) {\n'
           '        self.update_codec_on_login();\n'
           '        // 【HyDesk】hy_keep_wallpaper：不移除桌面壁纸（2026-11-09 用户要求）\n'
           '        #[cfg(any(target_os = "windows", target_os = "linux"))]\n'
           '        if false && config::option2bool(\n')
    if old not in src:
        raise SystemExit('patch failed: on_remote_authorized anchor not found')
    src = src.replace(old, new, 1)
    write(p, src)
    print('patched connection.rs (keep wallpaper during sessions)')


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    if not os.path.isfile(os.path.join(root, 'Cargo.toml')):
        raise SystemExit('Cargo.toml not found: %s' % root)
    patch_cargo(root)
    patch_lib_rs(root)
    patch_cm_interface(root)
    patch_chat_model(root)
    patch_connection(root)
    # 校验关键落点
    src = read(os.path.join(root, 'src', 'ui_cm_interface.rs'))
    assert 'hy_toast::show' in src and 'flash_taskbar' in src
    print('patch_host_toast: all anchors verified')


if __name__ == '__main__':
    main()
