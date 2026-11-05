import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart' show setPasswordDialog;
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';

/// 极简被控端首页。
///
/// 只保留 ID / 密码 / 复制 / 设置固定密码 / 两个开关，隐藏连接入口、侧边栏、
/// 帮助卡片与在线状态，用于「只被控」的贴牌客户端。
class SimpleHostPage extends StatefulWidget {
  const SimpleHostPage({Key? key}) : super(key: key);

  @override
  State<SimpleHostPage> createState() => _SimpleHostPageState();
}

class _SimpleHostPageState extends State<SimpleHostPage> {
  static const String _runPath =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  bool _pwdVisible = false;
  bool _fixedPwd = false;
  bool _autoStart = false;

  Timer? _idTimer;
  String _lastId = '';

  @override
  void initState() {
    super.initState();
    _setupWindow();
    _loadFlags();
    // 原版首页在 1s 定时器里调用 fetchID()，这里被替换后必须自己拉，
    // 否则 ID 永远停在「正在生成...」。
    _watchId();
  }

  @override
  void dispose() {
    _idTimer?.cancel();
    super.dispose();
  }

  void _watchId() {
    _idTimer?.cancel();
    var ticks = 0;
    _idTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      ticks++;
      try {
        await gFFI.serverModel.fetchID();
      } catch (_) {}
      final id = gFFI.serverModel.serverId.text;
      if (id.isNotEmpty && id != _lastId) {
        _lastId = id;
        if (mounted) {
          setState(() {});
        }
      }
      // 服务起不来时不要无限轮询
      if (ticks >= 120) {
        t.cancel();
        _idTimer = null;
      }
    });
  }

  Future<void> _setupWindow() async {
    if (!isWindows && !isLinux) {
      return;
    }
    try {
      await windowManager.setSize(const Size(320, 372));
      await windowManager.setMinimumSize(const Size(320, 340));
      await windowManager.center();
      await windowManager.setTitle(appName);
    } catch (_) {}
  }

  Future<void> _loadFlags() async {
    var fixedPwd = false;
    try {
      fixedPwd =
          (await bind.mainGetCommon(key: "permanent-password-set")) == "true";
    } catch (_) {}
    final autoStart = await _queryAutoStart();
    if (!mounted) {
      return;
    }
    setState(() {
      _fixedPwd = fixedPwd;
      _autoStart = autoStart;
    });
  }

  String get _runKey => appName;

  Future<bool> _queryAutoStart() async {
    if (!isWindows) {
      return false;
    }
    try {
      final r = await Process.run('reg', ['query', _runPath, '/v', _runKey]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setAutoStart(bool on) async {
    if (isWindows) {
      try {
        if (on) {
          final exe = Platform.resolvedExecutable;
          await Process.run('reg', [
            'add',
            _runPath,
            '/v',
            _runKey,
            '/t',
            'REG_SZ',
            '/d',
            '"$exe"',
            '/f',
          ]);
        } else {
          await Process.run('reg', ['delete', _runPath, '/v', _runKey, '/f']);
        }
      } catch (_) {}
    }
    final v = await _queryAutoStart();
    if (!mounted) {
      return;
    }
    setState(() => _autoStart = v);
  }

  Future<void> _onFixedPwdChanged(bool on) async {
    setState(() => _fixedPwd = on);
    if (on) {
      // setPasswordDialog 返回 void，不能 await
      setPasswordDialog(notEmptyCallback: _reloadFlags);
    } else {
      try {
        await bind.mainSetPermanentPasswordWithResult(password: "");
      } catch (_) {}
    }
    _reloadFlags();
  }

  void _reloadFlags() {
    _loadFlags();
  }

  void _copy(String text, String tip) {
    if (text.isEmpty) {
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    showToast(tip);
  }

  void _openSettings() {
    try {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              DesktopSettingPage(initialTabkey: SettingsTabKey.safety)));
    } catch (_) {}
  }

  static String _groupedId(String raw) {
    final s = raw.replaceAll(' ', '');
    if (s.length < 6 || int.tryParse(s) == null) {
      return raw;
    }
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      buf.write(s[i]);
      if (i != s.length - 1 && (s.length - 1 - i) % 3 == 0) {
        buf.write(' ');
      }
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ChangeNotifierProvider<ServerModel>.value(
          value: gFFI.serverModel,
          child: Consumer<ServerModel>(
            builder: (context, model, _) {
              final textColor = Theme.of(context).textTheme.titleLarge?.color ??
                  const Color(0xFF1F1F1F);
              final subColor = textColor.withOpacity(0.45);
              final rawId = model.serverId.text;
              final id = rawId.isEmpty ? translate("Generating ...") : rawId;
              final pwd = model.serverPasswd.text;
              // 只启用固定密码时，RustDesk 用 '-' 表示「密码不外显」
              final fixedOnly = pwd == '-';
              final maskLen = fixedOnly ? 8 : pwd.length;
              final dots = '●' * maskLen;
              final shownPwd = !_pwdVisible
                  ? dots
                  : (fixedOnly ? '已设置固定密码' : pwd);
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 34,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 16),
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            constraints:
                                const BoxConstraints(minWidth: 24, minHeight: 24),
                            splashRadius: 14,
                            icon: Icon(Icons.settings,
                                size: 17, color: subColor),
                            onPressed: _openSettings,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, 0, 20, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('你的 ID',
                              style: TextStyle(fontSize: 12, color: subColor)),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _groupedId(id),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 26,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 2,
                                    color: textColor,
                                  ),
                                ),
                              ),
                              _iconBtn(
                                Icons.copy_rounded,
                                17,
                                subColor,
                                () => _copy(rawId, '已复制 ID'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Text('你的密码',
                              style: TextStyle(fontSize: 12, color: subColor)),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  shownPwd,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: !_pwdVisible && !fixedOnly
                                        ? 11
                                        : 15,
                                    height: 1.6,
                                    letterSpacing:
                                        !_pwdVisible && !fixedOnly ? 4 : 0.5,
                                    color: fixedOnly && _pwdVisible
                                        ? subColor
                                        : textColor,
                                  ),
                                ),
                              ),
                              _iconBtn(
                                _pwdVisible
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                18,
                                subColor,
                                () => setState(() => _pwdVisible = !_pwdVisible),
                              ),
                              _iconBtn(
                                Icons.copy_rounded,
                                17,
                                subColor,
                                () => _copyPwd(pwd, fixedOnly, rawId),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _outlinedButton(
                            '复制 ID 和密码',
                            Icons.copy_rounded,
                            () => fixedOnly
                                ? _copy(rawId, '已复制 ID（固定密码不外显）')
                                : _copy('ID: $rawId\n密码: $pwd', '已复制 ID 和密码'),
                          ),
                          const SizedBox(height: 8),
                          _filledButton('设置固定密码', () => setPasswordDialog()),
                          const SizedBox(height: 14),
                          Divider(height: 1, color: subColor.withOpacity(0.2)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              _switchGroup(
                                  '固定密码', _fixedPwd, _onFixedPwdChanged),
                              const Spacer(),
                              _switchGroup('开机自启', _autoStart, _setAutoStart),
                            ],
                          ),
                          const SizedBox(height: 4),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  void _copyPwd(String pwd, bool fixedOnly, String id) {
    if (fixedOnly) {
      _copy(id, '固定密码不外显，已复制 ID');
    } else {
      _copy(pwd, '已复制密码');
    }
  }

  Widget _iconBtn(IconData icon, double size, Color color, VoidCallback onTap) {
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      splashRadius: 14,
      icon: Icon(icon, size: size, color: color),
      onPressed: onTap,
    );
  }

  Widget _outlinedButton(String label, IconData icon, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      height: 36,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: const Color(0xFFF7F7F7),
          side: const BorderSide(color: Color(0xFFE2E2E2), width: 1),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          foregroundColor: const Color(0xFF3D3D3D),
          padding: EdgeInsets.zero,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 13.5)),
          ],
        ),
      ),
    );
  }

  Widget _filledButton(String label, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      height: 36,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: MyTheme.accent,
          foregroundColor: Colors.white,
          elevation: 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: EdgeInsets.zero,
        ),
        child: Text(label, style: const TextStyle(fontSize: 13.5)),
      ),
    );
  }

  Widget _switchGroup(String label, bool value, ValueChanged<bool> onChanged) {
    final textColor = Theme.of(context).textTheme.titleLarge?.color ??
        const Color(0xFF1F1F1F);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration:
              BoxDecoration(color: MyTheme.accent, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: textColor),
        ),
        const SizedBox(width: 2),
        Transform.scale(
          scale: 0.62,
          child: Switch(
            value: value,
            activeColor: Colors.white,
            activeTrackColor: MyTheme.accent,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: const Color(0xFFD9D9D9),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
