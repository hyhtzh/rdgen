import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart' show setPasswordDialog;
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
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

  @override
  void initState() {
    super.initState();
    _setupWindow();
    _loadFlags();
  }

  Future<void> _setupWindow() async {
    if (!isWindows && !isLinux) {
      return;
    }
    try {
      await windowManager.setSize(const Size(376, 470));
      await windowManager.center();
      await windowManager.setTitle(bind.mainGetAppNameSync());
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

  String get _runKey => bind.mainGetAppNameSync();

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
      await setPasswordDialog(notEmptyCallback: _reloadFlags);
    } else {
      try {
        await bind.mainSetPermanentPasswordWithResult(password: "");
      } catch (_) {}
    }
    await _reloadFlags();
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
              const DesktopSettingPage(initialTabkey: SettingsTabKey.safety)));
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
              final id = model.serverId.text;
              final pwd = model.serverPasswd.text;
              final hidden = !_pwdVisible;
              final shownPwd = hidden ? '●' * pwd.length : pwd;
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        splashRadius: 16,
                        icon: Icon(Icons.settings, size: 18, color: subColor),
                        onPressed: _openSettings,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('你的 ID',
                              style:
                                  TextStyle(fontSize: 13, color: subColor)),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _groupedId(id),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 25,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 1.5,
                                    color: textColor,
                                  ),
                                ),
                              ),
                              IconButton(
                                splashRadius: 16,
                                icon: Icon(Icons.copy_rounded,
                                    size: 18, color: subColor),
                                onPressed: () => _copy(id, '已复制 ID'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text('你的密码',
                              style:
                                  TextStyle(fontSize: 13, color: subColor)),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  shownPwd,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: hidden ? 13 : 17,
                                    letterSpacing: hidden ? 3 : 1,
                                    color: textColor,
                                  ),
                                ),
                              ),
                              IconButton(
                                splashRadius: 16,
                                icon: Icon(
                                  _pwdVisible
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 19,
                                  color: subColor,
                                ),
                                onPressed: () => setState(
                                    () => _pwdVisible = !_pwdVisible),
                              ),
                              IconButton(
                                splashRadius: 16,
                                icon: Icon(Icons.copy_rounded,
                                    size: 18, color: subColor),
                                onPressed: () => _copy(pwd, '已复制密码'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          _outlinedButton(
                            '复制 ID 和密码',
                            Icons.copy_rounded,
                            () => _copy('ID: $id\n密码: $pwd', '已复制 ID 和密码'),
                          ),
                          const SizedBox(height: 10),
                          _filledButton('设置固定密码', () => setPasswordDialog()),
                          const SizedBox(height: 18),
                          Divider(height: 1, color: subColor.withOpacity(0.25)),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: _switchRow(
                                  context,
                                  '使用固定密码',
                                  _fixedPwd,
                                  _onFixedPwdChanged,
                                ),
                              ),
                              Expanded(
                                child: _switchRow(
                                  context,
                                  '开机自启',
                                  _autoStart,
                                  _setAutoStart,
                                ),
                              ),
                            ],
                          ),
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

  Widget _outlinedButton(String label, IconData icon, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: const Color(0xFFDCDCDC), width: 1),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          foregroundColor: const Color(0xFF4A4A4A),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _filledButton(String label, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: MyTheme.accent,
          foregroundColor: Colors.white,
          elevation: 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Text(label, style: const TextStyle(fontSize: 14)),
      ),
    );
  }

  Widget _switchRow(
    BuildContext context,
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    final textColor = Theme.of(context).textTheme.titleLarge?.color ??
        const Color(0xFF1F1F1F);
    return Row(
      children: [
        Icon(Icons.circle, size: 8, color: MyTheme.accent),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: textColor),
          ),
        ),
        Transform.scale(
          scale: 0.72,
          child: Switch(
            value: value,
            activeColor: Colors.white,
            activeTrackColor: MyTheme.accent,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
