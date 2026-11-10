#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""安卓端收费门禁：隐私屏 + 文字聊天（与 Windows 同一套 licenseFeature 体系）。

用法: python patch_mobile_privacy_gate.py <rustdesk 源码根目录>

背景：安卓远控会话里的隐私屏、文字聊天本来是免费入口（上游自带），
Windows 端已按附加包收费（kPaidFeatures 里的 'privacy' / 'chat'），
安卓必须同样门禁，否则用户会从手机白嫖。

改法（锚点找不到直接报错退出，宁缺勿错）：
1. `showOptions` 里生成 privacyModeList 的条件加 `licenseFeature('privacy')`；
   未开通时菜单里换成「隐私屏（增值功能，未开通）」引导项；
2. 聊天入口两个函数（showChatOptions / onPressedTextChat）开头加
   `licenseFeature('chat')` 守卫，未开通直接弹引导，不打开聊天窗；
3. 引导弹窗都带「去商城购买」（gotoShop，带对应商品 id）和兑换说明；
   客户端永远不显示金额，价格只在商城套餐里配置。
"""

import os
import sys

REL = os.path.join('flutter', 'lib', 'mobile', 'pages', 'remote_page.dart')

IMPORT_ANCHOR = "import '../widgets/custom_scale_widget.dart';\n"
IMPORT_ADD = (
    "import '../widgets/custom_scale_widget.dart';\n"
    "import '../../desktop/pages/license_client.dart';\n"
)

GATE_ANCHOR = """  List<TToggleMenu> privacyModeList = [];
  if ((gFFI.ffiModel.pi.features.privacyMode && gFFI.ffiModel.keyboard) ||
      privacyModeState.isNotEmpty) {
"""
GATE_NEW = """  List<TToggleMenu> privacyModeList = [];
  // 【HyDesk】隐私屏为收费附加包：未开通不给开关，菜单换引导项（同 Windows）。
  final bool hyPrivacyLicensed = licenseFeature('privacy');
  if (hyPrivacyLicensed &&
      ((gFFI.ffiModel.pi.features.privacyMode && gFFI.ffiModel.keyboard) ||
          privacyModeState.isNotEmpty)) {
"""

WIDGET_ANCHOR = """    Widget privacyModeWidget = Offstage();
    if (privacyModeList.length > 1) {
"""
WIDGET_NEW = """    Widget privacyModeWidget = Offstage();
    if (!hyPrivacyLicensed &&
        ((gFFI.ffiModel.pi.features.privacyMode && gFFI.ffiModel.keyboard) ||
            privacyModeState.isNotEmpty)) {
      privacyModeWidget = ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: const Text('隐私屏（增值功能，未开通）'),
        onTap: () {
          close();
          hyShowPrivacyUpgrade();
        },
      );
    }
    if (privacyModeList.length > 1) {
"""

# 文字聊天：两个入口函数开头加守卫（函数签名唯一，锚点稳）
CHAT_TEXT_ANCHOR = ("  onPressedTextChat(String id, "
                    "{bool requestSoftKeyboard = true}) {\n")
CHAT_TEXT_NEW = (CHAT_TEXT_ANCHOR +
                 "    // 【HyDesk】文字聊天为收费附加包（chat）：未开通弹引导\n"
                 "    if (!licenseFeature('chat')) {\n"
                 "      hyShowChatUpgrade();\n"
                 "      return;\n"
                 "    }\n")

CHAT_OPT_ANCHOR = "  showChatOptions(String id) async {\n"
CHAT_OPT_NEW = (CHAT_OPT_ANCHOR +
                "    // 【HyDesk】文字聊天/语音通话为收费附加包（chat）\n"
                "    if (!licenseFeature('chat')) {\n"
                "      hyShowChatUpgrade();\n"
                "      return;\n"
                "    }\n")

HELPER = r'''
// 【HyDesk】收费附加包引导（安卓）：与 Windows 端同一套 licenseFeature。
// 界面只提示「去商城购买」+「到设置里兑换」，客户端不显示金额。
void hyShowPrivacyUpgrade() {
  gFFI.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Row(children: [
        const Icon(Icons.lock_outline, size: 18),
        const SizedBox(width: 6),
        const Text('隐私屏 · 增值功能'),
      ]),
      content: const Text(
          '隐私屏是付费附加包：开启后受控端本机屏幕将被遮挡，仅远程画面可见。\n'
          '购买后凭授权码到「设置 → 激活 → 兑换附加包」开通，立即生效。'),
      actions: [
        dialogButton('知道了', onPressed: close),
        dialogButton('去商城购买', onPressed: () {
          close();
          gotoShop(context, productId: 'paPrivacy');
        }),
      ],
    );
  }, clickMaskDismiss: true, backDismiss: true);
}

// 【HyDesk】文字聊天收费引导（chat 附加包，含语音通话入口）
void hyShowChatUpgrade() {
  gFFI.dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Row(children: [
        const Icon(Icons.chat_bubble_outline, size: 18),
        const SizedBox(width: 6),
        const Text('文字聊天 · 增值功能'),
      ]),
      content: const Text(
          '文字聊天是付费附加包（含远控会话里的文字消息与语音通话入口）。\n'
          '购买后凭授权码到「设置 → 激活 → 兑换附加包」开通，立即生效。'),
      actions: [
        dialogButton('知道了', onPressed: close),
        dialogButton('去商城购买', onPressed: () {
          close();
          gotoShop(context, productId: 'paChat');
        }),
      ],
    );
  }, clickMaskDismiss: true, backDismiss: true);
}
'''


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    p = os.path.join(root, REL)
    if not os.path.isfile(p):
        raise SystemExit('mobile remote_page.dart not found: %s' % p)

    with open(p, encoding='utf-8') as f:
        src = f.read()

    # 1) import（老版本补丁已加过则跳过）
    if 'desktop/pages/license_client.dart' not in src:
        if src.count(IMPORT_ANCHOR) != 1:
            raise SystemExit('patch failed: import anchor matched %d times'
                             % src.count(IMPORT_ANCHOR))
        src = src.replace(IMPORT_ANCHOR, IMPORT_ADD, 1)

    # 2) 隐私屏门禁（幂等）
    if 'hyPrivacyLicensed' not in src:
        for tag, old, new in (
            ('gate', GATE_ANCHOR, GATE_NEW),
            ('widget', WIDGET_ANCHOR, WIDGET_NEW),
        ):
            n = src.count(old)
            if n != 1:
                raise SystemExit('patch failed: %s anchor matched %d times'
                                 % (tag, n))
            src = src.replace(old, new, 1)

    # 3) 文字聊天门禁（幂等）
    if "licenseFeature('chat')" not in src:
        for tag, old, new in (
            ('chat-text', CHAT_TEXT_ANCHOR, CHAT_TEXT_NEW),
            ('chat-opt', CHAT_OPT_ANCHOR, CHAT_OPT_NEW),
        ):
            n = src.count(old)
            if n != 1:
                raise SystemExit('patch failed: %s anchor matched %d times'
                                 % (tag, n))
            src = src.replace(old, new, 1)

    # 4) 引导弹窗（幂等）：老版本只有「知道了」的隐私屏弹窗，整段换成新版
    if 'void hyShowChatUpgrade' not in src:
        if 'void hyShowPrivacyUpgrade' in src:
            start = src.find('// 【HyDesk】隐私屏收费引导（安卓）')
            if start < 0:
                fn = src.find('void hyShowPrivacyUpgrade')
                start = src.rfind('// 【HyDesk】', 0, fn)
                if start < 0:
                    start = fn
            src = src[:start].rstrip() + '\n' + HELPER
        else:
            src = src.rstrip() + '\n' + HELPER

    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched mobile gates: privacy + chat (licenseFeature)')


if __name__ == '__main__':
    main()
