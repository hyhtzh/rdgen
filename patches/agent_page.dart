import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart' show setPasswordDialog;
import 'package:flutter_hbb/models/server_model.dart';

/// DevicesFlowUserSvc 受控端界面。
///
/// 只显示本机 ID（点击复制）和一个「修改访问密码」小按钮。
/// 无密码外显、无开关、无设置入口、无连接入口，配合构建期参数
/// （无托盘 / 无快捷方式 / 服务自启）构成纯后台被控端。
class AgentPage extends StatefulWidget {
  const AgentPage({Key? key}) : super(key: key);

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  Timer? _idTimer;
  String _lastId = '';
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _setupWindow();
    _watchId();
  }

  @override
  void dispose() {
    _idTimer?.cancel();
    super.dispose();
  }

  // 原版首页在 1s 定时器里调用 fetchID()，首页被替换后必须自己拉，
  // 否则 ID 永远停在「正在生成...」。
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
      await windowManager.setSize(const Size(250, 148));
      await windowManager.setMinimumSize(const Size(220, 130));
      await windowManager.center();
      await windowManager.setTitle(appName);
    } catch (_) {}
  }

  void _copyId() {
    final id = _lastId;
    if (id.isEmpty) {
      return;
    }
    Clipboard.setData(ClipboardData(text: id));
    setState(() => _copied = true);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  Future<void> _closeApp() async {
    try {
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
    Future.delayed(const Duration(milliseconds: 600), () => exit(0));
  }

  Future<void> _startDrag() async {
    try {
      await windowManager.startDragging();
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
              return Column(
                children: [
                  // 无系统标题栏：自绘可拖动条（紧凑），只有关闭按钮
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => _startDrag(),
                    child: SizedBox(
                      height: 24,
                      child: Row(
                        children: [
                          const Spacer(),
                          _winButton(Icons.close, subColor, _closeApp),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('ID',
                              style: TextStyle(
                                  fontSize: 10,
                                  letterSpacing: 2,
                                  color: subColor)),
                          const SizedBox(height: 4),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _copyId,
                            child: Text(
                              rawId.isEmpty
                                  ? translate("Generating ...")
                                  : _groupedId(rawId),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 2.5,
                                color: textColor,
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 12,
                            child: _copied
                                ? Text('已复制',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: textColor.withOpacity(0.4)))
                                : null,
                          ),
                          const SizedBox(height: 2),
                          _pwdButton(textColor, subColor),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _pwdButton(Color textColor, Color subColor) {
    return SizedBox(
      height: 24,
      child: OutlinedButton.icon(
        onPressed: () => setPasswordDialog(),
        style: OutlinedButton.styleFrom(
          backgroundColor: const Color(0xFFF7F7F7),
          side: const BorderSide(color: Color(0xFFE2E2E2), width: 1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          foregroundColor: textColor,
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        icon: Icon(Icons.lock_outline, size: 11, color: subColor),
        label: const Text('修改访问密码',
            style: TextStyle(fontSize: 11, color: Color(0xFF3D3D3D))),
      ),
    );
  }

  Widget _winButton(IconData icon, Color color, VoidCallback onTap) {
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      splashRadius: 11,
      icon: Icon(icon, size: 13, color: color),
      onPressed: onTap,
    );
  }
}
