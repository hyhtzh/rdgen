// 地址簿：本地保存的设备清单（识别码 + 名称 + 分组 + 备注）。
//
// 为什么不用上游 AddressBook（flutter/lib/common/widgets/address_book.dart）：
// 那个页面要求 gFFI.userModel.isLogin，必须有 RustDesk API Server（Pro 或自建 api）
// 才能用；我们只部署了 hbbs/hbbr，接上去只会看到「登录」按钮。
// 所以这里做成本地版：数据存 local option（key = address-book-v1，JSON 数组），
// 不联网、不需要账号，点行直接发起连接。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_hbb/common.dart';
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

/// 地址簿数据源。单例 + ChangeNotifier，切 tab 不丢状态。
class AddressBookStore extends ChangeNotifier {
  AddressBookStore._();

  static final AddressBookStore instance = AddressBookStore._();

  static const _kKey = 'address-book-v1';

  final List<AbEntry> entries = [];
  bool loaded = false;

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

  Future<void> load({bool force = false}) async {
    if (loaded && !force) return;
    try {
      final raw = bind.mainGetLocalOption(key: _kKey);
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
      debugPrint('address book load failed: $e');
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> save() async {
    try {
      await bind.mainSetLocalOption(
        key: _kKey,
        value: jsonEncode(entries.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('address book save failed: $e');
    }
    notifyListeners();
  }

  /// [oldId] 用于改识别码时定位原条目
  Future<void> upsert(AbEntry entry, {String? oldId}) async {
    final key = oldId ?? entry.id;
    final i = entries.indexWhere((e) => e.id == key);
    if (i >= 0) {
      entries[i] = entry;
    } else {
      entries.add(entry);
    }
    await save();
  }

  Future<void> remove(String id) async {
    entries.removeWhere((e) => e.id == id);
    await save();
  }

  bool exists(String id, {String? exceptId}) =>
      entries.any((e) => e.id == id && e.id != exceptId);
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
  String _tag = '';

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
      if (_tag.isNotEmpty && e.tag != _tag) return false;
      if (q.isEmpty) return true;
      return e.id.toLowerCase().contains(q) ||
          e.alias.toLowerCase().contains(raw) ||
          e.tag.toLowerCase().contains(raw) ||
          e.note.toLowerCase().contains(raw);
    }).toList();
    list.sort((a, b) => a.display.compareTo(b.display));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AddressBookStore.instance,
      builder: (context, _) {
        final store = AddressBookStore.instance;
        final list = _visible();
        if (store.entries.isEmpty) return _empty();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _tagPane(store),
            Container(width: 1, color: _AC.line),
            Expanded(child: list.isEmpty ? _noMatch() : _list(list)),
          ],
        );
      },
    );
  }

  Widget _tagPane(AddressBookStore store) {
    final tags = store.tags;
    // 选中的分组被删空后回到「全部」
    if (_tag.isNotEmpty && !tags.contains(_tag)) _tag = '';
    return Container(
      width: 152,
      color: _AC.pane,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _tagRow('全部设备', '', store.entries.length),
          for (final t in tags) _tagRow(t, t, store.countOf(t)),
        ],
      ),
    );
  }

  Widget _tagRow(String label, String value, int count) {
    final active = _tag == value;
    return InkWell(
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
  }

  Widget _list(List<AbEntry> list) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(
          height: 1, thickness: 1, color: Color(0xFFF2F2F2), indent: 58),
      itemBuilder: (context, i) => _row(list[i]),
    );
  }

  Widget _row(AbEntry e) {
    final online = _onlineOf(e.id);
    return InkWell(
      onTap: () => widget.onConnect(e.id),
      hoverColor: _AC.hover,
      child: Container(
        height: 56,
        padding: const EdgeInsets.only(left: 16, right: 8),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: online
                    ? _AC.blue.withOpacity(0.1)
                    : const Color(0xFFF0F0F0),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.contacts_outlined,
                  size: 17, color: online ? _AC.blue : const Color(0xFF9E9E9E)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          e.display,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14,
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
                  Text(
                    e.note.isEmpty
                        ? formatAbId(e.id)
                        : '${formatAbId(e.id)} · ${e.note}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _AC.sub),
                  ),
                ],
              ),
            ),
            Text(
              online ? '在线' : '离线',
              style: TextStyle(
                fontSize: 12,
                color: online ? _AC.green : const Color(0xFFAAAAAA),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 30,
              child: TextButton(
                onPressed: () => widget.onConnect(e.id),
                style: TextButton.styleFrom(
                  backgroundColor: _AC.blue.withOpacity(0.08),
                  foregroundColor: _AC.blue,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5)),
                ),
                child: const Text('连接', style: TextStyle(fontSize: 12.5)),
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
                  }
                },
                itemBuilder: (_) => const [
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

  Widget _empty() {
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
          const Text('点右上角的「+」把常用设备存进来',
              style: TextStyle(fontSize: 12, color: _AC.sub)),
          const SizedBox(height: 14),
          SizedBox(
            height: 32,
            child: TextButton.icon(
              onPressed: () => _add(context),
              icon: const Icon(Icons.add, size: 15),
              label: const Text('添加设备', style: TextStyle(fontSize: 12.5)),
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
      ),
    );
  }

  Widget _noMatch() {
    return const Center(
      child: Text('没有匹配的设备',
          style: TextStyle(fontSize: 13, color: _AC.sub)),
    );
  }

  bool _onlineOf(String id) {
    final key = _norm(id);
    try {
      for (final p in gFFI.favoritePeersModel.peers) {
        if (_norm(p.id) == key) return p.online;
      }
      for (final p in gFFI.recentPeersModel.peers) {
        if (_norm(p.id) == key) return p.online;
      }
    } catch (_) {}
    return false;
  }

  /// 收藏里的 ID 可能带分隔空格（"982 471 635"），地址簿里存的是去掉空格的，
  /// 直接比较会永远判成离线。
  static String _norm(String s) => s.replaceAll(' ', '').trim();
}

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
      content: Text('确定从地址簿删除「${e.display}」吗？',
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
