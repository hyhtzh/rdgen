// 启动门禁 + 激活界面。
//
// 用 LicenseGate 包住整个 App：未激活时只显示激活页，激活后原样返回 child。
// Windows 控制端和安卓共用这一套，被控端构建不引用本文件。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:flutter_hbb/desktop/pages/license_client.dart';

class _LC {
  static const blue = Color(0xFF1B72D6);
  static const text = Color(0xFF1F2937);
  static const sub = Color(0xFF6B7280);
  static const line = Color(0xFFE3E8F0);
  static const red = Color(0xFFE23B3B);
}

class LicenseGate extends StatefulWidget {
  final Widget child;

  const LicenseGate({Key? key, required this.child}) : super(key: key);

  @override
  State<LicenseGate> createState() => _LicenseGateState();
}

class _LicenseGateState extends State<LicenseGate> {
  /// null 表示还在检查
  LicenseStatus? _status;
  String _message = '';
  String _expire = '';
  bool _offline = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _check();
    // 运行中定期复检：后台解绑/停用/重置后，最多 5 分钟内锁定正在使用的客户端
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _check());
    // 授权详情弹窗里点了「解绑设备」→ 立即回到激活页
    LicenseClient.instance.revoked.addListener(_check);
  }

  @override
  void dispose() {
    _timer?.cancel();
    LicenseClient.instance.revoked.removeListener(_check);
    super.dispose();
  }

  Future<void> _check() async {
    final r = await LicenseClient.instance.check();
    if (!mounted) return;
    setState(() {
      _status = r.status;
      _message = r.message;
      _expire = r.expireAt;
      _offline = r.offline;
    });
  }

  void _onActivated(LicenseResult r) {
    setState(() {
      _status = r.status;
      _expire = r.expireAt;
      _message = '';
      _offline = false;
    });
  }

  void _onBlocked(String msg) {
    setState(() {
      _status = LicenseStatus.blocked;
      _message = msg;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_status == LicenseStatus.licensed) {
      // 离线宽限时给一条不打扰的提示，用户知道该联网了
      if (!_offline) return widget.child;
      return Stack(children: [
        widget.child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Container(
              color: const Color(0xE6FFF5E6),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
              child: const Text('授权暂时无法在线校验，已进入离线宽限期，请尽快联网',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Color(0xFFB45309))),
            ),
          ),
        ),
      ]);
    }

    // 挂在主 MaterialApp 的 home 位置上，所以这里只给 Scaffold，不再套一层 MaterialApp
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      body: Center(
        child: SingleChildScrollView(
          child: _status == null
              ? const _Checking()
              : _ActivateCard(
                  blocked: _status == LicenseStatus.blocked,
                  blockMessage: _message,
                  expire: _expire,
                  onActivated: _onActivated,
                  onBlocked: _onBlocked,
                ),
        ),
      ),
    );
  }
}

class _Checking extends StatelessWidget {
  const _Checking();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: const [
        SizedBox(
            width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        SizedBox(height: 14),
        Text('正在校验授权…', style: TextStyle(fontSize: 13, color: _LC.sub)),
      ],
    );
  }
}

class _ActivateCard extends StatefulWidget {
  final bool blocked;
  final String blockMessage;
  final String expire;
  final void Function(LicenseResult) onActivated;
  final void Function(String) onBlocked;

  const _ActivateCard({
    required this.blocked,
    required this.blockMessage,
    required this.expire,
    required this.onActivated,
    required this.onBlocked,
  });

  @override
  State<_ActivateCard> createState() => _ActivateCardState();
}

