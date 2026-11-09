#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""安卓端隐私屏收费门禁（与 Windows 同一套 licenseFeature('privacy') 体系）。

用法: python patch_mobile_privacy_gate.py <rustdesk 源码根目录>

背景：安卓远控会话的「显示设置」菜单里本来就带隐私屏开关（上游
toolbarPrivacyMode），但它是免费开关。Windows 端隐私屏已按附加包收费
（kPaidFeatures 里的 'privacy'），安卓必须同样门禁，否则用户会从手机
白嫖隐私屏。

改法（锚点找不到直接报错退出，宁缺勿错）：
1. `showOptions` 里生成 privacyModeList 的条件加 `licenseFeature('privacy')`；
2. 未开通时菜单里换成「隐私屏（增值功能，未开通）」引导项 → 弹窗提示
   去设置里激活（激活页由 patch_license.py 的 android 分支挂进设置）。
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

HELPER = r'''
// 【HyDesk】隐私屏收费引导（安卓）：激活走「设置 → 激活」
//（patch_license.py 的 android 分支挂的入口）。
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
          '如已获取授权码，请到「设置 → 激活」完成激活后重试。'),
      actions: [
        dialogButton('知道了', onPressed: close),
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

    if 'hyPrivacyLicensed' in src:
        print('mobile privacy gate already patched')
        return

    for tag, old, new in (
        ('import', IMPORT_ANCHOR, IMPORT_ADD),
        ('gate', GATE_ANCHOR, GATE_NEW),
        ('widget', WIDGET_ANCHOR, WIDGET_NEW),
    ):
        n = src.count(old)
        if n != 1:
            raise SystemExit('patch failed: %s anchor matched %d times' % (tag, n))
        src = src.replace(old, new, 1)

    src = src.rstrip() + '\n' + HELPER

    with open(p, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)
    print('patched mobile privacy gate (licenseFeature privacy)')


if __name__ == '__main__':
    main()
