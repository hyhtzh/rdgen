#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DevicesFlowUserSvc 受控端 MSI 静默化补丁。

用法: python patch_agent_msi.py <rustdesk 源码根目录>

改 res/msi 三处（WiX 源码级，打进安装包默认行为）：
1. ShortcutProperties.wxs：开始菜单/桌面/开机启动托盘三个快捷方式默认改为「不创建」
   （Value="1" -> Value="0"；不能写空串，WiX 报 WIX0006）。安装期仍可用 STARTMENUSHORTCUTS=1 显式打开。
2. ShortcutProperties.wxs：加 <Property Id="ARPSYSTEMCOMPONENT" Value="1"/>，
   安装后不出现在「程序和功能」卸载列表（卸载走 msiexec /x 或远程指令）。
3. Folders.wxs：INSTALLFOLDER 默认值改为 [LocalAppDataFolder]\\<Product>\\，
   未显式传目录时静默装到当前管理员用户的 LocalAppData
   （本机即 C:\\Users\\Administrator\\AppData\\Local\\DevicesFlowUserSvc）。
4. Components/RustDesk.wxs：加 sc failure 自定义动作 —— 服务进程崩溃/被杀后
   Windows 服务管理器 60 秒内自动拉起（恢复计数每天重置）。
   这样「控制端远程结束受控端进程」就等于「远程重启受控端软件」，
   与 NSIS Setup 壳（agent_setup.nsi 已配 sc failure）行为一致。
"""

import os
import sys


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
    """RustDesk.wxs：安装末尾跑 sc failure 配服务自动恢复（对齐 NSIS 壳）。"""
    p = os.path.join(root, 'res', 'msi', 'Package', 'Components', 'RustDesk.wxs')
    if not os.path.isfile(p):
        raise SystemExit('RustDesk.wxs not found: %s' % p)
    src = read(p)

    if 'SetServiceRecovery' in src:
        print('RustDesk.wxs already patched (service recovery)')
        return

    # 1) CustomAction 定义：插在 TryStopDeleteService.SetParam 之后。
    #    WiX v4 Directory+ExeCommand = 追加成完整命令行
    #    [SystemFolder]sc.exe failure <Product> reset= 86400 actions= restart/60000 ...
    anchor_def = ('<CustomAction Id="TryStopDeleteService.SetParam" '
                  'Return="check" Property="TryStopDeleteService" '
                  'Value="$(var.Product)" />')
    idx = src.find(anchor_def)
    if idx < 0:
        raise SystemExit('patch failed: TryStopDeleteService.SetParam anchor')
    end = src.find('\n', idx) + 1
    ins_def = ('\t\t<!-- agent: service auto-recovery, restart 60s after crash, '
               'reset counter daily -->\n'
               '\t\t<CustomAction Id="SetServiceRecovery" Directory="SystemFolder" '
               'ExeCommand="sc.exe failure $(var.Product) '
               'reset= 86400 actions= restart/60000 restart/60000 '
               'restart/60000" Return="ignore" Impersonate="no" '
               'Execute="deferred" />\n')
    src = src[:end] + ins_def + src[end:]

    # 2) 排序：紧跟 CreateStartService（同一条件：装/升级且建了服务才配恢复）。
    anchor_seq_start = '<Custom Action="CreateStartService" Before="InstallFinalize"'
    idx = src.find(anchor_seq_start)
    if idx < 0:
        raise SystemExit('patch failed: CreateStartService sequence anchor')
    end = src.find('\n', idx) + 1
    # CreateStartService.SetParam 排在它前面，插入点放在 SetParam 那行之后
    ins_seq = ('\t\t\t<!-- agent: configure service recovery right after the '
               'service is created/started -->\n'
               '\t\t\t<Custom Action="SetServiceRecovery" '
               'After="CreateStartService" '
               'Condition="(NOT (Installed AND REMOVE AND NOT '
               'UPGRADINGPRODUCTCODE)) AND (NOT '
               'STOP_SERVICE=&quot;&apos;Y&apos;&quot;) AND (NOT '
               'CC_CONNECTION_TYPE=&quot;outgoing&quot;)" />\n')
    src = src[:end] + ins_seq + src[end:]

    write(p, src)
    print('patched RustDesk.wxs (service auto-recovery on crash)')


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    patch_shortcut_props(root)
    patch_folders(root)
    patch_service_recovery(root)


if __name__ == '__main__':
    main()
