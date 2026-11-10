// 地址簿：账号登录 + 云端同步版。
//
// 账号和设备清单存在地址簿服务 https://api.hydesk.cn（/api/login、/api/ab/*），
// 同一个账号在任何一台电脑上登录都能看到同一份设备清单，也能用浏览器登录
// https://api.hydesk.cn/ 直接管理。
// 设计要点：
//   - 本地始终保留一份缓存（local option = address-book-v2），断网也能看、能连；
//   - 打开页面先显示缓存，后台拉云端，按识别码合并（本地新增的不丢）；
//   - 增删改后整体推送到云端（条目量小，全量替换最不容易出 bug）；
//   - 推送失败不阻塞本地操作，顶部出现「同步失败」提示条，点一下重试。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/pages/license_client.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';

/// 配色与首页保持一致
class _AC {
  static const blue = Color(0xFF1B72D6);
  static const text = Color(0xFF333333);
  static const sub = Color(0xFF7A7A7A);
  static const line = Color(0xFFE7E7E7);
  static const hover = Color(0xFFF5F8FD);
  static const pane = Color(0xFFFAFAFA);
  static const green = Color(0xFF16A34A);
}

class AbEntry {
  String id;
  String alias;
  String tag;
  String note;

  AbEntry({
    required this.id,
    this.alias = '',
    this.tag = '',
    this.note = '',
  });

  factory AbEntry.fromJson(Map<String, dynamic> j) => AbEntry(
        id: (j['id'] ?? '').toString(),
        alias: (j['alias'] ?? '').toString(),
        tag: (j['tag'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'alias': alias, 'tag': tag, 'note': note};

  String get display => alias.isEmpty ? id : alias;
}

/// 地址簿数据源 + 账号状态。单例 + ChangeNotifier，切 tab 不丢状态。
class AddressBookStore extends ChangeNotifier {
  AddressBookStore._();

  static final AddressBookStore instance = AddressBookStore._();

  static const _kKey = 'address-book-v2';
  static const _kUser = 'ab-user';
  static const _kToken = 'ab-token';

  final List<AbEntry> entries = [];
  bool loaded = false;
  bool syncing = false;
  String syncError = '';

  String _username = '';
  String _token = '';

  String get username => _username;
  bool get signedIn => _token.isNotEmpty;
  bool get needsSync => syncError.isNotEmpty;

  /// 分组（去重、保序），空分组不返回
  List<String> get tags {
    final out = <String>[];
    for (final e in entries) {
      final t = e.tag.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }
    return out;
  }

  int countOf(String tag) =>
      tag.isEmpty ? entries.length : entries.where((e) => e.tag == tag).length;

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

  // ---------------- 账号 ----------------

  Future<bool> login(String username, String password) async {
    final d = await _request('POST', '/api/login',
        body: {'username': username, 'password': password});
    if (d['ok'] != true) throw Exception(_errText(d, '登录失败'));
    final token = (d['token'] ?? d['access_token'] ?? '').toString();
    if (token.isEmpty) throw Exception('登录失败：服务未返回登录凭证');
    await _adopt(username, token);
    return true;
  }

  Future<bool> register(String username, String password) async {
    final d = await _request('POST', '/api/register',
        body: {'username': username, 'password': password});
    if (d['ok'] != true) throw Exception(_errText(d, '注册失败'));
    final token = (d['token'] ?? d['access_token'] ?? '').toString();
    if (token.isEmpty) {
      // 有些部署注册后需要管理员开通，这时没有 token
      throw Exception('注册成功，请登录（若提示账号未开通，请联系管理员）');
    }
    await _adopt(username, token);
    return true;
  }

  Future<void> logout() async {
    _username = '';
    _token = '';
    await _set(_kUser, '');
    await _set(_kToken, '');
    syncError = '';
    notifyListeners();
  }

  Future<void> _adopt(String username, String token) async {
    _username = username;
    _token = token;
    await _set(_kUser, username);
    await _set(_kToken, token);
    loaded = false;
    await load(force: true);
  }

  // ---------------- 云端 ----------------

  /// 统一请求：登录用 POST，读清单用 GET（带 Bearer），增删用 POST/DELETE。
  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool auth = false,
    int timeoutSec = 12,
  }) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (auth && _token.isNotEmpty) headers['Authorization'] = 'Bearer $_token';
    final uri = Uri.parse('$kAbBase$path');
    final dur = Duration(seconds: timeoutSec);
    late final http.Response r;
    switch (method) {
      case 'GET':
        r = await http.get(uri, headers: headers).timeout(dur);
        break;
      case 'DELETE':
        r = await http.delete(uri, headers: headers).timeout(dur);
        break;
      default:
        r = await http
            .post(uri, headers: headers, body: jsonEncode(body ?? {}))
            .timeout(dur);
    }
    final txt = utf8.decode(r.bodyBytes);
    try {
      final j = jsonDecode(txt);
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {
      // 掉到下面统一处理
    }
    if (r.statusCode == 401 || r.statusCode == 403) {
      return {'ok': false, 'error': 'token_invalid', 'message': '登录已过期，请重新登录'};
    }
    return {
      'ok': false,
      'message': '地址簿服务返回异常（HTTP ${r.statusCode}）',
    };
  }

  String _errText(Map<String, dynamic> d, String fallback) {
    final m = (d['message'] ?? d['error'] ?? d['msg'] ?? '').toString().trim();
    return m.isEmpty ? fallback : m;
  }

  bool _isAuthError(Map<String, dynamic> d) {
    final e = '${d['error'] ?? ''} ${d['message'] ?? ''} ${d['msg'] ?? ''}'
        .toLowerCase();
    return e.contains('token') ||
        e.contains('auth') ||
        e.contains('login') ||
        e.contains('unauthorized') ||
        e.contains('未登录') ||
        e.contains('登录已过期') ||
        e.contains('重新登录');
  }

  /// 云端拉取 + 与本地缓存合并（并集，识别码去重，云端已删除的条目
  /// 只要本地还在就保留——删除是明确动作，靠推送覆盖）
  Future<void> _pullMerge() async {
    final d = await _request('GET', '/api/ab/me', auth: true);
    if (d['ok'] != true) {
      if (_isAuthError(d)) {
        await logout();
        return;
      }
      throw Exception(_errText(d, '同步失败'));
    }
    final list = d['peers'];
    if (list is List) {
      final cloud = <String, AbEntry>{};
      for (final raw in list) {
        if (raw is Map) {
          final m = Map<String, dynamic>.from(raw);
          final e = AbEntry(
            id: (m['id'] ?? '').toString().replaceAll(' ', ''),
            alias: (m['alias'] ?? '').toString(),
            tag: (m['tag'] ?? '').toString(),
          );
          if (e.id.isNotEmpty) cloud[e.id] = e;
        }
      }
      for (final e in entries) {
        // 本地有的云端没有：视为本地新增（或云端被另一台删了，以本地为准，推送后一致）
        cloud.putIfAbsent(e.id, () => e);
      }
      entries
        ..clear()
        ..addAll(cloud.values.toList()
          ..sort((a, b) => a.id.compareTo(b.id)));
    }
  }

