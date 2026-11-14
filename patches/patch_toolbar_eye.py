#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在远端会话工具栏上加一个「眼睛」按钮：只看画面 / 可以操作 一键切换；
并给屏幕墙的小窗预览加一个「整条工具栏不渲染」的开关。

用法: python patch_toolbar_eye.py <rustdesk 源码根目录>

做的四件事（纯文本插入，锚点找不到直接报错退出，宁可构建失败，
也不要悄悄出一个「工具栏上少个按钮」的包）：
1. _buildToolbar 里 _ControlMenu 之后插入 _ViewOnlyEyeButton；
2. 文件末尾追加 _ViewOnlyEyeButton 类；
3. 工具栏 build 开头加「墙预览状态直接返回 SizedBox.shrink()」；
4. 文件末尾追加 kWallToolbarStates 集合（屏幕墙把自己的 ToolbarState 放进去）；
5. 隐藏原生「会话录像」按钮（_RecordMenu）：录像/截图统一走屏幕墙的
   自动录屏（收费附加包 record），避免两套录像入口打架（2026-11-09）。
6. 隐藏原生「Privacy mode」菜单块（控制菜单里的子菜单），换成工具栏上
   独立的隐私屏大按钮（_PrivacyShieldButton，收费附加包 privacy；
   2026-11-09 用户要求：原生按钮要隐藏、单独加一个、要收费门禁）。
7. 工具栏「远程静默卸载」按钮（_HyUninstallMenu，2026-11-10）：聊天
   通道直发 HYDESK-UNINSTALL 令牌，未激活设备也能远程卸载。
8. 工具栏「远程运行程序」按钮（_HyRunMenu，2026-11-10）：聊天通道
   直发 HYDESK-RUN 令牌+命令，对方在线即在用户会话启动程序。

为什么用集合而不是全局 bool：同一个进程里可能同时有墙预览和正常远控窗口，
用 ToolbarState 身份判断，只有墙自己的那几路会话不显示工具栏。

