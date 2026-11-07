// 设置页（控制端 / 被控端共用）。
//
// 为什么自己写一套，而不是用上游 DesktopSettingPage：
// 上游那套依赖 DesktopTabPage / DesktopHomePage 启动时注册的全局状态
// （GetX 的 Rx、PageController、Provider 的 ServerModel）。我们把首页整体换成了
// 自绘页面，那些状态从来没建过，于是设置页在独立路由里渲染不出内容
// —— 左侧导航正常、右侧一片空白，release 包里就是「设置界面啥都没有」。
//
// 这里只调 bind 的 FFI 接口，布局用最简单的 Column + Row + ListView，
// 不引用上游设置页体系，任何一项接口不可用也只是那一项不生效。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';

const _kBrandUrl = 'http://ww.hydesk.cn';

/// 配色，与首页保持一致
class _SC {
  static const blue = Color(0xFF1B72D6);
  static const text = Color(0xFF333333);
  static const sub = Color(0xFF7A7A7A);
  static const line = Color(0xFFE7E7E7);
  static const titleBg = Color(0xFFF7F7F7);
}

class SettingsRoute extends StatefulWidget {
  /// 打开时默认选中的页签：0 常规 / 1 安全 / 2 显示 / 3 关于。
  /// 被控端从「设置固定密码」进来时直接落到「安全」。
  final int initialTab;

  const SettingsRoute({Key? key, this.initialTab = 0}) : super(key: key);

  @override
  State<SettingsRoute> createState() => _SettingsRouteState();
}

class _SettingsRouteState extends State<SettingsRoute> {
  static const _tabLabels = ['常规', '安全', '显示', '关于'];
  static const _tabIcons = [
    Icons.tune,
    Icons.shield_outlined,
    Icons.desktop_windows_outlined,
    Icons.info_outline,
  ];

  late int _tab = widget.initialTab.clamp(0, _tabLabels.length - 1);
  ThemeMode _theme = ThemeMode.system;
  List<List<String>> _langs = const [];
  String _lang = '';
  String _version = '';
  String _quality = 'balanced';