  /// 以本地为准做一次对账：云端多出来的删掉，本地新增/改过的写上去。
  Future<bool> _push() async {
    final me = await _request('GET', '/api/ab/me', auth: true);
    if (me['ok'] != true) {
      if (_isAuthError(me)) {
        await logout();
        return false;
      }
      return false;
    }
    final cloud = <String, AbEntry>{};
    final cloudTags = <String>{};
    final peers = me['peers'];
    if (peers is List) {
      for (final raw in peers) {
        if (raw is Map) {
          final m = Map<String, dynamic>.from(raw);
          final id = (m['id'] ?? '').toString().replaceAll(' ', '');
          if (id.isEmpty) continue;
          cloud[id] = AbEntry(
            id: id,
            alias: (m['alias'] ?? '').toString(),
            tag: (m['tag'] ?? '').toString(),
          );
        }
      }
    }
    final tags = me['tags'];
    if (tags is List) {
      for (final t in tags) {
        cloudTags.add(t.toString());
      }
    }

    var ok = true;
    final localIds = entries.map((e) => e.id).toSet();
    for (final id in cloud.keys.toList()) {
      if (!localIds.contains(id)) {
        final r = await _request(
            'DELETE', '/api/ab/peers?id=${Uri.encodeComponent(id)}',
            auth: true);
        if (r['ok'] != true) ok = false;
      }
    }
    for (final e in entries) {
      final old = cloud[e.id];
      if (old == null || old.alias != e.alias || old.tag != e.tag) {
        final r = await _request('POST', '/api/ab/peers', auth: true, body: {
          'id': e.id,
          'alias': e.alias,
          'tag': e.tag,
        });
        if (r['ok'] != true) ok = false;
      }
      final t = e.tag.trim();
      if (t.isNotEmpty && !cloudTags.contains(t)) {
        // 分组不存在时顺手建一下，失败不影响设备同步
        await _request('POST', '/api/ab/tags', auth: true, body: {'name': t});
        cloudTags.add(t);
      }
    }
    return ok;
  }

  /// 增删改后调用：先写本地缓存（立即生效），再后台推送云端
  Future<void> _persist() async {
    await _set(
        _kKey, jsonEncode(entries.map((e) => e.toJson()).toList()));
    notifyListeners();
    if (!signedIn) return;
    syncing = true;
    notifyListeners();
    try {
      final ok = await _push();
      syncError = ok ? '' : '保存到云端失败，请稍后重试';
    } catch (_) {
      syncError = '网络异常，改动只保存在本机，联网后点击重试';
    }
    syncing = false;
    notifyListeners();
  }

  Future<void> retrySync() async {
    syncError = '';
    await _persist();
  }

  // ---------------- 本地缓存 ----------------

  Future<void> load({bool force = false}) async {
    if (loaded && !force) return;
    _username = _get(_kUser);
    _token = _get(_kToken);
    try {
      final raw = _get(_kKey);
      if (raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          entries
            ..clear()
            ..addAll(list
                .whereType<Map>()
                .map((e) => AbEntry.fromJson(Map<String, dynamic>.from(e))));
        }
      }
    } catch (e) {
      debugPrint('address book cache load failed: $e');
    }
    loaded = true;
    notifyListeners();
    if (signedIn) {
      syncing = true;
      notifyListeners();
      try {
        await _pullMerge();
        syncError = '';
        await _set(
            _kKey, jsonEncode(entries.map((e) => e.toJson()).toList()));
      } catch (_) {
        syncError = '无法连接同步服务，显示的是本机缓存';
      }
      syncing = false;
      notifyListeners();
    }
  }

  // ---------------- 增删改 ----------------

  /// [oldId] 用于改识别码时定位原条目
  Future<void> upsert(AbEntry entry, {String? oldId}) async {
    final key = oldId ?? entry.id;
    final i = entries.indexWhere((e) => e.id == key);
    if (i >= 0) {
      entries[i] = entry;
    } else {
      entries.add(entry);
    }
    await _persist();
  }

  Future<void> remove(String id) async {
    entries.removeWhere((e) => e.id == id);
    await _persist();
  }

  /// 批量导入（2026-11-10）：一次 _persist 一次云端推送，比逐条 upsert
  /// 少 N-1 次网络往返。合并规则保守：
  ///   - 不存在 → 新增；
  ///   - 已存在 → 新别名非空才覆盖别名；旧分组/备注为空且新值非空才补上
  ///     （已有内容一律不冲掉）。
  /// 返回 [新增数, 更新数]。
  Future<List<int>> batchUpsert(List<AbEntry> list) async {
    var added = 0;
    var updated = 0;
    for (final e in list) {
      if (e.id.isEmpty) continue;
      final i = entries.indexWhere((x) => x.id == e.id);
      if (i >= 0) {
        final old = entries[i];
        var changed = false;
        if (e.alias.isNotEmpty && e.alias != old.alias) {
          old.alias = e.alias;
          changed = true;
        }
        if (e.tag.isNotEmpty && old.tag.isEmpty) {
          old.tag = e.tag;
          changed = true;
        }
        if (e.note.isNotEmpty && old.note.isEmpty) {
          old.note = e.note;
          changed = true;
        }
        if (changed) updated++;
      } else {
        entries.add(e);
        added++;
      }
    }
    if (added + updated > 0) await _persist();
    return [added, updated];
  }

  bool exists(String id, {String? exceptId}) =>
      entries.any((e) => e.id == id && e.id != exceptId);

  /// 批量设置分组（2026-11-10）：把勾选的一批设备归入 [tag]，
  /// [tag] 为空 = 移出分组（变成未分组）。一次 persist + 一次推送。
  /// 返回实际改动的条数。
  Future<int> setTagFor(List<String> ids, String tag) async {
    final set = ids.map((s) => s.replaceAll(' ', '')).toSet();
    final t = tag.trim();
    var n = 0;
    for (final e in entries) {
      if (set.contains(e.id) && e.tag != t) {
        e.tag = t;
        n++;
      }
    }
    if (n > 0) await _persist();
    return n;
  }

  /// 重命名分组：旧组名下的设备全部换成新组名。返回改动条数。
  Future<int> renameTag(String oldTag, String newTag) async {
    final t = newTag.trim();
    if (t.isEmpty || t == oldTag) return 0;
    var n = 0;
    for (final e in entries) {
      if (e.tag == oldTag) {
        e.tag = t;
        n++;
      }
    }
    if (n > 0) await _persist();
    return n;
  }

  /// 删除分组：组内设备保留，只是变成未分组。返回改动条数。
  Future<int> clearTag(String tag) async {
    var n = 0;
    for (final e in entries) {
      if (e.tag == tag) {
        e.tag = '';
        n++;
      }
    }
    if (n > 0) await _persist();
    return n;
  }
}

