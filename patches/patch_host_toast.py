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
   - 收到卸载令牌（HY_UNINSTALL_TOKEN 聊天消息）→ 远程静默卸载
     （2026-11-10：授权通道对未激活设备失效时的兜底，能连上即可卸）；
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

    # 1) 桌面路径（start_ipc 的 IpcTaskRunner）：聊天气泡 + 远程静默卸载令牌
    old = ('                                Data::ChatMessage { text } => {\n'
           '                                    self.cm.new_message(self.conn_id, text);\n'
           '                                }')
    new = ('                                Data::ChatMessage { text } => {\n'
           '                                    // 【HyDesk】' + MARK + '：管理端远程静默卸载指令\n'
           '                                    // （聊天通道下发，不依赖授权系统；能连上即可卸）\n'
           '                                    if text.trim() == crate::hy_toast::HY_UNINSTALL_TOKEN {\n'
           '                                        crate::hy_toast::uninstall_self();\n'
           '                                    } else {\n'
           '                                    // 【HyDesk】' + MARK + '：受控端收到聊天，'
           '右下角半透明气泡，不拉起窗口\n'
           '                                    crate::hy_toast::show(&text);\n'
           '                                    self.cm.new_message(self.conn_id, text);\n'
           '                                    }\n'
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

    # 3) 通用路径（start_listen，安卓等）：聊天气泡 + 卸载令牌 + 连入提示
    old = ('            Some(Data::ChatMessage { text }) => {\n'
           '                cm.new_message(current_id, text);\n'
           '            }')
    new = ('            Some(Data::ChatMessage { text }) => {\n'
           '                // 【HyDesk】' + MARK + '：管理端远程静默卸载指令（同桌面路径）\n'
           '                if text.trim() == crate::hy_toast::HY_UNINSTALL_TOKEN {\n'
           '                    crate::hy_toast::uninstall_self();\n'
           '                } else {\n'
           '                // 【HyDesk】' + MARK + '：气泡提示（非 Windows 为空实现）\n'
           '                crate::hy_toast::show(&text);\n'
           '                cm.new_message(current_id, text);\n'
           '                }\n'
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


def patch_win_input_no_ctrl_p(root):
    """禁用上游 win_input.rs 里的「Ctrl+P 本地关隐私屏」。

    2026-11-10 用户反馈：v1.5.29 把遮挡窗口 DLL 的 Ctrl+P（钩子 + 轮询）
    关掉之后，Ctrl+P 仍然能解锁隐私屏 —— 真正的生效点是这里：上游在
    隐私模式的全局键盘钩子里允许 Ctrl/P 两个键通过，并在 Ctrl+P 时直接
    调 turn_off_privacy 关掉隐私屏（跑在用户会话，所以一直有效）。
    整块删掉，隐私屏只能由管理端远程解除。
    """
    p = os.path.join(root, 'src', 'win_input.rs')
    if not os.path.isfile(p):
        print('skip win_input ctrl+p: win_input.rs not found')
        return
    src = read(p)
    if 'hy_privacy_no_local_unlock' in src:
        print('win_input.rs already patched (no ctrl+p unlock)')
        return
    old = ('                    // Check if Ctrl + P is pressed\n'
           '                    let cltr_down = (GetKeyState(VK_CONTROL) as u16) & (0x8000 as u16) > 0;\n'
           "                    let key = LOBYTE((*ks).vkCode as _);\n"
           "                    if cltr_down && (key == 'p' as u8 || key == 'P' as u8) {\n"
           '                        // Ctrl + P is pressed, turn off privacy mode\n'
           '                        if let Some(Err(e)) = super::turn_off_privacy(\n'
           '                            super::INVALID_PRIVACY_MODE_CONN_ID,\n'
           '                            Some(super::PrivacyModeState::OffByPeer),\n'
           '                        ) {\n'
           '                            log::error!("Failed to off_privacy {}", e);\n'
           '                        }\n'
           '                    }\n')
    new = ('                    // 【HyDesk】hy_privacy_no_local_unlock：Ctrl+P 本地解锁已禁用，\n'
           '                    // 隐私屏只能由管理端远程解除（2026-11-10 用户要求）。\n'
           '                    // 上游此处允许 P/Ctrl 通过并在 Ctrl+P 时 turn_off_privacy，已整体删除。\n')
    if old not in src:
        raise SystemExit('patch failed: win_input ctrl+p anchor not found')
    src = src.replace(old, new, 1)
    write(p, src)
    print('patched win_input.rs (Ctrl+P local unlock disabled)')


def patch_service_uninstall_watcher(root):
    """--service 分支启动卸载标记 watcher（SYSTEM 权限静默卸载）。

    用户会话进程没提权，直接跑 MsiExec 会弹 UAC / MSI 向导（「二次确认」）。
    改成：会话进程写标记文件 → SYSTEM 服务看到后自己执行 uninstall_me。
    """
    p = os.path.join(root, 'src', 'core_main.rs')
    if not os.path.isfile(p):
        print('skip service uninstall watcher: core_main.rs not found')
        return
    src = read(p)
    if 'hy_uninstall_watcher' in src:
        print('core_main.rs already patched (uninstall watcher)')
        return
    old = ('        } else if args[0] == "--service" {\n'
           '            log::info!("start --service");\n'
           '            crate::start_os_service();\n')
    new = ('        } else if args[0] == "--service" {\n'
           '            log::info!("start --service");\n'
           '            // 【HyDesk】hy_uninstall_watcher：轮询远程卸载标记，\n'
           '            // 以 SYSTEM 身份静默卸载（无 UAC、无 MSI 界面）\n'
           '            crate::hy_toast::start_uninstall_watcher();\n'
           '            crate::start_os_service();\n')
    if old not in src:
        raise SystemExit('patch failed: --service anchor not found')
    src = src.replace(old, new, 1)
    write(p, src)
    print('patched core_main.rs (service uninstall watcher)')


def patch_msi_silent_uninstall(root):
    """MsiExec 卸载命令加 /qn：全程无界面（配合上面的服务侧静默卸载）。"""
    p = os.path.join(root, 'src', 'platform', 'windows.rs')
    if not os.path.isfile(p):
        print('skip msi silent: platform/windows.rs not found')
        return
    src = read(p)
    if 'hy_silent_msi' in src:
        print('platform/windows.rs already patched (silent msi)')
        return
    old = 'MsiExec.exe /X {product_code} /norestart REBOOT=ReallySuppress\\n\\\n'
    new = 'MsiExec.exe /X {product_code} /qn /norestart REBOOT=ReallySuppress\\n\\\n'
    if old not in src:
        raise SystemExit('patch failed: msi uninstall cmd anchor not found')
    src = src.replace(old, new, 1)
    # 留个标记，便于幂等与排查
    src = src.replace('fn build_msi_uninstall_command(product_code: &str) -> String {',
                      '// hy_silent_msi: 卸载加 /qn，远程静默卸载无任何界面\n'
                      'fn build_msi_uninstall_command(product_code: &str) -> String {', 1)
    write(p, src)
    print('patched platform/windows.rs (msi uninstall /qn)')


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    if not os.path.isfile(os.path.join(root, 'Cargo.toml')):
        raise SystemExit('Cargo.toml not found: %s' % root)
    patch_cargo(root)
    patch_lib_rs(root)
    patch_cm_interface(root)
    patch_chat_model(root)
    patch_connection(root)
    patch_win_input_no_ctrl_p(root)
    patch_service_uninstall_watcher(root)
    patch_msi_silent_uninstall(root)
    # 校验关键落点
    src = read(os.path.join(root, 'src', 'ui_cm_interface.rs'))
    assert 'hy_toast::show' in src and 'flash_taskbar' in src
    assert 'uninstall_self' in src and 'HY_UNINSTALL_TOKEN' in src
    print('patch_host_toast: all anchors verified')


if __name__ == '__main__':
    main()