class _ActivateCardState extends State<_ActivateCard> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String _error = '';
  String _machine = '';

  @override
  void initState() {
    super.initState();
    if (widget.blocked) _error = widget.blockMessage;
    LicenseClient.instance.machineId().then((v) {
      if (mounted) setState(() => _machine = v);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 输入即格式化：大写、去掉非字母数字、每 4 位插一个横线
  void _format(String raw) {
    final clean = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final buf = StringBuffer();
    for (var i = 0; i < clean.length && i < 16; i++) {
      if (i > 0 && i % 4 == 0) buf.write('-');
      buf.write(clean[i]);
    }
    final s = buf.toString();
    if (s != _controller.text) {
      _controller.value = TextEditingValue(
        text: s,
        selection: TextSelection.collapsed(offset: s.length),
      );
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    final code = _controller.text.trim();
    if (code.replaceAll('-', '').length < 8) {
      setState(() => _error = '请填写完整的授权码');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final r = await LicenseClient.instance.activate(code);
      if (!mounted) return;
      widget.onActivated(r);
    } on LicenseException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.msg;
      });
      if (e.code == 'seat_limit' || e.code == 'machine_mismatch') {
        widget.onBlocked(e.msg);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '激活失败：$e';
      });
    }
  }

  Future<void> _buy() async {
    try {
      await launchUrlString(kPurchaseUrl, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 打不开浏览器（少见）：把地址放剪贴板兜底
      Clipboard.setData(const ClipboardData(text: kPurchaseUrl));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已复制购买地址：$kPurchaseUrl'),
          duration: Duration(seconds: 3)));
    }
  }

  Future<void> _copyMachine() async {
    if (_machine.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _machine));
    setState(() => _error = '');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('机器码已复制'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 420,
      padding: const EdgeInsets.fromLTRB(34, 32, 34, 26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Color(0x0F1B2A4A), blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _LC.blue,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.desktop_windows_rounded,
                    size: 20, color: Colors.white),
              ),
              const SizedBox(width: 11),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('HyDesk',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _LC.text)),
                  SizedBox(height: 1),
                  Text('授权激活',
                      style: TextStyle(fontSize: 12, color: _LC.sub)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 26),
          Text(
            widget.blocked ? '授权不可用' : '请输入授权码',
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _LC.text),
          ),
          const SizedBox(height: 6),
          Text(
            widget.blocked
                ? '当前授权无法继续使用，换一个授权码或联系客服处理。'
                : '首次使用需要激活，激活后自动记住本机。',
            style: const TextStyle(fontSize: 12.5, color: _LC.sub, height: 1.6),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 46,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              onChanged: _format,
              onSubmitted: (_) => _submit(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                letterSpacing: 2.4,
                fontWeight: FontWeight.w500,
                color: _LC.text,
                fontFamily: 'Consolas',
                fontFamilyFallback: ['Menlo', 'monospace'],
              ),
              decoration: InputDecoration(
                hintText: 'XXXX-XXXX-XXXX-XXXX',
                hintStyle: TextStyle(
                    fontSize: 15,
                    letterSpacing: 2,
                    color: const Color(0xFFB8C0CC)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                filled: true,
                fillColor: const Color(0xFFF8FAFD),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _LC.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: _LC.blue, width: 1.4),
                ),
              ),
            ),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFDECEC),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline, size: 15, color: _LC.red),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_error,
                        style: const TextStyle(
                            fontSize: 12.5, color: _LC.red, height: 1.5)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 42,
            child: ElevatedButton(
              onPressed: _busy ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: _LC.blue,
                disabledBackgroundColor: const Color(0xFF9DC0EA),
                elevation: 0,
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('激活',
                      style: TextStyle(
                          fontSize: 14.5,
                          color: Colors.white,
                          fontWeight: FontWeight.w500)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _buy,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _LC.blue),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.shopping_cart_outlined,
                  size: 17, color: _LC.blue),
              label: const Text('购买授权',
                  style: TextStyle(
                      fontSize: 14.5,
                      color: _LC.blue,
                      fontWeight: FontWeight.w500)),
            ),
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: const Color(0xFFF0F3F8)),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('机器码', style: TextStyle(fontSize: 12, color: _LC.sub)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _machine.isEmpty ? '读取中…' : _machine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF8A94A6),
                      fontFamily: 'Consolas'),
                ),
              ),
              InkWell(
                onTap: _copyMachine,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text('复制',
                      style: TextStyle(fontSize: 12, color: _LC.blue)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('没有授权码？点击「购买授权」在线购买，或联系客服。',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF9AA3B2))),
        ],
      ),
    );
  }
}

/// 安卓端「授权详情」弹窗：移动端设置页入口调用（桌面端在首页授权卡里）。
///
/// 展示版本类型 / 授权类型 / 到期时间 / 剩余天数 / 设备占用 / 激活码，
/// 并提供购买授权与本机解绑。解绑后 LicenseGate 的 revoked 监听会自动弹激活页。
Future<void> showMobileLicenseDetail(BuildContext context) async {
  final c = LicenseClient.instance;
  final planName = c.savedPlanName.isEmpty ? '已授权' : c.savedPlanName;
  String planType;
  switch (c.savedPlan) {
    case 'std':
      planType = '标准版';
      break;
    case 'pro':
      planType = '专业版';
      break;
    case 'manual':
      planType = '手工授权';
      break;
    default:
      planType = c.savedPlan.isEmpty ? '—' : c.savedPlan;
  }
  final days = c.daysLeft;
  final used = c.savedDevicesUsed;
  final max = c.savedDevicesMax;
  final code = c.savedCode;
  final expDay = c.savedExpire.isEmpty ? '' : c.savedExpire.split(' ').first;

  Widget kv(String k, String v, {Color color = _LC.text, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 92,
              child: Text(k,
                  style: const TextStyle(fontSize: 13, color: _LC.sub))),
          Expanded(
            child: Text(v,
                style: TextStyle(
                    fontSize: 13.5,
                    color: color,
                    fontWeight: bold ? FontWeight.w600 : FontWeight.w400)),
          ),
        ],
      ),
    );
  }

  Future<void> buy() async {
    try {
      await launchUrlString(kPurchaseUrl, mode: LaunchMode.externalApplication);
    } catch (_) {
      Clipboard.setData(const ClipboardData(text: kPurchaseUrl));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('已复制购买地址：$kPurchaseUrl'),
          duration: const Duration(seconds: 3)));
    }
  }

  Future<void> unbind() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解绑本机设备',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: const Text(
            '解绑后本机授权被移除，软件将回到激活界面（不影响其他设备）。确定解绑？',
            style: TextStyle(fontSize: 13.5, height: 1.6)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消', style: TextStyle(color: _LC.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定解绑',
                style: TextStyle(color: _LC.red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await c.localDeactivate();
    if (context.mounted) Navigator.of(context).pop();
  }

  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('授权详情',
          style:
              TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600, color: _LC.text)),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            kv('版本类型', planType, bold: true),
            kv('授权类型', planName, color: const Color(0xFF2FA45C), bold: true),
            kv('到期时间', expDay.isEmpty ? '—' : expDay),
            kv('剩余天数', days >= 0 ? '$days 天' : '—'),
            kv('设备占用', used < 0 ? '—' : (max > 0 ? '$used / $max 台' : '$used 台')),
            kv('激活码', code.isEmpty ? '—' : code),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭', style: TextStyle(fontSize: 13.5, color: _LC.sub)),
        ),
        TextButton(
          onPressed: buy,
          child: const Text('购买授权',
              style: TextStyle(
                  fontSize: 13.5,
                  color: _LC.blue,
                  fontWeight: FontWeight.w500)),
        ),
        TextButton(
          onPressed: unbind,
          child: const Text('解绑设备',
              style: TextStyle(
                  fontSize: 13.5,
                  color: _LC.red,
                  fontWeight: FontWeight.w500)),
        ),
      ],
    ),
  );
}