/// 9 位数字识别码每三位加一个空格，和首页显示方式一致
String formatAbId(String id) {
  if (id.length < 6 || int.tryParse(id) == null) return id;
  final buf = StringBuffer();
  for (var i = 0; i < id.length; i++) {
    buf.write(id[i]);
    if (i != id.length - 1 && (id.length - 1 - i) % 3 == 0) buf.write(' ');
  }
  return buf.toString();
}

/// 识别码打码：保留前 3 位 + 后 2 位，中间用 * 顶替。
/// 屏幕墙等「对外展示」位置统一走这里，避免完整识别码外泄
/// （2026-11-10 用户要求：墙上名字一律以重命名为准，保护 ID）。
String maskAbId(String id) {
  final s = id.replaceAll(' ', '').trim();
  if (s.isEmpty) return '';
  if (s.length <= 5) return s.substring(0, 1) + List.filled(s.length - 1, '*').join();
  return s.substring(0, 3) +
      List.filled(s.length - 5, '*').join() +
      s.substring(s.length - 2);
}

/// 原生风格头像底色：按名称哈希取固定颜色，同一台设备每次进来颜色一样。
/// 地址簿、首页设备列表共用（顶层公开，client_home_page.dart 直接引用）。
const List<Color> kAbAvatarColors = [
  Color(0xFFE2A39A),
  Color(0xFFE9A9C7),
  Color(0xFFCFC79A),
  Color(0xFFB9A6E3),
  Color(0xFFA9C6A7),
  Color(0xFF9FBBD8),
  Color(0xFFE0B389),
  Color(0xFFA8BFC6),
];

Color abAvatarColor(String seed) {
  if (seed.isEmpty) return kAbAvatarColors.first;
  var h = 0;
  for (final c in seed.runes) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return kAbAvatarColors[h % kAbAvatarColors.length];
}

/// 把一批识别码加入屏幕墙。屏幕墙显示的就是「收藏」设备列表，
/// 所以加墙 = 写入收藏 + 通知刷新。返回实际新增台数，-1 表示失败。
/// 地址簿、首页最近/收藏列表共用。
Future<int> addPeersToScreenWall(List<String> ids) async {
  final clean = ids
      .map((s) => s.replaceAll(' ', ''))
      .where((s) => s.isNotEmpty)
      .toList();
  if (clean.isEmpty) return 0;
  List<String> favs;
  try {
    favs = (await bind.mainGetFav()).toList();
  } catch (_) {
    return -1;
  }
  var added = 0;
  for (final id in clean) {
    if (!favs.contains(id)) {
      favs.add(id);
      added++;
    }
  }
  if (added == 0) return 0;
  try {
    await bind.mainStoreFav(favs: favs);
    bind.mainLoadFavPeers();
  } catch (_) {
    return -1;
  }
  return added;
}

/// 从屏幕墙（=收藏夹）里移除设备。屏幕墙就是收藏列表，所以移除等于取消收藏。
Future<int> removePeersFromScreenWall(List<String> ids) async {
  final clean = ids
      .map((s) => s.replaceAll(' ', ''))
      .where((s) => s.isNotEmpty)
      .toSet();
  if (clean.isEmpty) return 0;
  List<String> favs;
  try {
    favs = (await bind.mainGetFav()).toList();
  } catch (_) {
    return -1;
  }
  final before = favs.length;
  favs = favs.where((s) => !clean.contains(s.replaceAll(' ', ''))).toList();
  if (favs.length == before) return 0;
  try {
    await bind.mainStoreFav(favs: favs);
    bind.mainLoadFavPeers();
  } catch (_) {
    return -1;
  }
  return before - favs.length;
}

/// 内嵌在首页设备区里的地址簿视图
class AddressBookView extends StatefulWidget {
  final String query;
  final void Function(String id) onConnect;

  const AddressBookView({
    Key? key,
    required this.query,
    required this.onConnect,
  }) : super(key: key);

  @override
  State<AddressBookView> createState() => _AddressBookViewState();
}

class _AddressBookViewState extends State<AddressBookView> {
  /// 「未分组」筛选用的哨兵值（正常分组名不会出现 § 号）
  static const _kNoTag = '§未分组§';

  String _tag = '';
  bool _batch = false;
  final Set<String> _sel = {};

  /// 排列方式：列表 / 网格（和首页设备列表那套一致）
  bool _grid = false;

  /// 名称正序 / 倒序
  bool _asc = true;

  /// 行首的状态点读的是收藏/最近模型里的 online，模型收到
  /// callback_query_onlines 后会 notifyListeners，这里一并订阅才会跟着变红绿。
  late final Listenable _ticker = Listenable.merge([
    AddressBookStore.instance,
    gFFI.favoritePeersModel,
    gFFI.recentPeersModel,
  ]);

  @override
  void initState() {
    super.initState();
    AddressBookStore.instance.load();
  }

