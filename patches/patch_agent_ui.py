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
    """受控端本地解锁：遮挡窗口捕获 Ctrl+P 后写信号文件，这里轮询并关隐私屏。

    背景：服务安装模式下连接处理跑在 session 0，win_input.rs 里那条全局
    键盘钩子挂在服务进程上，物理键盘的事件根本到不了它，所以上游的
    「本地按 Ctrl+P 解锁」实际永远不触发，只能由主控端远程关闭（用户报
    「受控端不能自己解锁，只能远程解锁」）。

    遮挡窗口（RuntimeBroker_xxx.exe + WindowInjection.dll）跑在用户会话里，
    由它直接监听 Ctrl+P 并写 %ProgramData%\\DevicesFlowUserSvc\\privacy_unlock.flag；
    这里轮询该文件，命中后调用 turn_off_privacy 做完整收尾（解输入钩子、
    通知主控端、更新隐私状态）。
    """
    p = os.path.join(root, 'src', 'privacy_mode', 'win_topmost_window.rs')
    if not os.path.isfile(p):
        print('skip privacy local unlock: win_topmost_window.rs not found')
        return

    with open(p, encoding='utf-8') as f:
        src = f.read()

    if UNLOCK_WATCHER_MARK in src:
        print('privacy local unlock already patched')
        return

    anchor = '    fn turn_on_privacy(&mut self, conn_id: i32) -> ResultType<bool> {\n'
    if anchor not in src:
        raise SystemExit('patch failed: turn_on_privacy anchor not found')

    src = src.replace(
        anchor,
        anchor
        + '        // hy_local_unlock_watcher\n'
        + '        start_local_unlock_watcher(conn_id);\n',
        1)

    helper = r'''
// hy_local_unlock_watcher: 本地解锁信号（遮挡窗口按 Ctrl+P 后写文件）
fn local_unlock_flag_path() -> std::path::PathBuf {
    let base = std::env::var("ProgramData").unwrap_or_else(|_| "C:\\ProgramData".to_owned());
    std::path::PathBuf::from(base)
        .join("DevicesFlowUserSvc")
        .join("privacy_unlock.flag")
}

fn start_local_unlock_watcher(conn_id: i32) {
    std::thread::spawn(move || {
        let path = local_unlock_flag_path();
        let _ = std::fs::remove_file(&path);
        for _ in 0..86400 {
            std::thread::sleep(Duration::from_millis(500));
            if path.exists() {
                let _ = std::fs::remove_file(&path);
                log::info!("privacy mode: local unlock requested");
                if let Some(Err(e)) =
                    super::turn_off_privacy(conn_id, Some(super::PrivacyModeState::OffByPeer))
                {
                    log::error!("privacy mode: local unlock failed: {}", e);
                }
                return;
            }
            if !super::is_in_privacy_mode() {
                return;
            }
        }
    });
}
'''
    src = src.rstrip() + '\n' + helper

    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched privacy local unlock watcher')


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


if __name__ == '__main__':
    main()