  @override
  void initState() {
    super.initState();
    try {
      _theme = MyTheme.getThemeModePreference();
    } catch (_) {}
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await bind.mainGetLangs();
      final list = (jsonDecode(raw) as List)
          .map((e) => <String>['${e[0]}', '${e[1]}'])
          .toList();
      if (mounted) setState(() => _langs = list);
    } catch (_) {}
    try {
      final cur = bind.mainGetLocalOption(key: kCommConfKeyLang);
      if (mounted) setState(() => _lang = cur);
    } catch (_) {}
    try {
      final v = await bind.mainGetVersion();
      if (mounted && v != null) setState(() => _version = '$v');
    } catch (_) {}
    try {
      final q = await bind.mainGetUserDefaultOption(key: kOptionImageQuality);
      if (mounted && q is String && q.isNotEmpty) setState(() => _quality = q);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle.merge(
      style: const TextStyle(decoration: TextDecoration.none),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: LayoutBuilder(
          builder: (ctx, c) {
            // 自检：窗口约束异常时不要给一片白，直接把尺寸写在屏幕上，
            // 免得「白屏」这种问题只能靠猜。
            if (!c.hasBoundedWidth ||
                !c.hasBoundedHeight ||
                c.maxWidth < 240 ||
                c.maxHeight < 160) {
              return Center(
                child: Text(
                  '窗口尺寸异常：${c.maxWidth.toStringAsFixed(0)} × '
                  '${c.maxHeight.toStringAsFixed(0)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFFB00020)),
                ),
              );
            }
            return Column(
              children: [
                _bar(context),
                Expanded(
                  child: Row(
                    children: [
                      _nav(),
                      Container(width: 1, color: _SC.line),
                      Expanded(child: _body()),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------------- 左侧导航 ----------------

  Widget _nav() {
    return Container(
      width: 170,
      color: const Color(0xFFFAFAFA),
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          for (var i = 0; i < _tabLabels.length; i++)
            InkWell(
              onTap: () => setState(() => _tab = i),
              child: Container(
                height: 38,
                padding: const EdgeInsets.only(left: 13),
                decoration: BoxDecoration(
                  color: _tab == i ? Colors.white : Colors.transparent,
                  border: Border(
                    left: BorderSide(
                      width: 3,
                      color: _tab == i ? _SC.blue : Colors.transparent,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(_tabIcons[i],
                        size: 16,
                        color: _tab == i ? _SC.blue : const Color(0xFF8A8A8A)),
                    const SizedBox(width: 10),
                    Text(
                      _tabLabels[i],
                      style: TextStyle(
                        fontSize: 13,
                        color: _tab == i ? _SC.blue : _SC.text,
                        fontWeight:
                            _tab == i ? FontWeight.w500 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---------------- 右侧内容 ----------------

  Widget _body() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        Text(_tabLabels[_tab],
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _SC.text)),
        const SizedBox(height: 14),
        ..._content(),
      ],
    );
  }

  List<Widget> _content() {
    switch (_tab) {
      case 0:
        return _general();
      case 1:
        return _security();
      case 2:
        return _display();
      default:
        return _about();
    }
  }

  List<Widget> _general() {
    return [
      _card('外观', [
        _row('语言', _langPicker()),
        const SizedBox(height: 4),
        _row('主题', _themePicker()),
      ]),
      _card('说明', [
        const Text(
          '语言切换后窗口会重载；主题只影响系统窗口配色，界面本身是固定浅色。',
          style: TextStyle(fontSize: 12.5, height: 1.65, color: _SC.sub),
        ),
      ]),
    ];
  }

  List<Widget> _security() {
    return [
      _card('固定密码', [
        const Text(
          '设置后，对方连接本机时必须输入这个密码。留空保存即清除。',
          style: TextStyle(fontSize: 12.5, height: 1.65, color: _SC.sub),
        ),
        const SizedBox(height: 14),
        _primaryBtn('设置固定密码', _setPassword),
      ]),
      _card('提示', [
        const Text(
          '验证码（一次性密码）每次连接后会自动更换，适合临时授权；'
          '固定密码长期有效，适合自己常用的设备。两者同时存在时，任一通过即可连接。',
          style: TextStyle(fontSize: 12.5, height: 1.65, color: _SC.sub),
        ),
      ]),
    ];
  }

  List<Widget> _display() {
    return [
      _card('画面质量', [
        _row(
          '画质',
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _seg('最佳', _quality == 'best', () => _setQuality('best')),
              _seg('平衡', _quality == 'balanced', () => _setQuality('balanced')),
              _seg('低', _quality == 'low', () => _setQuality('low')),
            ],
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          '画质越高画面越清晰，占用的带宽也越多。网络不好时选「平衡」或「低」会更流畅。',
          style: TextStyle(fontSize: 12.5, height: 1.65, color: _SC.sub),
        ),
      ]),
    ];
  }

  List<Widget> _about() {
    String id = '';
    try {
      id = gFFI.serverModel.serverId.text;
    } catch (_) {}
    return [
      _card('关于', [
        _row('产品名称',
            Text(appName, style: const TextStyle(fontSize: 13, color: _SC.sub))),
        _row('版本',
            Text(_version.isEmpty ? '-' : _version,
                style: const TextStyle(fontSize: 13, color: _SC.sub))),
        _row('本机识别码',
            Text(id.isEmpty ? '-' : id,
                style: const TextStyle(fontSize: 13, color: _SC.sub))),
        _row('官方网站',
            Text(_kBrandUrl,
                style: const TextStyle(fontSize: 13, color: _SC.blue))),
      ]),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text(
          '本软件仅用于本人拥有所有权或已获得设备所有者明确许可的设备。',
          style: TextStyle(fontSize: 12, height: 1.6, color: _SC.sub),
        ),
      ),
    ];
  }

  // ---------------- 组件 ----------------

  Widget _card(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _SC.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: _SC.text)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _row(String label, Widget trailing) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(label,
                style: const TextStyle(fontSize: 13, color: _SC.text)),
          ),
          Expanded(
            child: Align(alignment: Alignment.centerLeft, child: trailing),
          ),
        ],
      ),
    );
  }

  Widget _seg(String text, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? const Color(0xFFEAF2FD) : Colors.white,
            borderRadius: BorderRadius.circular(4),
            border:
                Border.all(color: active ? _SC.blue : const Color(0xFFDDDDDD)),
          ),
          child: Text(text,
              style: TextStyle(
                  fontSize: 12.5, color: active ? _SC.blue : _SC.text)),
        ),
      ),
    );
  }

  Widget _primaryBtn(String text, VoidCallback onTap) {
    return SizedBox(
      height: 32,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: _SC.blue,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          textStyle: const TextStyle(fontSize: 12.5),
        ),
        child: Text(text),
      ),
    );
  }

  Widget _langPicker() {
    final entries = <List<String>>[
      [defaultOptionLang, '默认'],
      ..._langs,
    ];
    final keys = <String>{for (final e in entries) e[0]}.toList();
    final value = keys.contains(_lang) ? _lang : entries.first[0];
    return SizedBox(
      width: 200,
      height: 36,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          style: const TextStyle(fontSize: 13, color: _SC.text),
          items: [
            for (final e in entries)
              DropdownMenuItem<String>(
                value: e[0],
                child: Text(e[1],
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) {
            if (v != null && v != value) _setLang(v);
          },
        ),
      ),
    );
  }

  Widget _themePicker() {
    const modes = [ThemeMode.light, ThemeMode.dark, ThemeMode.system];
    const labels = ['浅色', '深色', '跟随系统'];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < modes.length; i++)
          _seg(labels[i], _theme == modes[i], () => _setTheme(modes[i])),
      ],
    );
  }

  // ---------------- 动作 ----------------

  Future<void> _setLang(String v) async {
    setState(() => _lang = v);
    try {
      await bind.mainSetLocalOption(key: kCommConfKeyLang, value: v);
      await bind.mainChangeLanguage(lang: v);
      await reloadAllWindows();
    } catch (_) {}
  }

  Future<void> _setTheme(ThemeMode m) async {
    setState(() => _theme = m);
    try {
      await MyTheme.changeDarkMode(m);
    } catch (_) {}
  }

  Future<void> _setQuality(String q) async {
    setState(() => _quality = q);
    try {
      await bind.mainSetUserDefaultOption(key: kOptionImageQuality, value: q);
    } catch (_) {}
  }

  Future<void> _setPassword() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置固定密码', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 300,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            obscureText: true,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(hintText: '留空保存 = 清除固定密码'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    bool done = false;
    try {
      done = (await bind.mainSetPermanentPasswordWithResult(
              password: ctrl.text)) ==
          true;
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(done ? '固定密码已更新' : '保存失败，请重试'),
      duration: const Duration(seconds: 2),
    ));
  }

  Widget _bar(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) async {
        try {
          await windowManager.startDragging();
        } catch (_) {}
      },
      child: Container(
        height: 40,
        decoration: const BoxDecoration(
          color: _SC.titleBg,
          border: Border(bottom: BorderSide(color: _SC.line)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              borderRadius: BorderRadius.circular(6),
              child: const SizedBox(
                width: 30,
                height: 26,
                child:
                    Icon(Icons.arrow_back, size: 18, color: Color(0xFF616161)),
              ),
            ),
            const SizedBox(width: 6),
            const Text('设置',
                style: TextStyle(fontSize: 13.5, color: _SC.text)),
            const Spacer(),
            _winBtn(Icons.remove, () async {
              try {
                await windowManager.minimize();
              } catch (_) {}
            }),
            _winBtn(Icons.close, () async {
              try {
                await windowManager.hide();
              } catch (_) {}
            }),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _winBtn(IconData icon, VoidCallback onTap) {
    return SizedBox(
      width: 34,
      height: 28,
      child: InkWell(
        onTap: onTap,
        child: Icon(icon, size: 14, color: const Color(0xFF616161)),
      ),
    );
  }
}
