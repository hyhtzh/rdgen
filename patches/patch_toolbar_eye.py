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

# 【HyDesk】remote_toolbar.dart 需要 import 授权客户端（licenseFeature/gotoShop）。
LICENSE_IMPORT_ANCHOR = "import 'package:flutter_hbb/models/chat_model.dart';\n"
LICENSE_IMPORT_NEW = (LICENSE_IMPORT_ANCHOR +
    "import 'package:flutter_hbb/desktop/pages/license_client.dart';\n")

# 【HyDesk】聊天文字按钮收费门禁（chat 附加包，10元/月在套餐里配置）：
# 未开通时隐藏原生聊天按钮，开通后出现。
CHAT_ANCHOR = "    toolbarItems.add(_ChatMenu(id: widget.id, ffi: widget.ffi));"
CHAT_NEW = ("    // 【HyDesk】聊天按钮收费门禁（chat 附加包）：未开通不显示\n"
            "    if (licenseFeature('chat')) {\n"
            "      toolbarItems.add(_ChatMenu(id: widget.id, ffi: widget.ffi));\n"
            "    }")

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
void _hyPrivacyUpgradeDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text('隐私屏为增值功能',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      content: const Text(
          '当前授权未包含隐私屏附加包。\n\n购买后凭授权码在「授权详情 → 兑换附加包」里开通，立即生效，不需要重新激活。',
          style: TextStyle(fontSize: 13, height: 1.6)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(ctx).pop();
            gotoShop(context, productId: 'paPrivacy');
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFF1B72D6),
            elevation: 0,
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('去开通', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
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
    if 'final Set<ToolbarState> kWallToolbarStates' not in src:
        src = src.rstrip('\n') + '\n' + WALL_SET
        print('  patch: append kWallToolbarStates')

    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)


if __name__ == '__main__':
    main()