  List<AbEntry> _visible() {
    final raw = widget.query.trim().toLowerCase();
    // 识别码在地址簿里是不带空格的，用户可能照着界面上「982 471 635」的样子搜
    final q = raw.replaceAll(' ', '');
    final list = AddressBookStore.instance.entries.where((e) {
      if (_tag == _kNoTag) {
        // 未分组：只看没有分组的设备，方便批量归类
        if (e.tag.trim().isNotEmpty) return false;
      } else if (_tag.isNotEmpty && e.tag != _tag) {
        return false;
      }
      if (q.isEmpty) return true;
      return e.id.toLowerCase().contains(q) ||
          e.alias.toLowerCase().contains(raw) ||
          e.tag.toLowerCase().contains(raw) ||
          e.note.toLowerCase().contains(raw);
    }).toList();
    list.sort((a, b) => _asc
        ? a.display.compareTo(b.display)
        : b.display.compareTo(a.display));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ticker,
      builder: (context, _) {
        final store = AddressBookStore.instance;
        if (!store.signedIn) return _LoginCard();
        final list = _visible();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (store.needsSync) _syncBar(store),
            _batchBar(list),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _tagPane(store),
                  Container(width: 1, color: _AC.line),
                  Expanded(
                      child: list.isEmpty
                          ? _empty(store)
                          : (_grid ? _gridView(list) : _list(list))),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _syncBar(AddressBookStore store) {
    return InkWell(
      onTap: () => store.retrySync(),
      child: Container(
        height: 30,
        color: const Color(0xFFFFF6E5),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 14, color: Color(0xFFB45309)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(store.syncError,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFB45309))),
            ),
            if (store.syncing)
              const SizedBox(
                  width: 12,
                  height: 12,
                  child:
                      CircularProgressIndicator(strokeWidth: 1.6))
            else
              const Text('重试',
                  style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFFB45309),
                      fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _tagPane(AddressBookStore store) {
    final tags = store.tags;
    final noTag = store.entries.where((e) => e.tag.trim().isEmpty).length;
    // 选中的分组被删空后回到「全部」（未分组同理）
    if (_tag.isNotEmpty) {
      if (_tag == _kNoTag) {
        if (noTag == 0) _tag = '';
      } else if (!tags.contains(_tag)) {
        _tag = '';
      }
    }
    return Container(
      width: 152,
      color: _AC.pane,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _tagRow('全部设备', '', store.entries.length),
                for (final t in tags) _tagRow(t, t, store.countOf(t)),
                if (noTag > 0 && tags.isNotEmpty)
                  _tagRow('未分组', _kNoTag, noTag),
              ],
            ),
          ),
          Container(height: 1, color: _AC.line),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.person_outline,
                    size: 14, color: _AC.sub),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    store.username.isEmpty ? '已登录' : store.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: _AC.sub),
                  ),
                ),
                InkWell(
                  onTap: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('退出登录',
                            style: TextStyle(fontSize: 16)),
                        content: const Text(
                            '退出后地址簿仍保留在本机缓存，重新登录同一账号即可恢复同步。',
                            style: TextStyle(fontSize: 13.5)),
                        actions: [
                          TextButton(
                              onPressed: () =>
                                  Navigator.of(ctx).pop(false),
                              child: const Text('取消')),
                          TextButton(
                              onPressed: () =>
                                  Navigator.of(ctx).pop(true),
                              child: const Text('退出',
                                  style: TextStyle(
                                      color: Color(0xFFE23B3B)))),
                        ],
                      ),
                    );
                    if (ok == true) {
                      setState(() => _tag = '');
                      await AddressBookStore.instance.logout();
                    }
                  },
                  child: const Text('退出',
                      style: TextStyle(
                          fontSize: 11.5, color: _AC.blue)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tagRow(String label, String value, int count) {
    final active = _tag == value;
    final row = InkWell(
      onTap: () => setState(() => _tag = value),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        color: active ? _AC.blue.withOpacity(0.08) : Colors.transparent,
        child: Row(
          children: [
            if (active)
              Container(
                width: 3,
                height: 16,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: _AC.blue,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: active ? _AC.blue : _AC.text,
                  fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
            ),
            Text('$count',
                style: const TextStyle(fontSize: 11.5, color: _AC.sub)),
          ],
        ),
      ),
    );
    // 真实分组支持右键管理（重命名 / 删除）；「全部设备」「未分组」不参与
    if (value.isEmpty || value == _kNoTag) return row;
    return GestureDetector(
      onSecondaryTapUp: (d) => _groupMenu(value, d.globalPosition),
      child: row,
    );
  }

  /// 分组右键菜单：重命名 / 删除（设备保留，只是变成未分组）
  Future<void> _groupMenu(String tag, Offset pos) async {
    final store = AddressBookStore.instance;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: const [
        PopupMenuItem(value: 'rename', child: Text('重命名分组')),
        PopupMenuItem(
            value: 'del',
            child: Text('删除分组',
                style: TextStyle(color: Color(0xFFE23B3B)))),
      ],
    );
    if (v == null || !mounted) return;
    if (v == 'rename') {
      final ctrl = TextEditingController(text: tag);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('重命名分组', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 340,
            child: TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(fontSize: 13, color: _AC.text),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '分组名',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (x) => Navigator.of(ctx).pop(x),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消')),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _AC.blue),
                onPressed: () => Navigator.of(ctx).pop(ctrl.text),
                child: const Text('确定')),
          ],
        ),
      );
      final n = name?.trim();
      ctrl.dispose();
      if (n == null || n.isEmpty || n == tag) return;
      final cnt = await store.renameTag(tag, n);
      if (!mounted) return;
      setState(() => _tag = n);
      showToast(cnt > 0
          ? '已把「$tag」改名为「$n」，共 $cnt 台设备'
          : '「$tag」分组里没有设备');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分组', style: TextStyle(fontSize: 16)),
        content: Text(
            '删除分组「$tag」后，组内设备仍保留在地址簿里，只是变成「未分组」。',
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除',
                  style: TextStyle(color: Color(0xFFE23B3B)))),
        ],
      ),
    );
    if (ok != true) return;
    final cnt = await store.clearTag(tag);
    if (!mounted) return;
    setState(() => _tag = '');
    showToast(cnt > 0 ? '已删除分组「$tag」，$cnt 台设备变为未分组' : '该分组已空');
  }

  /// 列表顶部条：普通态显示设备数 + 批量管理入口；批量态显示全选/加墙/取消
  Widget _batchBar(List<AbEntry> list) {
    final allSel = list.isNotEmpty && list.every((e) => _sel.contains(e.id));
    return Container(
      height: 36,
      padding: const EdgeInsets.only(left: 14, right: 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: _AC.line)),
      ),
      child: _batch
          ? Row(
              children: [
                Text('已选 ${_sel.length} 台',
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: _AC.text)),
                const SizedBox(width: 6),
                // 批量动作多了（设置分组 / 远程运行），窄窗口横向滚动兜底
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      children: [
                        TextButton(
                  onPressed: () => setState(() {
                    if (allSel) {
                      _sel.clear();
                    } else {
                      _sel.addAll(list.map((e) => e.id));
                    }
                  }),
                  child: Text(allSel ? '全不选' : '全选',
                      style: const TextStyle(fontSize: 12.5)),
                ),
                TextButton.icon(
                  onPressed: _sel.isEmpty ? null : _batchSetTag,
                  icon: const Icon(Icons.label_outline, size: 15),
                  label: const Text('设置分组',
                      style: TextStyle(fontSize: 12.5)),
                ),
                TextButton.icon(
                  onPressed: _sel.isEmpty ? null : _addSelToWall,
                  icon: const Icon(Icons.tv, size: 15),
                  label: const Text('添加到屏幕墙',
                      style: TextStyle(fontSize: 12.5)),
                ),
                TextButton.icon(
                  onPressed: _sel.isEmpty ? null : _batchRemoteRun,
                  icon: const Icon(Icons.play_circle_outline, size: 15),
                  label: const Text('远程运行',
                      style: TextStyle(fontSize: 12.5)),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _batch = false;
                    _sel.clear();
                  }),
                  child: const Text('取消',
                      style: TextStyle(fontSize: 12.5, color: _AC.sub)),
                ),
                      ],
                    ),
                  ),
                ),
              ],
            )
          : Row(
              children: [
                Text('共 ${list.length} 台设备',
                    style: const TextStyle(fontSize: 12, color: _AC.sub)),
                const Spacer(),
                _barIcon(
                  _grid ? Icons.view_list_rounded : Icons.grid_on_rounded,
                  _grid ? '列表排列' : '网格排列',
                  () => setState(() => _grid = !_grid),
                  active: _grid,
                ),
                _barIcon(
                  Icons.swap_vert,
                  _asc ? '改为倒序' : '改为正序',
                  () => setState(() => _asc = !_asc),
                  active: !_asc,
                ),
                const SizedBox(width: 2),
                TextButton.icon(
                  onPressed: list.isEmpty
                      ? null
                      : () => setState(() => _batch = true),
                  icon: const Icon(Icons.playlist_add_check, size: 15),
                  label:
                      const Text('批量管理', style: TextStyle(fontSize: 12.5)),
                ),
              ],
            ),
    );
  }

  Future<void> _addSelToWall() async {
    final n = await addPeersToScreenWall(_sel.toList());
    if (!mounted) return;
    if (n < 0) {
      showToast('添加失败，请重试');
      return;
    }
    showToast(n == 0 ? '所选设备都已在屏幕墙里' : '已把 $n 台设备加入屏幕墙');
    setState(() {
      _batch = false;
      _sel.clear();
    });
  }

  /// 批量设置分组（2026-11-10）：勾选多台设备一次归组；填「-」或点
  /// 「移出分组」= 清除分组（变成未分组）。
  Future<void> _batchSetTag() async {
    if (_sel.isEmpty) return;
    final store = AddressBookStore.instance;
    final tags = store.tags;
    final ctrl = TextEditingController(text: _tag == _kNoTag ? '' : _tag);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('批量设置分组（已选 ${_sel.length} 台）',
            style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 34,
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: const TextStyle(fontSize: 13, color: _AC.text),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '分组名，如：公司 / 客户 / 门店',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (x) => Navigator.of(ctx).pop(x),
                ),
              ),
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('已有分组（点一下填入）',
                    style: TextStyle(fontSize: 12, color: _AC.sub)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final t in tags)
                      InkWell(
                        onTap: () => Navigator.of(ctx).pop(t),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            border: Border.all(color: _AC.line),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(t,
                              style: const TextStyle(
                                  fontSize: 11.5, color: _AC.text)),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              const Text('留空后点「归入分组」等于移出分组。',
                  style: TextStyle(fontSize: 11.5, color: _AC.sub)),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(''),
              child: const Text('移出分组')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _AC.blue),
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('归入分组'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (r == null) return;
    final n = await store.setTagFor(_sel.toList(), r);
    if (!mounted) return;
    setState(() {
      _batch = false;
      _sel.clear();
      if (r.isNotEmpty) _tag = r;
    });
    showToast(r.isEmpty
        ? '已把 $n 台设备移出分组'
        : (n > 0 ? '已把 $n 台设备归入「$r」' : '所选设备已在此分组里'));
  }

  /// 批量远程运行程序（2026-11-10）：同一条运行指令并行下发到所有勾选设备。
  Future<void> _batchRemoteRun() async {
    final ids = _sel
        .map((s) => s.replaceAll(' ', ''))
        .where((s) => s.isNotEmpty)
        .toList();
    if (ids.isEmpty) return;
    final ctrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量远程运行程序', style: TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '将向已选 ${ids.length} 台设备下发同一条运行指令，'
                '对方客户端联网校验后自动执行，不需要对方确认。',
                style: const TextStyle(fontSize: 12.5, color: _AC.sub),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: r'对方机器上的完整路径，如 C:\apps\tool.exe --silent',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _AC.blue),
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text('全部下发（${ids.length} 台）'),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    var ok = 0;
    var fail = 0;
    final results = await Future.wait(ids.map((id) async {
      try {
        final r =
            await LicenseClient.instance.issueCommand(id, 'run', payload: path);
        return r['ok'] == true;
      } catch (_) {
        return false;
      }
    }));
    for (final r in results) {
      r ? ok++ : fail++;
    }
    if (!mounted) return;
    if (fail == 0) {
      showToast('已向 $ok 台设备下发运行指令，对方联网后自动执行');
    } else if (ok == 0) {
      showToast('下发失败：所选设备需与本机在同一授权卡下（远程运行限制）');
    } else {
      showToast('已下发 $ok 台，失败 $fail 台（未激活或不在同一授权下）');
    }
  }

  Future<void> _addOneToWall(String id) async {    final n = await addPeersToScreenWall([id]);
    if (!mounted) return;
    if (n < 0) {
      showToast('添加失败，请重试');
      return;
    }
    showToast(n == 0 ? '该设备已在屏幕墙里' : '已加入屏幕墙');
  }

  /// 顶部小图标按钮（列表/网格、正倒序）
  Widget _barIcon(IconData icon, String tip, VoidCallback onTap,
      {bool active = false}) {
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: SizedBox(
          width: 30,
          height: 28,
          child: Icon(icon, size: 17, color: active ? _AC.blue : _AC.sub),
        ),
      ),
    );
  }

  Widget _gridView(List<AbEntry> list) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 268,
        mainAxisExtent: 80,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) => _card(list[i]),
    );
  }

  /// 网格卡片：一行标题（状态点 + 名称 + 标签 + 更多），一行头像 + 识别码/备注
  Widget _card(AbEntry e) {
    final status = _statusOf(e.id);
    final checked = _sel.contains(e.id);
    final seed = e.display.isEmpty ? e.id : e.display;
    final letter = seed.isEmpty ? '?' : seed.substring(0, 1);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: _AC.hover,
        onTap: () {
          if (_batch) {
            setState(() => checked ? _sel.remove(e.id) : _sel.add(e.id));
          } else {
            widget.onConnect(e.id);
          }
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: checked ? _AC.blue : const Color(0xFFEDEFF2)),
          ),
          padding: const EdgeInsets.fromLTRB(9, 5, 2, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (_batch)
                    SizedBox(
                      width: 24,
                      child: Checkbox(
                        value: checked,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) => setState(
                            () => v == true ? _sel.add(e.id) : _sel.remove(e.id)),
                      ),
                    )
                  else
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                          color: _dotColor(status), shape: BoxShape.circle),
                    ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      seed,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: _AC.text),
                    ),
                  ),
                  if (e.tag.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(right: 2),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: _AC.blue.withOpacity(0.07),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(e.tag,
                          style:
                              const TextStyle(fontSize: 10, color: _AC.blue)),
                    ),
                  _entryMenu(e),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: abAvatarColor(seed),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      letter.toUpperCase(),
                      style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // 重命名后隐藏识别码，防 ID 泄露；未命名仍显示便于辨认
                        if (e.alias.isEmpty)
                          Text(
                            formatAbId(e.id),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11.5, color: _AC.sub),
                          ),
                        if (e.note.isNotEmpty)
                          Text(
                            e.note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 10.5, color: Color(0xFF9AA3AF)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 卡片右上角的「更多」菜单（和列表行同一套动作）
  Widget _entryMenu(AbEntry e) {
    return SizedBox(
      width: 26,
      height: 24,
      child: PopupMenuButton<String>(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        icon: const Icon(Icons.more_horiz, size: 17, color: Color(0xFF9E9E9E)),
        onSelected: (v) {
          if (v == 'edit') {
            _edit(context, e);
          } else if (v == 'delete') {
            _confirmDelete(context, e);
          } else if (v == 'copy') {
            _copyId(e.id);
          } else if (v == 'wall') {
            _addOneToWall(e.id);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
              value: 'wall',
              height: 36,
              child: Text('添加到屏幕墙', style: TextStyle(fontSize: 13))),
          PopupMenuItem(
              value: 'edit',
              height: 36,
              child: Text('编辑', style: TextStyle(fontSize: 13))),
          PopupMenuItem(
              value: 'copy',
              height: 36,
              child: Text('复制识别码', style: TextStyle(fontSize: 13))),
          PopupMenuItem(
              value: 'delete',
              height: 36,
              child: Text('删除',
                  style: TextStyle(fontSize: 13, color: Color(0xFFE23B3B)))),
        ],
      ),
    );
  }

  Widget _list(List<AbEntry> list) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(
          height: 1, thickness: 1, color: Color(0xFFF4F5F7), indent: 72),
      itemBuilder: (context, i) => _row(list[i]),
    );
  }

  Widget _row(AbEntry e) {
    final status = _statusOf(e.id);
    final store = AddressBookStore.instance;
    final checked = _sel.contains(e.id);
    // 首字做头像文字：中文取第一个汉字，英文/数字取首字符
    final seed = e.display.isEmpty ? e.id : e.display;
    final letter = seed.isEmpty ? '?' : seed.substring(0, 1);
    final user = store.username.isEmpty ? '' : store.username;
    // 已命名设备不再显示识别码（防泄露）；未命名的照常显示
    final named = e.alias.trim().isNotEmpty;
    final second = named
        ? ''
        : (user.isEmpty ? formatAbId(e.id) : '$user@${formatAbId(e.id)}');
    return InkWell(
      onTap: () {
        if (_batch) {
          setState(() => checked ? _sel.remove(e.id) : _sel.add(e.id));
        } else {
          widget.onConnect(e.id);
        }
      },
      hoverColor: _AC.hover,
      child: Container(
        height: 54,
        padding: const EdgeInsets.only(left: 16, right: 6),
        child: Row(
          children: [
            if (_batch) ...[
              SizedBox(
                width: 30,
                child: Checkbox(
                  value: checked,
                  onChanged: (v) => setState(
                      () => v == true ? _sel.add(e.id) : _sel.remove(e.id)),
                ),
              ),
              const SizedBox(width: 4),
            ],
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: abAvatarColor(seed),
                borderRadius: BorderRadius.circular(7),
              ),
              alignment: Alignment.center,
              child: Text(
                letter.toUpperCase(),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _dotColor(status),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          seed,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w500,
                              color: _AC.text),
                        ),
                      ),
                      if (e.tag.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: _AC.blue.withOpacity(0.07),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(e.tag,
                              style: const TextStyle(
                                  fontSize: 10.5, color: _AC.blue)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Builder(builder: (_) {
                    final line = second.isEmpty
                        ? e.note
                        : (e.note.isEmpty ? second : '$second · ${e.note}');
                    if (line.isEmpty) return const SizedBox.shrink();
                    return Text(
                      line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: _AC.sub),
                    );
                  }),
                ],
              ),
            ),
            SizedBox(
              width: 32,
              height: 30,
              child: PopupMenuButton<String>(
                tooltip: '更多',
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.more_horiz,
                    size: 18, color: Color(0xFF9E9E9E)),
                onSelected: (v) {
                  if (v == 'edit') {
                    _edit(context, e);
                  } else if (v == 'delete') {
                    _confirmDelete(context, e);
                  } else if (v == 'copy') {
                    _copyId(e.id);
                  } else if (v == 'wall') {
                    _addOneToWall(e.id);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'wall', height: 36, child: Text('添加到屏幕墙', style: TextStyle(fontSize: 13))),
                  PopupMenuItem(value: 'edit', height: 36, child: Text('编辑', style: TextStyle(fontSize: 13))),
                  PopupMenuItem(value: 'copy', height: 36, child: Text('复制识别码', style: TextStyle(fontSize: 13))),
                  PopupMenuItem(value: 'delete', height: 36, child: Text('删除', style: TextStyle(fontSize: 13))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty(AddressBookStore store) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.contacts_outlined,
              size: 34, color: Color(0xFF9E9E9E)),
          const SizedBox(height: 10),
          const Text('地址簿还是空的',
              style: TextStyle(fontSize: 14, color: _AC.text)),
          const SizedBox(height: 4),
          Text(
            store.syncing ? '正在同步云端数据…' : '点右上角的「+」把常用设备存进来',
            style: const TextStyle(fontSize: 12, color: _AC.sub),
          ),
          if (!store.syncing) ...[
            const SizedBox(height: 14),
            SizedBox(
              height: 32,
              child: TextButton.icon(
                onPressed: () => _add(context),
                icon: const Icon(Icons.add, size: 15),
                label:
                    const Text('添加设备', style: TextStyle(fontSize: 12.5)),
                style: TextButton.styleFrom(
                  backgroundColor: _AC.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 地址簿里的设备不一定在「最近/收藏」里，查不到就说明本机没它的在线信息。
  /// 以前查不到统一当离线，于是整页都是灰点；现在区分成三态：
  ///   online / offline / unknown
  int _statusOf(String id) {
    final key = _norm(id);
    try {
      for (final p in gFFI.favoritePeersModel.peers) {
        if (_norm(p.id) == key) {
          return p.online ? _kStatusOnline : _kStatusOffline;
        }
      }
      for (final p in gFFI.recentPeersModel.peers) {
        if (_norm(p.id) == key) {
          return p.online ? _kStatusOnline : _kStatusOffline;
        }
      }
    } catch (_) {}
    return _kStatusUnknown;
  }

  static const _kStatusOnline = 0;
  static const _kStatusOffline = 1;
  static const _kStatusUnknown = 2;

  /// 绿 = 在线，黄 = 本机还没有它的在线信息，红 = 离线
  Color _dotColor(int status) {
    switch (status) {
      case _kStatusOnline:
        return const Color(0xFF3DBE5B);
      case _kStatusOffline:
        return const Color(0xFFE23B3B);
      default:
        return const Color(0xFFE8A317);
    }
  }

  /// 收藏里的 ID 可能带分隔空格（"982 471 635"），地址簿里存的是去掉空格的，
  /// 直接比较会永远判成离线。
  static String _norm(String s) => s.replaceAll(' ', '').trim();
}

// ---------------------------------------------------------------- 登录卡片

/// 未登录时显示的登录/注册卡片
class _LoginCard extends StatefulWidget {
  @override
  State<_LoginCard> createState() => _LoginCardState();
}

class _LoginCardState extends State<_LoginCard> {
  final _user = TextEditingController();
  final _pwd = TextEditingController();
  final _pwd2 = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String _error = '';
  bool _showPwd = false;

  @override
  void dispose() {
    _user.dispose();
    _pwd.dispose();
    _pwd2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final u = _user.text.trim();
    final p = _pwd.text;
    if (u.isEmpty || p.isEmpty) {
      setState(() => _error = '请填写账号和密码');
      return;
    }
    if (_register && p != _pwd2.text) {
      setState(() => _error = '两次输入的密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final store = AddressBookStore.instance;
      if (_register) {
        await store.register(u, p);
      } else {
        await store.login(u, p);
      }
      // 成功后 store 会 notifyListeners，界面自动切换
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _AC.line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              _register ? Icons.person_add_alt_1_outlined : Icons.person_outline,
              size: 34,
              color: _AC.blue,
            ),
            const SizedBox(height: 10),
            Text(
              _register ? '注册地址簿账号' : '登录地址簿',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: _AC.text),
            ),
            const SizedBox(height: 4),
            const Text(
              '登录后设备清单云端保存，换电脑登录也都在',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: _AC.sub),
            ),
            const SizedBox(height: 4),
            const Text(
              '服务：api.hydesk.cn（也可用浏览器打开管理）',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Color(0xFF9AA1AD)),
            ),
            const SizedBox(height: 18),
            _input(_user, '账号（字母 / 数字 / 中文）',
                icon: Icons.person_outline, first: true),
            const SizedBox(height: 10),
            _input(_pwd, '密码（至少 6 位）',
                icon: Icons.lock_outline,
                obscure: !_showPwd,
                suffix: IconButton(
                  splashRadius: 16,
                  icon: Icon(
                      _showPwd
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 17,
                      color: _AC.sub),
                  onPressed: () => setState(() => _showPwd = !_showPwd),
                )),
            if (_register) ...[
              const SizedBox(height: 10),
              _input(_pwd2, '确认密码',
                  icon: Icons.lock_outline, obscure: true),
            ],
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_error,
                  style:
                      const TextStyle(fontSize: 12.5, color: Color(0xFFE23B3B))),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 38,
              child: ElevatedButton(
                onPressed: _busy ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _AC.blue,
                  disabledBackgroundColor: const Color(0xFF9DC0EA),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(_register ? '注册并登录' : '登录',
                        style: const TextStyle(
                            fontSize: 14,
                            color: Colors.white,
                            fontWeight: FontWeight.w500)),
              ),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _register = !_register;
                        _error = '';
                      }),
              child: Text(
                _register ? '已有账号？返回登录' : '没有账号？注册一个',
                style: const TextStyle(fontSize: 12.5, color: _AC.blue),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _input(TextEditingController c, String hint,
      {IconData? icon, bool obscure = false, Widget? suffix, bool first = false}) {
    return SizedBox(
      height: 38,
      child: TextField(
        controller: c,
        obscureText: obscure,
        onSubmitted: (_) => _submit(),
        autofocus: first,
        style: const TextStyle(fontSize: 13.5, color: _AC.text),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 12.5, color: Color(0xFFB0B8C4)),
          prefixIcon: icon == null
              ? null
              : Icon(icon, size: 17, color: _AC.sub),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 36, minHeight: 36),
          suffixIcon: suffix,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 36, minHeight: 36),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          filled: true,
          fillColor: const Color(0xFFF8FAFD),
          isDense: true,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _AC.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _AC.blue, width: 1.3),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 动作

void _copyId(String id) {
  Clipboard.setData(ClipboardData(text: id));
  showToast('已复制 $id');
}

Future<void> _add(BuildContext context) async {
  final entry = await showAddressEntryDialog(context);
  if (entry == null) return;
  await AddressBookStore.instance.upsert(entry);
  showToast('已加入地址簿');
}

/// 批量添加地址簿（2026-11-10）：每行一台设备，「ID 名称」或纯 ID 都行
/// （名称可用空格 / 逗号 / 冒号与 ID 分隔，与批量添加收藏的写法一致）。
/// 可选填一个统一分组，导入的所有设备都会带上。已在地址簿里的：
/// 本次填了名称则更新名称（分组/备注只在原值为空时补），否则跳过。
/// 导入结果用 toast 汇总。
Future<void> showBatchAddressDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  final tagCtrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text('批量添加地址簿',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              maxLines: 8,
              autofocus: true,
              decoration: const InputDecoration(
                hintText:
                    '每行一台设备，名称可选，例如：\n123456789 前台电脑\n987654321 会议室\n555666777',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const SizedBox(
                  width: 60,
                  child: Text('统一分组',
                      style: TextStyle(fontSize: 13, color: _AC.text)),
                ),
                Expanded(
                  child: SizedBox(
                    height: 34,
                    child: TextField(
                      controller: tagCtrl,
                      style: const TextStyle(fontSize: 13, color: _AC.text),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '选填，导入的设备都归入该分组',
                        hintStyle: const TextStyle(
                            fontSize: 12.5, color: Color(0xFFB0B0B0)),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: const BorderSide(color: _AC.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: const BorderSide(color: _AC.line),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
                'ID 必填；名称可选（跟在 ID 后面）。已在地址簿的设备：本次填了名称则更新，否则跳过。',
                style: TextStyle(fontSize: 12, color: _AC.sub)),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消')),
        FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _AC.blue),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('导入')),
      ],
    ),
  );
  // 先把两个输入框的文本取出来再 dispose（dispose 后不应再访问）
  final text = ok == true ? ctrl.text : '';
  final tag = ok == true ? tagCtrl.text.trim() : '';
  ctrl.dispose();
  tagCtrl.dispose();
  if (ok != true) return;

  final store = AddressBookStore.instance;
  final list = <AbEntry>[];
  final seen = <String>{};
  for (var raw in text.split(RegExp(r'[\n;；]'))) {
    var line = raw.trim();
    if (line.isEmpty) continue;
    String alias = '';
    final m = RegExp(r'^([0-9A-Za-z]+)\s*[:：,，\s]\s*(.*)$').firstMatch(line);
    if (m != null) {
      line = m.group(1)!;
      alias = m.group(2)!.trim();
    }
    final id = line.replaceAll(' ', '');
    if (id.isEmpty) continue;
    if (!seen.add(id)) continue; // 输入内部去重
    list.add(AbEntry(id: id, alias: alias, tag: tag));
  }
  if (list.isEmpty) {
    showToast('没有识别到有效的设备 ID');
    return;
  }
  final r = await store.batchUpsert(list);
  if (!context.mounted) return;
  final parts = <String>[];
  if (r[0] > 0) parts.add('新增 ${r[0]} 台');
  if (r[1] > 0) parts.add('更新 ${r[1]} 台');
  final skipped = list.length - r[0] - r[1];
  if (skipped > 0) parts.add('跳过 $skipped 台（已在地址簿）');
  showToast(parts.isEmpty ? '没有变化' : parts.join('，'));
}

Future<void> _edit(BuildContext context, AbEntry e) async {
  final entry = await showAddressEntryDialog(context, entry: e);
  if (entry == null) return;
  await AddressBookStore.instance.upsert(entry, oldId: e.id);
}

Future<void> _confirmDelete(BuildContext context, AbEntry e) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除设备', style: TextStyle(fontSize: 16)),
      content: Text('确定从地址簿删除「${e.display}」吗？删除会同步到所有登录这台账号的设备。',
          style: const TextStyle(fontSize: 13.5)),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFE23B3B)))),
      ],
    ),
  );
  if (ok != true) return;
  await AddressBookStore.instance.remove(e.id);
}

