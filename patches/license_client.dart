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

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// 授权服务地址（nginx 反代到本机授权服务）
const kLicenseBase = 'https://hd.fcpx0.cn/license';

/// 断网宽限天数
const kLicenseGraceDays = 7;

const _kToken = 'license-token';
const _kExpire = 'license-expire';
const _kLastOk = 'license-last-ok';
const _kCode = 'license-code';
const _kConfig = 'license-config';
const _kPlan = 'license-plan';

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

  const LicenseResult(this.status,
      {this.expireAt = '',
      this.code = '',
      this.message = '',
      this.offline = false,
      this.plan = '',
      this.planName = ''});

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
    final token = (data['token'] ?? '').toString();
    final exp = (data['expire_at'] ?? '').toString();
    await _set(_kToken, token);
    await _set(_kExpire, exp);
    await _set(_kCode, (data['code'] ?? c).toString());
    await _set(_kLastOk, DateTime.now().millisecondsSinceEpoch.toString());
    final plan = (data['plan'] ?? '').toString();
    final planName = (data['plan_name'] ?? '').toString();
    await _set(_kPlan, '$plan|$planName');
    final cfg = data['config'];
    if (cfg is Map) await applyConfig(Map<String, dynamic>.from(cfg));
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
bool licenseFeature(String key) {
  final cfg = LicenseClient.instance.savedConfigMap;
  final f = cfg['features'];
  if (f is Map && f.containsKey(key)) return f[key] == true;
  return true;
}
