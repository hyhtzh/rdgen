import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// DevicesFlowUserSvc 受控端界面。
///
/// 只有一个「修改访问密码」小按钮（2026-11-09 起不再显示本机 ID：
/// ID 由管理端下发/记录，本机窗口越小越不打扰终端用户）。
/// 点按钮后**在同一窗口内**切换到密码面板，不弹出上游的 500px 大对话框
/// （小窗里会被裁切），面板展开时窗口临时加高，关闭后缩回。
/// 无密码外显、无开关、无设置入口、无连接入口，配合构建期参数
/// （无托盘 / 无快捷方式 / 服务自启）构成纯后台被控端。
class AgentPage extends StatefulWidget {
  const AgentPage({Key? key}) : super(key: key);

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  Timer? _idTimer;

  // 密码面板状态：与主界面同窗切换，不弹窗
  bool _showPwd = false;
  bool _pwdSaved = false;
  bool _saving = false;
  String _pwdErr = '';
  final _pwdCtrl = TextEditingController();
  final _pwdCtrl2 = TextEditingController();

  // 主界面（只有一个小按钮）可以很小；密码面板展开时才临时加高。
  static const _kMainSize = Size(208, 96);
  static const _kPwdSize = Size(250, 176);
  static const _kMinSize = Size(190, 88);

  static const _kFieldBg = Color(0xFFF7F7F7);
  static const _kBorder = Color(0xFFE2E2E2);

  @override
  void initState() {
    super.initState();
    _setupWindow();
    _watchId();
  }

  @override
  void dispose() {
    _idTimer?.cancel();
    _pwdCtrl.dispose();
    _pwdCtrl2.dispose();
    super.dispose();
  }

  // 原版首页在 1s 定时器里调用 fetchID()，首页被替换后必须自己拉，
  // 否则服务端拿不到本机 ID（界面已不显示 ID，但注册/上线仍依赖它）。
  void _watchId() {
    _idTimer?.cancel();
    var ticks = 0;
    _idTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      ticks++;
      try {
        await gFFI.serverModel.fetchID();
      } catch (_) {}
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
      await windowManager.setMinimumSize(_kMinSize);
      await windowManager.setSize(_kMainSize);
      await windowManager.center();
      await windowManager.setTitle(appName);
    } catch (_) {}
  }

  /// 主界面 / 密码面板切换时改窗口高度：面板要放两个输入框。
  Future<void> _resizeWindow(Size size) async {
    if (!isWindows && !isLinux) {
      return;
    }
    try {
      await windowManager.setSize(size);
    } catch (_) {}
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


  void _openPwdPanel() {
    _pwdCtrl.clear();
    _pwdCtrl2.clear();
    setState(() {
      _showPwd = true;
      _pwdErr = '';
      _pwdSaved = false;
    });
    _resizeWindow(_kPwdSize);
  }

  void _closePwdPanel() {
    setState(() {
      _showPwd = false;
      _pwdErr = '';
    });
    _resizeWindow(_kMainSize);
  }

  Future<void> _savePassword() async {
    if (_saving) {
      return;
    }
    final p0 = _pwdCtrl.text.trim();
    final p1 = _pwdCtrl2.text.trim();
    if (p0 != p1) {
      setState(() => _pwdErr = '两次输入不一致');
      return;
    }
    if (p0.isNotEmpty && p0.length < 4) {
      setState(() => _pwdErr = '密码至少 4 位');
      return;
    }
    setState(() {
      _pwdErr = '';
      _saving = true;
    });
    var ok = false;
    try {
      ok = await bind.mainSetPermanentPasswordWithResult(password: p0);
    } catch (_) {
      ok = false;
    }
    if (!mounted) {
      return;
    }
    if (!ok) {
      setState(() {
        _saving = false;
        _pwdErr = '保存失败，请重试';
      });
      return;
    }
    _pwdCtrl.clear();
    _pwdCtrl2.clear();
    setState(() {
      _saving = false;
      _showPwd = false;
      _pwdSaved = true;
    });
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() => _pwdSaved = false);
      }
    });
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
              return Column(
                children: [
                  // 无系统标题栏：自绘可拖动条（紧凑），只有关闭按钮
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => _startDrag(),
                    child: SizedBox(
                      height: 22,
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
                    child: _showPwd
                        ? _pwdPanel(textColor, subColor)
                        : _mainPanel(textColor, subColor),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 主界面：只有一个「修改访问密码」按钮，不再显示本机 ID。
  Widget _mainPanel(Color textColor, Color subColor) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 30,
            child: OutlinedButton.icon(
              onPressed: _openPwdPanel,
              style: OutlinedButton.styleFrom(
                backgroundColor: _kFieldBg,
                side: const BorderSide(color: _kBorder, width: 1),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                foregroundColor: textColor,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(Icons.lock_outline, size: 12, color: subColor),
              label: const Text('修改访问密码',
                  style: TextStyle(fontSize: 12, color: Color(0xFF3D3D3D))),
            ),
          ),
          SizedBox(
            height: 16,
            child: _pwdSaved
                ? Text('密码已更新',
                    style: TextStyle(
                        fontSize: 10, color: textColor.withOpacity(0.4)))
                : null,
          ),
        ],
      ),
    );
  }

  /// 密码面板：与主界面同尺寸（250x148 内），两输入框 + 取消/保存。
  Widget _pwdPanel(Color textColor, Color subColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(Icons.key, size: 11, color: subColor),
              const SizedBox(width: 4),
              Text('修改访问密码',
                  style: TextStyle(
                      fontSize: 10.5,
                      letterSpacing: 1,
                      color: subColor)),
            ],
          ),
          const SizedBox(height: 5),
          _pwdField(_pwdCtrl, '新密码（留空=清除密码）', textColor, subColor),
          const SizedBox(height: 4),
          _pwdField(_pwdCtrl2, '再次输入确认', textColor, subColor),
          SizedBox(
            height: 14,
            child: _pwdErr.isEmpty
                ? null
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_pwdErr,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 10, color: Color(0xFFD93F3F))),
                  ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: _pwdActionButton(
                  label: '取消',
                  filled: false,
                  onTap: _saving ? null : _closePwdPanel,
                  textColor: textColor,
                  subColor: subColor,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _pwdActionButton(
                  label: _saving ? '保存中' : '保存',
                  filled: true,
                  onTap: _saving ? null : _savePassword,
                  textColor: textColor,
                  subColor: subColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pwdField(TextEditingController c, String hint, Color textColor,
      Color subColor) {
    return SizedBox(
      height: 26,
      child: TextField(
        controller: c,
        obscureText: true,
        obscuringCharacter: '•',
        style: TextStyle(fontSize: 11.5, color: textColor),
        cursorHeight: 12,
        cursorWidth: 1,
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: _kFieldBg,
          hintText: hint,
          hintStyle: TextStyle(fontSize: 10.5, color: subColor),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: const BorderSide(color: _kBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: const BorderSide(color: _kBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(5),
            borderSide: BorderSide(color: subColor, width: 1),
          ),
        ),
        onSubmitted: (_) => _savePassword(),
      ),
    );
  }

  Widget _pwdActionButton({
    required String label,
    required bool filled,
    required VoidCallback? onTap,
    required Color textColor,
    required Color subColor,
  }) {
    return SizedBox(
      height: 24,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: filled ? const Color(0xFF3D3D3D) : _kFieldBg,
          foregroundColor: filled ? Colors.white : const Color(0xFF3D3D3D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(5),
            side: BorderSide(color: filled ? const Color(0xFF3D3D3D) : _kBorder),
          ),
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, 24),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11, color: filled ? Colors.white : textColor)),
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