/// 新增/编辑对话框，返回 null 表示取消
Future<AbEntry?> showAddressEntryDialog(BuildContext context,
    {AbEntry? entry}) {
  return showDialog<AbEntry>(
    context: context,
    builder: (_) => _EntryDialog(entry: entry),
  );
}

class _EntryDialog extends StatefulWidget {
  final AbEntry? entry;
  const _EntryDialog({this.entry});

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  late final TextEditingController _id;
  late final TextEditingController _alias;
  late final TextEditingController _tag;
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _id = TextEditingController(text: e?.id ?? '');
    _alias = TextEditingController(text: e?.alias ?? '');
    _tag = TextEditingController(text: e?.tag ?? '');
    _note = TextEditingController(text: e?.note ?? '');
  }

  @override
  void dispose() {
    _id.dispose();
    _alias.dispose();
    _tag.dispose();
    _note.dispose();
    super.dispose();
  }

  /// 收藏 / 最近里出现过的设备，点一下自动填 ID 与名称
  List<Peer> _suggestions() {
    final seen = <String>{};
    final out = <Peer>[];
    try {
      for (final p in [
        ...gFFI.favoritePeersModel.peers,
        ...gFFI.recentPeersModel.peers,
      ]) {
        if (p.id.isEmpty || !seen.add(p.id)) continue;
        out.add(p);
        if (out.length >= 12) break;
      }
    } catch (_) {}
    return out;
  }

  void _submit() {
    final id = _id.text.replaceAll(' ', '').trim();
    if (id.isEmpty) {
      showToast('请填写识别码');
      return;
    }
    if (AddressBookStore.instance.exists(id, exceptId: widget.entry?.id)) {
      showToast('识别码已在地址簿里');
      return;
    }
    Navigator.of(context).pop(AbEntry(
      id: id,
      alias: _alias.text.trim(),
      tag: _tag.text.trim(),
      note: _note.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = _suggestions();
    final tags = AddressBookStore.instance.tags;
    return AlertDialog(
      title: Text(widget.entry == null ? '添加设备' : '编辑设备',
          style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (suggestions.isNotEmpty && widget.entry == null) ...[
              const Text('从收藏 / 最近选择',
                  style: TextStyle(fontSize: 12, color: _AC.sub)),
              const SizedBox(height: 6),
              SizedBox(
                height: 30,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in suggestions)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(
                          label: Text(p.alias.isEmpty ? p.id : p.alias,
                              style: const TextStyle(fontSize: 11.5)),
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            setState(() {
                              _id.text = p.id;
                              if (_alias.text.trim().isEmpty) {
                                _alias.text = p.alias;
                              }
                            });
                          },
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            _field('识别码', _id, hint: '远程设备的 ID'),
            const SizedBox(height: 10),
            _field('名称', _alias, hint: '不填就显示识别码'),
            const SizedBox(height: 10),
            _field('分组', _tag, hint: '例如：公司 / 客户 / 家里'),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final t in tags)
                    InkWell(
                      onTap: () => setState(() => _tag.text = t),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          border: Border.all(color: _AC.line),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(t,
                            style: const TextStyle(
                                fontSize: 11, color: _AC.sub)),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            _field('备注', _note, hint: '选填'),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        TextButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }

  Widget _field(String label, TextEditingController c, {String? hint}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 56,
          child: Text(label,
              style: const TextStyle(fontSize: 13, color: _AC.text)),
        ),
        Expanded(
          child: SizedBox(
            height: 34,
            child: TextField(
              controller: c,
              style: const TextStyle(fontSize: 13, color: _AC.text),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                hintStyle:
                    const TextStyle(fontSize: 12.5, color: Color(0xFFB0B0B0)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: const BorderSide(color: _AC.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: const BorderSide(color: _AC.line),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
        ),
      ],
    );
  }
}
