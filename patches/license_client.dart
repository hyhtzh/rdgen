// 授权客户端：激活 / 校验 / 本地缓存。
//
// 机器指纹用 Rust 侧的 uuid（bind.mainGetUuid，写死在配置目录里），
// Windows / Android 都能拿到，不用读注册表，也不怕用户改识别码。
//
// 续期与容错：
//   - 激活成功把 token / 到期日 / 最后在线时间存在 local option 里；
//   - 启动时先本地放行、后台静默校验，校验通过就刷新最后在线时间；
//   - 断网或服务器挂了，最后一次成功校验在 7 天内仍然放行（不影响老客户干活）；
//   - 服务端明确回「已停用 / 已到期 / 凭证无效」才拦截，且不允许离线宽限。
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Process, ProcessStartMode, exit;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher_string.dart';

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// 授权服务地址（nginx 反代到本机授权服务）
const kLicenseBase = 'https://hd.fcpx0.cn/license';

/// 地址簿服务（账号 + 云端设备清单）。
/// 与授权服务分开部署：这里是用户的账号体系，授权那边只管激活码。
const kAbBase = 'https://api.hydesk.cn';

/// 购买授权的落地页（激活页「购买」与详情弹窗「续费升级」都跳这里）
const kPurchaseUrl = 'https://1t.8kub.cn';

/// 商城地址：带上商品 id 时直接选中对应加购包（pa16 / pa32 / pa64 / paGroup）
String shopUrl([String? productId]) {
  final id = (productId ?? '').trim();
  return id.isEmpty ? kPurchaseUrl : '$kPurchaseUrl/?p=$id';
}

/// 唤起系统浏览器。桌面 / 安卓都走外部应用，失败再逐级降级，全失败返回 false。
///
/// 这里不用 dart:io（预览工程要在浏览器里编译），所以唤起失败只能靠调用方兜底：
/// gotoShop() 会把地址复制到剪贴板并弹窗说明，绝不让「点了没反应」发生。
Future<bool> openExternalUrl(String url) async {
  for (final mode in const [
    LaunchMode.externalApplication,
    LaunchMode.platformDefault,
    LaunchMode.inAppBrowserView,
  ]) {
    try {
      if (await launchUrlString(url, mode: mode)) return true;
    } catch (_) {
      // 继续尝试下一种方式
    }
  }
  return false;
}