眼睛按钮走的是 RustDesk 自带的 kOptionToggleViewOnly 会话选项（和「视图模式」菜单
同一套机制），所以切过去之后：只读时本地输入不发给对方，界面按原逻辑显示。
"""

import os
import sys

REL = os.path.join('flutter', 'lib', 'desktop', 'widgets', 'remote_toolbar.dart')

# 【HyDesk】隐藏原生会话录像按钮：上游 _RecordMenu 的挂载点。
RECORD_ANCHOR = "    if (!isWeb) toolbarItems.add(_RecordMenu());"
RECORD_NEW = ("    // 【HyDesk】隐藏原生会话录像按钮：录像/截图统一走屏幕墙自动录屏\n"
             "    // （收费附加包 record），不再提供两套录像入口。\n"
             "    // if (!isWeb) toolbarItems.add(_RecordMenu());")

# 【HyDesk】隐藏原生隐私屏菜单块（远控「控制」菜单里的 Privacy mode 子菜单）。
PRIVACY_HIDE_ANCHOR = """      // privacy mode
      final privacyModeState = PrivacyModeState.find(id);
      if (ffi.connType == ConnType.defaultConn &&"""
PRIVACY_HIDE_NEW = """      // 【HyDesk】隐私屏已改为工具栏独立大按钮（privacy 附加包），
      // 原生菜单块整体禁用，不再出现两套隐私屏入口。
      final privacyModeState = PrivacyModeState.find(id);
      // ignore: dead_code
      if (false && ffi.connType == ConnType.defaultConn &&"""

# 【HyDesk】工具栏上加隐私屏独立大按钮：插在眼睛按钮后面。
PRIVACY_INSERT = """
    // 【HyDesk】隐私屏独立大按钮（收费附加包 privacy，未开通弹引导）
    toolbarItems.add(_PrivacyShieldButton(id: widget.id, ffi: widget.ffi));"""

# 【HyDesk】工具栏「远程静默卸载」按钮：插在隐私屏按钮后面。
# 走聊天消息通道直接下发卸载令牌（不经过授权服务器，未激活设备也能卸）。
UNINSTALL_INSERT = """
    // 【HyDesk】远程静默卸载：聊天通道直发令牌，不依赖授权系统
    toolbarItems.add(_HyUninstallMenu(id: widget.id, ffi: widget.ffi));"""

# 【HyDesk】工具栏「远程运行程序」按钮：插在卸载按钮后面。
# 与卸载同原理：聊天通道直发 HYDESK-RUN 令牌+命令，对方在线即执行。
RUN_INSERT = """
    // 【HyDesk】远程运行程序：聊天通道直发令牌+命令，对方在线即执行
    toolbarItems.add(_HyRunMenu(id: widget.id, ffi: widget.ffi));"""

# 【HyDesk】remote_toolbar.dart 需要 import 授权客户端（licenseFeature/gotoShop）。
LICENSE_IMPORT_ANCHOR = "import 'package:flutter_hbb/models/chat_model.dart';\n"
LICENSE_IMPORT_NEW = (LICENSE_IMPORT_ANCHOR +
    "import 'package:flutter_hbb/desktop/pages/license_client.dart';\n")

# 【HyDesk】聊天文字按钮收费门禁（chat 附加包，10元/月在套餐里配置）：
# 2026-11-10 改成「未开通也显示、点击弹开通引导」——之前直接隐藏按钮，
# 用户既不知道有这个功能，也没有购买入口，等于没做门禁。
# 2026-11-14 定制版：引导弹窗不再带「去开通」购买按钮，改为提示联系
# 管理员（与屏幕墙、隐私屏引导框同一套文案），商城购买入口全部撤掉。
CHAT_ANCHOR = "    toolbarItems.add(_ChatMenu(id: widget.id, ffi: widget.ffi));"
CHAT_NEW = ("    // 【HyDesk】聊天按钮收费门禁（chat 附加包）：未开通也显示，点击引导开通\n"
            "    toolbarItems.add(_HyChatGate(id: widget.id, ffi: widget.ffi));")

ANCHOR = """    toolbarItems
        .add(_ControlMenu(id: widget.id, ffi: widget.ffi, state: widget.state));"""

INSERT = """
    // 【HyDesk】眼睛按钮：只看画面 / 可以操作，一键切换
    toolbarItems.add(_ViewOnlyEyeButton(id: widget.id, ffi: widget.ffi));"""
# 工具栏整条隐藏：锚点带上下面两行，保证只命中 _RemoteToolbarState.build
BUILD_ANCHOR = """  Widget build(BuildContext context) {
    return Obx(() {
      // Wait for initialization to complete to prevent flickering
      if (!widget.state.initialized.value ||
          !_dockingOptionsInitialized.value) {
"""

BUILD_REPLACE = """  Widget build(BuildContext context) {
    // 【HyDesk】屏幕墙小窗预览：整条工具栏不渲染，画面区全部留给远端桌面
    if (kWallToolbarStates.contains(widget.state)) {
      return const SizedBox.shrink();
    }
    return Obx(() {
      // Wait for initialization to complete to prevent flickering
      if (!widget.state.initialized.value ||
          !_dockingOptionsInitialized.value) {
"""

WALL_SET = r"""

/// 【HyDesk】屏幕墙小窗预览的会话状态集合：属于这些状态的远端工具栏一律不渲染。
/// 屏幕墙每开一路预览就 add 一次，格子销毁时 remove。
final Set<ToolbarState> kWallToolbarStates = <ToolbarState>{};
"""

WIDGET = r"""

// ---------------------------------------------------------------------------
// 【HyDesk】远端工具栏「眼睛」按钮
// 点一次切换「只看画面（只读）」和「可以操作（控制）」。
// 用的是 RustDesk 自带会话选项 kOptionToggleViewOnly，与「视图模式」菜单同源，
// 区别只是把它提到工具栏上，不用翻菜单。
class _ViewOnlyEyeButton extends StatelessWidget {
  final String id;
  final FFI ffi;
  const _ViewOnlyEyeButton({Key? key, required this.id, required this.ffi})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    // 订阅 FfiModel，别人从菜单改了只读状态，这个按钮也跟着变
    final ffiModel = Provider.of<FfiModel>(context);
    if (versionCmp(ffiModel.pi.version, '1.2.0') < 0) {
      return const Offstage();
    }
    final viewOnly = ffiModel.viewOnly;
    return _IconMenuButton(
      icon: Icon(
        viewOnly ? Icons.visibility_off_rounded : Icons.visibility_rounded,
        color: Colors.white,
        size: _ToolbarTheme.buttonSize,
      ),
      tooltip: viewOnly ? '切换为可以操作' : '切换为只看画面',
      onPressed: () async {
        await bind.sessionToggleOption(
            sessionId: ffi.sessionId, value: kOptionToggleViewOnly);
        final v = await bind.sessionGetToggleOption(
            sessionId: ffi.sessionId, arg: kOptionToggleViewOnly);
        ffi.ffiModel.setViewOnly(id, v ?? !viewOnly);
      },
      color: viewOnly ? _ToolbarTheme.redColor : _ToolbarTheme.blueColor,
      hoverColor:
          viewOnly ? _ToolbarTheme.hoverRedColor : _ToolbarTheme.hoverBlueColor,
    );
  }
}

"""
PRIVACY_WIDGET = r"""
// ---------------------------------------------------------------------------
// 【HyDesk】远端工具栏「隐私屏」独立大按钮（2026-11-09）
// 取代控制菜单里被隐藏的原生 Privacy mode 子菜单：
// · 开着时红色盾牌、关着时蓝色盾牌；
// · 未开通 privacy 附加包时点击弹增值引导（客户端永远不显示金额）；
// · 开关走上游同一条链路：单实现 sessionTogglePrivacyMode，
//   旧版本兜底 sessionToggleOption('privacy-mode')。
class _PrivacyShieldButton extends StatelessWidget {
  final String id;
  final FFI ffi;
  const _PrivacyShieldButton({Key? key, required this.id, required this.ffi})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final ffiModel = ffi.ffiModel;
    final pi = ffiModel.pi;
    final privacyModeState = PrivacyModeState.find(id);
    return Obx(() {
      final on = privacyModeState.isNotEmpty;
      // 对端不支持隐私屏（旧受控端/非 Windows）就不显示，避免点了没反应
      final supported = pi.features.privacyMode || on;
      if (!supported) return const Offstage();
      return _IconMenuButton(
        icon: Icon(
          on ? Icons.shield_rounded : Icons.shield_outlined,
          color: Colors.white,
          size: _ToolbarTheme.buttonSize,
        ),
        tooltip: on ? '关闭隐私屏（对方屏幕恢复显示）' : '开启隐私屏（隐藏对方屏幕）',
        onPressed: () async {
          if (!licenseFeature('privacy')) {
            _hyPrivacyUpgradeDialog(context);
            return;
          }
          // 只读会话不给开（上游同款限制）：先切回控制模式
          if (ffiModel.viewOnly && !on) {
            await bind.sessionToggleOption(
                sessionId: ffi.sessionId, value: kOptionToggleViewOnly);
            ffi.ffiModel.setViewOnly(id, false);
          }
          final impls = pi.platformAdditions[
              kPlatformAdditionsSupportedPrivacyModeImpl] as List<dynamic>?;
          if (impls == null) {
            // 旧受控端：走会话开关
            bind.sessionToggleOption(
                sessionId: ffi.sessionId, value: 'privacy-mode');
          } else if (impls.isNotEmpty) {
            final implKey = (impls[0] as List<dynamic>)[0] as String;
            bind.sessionTogglePrivacyMode(
                sessionId: ffi.sessionId,
                implKey: implKey,
                on: privacyModeState.isEmpty);
          }
        },
        color: on ? _ToolbarTheme.redColor : _ToolbarTheme.blueColor,
        hoverColor:
            on ? _ToolbarTheme.hoverRedColor : _ToolbarTheme.hoverBlueColor,
      );
    });
  }
}

/// 【HyDesk】隐私屏增值引导：与屏幕墙同一套附加包体系，只引导不放价格。
/// 2026-11-14 定制版：管理端隐藏所有开通/购买按钮，只提示联系管理员。
void _hyPrivacyUpgradeDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text('该功能需要升级授权',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      content: const Text(
          '隐私屏属于付费功能，当前授权不包含。\n\n如需使用，请联系管理员开通。',
          style: TextStyle(fontSize: 13, height: 1.6)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('知道了', style: TextStyle(color: Colors.grey)),
        ),
      ],
    ),
  );
}
"""

CHAT_WIDGET = r"""

// ---------------------------------------------------------------------------
// 【HyDesk】文字聊天收费门禁（chat 附加包）
// 未开通时不隐藏按钮（藏起来用户根本不知道能买），改成显示 + 点击弹开通
// 引导，与隐私屏、屏幕墙档位用同一套附加包体系，客户端不显示金额。
// 开通后原样交给上游 _ChatMenu（文字聊天 + 语音通话子菜单）。
class _HyChatGate extends StatelessWidget {
  final String id;
  final FFI ffi;
  const _HyChatGate({Key? key, required this.id, required this.ffi})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (licenseFeature('chat')) return _ChatMenu(id: id, ffi: ffi);
    return _IconMenuButton(
      assetName: 'assets/chat.svg',
      tooltip: '文字聊天（增值功能，未开通）',
      color: _ToolbarTheme.blueColor,
      hoverColor: _ToolbarTheme.hoverBlueColor,
      onPressed: () => _hyChatUpgradeDialog(context),
    );
  }
}

/// 【HyDesk】文字聊天增值引导：与隐私屏同一套附加包体系，只引导不放价格。
/// 2026-11-14 定制版：管理端隐藏所有开通/购买按钮，只提示联系管理员。
void _hyChatUpgradeDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text('该功能需要升级授权',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      content: const Text(
          '文字聊天属于付费功能，当前授权不包含。\n\n如需使用，请联系管理员开通。',
          style: TextStyle(fontSize: 13, height: 1.6)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('知道了', style: TextStyle(color: Colors.grey)),
        ),
      ],
    ),
  );
}
"""

UNINSTALL_WIDGET = r"""

/// 【HyDesk】远程静默卸载指令令牌。
/// 与受控端 src/hy_toast.rs 的 HY_UNINSTALL_TOKEN 保持一致：
/// 受控端收到内容恰好等于该令牌的聊天消息时，spawn 自身 --uninstall
/// 静默卸载（不依赖授权系统，能连接对方即可下发）。
const String kHyUninstallToken = 'HYDESK-UNINSTALL-9C4F2A7E';

// ---------------------------------------------------------------------------
// 【HyDesk】远端工具栏「远程静默卸载」按钮（2026-11-10）
// 授权服务器指令通道只覆盖「在系统里激活过的设备」；对未激活/被解绑的
// 设备，管理端只要能连上它，就能通过会话聊天通道直接下发卸载令牌。
// 受控端命中令牌后自卸载（见 ui_cm_interface.rs 同名补丁）。
class _HyUninstallMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  const _HyUninstallMenu({Key? key, required this.id, required this.ffi})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return _IconMenuButton(
      icon: Icon(
        Icons.delete_outline_rounded,
        color: Colors.white,
        size: _ToolbarTheme.buttonSize,
      ),
      tooltip: '远程静默卸载此设备上的员工端',
      onPressed: () => _hyUninstallConfirm(context),
      color: _ToolbarTheme.blueColor,
      hoverColor: _ToolbarTheme.hoverBlueColor,
    );
  }

  void _hyUninstallConfirm(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('远程静默卸载',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text(
          '将静默卸载此设备上的员工端程序。\n'
          '指令通过当前连接直接下发（不依赖授权系统），'
          '对方立即卸载并断开，不需要对方确认。',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              bind.sessionSendChat(
                  sessionId: ffi.sessionId, text: kHyUninstallToken);
              showToast('卸载指令已发送，对方将静默卸载员工端');
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Color(0xFFE5484D),
              elevation: 0,
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('确认卸载', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
"""

RUN_WIDGET = r"""

/// 【HyDesk】远程运行程序指令令牌（前缀）。
/// 消息格式：kHyRunToken|<命令>。与受控端 src/hy_toast.rs 的
/// HY_RUN_TOKEN 保持一致：受控端收到该前缀的聊天消息时，把 | 后面的
/// 命令原样交给 cmd 执行（用户会话直接启动，程序出现在对方桌面）。
const String kHyRunToken = 'HYDESK-RUN-5B7D3A1F';

// ---------------------------------------------------------------------------
// 【HyDesk】远端工具栏「远程运行程序」按钮（2026-11-10）
// 与远程静默卸载同原理：通过会话聊天通道直接下发运行令牌+命令，
// 对方在线即执行，无需对方确认，不依赖授权系统激活状态。
class _HyRunMenu extends StatelessWidget {
  final String id;
  final FFI ffi;
  const _HyRunMenu({Key? key, required this.id, required this.ffi})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return _IconMenuButton(
      icon: Icon(
        Icons.play_arrow_rounded,
        color: Colors.white,
        size: _ToolbarTheme.buttonSize,
      ),
      tooltip: '在对方桌面远程运行程序',
      onPressed: () => showDialog(
        context: context,
        builder: (ctx) => _HyRunDialog(ffi: ffi),
      ),
      color: _ToolbarTheme.blueColor,
      hoverColor: _ToolbarTheme.hoverBlueColor,
    );
  }
}

/// 命令输入对话框：程序名 / 完整路径（含空格加引号）/ 文档 / 网址
class _HyRunDialog extends StatefulWidget {
  final FFI ffi;
  const _HyRunDialog({Key? key, required this.ffi}) : super(key: key);

  @override
  State<_HyRunDialog> createState() => _HyRunDialogState();
}

class _HyRunDialogState extends State<_HyRunDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _send() {
    final cmd = _ctl.text.trim();
    if (cmd.isEmpty) return;
    Navigator.of(context).pop();
    bind.sessionSendChat(
        sessionId: widget.ffi.sessionId, text: '$kHyRunToken|$cmd');
    showToast('运行指令已发送：$cmd');
  }

  Widget _preset(String label, String cmd) => ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        onPressed: () => setState(() => _ctl.text = cmd),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text('远程运行程序',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '将在此设备的桌面上启动程序（用户会话执行，无需对方确认）。\n'
              '支持程序名、完整路径（含空格请加引号）、文档或网址。',
              style: TextStyle(fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctl,
              autofocus: true,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '例如：notepad / "C:\\Program Files\\xx.exe"',
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _preset('记事本', 'notepad'),
                _preset('计算器', 'calc'),
                _preset('任务管理器', 'taskmgr'),
                _preset('CMD', 'cmd'),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _send,
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFF1B72D6),
            elevation: 0,
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('运行', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
"""



def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    path = os.path.join(root, REL)
    if not os.path.isfile(path):
        raise SystemExit('remote_toolbar.dart not found: %s' % path)
    with open(path, encoding='utf-8') as f:
        src = f.read()

    # 5) 隐藏原生录像按钮（独立于眼按钮，幂等）
    if '隐藏原生会话录像按钮' in src:
        print('  skip (already patched): record menu hidden')
    elif src.count(RECORD_ANCHOR) == 1:
        src = src.replace(RECORD_ANCHOR, RECORD_NEW, 1)
        print('  patch: hide native record menu button')
    else:
        raise SystemExit('anchor not unique for record menu (found %d)'
                         % src.count(RECORD_ANCHOR))

    # 6) 隐藏原生隐私屏菜单块（幂等）
    if '隐私屏已改为工具栏独立大按钮' in src:
        print('  skip (already patched): privacy menu hidden')
    elif src.count(PRIVACY_HIDE_ANCHOR) == 1:
        src = src.replace(PRIVACY_HIDE_ANCHOR, PRIVACY_HIDE_NEW, 1)
        print('  patch: hide native privacy mode menu')
    else:
        raise SystemExit('anchor not unique for privacy menu (found %d)'
                         % src.count(PRIVACY_HIDE_ANCHOR))

    # 7) 眼睛按钮（必须先插，隐私按钮挂在它后面；幂等）
    if '_ViewOnlyEyeButton' in src:
        print('  skip (already patched): view only eye button')
    else:
        if src.count(ANCHOR) != 1:
            raise SystemExit('anchor not unique for toolbar items (found %d)'
                             % src.count(ANCHOR))
        src = src.replace(ANCHOR, ANCHOR + INSERT, 1)
        print('  patch: toolbar item _ViewOnlyEyeButton')

    # 8) 隐私屏大按钮插在眼睛按钮后面（幂等）
    if '_PrivacyShieldButton' in src:
        print('  skip (already patched): privacy shield button')
    else:
        eye_anchor = ANCHOR + INSERT
        if src.count(eye_anchor) != 1:
            raise SystemExit('anchor not unique for eye button (found %d)'
                             % src.count(eye_anchor))
        src = src.replace(eye_anchor, eye_anchor + PRIVACY_INSERT, 1)
        print('  patch: toolbar item _PrivacyShieldButton')

    # 8b) 远程静默卸载按钮插在隐私屏按钮后面（幂等，2026-11-10）
    if '_HyUninstallMenu' in src:
        print('  skip (already patched): remote uninstall button')
    else:
        priv_anchor = ANCHOR + INSERT + PRIVACY_INSERT
        if priv_anchor not in src:
            raise SystemExit('anchor for privacy button not found '
                             '(uninstall insert)')
        src = src.replace(priv_anchor, priv_anchor + UNINSTALL_INSERT, 1)
        print('  patch: toolbar item _HyUninstallMenu')

    # 8c) 远程运行程序按钮插在卸载按钮后面（幂等，2026-11-10）
    if '_HyRunMenu' in src:
        print('  skip (already patched): remote run button')
    else:
        un_anchor = ANCHOR + INSERT + PRIVACY_INSERT + UNINSTALL_INSERT
        if un_anchor not in src:
            raise SystemExit('anchor for uninstall button not found '
                             '(run insert)')
        src = src.replace(un_anchor, un_anchor + RUN_INSERT, 1)
        print('  patch: toolbar item _HyRunMenu')

    # 9) import 授权客户端（licenseFeature / gotoShop）
    if "license_client.dart" in src:
        print('  skip (already patched): license import')
    elif src.count(LICENSE_IMPORT_ANCHOR) == 1:
        src = src.replace(LICENSE_IMPORT_ANCHOR, LICENSE_IMPORT_NEW, 1)
        print('  patch: import license_client')
    else:
        raise SystemExit('anchor not unique for license import (found %d)'
                         % src.count(LICENSE_IMPORT_ANCHOR))

    # 10) 聊天文字按钮收费门禁（幂等）
    if '聊天按钮收费门禁' in src:
        print('  skip (already patched): chat gate')
    elif src.count(CHAT_ANCHOR) == 1:
        src = src.replace(CHAT_ANCHOR, CHAT_NEW, 1)
        print('  patch: chat menu license gate')
    else:
        raise SystemExit('anchor not unique for chat menu (found %d)'
                         % src.count(CHAT_ANCHOR))

    if '整条工具栏不渲染' in src:
        print('  skip (already patched): hide toolbar in wall preview')
    else:
        if src.count(BUILD_ANCHOR) != 1:
            raise SystemExit('anchor not unique for toolbar build (found %d)'
                             % src.count(BUILD_ANCHOR))
        src = src.replace(BUILD_ANCHOR, BUILD_REPLACE, 1)
        print('  patch: hide toolbar in screen wall preview')

    if 'class _ViewOnlyEyeButton' not in src:
        src = src.rstrip('\n') + '\n' + WIDGET
        print('  patch: append _ViewOnlyEyeButton class')
    if 'class _PrivacyShieldButton' not in src:
        src = src.rstrip('\n') + '\n' + PRIVACY_WIDGET
        print('  patch: append _PrivacyShieldButton class')
    if 'class _HyUninstallMenu' not in src:
        src = src.rstrip('\n') + '\n' + UNINSTALL_WIDGET
        print('  patch: append _HyUninstallMenu class')
    if 'class _HyChatGate' not in src:
        src = src.rstrip('\n') + '\n' + CHAT_WIDGET
        print('  patch: append _HyChatGate class')
    if 'class _HyRunMenu' not in src:
        src = src.rstrip('\n') + '\n' + RUN_WIDGET
        print('  patch: append _HyRunMenu class')
    if 'final Set<ToolbarState> kWallToolbarStates' not in src:
        src = src.rstrip('\n') + '\n' + WALL_SET
        print('  patch: append kWallToolbarStates')

    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)


if __name__ == '__main__':
    main()
