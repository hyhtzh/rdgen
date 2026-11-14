#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""RuntimeAroker 受控端 MSI 静默化补丁。

用法: python patch_agent_msi.py <rustdesk 源码根目录>

改 res/msi 三处（WiX 源码级，打进安装包默认行为）：
1. ShortcutProperties.wxs：开始菜单/桌面/开机启动托盘三个快捷方式默认改为「不创建」
   （Value="1" -> Value="0"；不能写空串，WiX 报 WIX0006）。安装期仍可用 STARTMENUSHORTCUTS=1 显式打开。
2. ShortcutProperties.wxs：加 <Property Id="ARPSYSTEMCOMPONENT" Value="1"/>，
   安装后不出现在「程序和功能」卸载列表（卸载走 msiexec /x 或远程指令）。
3. Folders.wxs：INSTALLFOLDER 默认值改为 [LocalAppDataFolder]\\<Product>\\，
   未显式传目录时静默装到当前管理员用户的 LocalAppData
   （本机即 C:\\Users\\Administrator\\AppData\\Local\\RuntimeAroker）。
4. Components/RustDesk.wxs + CustomActions(.cpp/.def/.wxs)：加服务自动恢复
   自定义动作 —— 服务进程崩溃/被杀后 Windows 服务管理器 60 秒内自动拉起
   （恢复计数每天重置）。
   2026-11-15 起为 CustomActions.dll 原生动作（ChangeServiceConfig2W），
   不再 ExeCommand 跑 sc.exe：sc.exe 是控制台程序，静默安装会闪黑框；
   原生动作零子进程、零窗口，与上游 CreateStartService 同一模式。
   这样「控制端远程结束受控端进程」就等于「远程重启受控端软件」，
   与 NSIS Setup 壳（agent_setup.nsi 用 nsExec 隐藏执行 sc）行为一致。
"""

import os
import sys

# 【HyDesk】ServiceUtils.cpp 里新增的代码块：helper + MSI CA 入口。
# 纯 ASCII（上游 CI 编译环境最稳）；wcautil 宏经 framework.h 全局可用。
SERVICE_RECOVERY_CPP = r"""// [HyDesk] Service auto-recovery via ChangeServiceConfig2W:
// 3x restart after 60s, failure counter reset daily. Fully silent,
// no sc.exe child process (sc.exe is a console app and would flash
// a black window during the silent install).
bool MySetServiceRecoveryW(LPCWSTR serviceName)
{
    SC_HANDLE hSCManager = OpenSCManagerW(NULL, NULL, SC_MANAGER_CONNECT);
    if (hSCManager == NULL) {
        WcaLog(LOGMSG_STANDARD, "OpenSCManager failed (%d)\n", GetLastError());
        return false;
    }
    SC_HANDLE hService = OpenServiceW(hSCManager, serviceName, SERVICE_ALL_ACCESS);
    if (hService == NULL) {
        WcaLog(LOGMSG_STANDARD, "OpenService failed (%d)\n", GetLastError());
        CloseServiceHandle(hSCManager);
        return false;
    }
    SC_ACTION actions[3];
    actions[0].Type = SC_ACTION_RESTART;
    actions[0].Delay = 60000;
    actions[1].Type = SC_ACTION_RESTART;
    actions[1].Delay = 60000;
    actions[2].Type = SC_ACTION_RESTART;
    actions[2].Delay = 60000;
    SERVICE_FAILURE_ACTIONSW fa;
    ZeroMemory(&fa, sizeof(fa));
    fa.dwResetPeriod = 86400;
    fa.cActions = 3;
    fa.lpsaActions = actions;
    BOOL ok = ChangeServiceConfig2W(hService, SERVICE_CONFIG_FAILURE_ACTIONS, &fa);
    if (!ok) {
        WcaLog(LOGMSG_STANDARD, "ChangeServiceConfig2 failed (%d)\n", GetLastError());
    } else {
        WcaLog(LOGMSG_STANDARD, "Service recovery configured: %ls\n", serviceName);
    }
    CloseServiceHandle(hService);
    CloseServiceHandle(hSCManager);
    return ok ? true : false;
}

UINT __stdcall SetServiceRecovery(__in MSIHANDLE hInstall)
{
    HRESULT hr = S_OK;
    DWORD er = ERROR_SUCCESS;
    LPWSTR svcName = NULL;
    LPWSTR pwz = NULL;
    LPWSTR pwzData = NULL;

    hr = WcaInitialize(hInstall, "SetServiceRecovery");
    ExitOnFailure(hr, "Failed to initialize");

    hr = WcaGetProperty(L"CustomActionData", &pwzData);
    ExitOnFailure(hr, "failed to get CustomActionData");

    pwz = pwzData;
    hr = WcaReadStringFromCaData(&pwz, &svcName);
    ExitOnFailure(hr, "failed to read service name from custom action data: %ls", pwz);
    WcaLog(LOGMSG_STANDARD, "Set service recovery : %ls", svcName);

    MySetServiceRecoveryW(svcName);

LExit:
    if (pwzData) {
        ReleaseStr(pwzData);
    }

    er = SUCCEEDED(hr) ? ERROR_SUCCESS : ERROR_INSTALL_FAILURE;
    return WcaFinalize(er);
}