/// 去商城买附加包：能唤起浏览器就唤起，唤不起就复制链接 + 弹窗教用户手动打开。
Future<void> gotoShop(BuildContext context, {String? productId}) async {
  final url = shopUrl(productId);
  if (await openExternalUrl(url)) return;
  await Clipboard.setData(ClipboardData(text: url));
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text('打开商城购买',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('没能自动唤起浏览器，购买地址已复制。\n把它粘贴到浏览器或微信里打开即可购买，付款后马上出授权码。',
              style: TextStyle(fontSize: 13, height: 1.6)),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F7FB),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(url,
                style: const TextStyle(
                    fontSize: 12.5, color: Color(0xFF1B72D6))),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭', style: TextStyle(color: Color(0xFF6B7688))),
        ),
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          child: const Text('复制链接',
              style: TextStyle(color: Color(0xFF1B72D6))),
        ),
        ElevatedButton(
          onPressed: () async {
            final ok = await openExternalUrl(url);
            if (!ctx.mounted) return;
            if (ok) {
              Navigator.of(ctx).pop();
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1B72D6),
            elevation: 0,
          ),
          child: const Text('再试一次', style: TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
}

/// 断网宽限天数
const kLicenseGraceDays = 7;

const _kToken = 'license-token';
const _kExpire = 'license-expire';
const _kLastOk = 'license-last-ok';
const _kCode = 'license-code';
const _kConfig = 'license-config';
const _kPlan = 'license-plan';
const _kDevices = 'license-devices';
const _kCardType = 'license-cardtype';

class LicenseException implements Exception {
  /// 机器可读原因：invalid_code / expired / disabled / seat_limit /
  /// bad_token / machine_mismatch / network / server_error
  final String code;
  final String msg;
  LicenseException(this.code, this.msg);

  /// 这几种是「服务端明确拒绝」，不允许离线宽限
  bool get hardBlock =>
      code == 'invalid_code' ||
      code == 'expired' ||
      code == 'disabled' ||
      code == 'bad_token' ||
      code == 'machine_mismatch' ||
      code == 'seat_limit';

  @override
  String toString() => msg;
}

enum LicenseStatus {
  /// 已授权（校验通过或离线宽限内）
  licensed,

  /// 未激活
  none,

  /// 被服务端拒绝（停用 / 到期 / 换机）
  blocked,
}

class LicenseResult {
  final LicenseStatus status;
  final String expireAt;
  final String code;
  final String message;
  final bool offline;
  final String plan;
  final String planName;
  final int devices;
  final int maxDevices;

  /// 这一单是附加包（屏幕墙档位 / 群控），不是主授权
  final bool isAddon;
  final String addonName;
  final String addonExpire;

  /// 附加包的实际可用截止日（主授权先到期时就是主授权的日期）
  final String addonEffectiveExpire;

  /// 主授权比附加包先到期：附加包会跟着主授权一起失效
  final bool addonExpiresWithLicense;

  const LicenseResult(this.status,
      {this.expireAt = '',
      this.code = '',
      this.message = '',
      this.offline = false,
      this.plan = '',
      this.planName = '',
      this.devices = -1,
      this.maxDevices = 0,
      this.isAddon = false,
      this.addonName = '',
      this.addonExpire = '',
      this.addonEffectiveExpire = '',
      this.addonExpiresWithLicense = false});

  bool get ok => status == LicenseStatus.licensed;
}

class LicenseClient {
  LicenseClient._();

  static final LicenseClient instance = LicenseClient._();

  String? _cachedUuid;

  // ---------------- 本地缓存 ----------------

  String _get(String key) {
    try {
      return bind.mainGetLocalOption(key: key) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _set(String key, String value) async {
    try {
      await bind.mainSetLocalOption(key: key, value: value);
    } catch (_) {}
  }

  String get savedToken => _get(_kToken);
  String get savedExpire => _get(_kExpire);
  String get savedCode => _get(_kCode);

  bool get hasToken => savedToken.isNotEmpty;

  int get _lastOk {
    final v = int.tryParse(_get(_kLastOk));
    return v ?? 0;
  }

  /// 已到期（按本地缓存的到期日判断，避免到期后还能离线用）
  bool get expiredLocally {
    final exp = savedExpire;
    if (exp.isEmpty) return false;
    return exp.compareTo(_today()) < 0;
  }

  String _today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> clear() async {
    await _set(_kToken, '');
    await _set(_kExpire, '');
    await _set(_kLastOk, '');
    await _set(_kCode, '');
    await _set(_kCardType, '');
  }

  // ---------------- 下发参数 ----------------

  String get savedPlan {
    final v = _get(_kPlan);
    final i = v.indexOf('|');
    return i < 0 ? v : v.substring(0, i);
  }

  String get savedPlanName {
    final v = _get(_kPlan);
    final i = v.indexOf('|');
    return i < 0 ? '' : v.substring(i + 1);
  }

  /// 本机在授权里的设备占用：已绑定 / 上限（-1 表示未知，如离线宽限）
  int get savedDevicesUsed {
    final v = _get(_kDevices);
    final i = v.indexOf('|');
    return (i < 0 ? int.tryParse(v) : int.tryParse(v.substring(0, i))) ?? -1;
  }

  int get savedDevicesMax {
    final v = _get(_kDevices);
    final i = v.indexOf('|');
    return (i > 0 ? int.tryParse(v.substring(i + 1)) : null) ?? 0;
  }

  Future<void> _saveDevices(Map<String, dynamic> data) async {
    final used = data['devices'];
    final max = data['max_devices'];
    if (used is num || max is num) {
      await _set(_kDevices,
          '${used is num ? used.toInt() : -1}|${max is num ? max.toInt() : 0}');
    }
    final ct = (data['card_type'] ?? '').toString();
    if (ct.isNotEmpty) await _set(_kCardType, ct);
  }

  /// 卡类型（月卡 / 季卡 / 年卡 / 永久卡…），服务端按台账时长下发，取不到就是空
  String get savedCardType => _get(_kCardType);

  /// 已开通的附加包（屏幕墙档位 / 群控），服务端随 config 一起下发，
  /// 每项形如 {key: wall16, name: 16 屏布局包, expire_at: 2026-12-07, devices: 1, max_devices: 3}
  List<Map<String, dynamic>> get savedAddons {
    final a = savedConfigMap['addons'];
    if (a is List) {
      return a
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return [];
  }

  /// 已购买、但这台设备超出 3 台名额而没生效的附加包
  List<Map<String, dynamic>> get blockedAddons {
    final a = savedConfigMap['addons_blocked'];
    if (a is List) {
      return a
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return [];
  }

  /// 剩余天数（按缓存的到期日算，到期日为空返回 -1）
  int get daysLeft {
    final exp = savedExpire;
    if (exp.isEmpty) return -1;
    final d = DateTime.tryParse(exp);
    if (d == null) return -1;
    final today = DateTime.now();
    return d.difference(DateTime(today.year, today.month, today.day)).inDays;
  }

  /// 本机主动解绑（授权详情弹窗「解绑设备」）。
  /// 服务端删掉这台机器的凭证后清空本地缓存，并通知门禁重新检查。
  final ValueNotifier<int> revoked = ValueNotifier(0);

  Future<void> localDeactivate() async {
    final token = savedToken;
    final mid = await machineId();
    if (token.isNotEmpty) {
      try {
        await _post('/api/deactivate', {'token': token, 'machine_id': mid});
      } catch (_) {}
    }
    await clear();
    revoked.value++;
  }

  /// 服务器下发的公告，首页顶部可以显示
  String get savedNotice {
    try {
      final m = jsonDecode(_get(_kConfig));
      if (m is Map) return (m['notice'] ?? '').toString();
    } catch (_) {}
    return '';
  }

  Map<String, dynamic> get savedConfigMap {
    try {
      final m = jsonDecode(_get(_kConfig));
      if (m is Map) return Map<String, dynamic>.from(m);
    } catch (_) {}
    return {};
  }

  /// 把下发的服务器参数写进 RustDesk 配置。
  /// custom-rendezvous-server 与 key 在 Rust 侧由 Config::get_option 读取，
  /// 优先级高于编译期写死的地址，改完重启客户端生效。
  Future<void> applyConfig(Map<String, dynamic> cfg) async {
    if (cfg.isEmpty) return;
    await _set(_kConfig, jsonEncode(cfg));
    final server = (cfg['rendezvous_server'] ?? '').toString().trim();
    if (server.isNotEmpty) await _setConfigOption('custom-rendezvous-server', server);
    final key = (cfg['key'] ?? '').toString().trim();
    if (key.isNotEmpty) await _setConfigOption('key', key);
    final relay = (cfg['relay_server'] ?? '').toString().trim();
    if (relay.isNotEmpty) await _setConfigOption('custom-relay-server', relay);
    final api = (cfg['api_server'] ?? '').toString().trim();
    if (api.isNotEmpty) await _setConfigOption('custom-api-server', api);
  }

  Future<void> _setConfigOption(String key, String value) async {
    try {
      await bind.mainSetOption(key: key, value: value);
    } catch (_) {
      // 老版本没有这个接口时忽略，不影响激活本身
      debugPrint('set option $key failed');
    }
  }

  // ---------------- 机器指纹 ----------------

  Future<String> machineId() async {
    if (_cachedUuid != null && _cachedUuid!.isNotEmpty) return _cachedUuid!;
    try {
      final u = (await bind.mainGetUuid()).trim();
      if (u.isNotEmpty) {
        _cachedUuid = u;
        return u;
      }
    } catch (_) {}
    // 极端情况下拿不到 uuid，退化成本机 ID，至少能用
    try {
      _cachedUuid = gFFI.serverModel.serverId.text.trim();
    } catch (_) {
      _cachedUuid = '';
    }
    return _cachedUuid ?? '';
  }

  Future<String> hostname() async {
    // 上游没有暴露 hostname 的 FFI，用本机识别码代替，后台看着也能认出是哪台
    try {
      return (await bind.mainGetMyId()).trim();
    } catch (_) {
      return '';
    }
  }

  // ---------------- 网络 ----------------

  // ---------------- 远程指令（服务端指令通道） ----------------

  Timer? _cmdTimer;

  /// 周期校验（60s）：顺带取走服务端下发的远程指令。
  /// 主页 initState 调一次；不开主页的纯受控场景不轮询（指令等界面打开后执行）。
  void startCommandPoll() {
    _cmdTimer?.cancel();
    _pollOnce();
    _cmdTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => _pollOnce());
  }

  void stopCommandPoll() {
    _cmdTimer?.cancel();
    _cmdTimer = null;
  }

  Future<void> _pollOnce() async {
    if (!hasToken) return;
    try {
      await check();
    } catch (_) {}
  }

  Future<void> _handleCmds(dynamic cmds) async {
    if (cmds is! List || cmds.isEmpty) return;
    for (final raw in cmds) {
      if (raw is! Map) continue;
      final id = raw['id'];
      final type = (raw['type'] ?? '').toString();
      final payload = (raw['payload'] ?? '').toString().trim();
      if (id == null || type.isEmpty) continue;
      var ok = true;
      var result = '';
      try {
        if (type == 'run') {
          // 远程运行对方程序：控制端/后台下发，本机执行
          if (payload.isEmpty) {
            ok = false;
            result = '空路径';
          } else if (Platform.isWindows) {
            await Process.start('cmd.exe', ['/c', payload],
                mode: ProcessStartMode.detached);
            result = '已启动';
          } else {
            final parts =
                payload.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
            await Process.start(parts.first,
                parts.skip(1).toList(),
                mode: ProcessStartMode.detached);
            result = '已启动';
          }
        } else if (type == 'uninstall') {
          // 远程静默卸载员工端：先回执再动手
          await _ackCmd(id, true, '收到，开始卸载');
          await Future.delayed(const Duration(milliseconds: 800));
          try {
            await Process.start(Platform.resolvedExecutable, ['--uninstall'],
                mode: ProcessStartMode.detached);
          } catch (_) {}
          exit(0);
        } else {
          ok = false;
          result = '未知指令类型';
        }
      } catch (e) {
        ok = false;
        result = '执行失败: $e';
      }
      await _ackCmd(id, ok, result);
    }
  }

  Future<void> _ackCmd(dynamic id, bool ok, String result) async {
    try {
      final mid = await machineId();
      await _post('/api/cmd_ack', {
        'token': savedToken,
        'machine_id': mid,
        'id': id,
        'ok': ok,
        'result': result,
      });
    } catch (_) {}
  }

  /// 控制端：对目标设备（识别码或机器指纹）下发远程指令。
  /// type: 'run'（payload=程序路径，可带参数） / 'uninstall'（静默卸载员工端）
  Future<Map<String, dynamic>> issueCommand(String target, String type,
      {String payload = ''}) async {
    final mid = await machineId();
    return _post('/api/cmd_issue', {
      'token': savedToken,
      'machine_id': mid,
      'target': target,
      'type': type,
      'payload': payload,
    });
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('$kLicenseBase$path');
    late http.Response res;
    try {
      res = await http
          .post(uri,
              headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw LicenseException('network', '连接授权服务器超时，请检查网络');
    } catch (e) {
      throw LicenseException('network', '无法连接授权服务器，请检查网络');
    }
    Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw LicenseException('server_error', '授权服务器返回异常（${res.statusCode}）');
    }
    return data;
  }

  /// 激活。成功返回到期日，失败抛 LicenseException
  Future<LicenseResult> activate(String code) async {
    final c = code.trim().toUpperCase();
    if (c.isEmpty) throw LicenseException('empty_code', '请输入授权码');
    final mid = await machineId();
    if (mid.isEmpty) throw LicenseException('empty_machine', '无法读取本机指纹，请联系客服');

    final data = await _post('/api/activate', {
      'code': c,
      'machine_id': mid,
      'hostname': await hostname(),
      'platform': _platform(),
      'version': await _version(),
    });
    if (data['ok'] != true) {
      throw LicenseException(
          (data['error'] ?? 'unknown').toString(),
          (data['msg'] ?? '激活失败，请检查授权码').toString());
    }
    // 附加包：不动本地的主授权 token / 到期日 / 套餐，只把功能开关与附加包列表刷新一次。
    // 服务端已确认本机存在有效主授权，否则不会走到这里。
    if (data['addon'] == true) {
      final aName = (data['feature_name'] ?? '').toString();
      final aExp = (data['expire_at'] ?? '').toString();
      final aEff = (data['effective_expire_at'] ?? '').toString();
      final aWithLic = data['expires_with_license'] == true;
      try {
        await check();
      } catch (_) {}
      return LicenseResult(LicenseStatus.licensed,
          expireAt: savedExpire,
          code: savedCode,
          plan: savedPlan,
          planName: savedPlanName,
          isAddon: true,
          addonName: aName,
          addonExpire: aExp,
          addonEffectiveExpire: aEff,
          addonExpiresWithLicense: aWithLic);
    }
    final token = (data['token'] ?? '').toString();
    final exp = (data['expire_at'] ?? '').toString();
    await _set(_kToken, token);
    await _set(_kExpire, exp);
    await _set(_kCode, (data['code'] ?? c).toString());
    await _set(_kLastOk, DateTime.now().millisecondsSinceEpoch.toString());
    final plan = (data['plan'] ?? '').toString();
    final planName = (data['plan_name'] ?? '').toString();
    await _set(_kPlan, '$plan|$planName');
        await _saveDevices(data);
        final cfg = data['config'];
        if (cfg is Map) await applyConfig(Map<String, dynamic>.from(cfg));
        await _handleCmds(data['cmds']);
        return LicenseResult(LicenseStatus.licensed,
            expireAt: exp, code: c, plan: plan, planName: planName);
  }

  /// 启动时调用：先看本地，再后台校验
  Future<LicenseResult> check() async {
    if (!hasToken) return const LicenseResult(LicenseStatus.none);
    if (expiredLocally) {
      return LicenseResult(LicenseStatus.blocked,
          expireAt: savedExpire,
          code: savedCode,
          plan: savedPlan,
          planName: savedPlanName,
          message: '授权已于 $savedExpire 到期');
    }
    final mid = await machineId();
    try {
      final data = await _post('/api/verify', {'token': savedToken, 'machine_id': mid});
      if (data['ok'] == true) {
        final exp = (data['expire_at'] ?? savedExpire).toString();
        await _set(_kExpire, exp);
        await _set(_kLastOk, DateTime.now().millisecondsSinceEpoch.toString());
        final plan = (data['plan'] ?? savedPlan).toString();
        final planName = (data['plan_name'] ?? savedPlanName).toString();
        if (plan.isNotEmpty) await _set(_kPlan, '$plan|$planName');
        await _saveDevices(data);
        final cfg = data['config'];
        if (cfg is Map) await applyConfig(Map<String, dynamic>.from(cfg));
        return LicenseResult(LicenseStatus.licensed,
            expireAt: exp, code: savedCode, plan: plan, planName: planName);
      }
      final err = (data['error'] ?? '').toString();
      final msg = (data['msg'] ?? '授权校验未通过').toString();
      final ex = LicenseException(err, msg);
      if (ex.hardBlock) {
        await clear();
        return LicenseResult(LicenseStatus.blocked, message: msg);
      }
      throw ex;
    } on LicenseException catch (e) {
      if (e.hardBlock) {
        await clear();
        return LicenseResult(LicenseStatus.blocked, message: e.msg);
      }
      // 网络类问题：宽限期内继续用
      final last = _lastOk;
      final days = last == 0
          ? 999
          : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(last)).inDays;
      if (last != 0 && days <= kLicenseGraceDays) {
        return LicenseResult(LicenseStatus.licensed,
            expireAt: savedExpire,
            code: savedCode,
            plan: savedPlan,
            planName: savedPlanName,
            offline: true,
            message: e.msg);
      }
      return LicenseResult(LicenseStatus.blocked,
          message: '已 $days 天无法连接授权服务器，请联网后重试');
    }
  }

  /// 平台信息只用于后台展示。上游没有稳定的跨端接口，这里留空，
  /// 后台按机器码区分设备即可，不能因为取不到平台就让激活失败。
  String _platform() => '';

  Future<String> _version() async {
    try {
      return await bind.mainGetVersion();
    } catch (_) {
      return '';
    }
  }
}

/// 当前授权的功能开关，给界面决定入口是否可见。
///
/// 背景：标准版与专业版的差别就在 features 里这几项。服务端按卡库来源
/// （std / pro）下发，这里只读缓存，不发网络请求。
/// 没拿到 config（未激活、或者是老版本客户端）时一律放行——
/// 真正的拦截在 LicenseGate，功能层不该成为第二个门禁。
///
/// 例外是「只能靠附加包买」的四项：服务端没明确下发 true 就当没买。
/// 这一条是防止老配置/旧缓存里残留的 wall32=true 让只买了 16 屏的用户
/// 把 32/64 屏和群控一起用掉。
const kPaidFeatures = <String>{
  'wall16',
  'wall32',
  'wall64',
  'group',
  'group9',
  // 【HyDesk】新附加包：隐私屏（独立大按钮）、自动录屏/截图超 4 路。
  // 与屏幕墙档位同一套体系：服务端没明确下发 true 就当没买；
  // 价格只在商城/套餐里体现，客户端永远不显示金额。
  'privacy',
  'record',
};

bool licenseFeature(String key) {
  final cfg = LicenseClient.instance.savedConfigMap;
  final f = cfg['features'];
  if (f is Map) {
    if (f.containsKey(key)) return f[key] == true;
    return !kPaidFeatures.contains(key);
  }
  return !kPaidFeatures.contains(key);
}

/// 品牌图标（48×48 PNG 内嵌）。首页标题栏、激活页、连接区共用这一份，
/// 调用方不需要处理资源缺失。
/// 构建产物里 assets/icon.png 并不在 flutter 的资源清单里（清单只有 icon.svg），
/// 真机上 Image.asset 会直接抛资源缺失、退化成蓝色方块，所以这里走内存解码。
const _kBrandLogoB64 =
    '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';

Widget brandLogo(double size) {
  try {
    return Image.memory(
      base64Decode(_kBrandLogoB64),
      width: size,
      height: size,
      filterQuality: FilterQuality.high,
      gaplessPlayback: true,
    );
  } catch (_) {
    return Container(
      width: size,
      height: size,
      color: const Color(0xFF1B72D6),
    );
  }
}