"""


def read(p):
    with open(p, encoding='utf-8-sig') as f:
        return f.read()


def write(p, src):
    with open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(src)


def patch_shortcut_props(root):
    p = os.path.join(root, 'res', 'msi', 'Package', 'Fragments',
                     'ShortcutProperties.wxs')
    if not os.path.isfile(p):
        raise SystemExit('ShortcutProperties.wxs not found: %s' % p)
    src = read(p)

    for prop in ('STARTMENUSHORTCUTS', 'DESKTOPSHORTCUTS', 'STARTUPSHORTCUTS'):
        old = '<Property Id="%s" Value="1" Secure="yes"></Property>' % prop
        new = '<Property Id="%s" Value="0" Secure="yes"></Property>' % prop
        if old in src:
            src = src.replace(old, new)
        elif new in src:
            pass
        else:
            raise SystemExit('patch failed: %s property anchor not found' % prop)

    if 'ARPSYSTEMCOMPONENT' not in src:
        anchor = '<Property Id="STARTMENUSHORTCUTS"'
        idx = src.find(anchor)
        if idx < 0:
            raise SystemExit('patch failed: anchor for ARPSYSTEMCOMPONENT')
        ins = ('<!-- agent: hide from Programs and Features -->\n'
               '\t\t<Property Id="ARPSYSTEMCOMPONENT" Value="1"></Property>\n'
               '\t\t')
        src = src[:idx] + ins + src[idx:]

    write(p, src)
    print('patched ShortcutProperties.wxs (no shortcuts, ARP hidden)')


def patch_folders(root):
    p = os.path.join(root, 'res', 'msi', 'Package', 'Components', 'Folders.wxs')
    if not os.path.isfile(p):
        raise SystemExit('Folders.wxs not found: %s' % p)
    src = read(p)

    if 'INSTALLFOLDER_AGENT_DEFAULT' in src:
        print('Folders.wxs already patched')
        return

    # 在 RestoreSavedInstallFolderValue 之后、INSTALLFOLDER_INNER 推导之前，
    # 给未指定/未注册的 INSTALLFOLDER 一个 LocalAppData 默认值。
    anchor = ('<SetProperty Action="RestoreSavedInstallFolderValue" '
              'Id="INSTALLFOLDER"')
    idx = src.find(anchor)
    if idx < 0:
        raise SystemExit('patch failed: RestoreSavedInstallFolderValue anchor not found')
    # 找到该元素行尾
    end = src.find('\n', idx)
    line_end = src.find('/>', idx)
    if line_end < 0 or line_end > end:
        line_end = src.find('</SetProperty>', idx)
        if line_end < 0:
            raise SystemExit('patch failed: cannot locate anchor element end')
    insert_at = src.find('\n', line_end) + 1
    ins = ('\t\t<!-- agent: default install location is the installing '
           'user LocalAppData (INSTALLFOLDER_AGENT_DEFAULT) -->\n'
           '\t\t<SetProperty Id="INSTALLFOLDER" '
           'Value="[LocalAppDataFolder]$(var.Product)\\" '
           'After="RestoreSavedInstallFolderValue" Sequence="first" '
           'Condition="NOT INSTALLFOLDER" />\n')
    src = src[:insert_at] + ins + src[insert_at:]

    write(p, src)
    print('patched Folders.wxs (default INSTALLFOLDER -> LocalAppData)')


def patch_service_recovery(root):
    """服务自动恢复（对齐 NSIS 壳），全程静默、零黑框。

    v1 (2026-11-09): WiX ExeCommand 跑 sc.exe —— sc.exe 是控制台程序，
    静默安装时闪黑框。
    v2 (2026-11-15): CustomActions.dll 原生动作 SetServiceRecovery，
    直接 ChangeServiceConfig2W 改失败恢复策略，不起任何子进程，
    和上游 CreateStartService/TryStopDeleteService 同一套 wcautil 模式。
    涉及四个文件：
      res/msi/CustomActions/ServiceUtils.cpp   新增 MySetServiceRecoveryW + 入口
      res/msi/CustomActions/CustomActions.def  导出 SetServiceRecovery
      res/msi/Package/Fragments/CustomActions.wxs  DllEntry 动作声明
      res/msi/Package/Components/RustDesk.wxs  SetParam + InstallExecuteSequence
    """
    # ---- 1) ServiceUtils.cpp: helper + CA entry ----
    p = os.path.join(root, 'res', 'msi', 'CustomActions', 'ServiceUtils.cpp')
    if not os.path.isfile(p):
        raise SystemExit('ServiceUtils.cpp not found: %s' % p)
    src = read(p)
    if 'MySetServiceRecoveryW' in src:
        print('ServiceUtils.cpp already patched (service recovery)')
    else:
        anchor = 'bool MyDeleteServiceW(LPCWSTR serviceName)'
        idx = src.find(anchor)
        if idx < 0:
            raise SystemExit('patch failed: MyDeleteServiceW anchor')
        ins = SERVICE_RECOVERY_CPP
        src = src[:idx] + ins + src[idx:]
        write(p, src)
        print('patched ServiceUtils.cpp (native SetServiceRecovery CA)')

    # ---- 2) CustomActions.def: export ----
    p = os.path.join(root, 'res', 'msi', 'CustomActions', 'CustomActions.def')
    if not os.path.isfile(p):
        raise SystemExit('CustomActions.def not found: %s' % p)
    src = read(p)
    if 'SetServiceRecovery' in src:
        print('CustomActions.def already patched')
    else:
        anchor = '    TryStopDeleteService\n'
        idx = src.find(anchor)
        if idx < 0:
            raise SystemExit('patch failed: TryStopDeleteService def anchor')
        src = src[:idx + len(anchor)] + '    SetServiceRecovery\n' + src[idx + len(anchor):]
        write(p, src)
        print('patched CustomActions.def (export SetServiceRecovery)')

    # ---- 3) Fragments/CustomActions.wxs: DllEntry CA declaration ----
    p = os.path.join(root, 'res', 'msi', 'Package', 'Fragments',
                     'CustomActions.wxs')
    if not os.path.isfile(p):
        raise SystemExit('CustomActions.wxs (Fragments) not found: %s' % p)
    src = read(p)
    if 'Id="SetServiceRecovery"' in src:
        print('CustomActions.wxs already patched')
    else:
        anchor = '<CustomAction Id="TryStopDeleteService" DllEntry="TryStopDeleteService"'
        idx = src.find(anchor)
        if idx < 0:
            raise SystemExit('patch failed: TryStopDeleteService CA anchor')
        end = src.find('\n', idx) + 1
        ins = ('\t\t<!-- agent: service auto-recovery, restart 60s after '
               'crash, reset counter daily. Native DLL action: no sc.exe '
               'child process, no console flash during silent install. -->\n'
               '\t\t<CustomAction Id="SetServiceRecovery" '
               'DllEntry="SetServiceRecovery" Impersonate="no" '
               'Execute="deferred" Return="ignore" '
               'BinaryRef="Custom_Actions_Dll" />\n')
        src = src[:end] + ins + src[end:]
        write(p, src)
        print('patched CustomActions.wxs (SetServiceRecovery DllEntry CA)')

    # ---- 4) Components/RustDesk.wxs: SetParam + sequence ----
    p = os.path.join(root, 'res', 'msi', 'Package', 'Components', 'RustDesk.wxs')
    if not os.path.isfile(p):
        raise SystemExit('RustDesk.wxs not found: %s' % p)
    src = read(p)
    if 'SetServiceRecovery' in src:
        print('RustDesk.wxs already patched (service recovery)')
        return

    # SetParam（type-51 属性赋值，deferred 动作从 CustomActionData 读服务名）
    anchor_def = ('<CustomAction Id="TryStopDeleteService.SetParam" '
                  'Return="check" Property="TryStopDeleteService" '
                  'Value="$(var.Product)" />')
    idx = src.find(anchor_def)
    if idx < 0:
        raise SystemExit('patch failed: TryStopDeleteService.SetParam anchor')
    end = src.find('\n', idx) + 1
    ins_def = ('\t\t<!-- agent: service auto-recovery (native DLL action, '
               'silent) -->\n'
               '\t\t<CustomAction Id="SetServiceRecovery.SetParam" '
               'Return="check" Property="SetServiceRecovery" '
               'Value="$(var.Product)" />\n')
    src = src[:end] + ins_def + src[end:]

    # 排序：紧跟 CreateStartService（同一条件：装/升级且建了服务才配恢复）
    anchor_seq_start = '<Custom Action="CreateStartService" Before="InstallFinalize"'
    idx = src.find(anchor_seq_start)
    if idx < 0:
        raise SystemExit('patch failed: CreateStartService sequence anchor')
    end = src.find('\n', idx) + 1
    ins_seq = ('\t\t\t<!-- agent: configure service recovery right after the '
               'service is created/started (silent, no sc.exe) -->\n'
               '\t\t\t<Custom Action="SetServiceRecovery" '
               'After="CreateStartService" '
               'Condition="(NOT (Installed AND REMOVE AND NOT '
               'UPGRADINGPRODUCTCODE)) AND (NOT '
               'STOP_SERVICE=&quot;&apos;Y&apos;&quot;) AND (NOT '
               'CC_CONNECTION_TYPE=&quot;outgoing&quot;)" />\n'
               '\t\t\t<Custom Action="SetServiceRecovery.SetParam" '
               'Before="SetServiceRecovery" '
               'Condition="(NOT (Installed AND REMOVE AND NOT '
               'UPGRADINGPRODUCTCODE)) AND (NOT '
               'STOP_SERVICE=&quot;&apos;Y&apos;&quot;) AND (NOT '
               'CC_CONNECTION_TYPE=&quot;outgoing&quot;)" />\n')
    src = src[:end] + ins_seq + src[end:]

    write(p, src)
    print('patched RustDesk.wxs (service auto-recovery, native CA)')


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    patch_shortcut_props(root)
    patch_folders(root)
    patch_service_recovery(root)


if __name__ == '__main__':
    main()
