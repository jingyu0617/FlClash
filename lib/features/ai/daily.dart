import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/features/ai/assistant.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' show join;

Future<Directory> _aiDir(String name) async {
  final dir = Directory(join(await appPath.homeDirPath, 'ai', name));
  await dir.create(recursive: true);
  return dir;
}

Future<Map<String, Object?>> _readJson(File file) async {
  try {
    if (!await file.exists()) {
      return {};
    }
    final data = jsonDecode(await file.readAsString());
    return data is Map<String, Object?> ? data : {};
  } catch (_) {
    return {};
  }
}

String _dayOf(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)}';
}

class AiHostLog {
  final String host;
  String ip;
  String port;
  String process;
  String rule;
  String outbound;
  String group;
  String geo;
  int count;
  int noReply;
  int upload;
  int download;
  DateTime last;

  AiHostLog({
    required this.host,
    this.ip = '',
    this.port = '',
    this.process = '',
    this.rule = '',
    this.outbound = '',
    this.group = '',
    this.geo = '',
    this.count = 0,
    this.noReply = 0,
    this.upload = 0,
    this.download = 0,
    DateTime? last,
  }) : last = last ?? DateTime.now();

  bool get isFallback => rule.toUpperCase().startsWith('MATCH');

  bool get isDirect => outbound == 'DIRECT';

  void merge(AiHostLog other) {
    count += other.count;
    noReply += other.noReply;
    upload += other.upload;
    download += other.download;
    if (other.last.isAfter(last)) {
      ip = other.ip;
      port = other.port;
      process = other.process.isEmpty ? process : other.process;
      rule = other.rule;
      outbound = other.outbound;
      group = other.group;
      geo = other.geo.isEmpty ? geo : other.geo;
      last = other.last;
    }
  }

  factory AiHostLog.fromJson(Map<String, Object?> json) => AiHostLog(
    host: json['h'] as String? ?? '',
    ip: json['i'] as String? ?? '',
    port: json['p'] as String? ?? '',
    process: json['pr'] as String? ?? '',
    rule: json['r'] as String? ?? '',
    outbound: json['o'] as String? ?? '',
    group: json['g'] as String? ?? '',
    geo: json['geo'] as String? ?? '',
    count: (json['c'] as num?)?.toInt() ?? 0,
    noReply: (json['n'] as num?)?.toInt() ?? 0,
    upload: (json['u'] as num?)?.toInt() ?? 0,
    download: (json['d'] as num?)?.toInt() ?? 0,
    last: DateTime.tryParse(json['l'] as String? ?? ''),
  );

  Map<String, Object?> toJson() => {
    'h': host,
    'i': ip,
    'p': port,
    if (process.isNotEmpty) 'pr': process,
    'r': rule,
    'o': outbound,
    'g': group,
    if (geo.isNotEmpty) 'geo': geo,
    'c': count,
    if (noReply > 0) 'n': noReply,
    'u': upload,
    'd': download,
    'l': last.toIso8601String(),
  };
}

class _LiveConnection {
  final String key;
  final DateTime start;
  int upload = 0;
  int download = 0;
  bool settled = false;

  _LiveConnection(this.key, this.start);
}

/// One file a day of every host the core connected to, merged per host.
class AiTrafficLog with CoreEventListener {
  AiTrafficLog._();

  static final instance = AiTrafficLog._();

  static const keepDays = 30;
  static const _maxHosts = 30000;
  static const _maxLive = 20000;
  static const _noReplyAfter = Duration(minutes: 2);
  static const _forgetAfter = Duration(minutes: 30);

  String _day = _dayOf(DateTime.now());
  Map<String, AiHostLog> _hosts = {};
  final Map<String, _LiveConnection> _live = {};
  Timer? _timer;
  bool _dirty = false;
  bool _started = false;

  int get todayHosts => _hosts.length;

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    coreEventManager.addListener(this);
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => flush());
    unawaited(_loadDay(_day));
  }

  void stop() {
    if (!_started) {
      return;
    }
    _started = false;
    coreEventManager.removeListener(this);
    _timer?.cancel();
    unawaited(flush());
  }

  Future<File> _fileOf(String day) async {
    return File(join((await _aiDir('logs')).path, '$day.json'));
  }

  Future<Map<String, AiHostLog>> readDay(String day) async {
    final data = await _readJson(await _fileOf(day));
    final list = data['hosts'];
    if (list is! List) {
      return {};
    }
    return {
      for (final item in list.whereType<Map>())
        if (AiHostLog.fromJson(Map<String, Object?>.from(item)) case final log
            when log.host.isNotEmpty)
          log.host: log,
    };
  }

  Future<void> _loadDay(String day) async {
    final saved = await readDay(day);
    if (day != _day) {
      return;
    }
    for (final entry in saved.entries) {
      final current = _hosts[entry.key];
      if (current == null) {
        _hosts[entry.key] = entry.value;
      } else {
        current.merge(entry.value);
      }
    }
  }

  void _rollDay() {
    final today = _dayOf(DateTime.now());
    if (today == _day) {
      return;
    }
    final previousDay = _day;
    final previous = _hosts;
    _day = today;
    _hosts = {};
    unawaited(_write(previousDay, previous));
    unawaited(_purge());
  }

  @override
  void onRequest(TrackerInfo connection) {
    final meta = connection.metadata;
    final key = meta.host.isNotEmpty ? meta.host : meta.destinationIP;
    if (isLocalAddress(key)) {
      return;
    }
    _rollDay();
    if (!_hosts.containsKey(key) && _hosts.length >= _maxHosts) {
      return;
    }
    final log = _hosts.putIfAbsent(key, () => AiHostLog(host: key));
    log
      ..count += 1
      ..ip = meta.destinationIP
      ..port = meta.destinationPort
      ..process = meta.process.isEmpty ? log.process : meta.process
      ..rule = connection.rulePayload.isEmpty
          ? connection.rule
          : '${connection.rule},${connection.rulePayload}'
      ..outbound = connection.chains.isEmpty ? '' : connection.chains.first
      ..group = connection.chains.isEmpty ? '' : connection.chains.last
      ..geo = meta.destinationGeoIP.join('/')
      ..last = connection.start;
    if (_live.length >= _maxLive) {
      _live.remove(_live.keys.first);
    }
    _live[connection.id] = _LiveConnection(key, connection.start);
    _dirty = true;
  }

  @override
  void onRequestTraffic(Map<String, RequestTraffic> traffic) {
    traffic.forEach((id, value) {
      final live = _live[id];
      final log = live == null ? null : _hosts[live.key];
      if (live == null || log == null) {
        return;
      }
      log
        ..upload += max(0, value.upload - live.upload)
        ..download += max(0, value.download - live.download);
      live
        ..upload = value.upload
        ..download = value.download;
    });
  }

  void _settle() {
    final now = DateTime.now();
    final forgotten = <String>[];
    _live.forEach((id, live) {
      final age = now.difference(live.start);
      if (!live.settled && age > _noReplyAfter) {
        live.settled = true;
        if (live.download == 0) {
          _hosts[live.key]?.noReply += 1;
          _dirty = true;
        }
      }
      if (age > _forgetAfter) {
        forgotten.add(id);
      }
    });
    forgotten.forEach(_live.remove);
  }

  Future<void> flush() async {
    _rollDay();
    _settle();
    if (!_dirty) {
      return;
    }
    _dirty = false;
    await _write(_day, _hosts);
  }

  Future<void> _write(String day, Map<String, AiHostLog> hosts) async {
    try {
      final file = await _fileOf(day);
      await file.writeAsString(
        jsonEncode({
          'hosts': [for (final log in hosts.values) log.toJson()],
        }),
      );
    } catch (error) {
      commonPrint.log('ai log write failed: $error');
    }
  }

  Future<void> _purge() async {
    try {
      final cutoff = _dayOf(
        DateTime.now().subtract(const Duration(days: keepDays)),
      );
      await for (final entity in (await _aiDir('logs')).list()) {
        final name = entity.uri.pathSegments.last.replaceAll('.json', '');
        if (entity is File && name.compareTo(cutoff) < 0) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }
}

const aiCategoryLabels = {
  'site': '你打开过的网站',
  'ads': '广告和统计（网页后台自动加载的）',
  'infra': '公共资源和服务（字体、加速、云服务）',
  'ip': '看不出来源的 IP 地址',
  'preset': '常识名单（固定处理，不问 AI）',
};

String aiCategoryLabel(String category) => aiCategoryLabels[category] ?? '其他';

String aiVerdictLabel(String verdict) => switch (verdict) {
  'DIRECT' => '直连',
  'PROXY' => '走代理',
  'BLOCK' => '屏蔽',
  _ => '保持原样',
};

class AiKnownSite {
  final String verdict;
  final String source;
  final String reason;
  final String category;
  final String about;
  final DateTime at;

  const AiKnownSite({
    required this.verdict,
    required this.source,
    required this.reason,
    this.category = '',
    this.about = '',
    required this.at,
  });

  bool get byUser => source == 'user';

  factory AiKnownSite.fromJson(Map<String, Object?> json) => AiKnownSite(
    verdict: json['v'] as String? ?? 'KEEP',
    source: json['s'] as String? ?? 'ai',
    reason: json['r'] as String? ?? '',
    category: json['c'] as String? ?? '',
    about: json['a'] as String? ?? '',
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
  );

  Map<String, Object?> toJson() => {
    'v': verdict,
    's': source,
    'r': reason,
    if (category.isNotEmpty) 'c': category,
    if (about.isNotEmpty) 'a': about,
    'at': at.toIso8601String(),
  };
}

class AiPendingRule {
  final AiProposedRule rule;
  final String site;
  final String category;
  final String about;
  final String current;
  final int? direct;
  final int? proxy;
  final DateTime at;

  const AiPendingRule({
    required this.rule,
    required this.site,
    this.category = '',
    this.about = '',
    this.current = '',
    this.direct,
    this.proxy,
    required this.at,
  });

  String get verdict => rule.target == 'DIRECT'
      ? 'DIRECT'
      : rule.target == 'REJECT'
      ? 'BLOCK'
      : 'PROXY';

  String get suggestion => aiVerdictLabel(verdict);

  factory AiPendingRule.fromJson(Map<String, Object?> json) => AiPendingRule(
    rule: AiProposedRule(
      type: json['type'] as String? ?? '',
      value: json['value'] as String? ?? '',
      target: json['target'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
    ),
    site: json['site'] as String? ?? '',
    category: json['category'] as String? ?? '',
    about: json['about'] as String? ?? '',
    current: json['current'] as String? ?? '',
    direct: (json['direct'] as num?)?.toInt(),
    proxy: (json['proxy'] as num?)?.toInt(),
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
  );

  Map<String, Object?> toJson() => {
    'type': rule.type,
    'value': rule.value,
    'target': rule.target,
    'reason': rule.reason,
    'site': site,
    'category': category,
    'about': about,
    'current': current,
    'direct': direct,
    'proxy': proxy,
    'at': at.toIso8601String(),
  };
}

class AiReport {
  final DateTime at;
  final int hosts;
  final int unknown;
  final int measured;
  final List<String> applied;
  final int replaced;
  final int pending;
  final String summary;
  final String? error;

  const AiReport({
    required this.at,
    this.hosts = 0,
    this.unknown = 0,
    this.measured = 0,
    this.applied = const [],
    this.replaced = 0,
    this.pending = 0,
    this.summary = '',
    this.error,
  });

  String get headline {
    if (error != null) {
      return '没有完成：$error';
    }
    if (unknown == 0 && applied.isEmpty) {
      return '没有新的未识别地址，一切正常。';
    }
    final blocked = applied.where((raw) => raw.endsWith(',REJECT')).length;
    final routed = applied.length - blocked;
    final swapped = replaced > 0 ? '（替换了 $replaced 条旧规则）' : '';
    return '检查了 $unknown 个地址：自动调整 $routed 个、屏蔽广告统计 $blocked 个$swapped，'
        '$pending 条等你确认。';
  }

  factory AiReport.fromJson(Map<String, Object?> json) => AiReport(
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
    hosts: (json['hosts'] as num?)?.toInt() ?? 0,
    unknown: (json['unknown'] as num?)?.toInt() ?? 0,
    measured: (json['measured'] as num?)?.toInt() ?? 0,
    applied: [
      for (final item in (json['applied'] as List?) ?? const [])
        if (item is String) item,
    ],
    replaced: (json['replaced'] as num?)?.toInt() ?? 0,
    pending: (json['pending'] as num?)?.toInt() ?? 0,
    summary: json['summary'] as String? ?? '',
    error: json['error'] as String?,
  );

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'hosts': hosts,
    'unknown': unknown,
    'measured': measured,
    'applied': applied,
    'replaced': replaced,
    'pending': pending,
    'summary': summary,
    'error': ?error,
  };
}

class _Site {
  final String key;
  final Map<String, int> hostCounts = {};
  final Set<String> processes = {};
  final Map<String, int> outbounds = {};
  String geo = '';
  String port = '';
  int count = 0;
  int noReply = 0;
  int download = 0;

  _Site(this.key);

  String get topHost =>
      (hostCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
          .first
          .key;

  String get current => outbound == 'DIRECT'
      ? 'DIRECT'
      : outbound.startsWith('REJECT')
      ? 'BLOCK'
      : 'PROXY';

  String get outbound =>
      (outbounds.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
          .first
          .key;

  void add(AiHostLog log) {
    final previous = hostCounts[log.host] ?? 0;
    if (previous == 0 || log.count > previous) {
      port = log.port;
    }
    hostCounts[log.host] = previous + log.count;
    if (log.process.isNotEmpty) {
      processes.add(log.process);
    }
    outbounds[log.outbound] = (outbounds[log.outbound] ?? 0) + log.count;
    geo = log.geo.isEmpty ? geo : log.geo;
    count += log.count;
    noReply += log.noReply;
    download += log.download;
  }
}

/// The daily review: what the log saw that no rule decided, tested both
/// ways and judged by the model in one call.
class AiDaily {
  AiDaily._();

  static final instance = AiDaily._();

  static const runHour = 23;
  static const runMinute = 30;
  static const _knownFor = Duration(days: 30);
  static const _retryAfter = Duration(hours: 1);
  static const _offlineRetry = Duration(minutes: 20);
  static const _maxSites = 120;
  static const _maxRematchSites = 300;
  static const _sitesPerCall = 60;
  static const _maxPending = 60;
  static const _maxReports = 14;
  static final _sensitive = RegExp(
    r'pay|bank|stripe|wallet|checkout|login|account|auth|passport|sso|'
    r'ads|adservice|doubleclick|admin|shopify|shopline|myshopline|'
    r'facebook|meta\.com|google',
  );
  static const _secondLevel = {
    'com.cn',
    'net.cn',
    'org.cn',
    'gov.cn',
    'edu.cn',
    'com.hk',
    'com.tw',
    'com.sg',
    'com.au',
    'co.uk',
    'co.jp',
    'co.kr',
    'com.my',
    'co.in',
  };

  final changes = ValueNotifier<int>(0);
  bool running = false;

  Future<File> _stateFile() async =>
      File(join((await _aiDir('state')).path, 'daily.json'));

  Future<File> _knownFile() async =>
      File(join((await _aiDir('state')).path, 'known.json'));

  Future<Map<String, Object?>> readState() async =>
      _readJson(await _stateFile());

  Future<void> _writeState(Map<String, Object?> state) async {
    await (await _stateFile()).writeAsString(jsonEncode(state));
    changes.value++;
  }

  Future<Map<String, AiKnownSite>> readKnown() async {
    final data = await _readJson(await _knownFile());
    return {
      for (final entry in data.entries)
        if (entry.value is Map)
          entry.key: AiKnownSite.fromJson(
            Map<String, Object?>.from(entry.value as Map),
          ),
    };
  }

  Future<void> _writeKnown(Map<String, AiKnownSite> known) async {
    await (await _knownFile()).writeAsString(
      jsonEncode({
        for (final entry in known.entries) entry.key: entry.value.toJson(),
      }),
    );
  }

  Future<bool> isEnabled() async => (await readState())['enabled'] != false;

  Future<void> setEnabled(bool enabled) async {
    final state = await readState();
    state['enabled'] = enabled;
    await _writeState(state);
  }

  Future<List<AiPendingRule>> readPending() async {
    final list = (await readState())['pending'];
    return [
      if (list is List)
        for (final item in list.whereType<Map>())
          AiPendingRule.fromJson(Map<String, Object?>.from(item)),
    ];
  }

  Future<List<AiReport>> readReports() async {
    final list = (await readState())['reports'];
    return [
      if (list is List)
        for (final item in list.whereType<Map>())
          AiReport.fromJson(Map<String, Object?>.from(item)),
    ];
  }

  /// The code's own check on the model: a rule goes in unasked only when the
  /// test made today says the same thing.
  static bool shouldAutoApply({
    required String verdict,
    String category = '',
    required bool high,
    required bool sensitive,
    required int? directMs,
    required int? proxyMs,
  }) {
    if (verdict == 'BLOCK') {
      return high && category == 'ads';
    }
    if (!high || sensitive) {
      return false;
    }
    final direct = directMs ?? -1;
    final proxy = proxyMs ?? -1;
    return switch (verdict) {
      'DIRECT' => direct > 0 && (proxy <= 0 || direct * 10 <= proxy * 7),
      'PROXY' => direct <= 0 && proxy > 0,
      _ => false,
    };
  }

  static String siteOf(String host) {
    if (InternetAddress.tryParse(host) != null) {
      return host;
    }
    final labels = host.toLowerCase().split('.');
    if (labels.length <= 2) {
      return labels.join('.');
    }
    final lastTwo = labels.sublist(labels.length - 2).join('.');
    final take = _secondLevel.contains(lastTwo) ? 3 : 2;
    return labels.sublist(labels.length - take).join('.');
  }

  static DateTime _lastSlot(DateTime now) {
    final today = DateTime(now.year, now.month, now.day, runHour, runMinute);
    return now.isBefore(today)
        ? today.subtract(const Duration(days: 1))
        : today;
  }

  /// Due once the latest 23:30 has passed since the last run; a Mac asleep at
  /// that time runs it on the first check after it wakes.
  Future<void> maybeRun(WidgetRef ref) async {
    if (running || !ref.read(isStartProvider)) {
      return;
    }
    final state = await readState();
    if (state['enabled'] == false) {
      return;
    }
    final now = DateTime.now();
    final lastRun = DateTime.tryParse(state['lastRun'] as String? ?? '');
    if (lastRun == null) {
      state['lastRun'] = now.toIso8601String();
      await _writeState(state);
      return;
    }
    final retryAt = DateTime.tryParse(state['retryAt'] as String? ?? '');
    if (retryAt != null && now.isBefore(retryAt)) {
      return;
    }
    if (!lastRun.isBefore(_lastSlot(now))) {
      return;
    }
    if (!(await AiStore.instance.loadSettings()).ready) {
      return;
    }
    await run(ref);
  }

  Future<AiReport?> run(
    WidgetRef ref, {
    bool manual = false,
    bool rematch = false,
  }) async {
    if (running) {
      return null;
    }
    running = true;
    changes.value++;
    try {
      return await _run(ref, manual: manual || rematch, rematch: rematch);
    } finally {
      running = false;
      changes.value++;
    }
  }

  static bool _isUserRecord(AiRuleRecord record) =>
      record.reason.startsWith('［你确认的］') || record.reason.startsWith('［你改的］');

  static String _observed(AiHostLog log) => log.outbound.startsWith('REJECT')
      ? 'BLOCK'
      : log.isDirect
      ? 'DIRECT'
      : 'PROXY';

  Future<AiReport?> _run(
    WidgetRef ref, {
    required bool manual,
    required bool rematch,
  }) async {
    final now = DateTime.now();
    final state = await readState();
    final settings = await AiStore.instance.loadSettings();
    if (!settings.ready) {
      throw const AiException('还没有填 OpenAI API Key。');
    }
    final lastRun =
        DateTime.tryParse(state['lastRun'] as String? ?? '') ??
        now.subtract(const Duration(days: 1));
    final oldest = now.subtract(
      Duration(days: rematch ? AiTrafficLog.keepDays : 3),
    );
    final from = rematch || lastRun.isBefore(oldest) ? oldest : lastRun;
    await AiTrafficLog.instance.flush();
    final hosts = <String, AiHostLog>{};
    for (
      var day = DateTime(from.year, from.month, from.day);
      !day.isAfter(now);
      day = day.add(const Duration(days: 1))
    ) {
      final logs = await AiTrafficLog.instance.readDay(_dayOf(day));
      for (final log in logs.values) {
        if (manual || log.last.isAfter(from)) {
          final current = hosts[log.host];
          if (current == null) {
            hosts[log.host] = log;
          } else {
            current.merge(log);
          }
        }
      }
    }

    final votes = <String, int>{};
    for (final log in hosts.values) {
      if (!log.isDirect && log.group.isNotEmpty && log.group != 'REJECT') {
        votes[log.group] = (votes[log.group] ?? 0) + log.count;
      }
    }
    final proxyGroup = pickProxyGroup(votes, [
      for (final group in ref.read(groupsProvider)) group.name,
    ]);

    final known = await readKnown();
    bool isKnown(String site) {
      final item = known[site];
      if (item == null) {
        return false;
      }
      if (item.byUser) {
        return true;
      }
      return !rematch && now.difference(item.at) < _knownFor;
    }

    final records = await AiStore.instance.loadRecords();
    final aiRecords = <String, List<AiRuleRecord>>{};
    final userValues = <String>{};
    for (final record in records) {
      final value = ruleValueOf(record.raw).replaceAll('/32', '');
      if (_isUserRecord(record)) {
        userValues.add(value);
      } else {
        aiRecords.putIfAbsent(value, () => []).add(record);
      }
    }

    final presets = <String, AiPreset>{};
    void checkPreset(String host, String observed) {
      final match = aiPresetOf(host);
      if (match == null ||
          observed == match.preset.verdict ||
          known[match.domain]?.byUser == true ||
          userValues.contains(match.domain)) {
        return;
      }
      presets[match.domain] = match.preset;
    }

    for (final MapEntry(key: value, value: list) in aiRecords.entries) {
      for (final record in list) {
        final target = ruleTargetOf(record.raw);
        checkPreset(
          value,
          target == 'DIRECT'
              ? 'DIRECT'
              : target == 'REJECT'
              ? 'BLOCK'
              : 'PROXY',
        );
      }
    }

    final sites = <String, _Site>{};
    for (final log in hosts.values) {
      final site = siteOf(log.host);
      if (isLocalAddress(site)) {
        continue;
      }
      if (aiPresetOf(log.host) != null) {
        checkPreset(log.host, _observed(log));
        continue;
      }
      final comma = log.rule.indexOf(',');
      final payload = comma < 0
          ? ''
          : log.rule.substring(comma + 1).toLowerCase().replaceAll('/32', '');
      final ruledByAi = rematch && aiRecords.containsKey(payload);
      final directFailing =
          log.isDirect && log.count >= 3 && log.noReply * 2 >= log.count;
      if (!log.isFallback && !directFailing && !ruledByAi) {
        continue;
      }
      if (isKnown(site) || userValues.contains(site)) {
        continue;
      }
      sites.putIfAbsent(site, () => _Site(site)).add(log);
    }
    final ranked = sites.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    final chosen = ranked.take(rematch ? _maxRematchSites : _maxSites).toList();

    final existing = {
      for (final rule in ref.read(globalRulesProvider).value ?? <Rule>[])
        rule.rawValue.toUpperCase(),
    };
    final toApply = <AiProposedRule>[];
    final replaceValues = <String>{};
    void place(AiProposedRule rule, String value) {
      final raw = rule.raw.toUpperCase();
      final conflicting = (aiRecords[value] ?? const <AiRuleRecord>[]).any(
        (record) => record.raw.toUpperCase() != raw,
      );
      if (conflicting) {
        replaceValues.add(value);
      } else if (existing.contains(raw)) {
        return;
      }
      existing.add(raw);
      toApply.add(rule);
    }

    for (final MapEntry(key: domain, value: preset) in presets.entries) {
      place(
        AiProposedRule(
          type: 'DOMAIN-SUFFIX',
          value: domain,
          target: preset.verdict == 'DIRECT' ? 'DIRECT' : proxyGroup,
          reason: '常识名单：${preset.label}',
        ),
        domain,
      );
      known[domain] = AiKnownSite(
        verdict: preset.verdict,
        source: 'preset',
        reason: '常识名单：${preset.label}',
        category: 'preset',
        about: preset.label,
        at: now,
      );
    }

    final measurements = <String, AiMeasurement>{};
    final summaries = <String>[];
    final pending = rematch ? <AiPendingRule>[] : await readPending();
    final pendingRaw = {
      for (final item in pending) item.rule.raw.toUpperCase(),
    };
    if (chosen.isEmpty) {
      return _complete(
        ref,
        state,
        known: known,
        proxyGroup: proxyGroup,
        toApply: toApply,
        replaceValues: replaceValues,
        pending: pending,
        rematch: rematch,
        report: AiReport(at: now, hosts: hosts.length),
      );
    }

    final probe = await aiMeasure(
      label: 'probe',
      url: 'https://www.gstatic.com/generate_204',
      proxyGroup: proxyGroup,
    );
    final proxyUp = (probe.proxy ?? -1) > 0;
    final directUp =
        (probe.direct ?? -1) > 0 ||
        ((await aiMeasure(
                  label: 'probe',
                  url: 'http://www.baidu.com/',
                  proxyGroup: 'DIRECT',
                )).direct ??
                -1) >
            0;
    if (!directUp && !manual) {
      state['retryAt'] = now.add(_offlineRetry).toIso8601String();
      await _writeState(state);
      return null;
    }

    for (var index = 0; index < chosen.length; index += 15) {
      final batch = chosen.skip(index).take(15);
      final results = await Future.wait([
        for (final site in batch)
          aiMeasure(
            label: site.key,
            url: aiTestUrl(site.topHost, site.port),
            proxyGroup: proxyGroup,
          ),
      ]);
      for (final item in results) {
        measurements[item.host] = item;
      }
    }

    for (var index = 0; index < chosen.length; index += _sitesPerCall) {
      final batch = chosen.skip(index).take(_sitesPerCall).toList();
      final answer = AiClient.parseJson(
        await AiClient.ask(
          settings,
          system: _systemPrompt(proxyGroup, proxyUp: proxyUp),
          user: jsonEncode({
            'sites': [
              for (final site in batch)
                {
                  'site': site.key,
                  'hosts': (site.hostCounts.keys.take(3)).toList(),
                  if (site.processes.isNotEmpty)
                    'apps': site.processes.take(3).toList(),
                  'outbound': site.outbound,
                  if (site.geo.isNotEmpty) 'ipCountry': site.geo,
                  'connections': site.count,
                  'noReply': site.noReply,
                  'downKB': site.download ~/ 1024,
                  'directMs': measurements[site.key]?.direct,
                  'proxyMs': measurements[site.key]?.proxy,
                },
            ],
          }),
        ),
      );
      final summary = (answer['summary'] as String? ?? '').trim();
      if (summary.isNotEmpty) {
        summaries.add(summary);
      }
      final decisions = answer['decisions'];
      if (decisions is! List) {
        continue;
      }
      final bySite = {for (final site in batch) site.key: site};
      for (final item in decisions.whereType<Map>()) {
        final siteKey = (item['site'] as String? ?? '').trim().toLowerCase();
        final site = bySite[siteKey];
        if (site == null) {
          continue;
        }
        final verdict = (item['verdict'] as String? ?? '').toUpperCase();
        final reason = (item['reason'] as String? ?? '').trim();
        final category = (item['category'] as String? ?? '').trim();
        final about = (item['about'] as String? ?? '').trim();
        known[site.key] = AiKnownSite(
          verdict: verdict.isEmpty ? 'KEEP' : verdict,
          source: 'ai',
          reason: reason,
          category: category,
          about: about,
          at: now,
        );
        if (!{'DIRECT', 'PROXY', 'BLOCK'}.contains(verdict)) {
          continue;
        }
        final rule = validateAiRule(
          {
            'type': verdict == 'BLOCK' ? 'DOMAIN-SUFFIX' : item['type'],
            'value': item['value'] ?? site.key,
            'target': verdict,
            'reason': reason,
          },
          proxyGroup: proxyGroup,
          existing: existing,
          allowBlock: category == 'ads',
        );
        if (rule == null || pendingRaw.contains(rule.raw.toUpperCase())) {
          continue;
        }
        final measured = measurements[site.key];
        final auto = shouldAutoApply(
          verdict: verdict,
          category: category,
          high: (item['confidence'] as String? ?? '').toLowerCase() == 'high',
          sensitive: _sensitive.hasMatch(site.key),
          directMs: measured?.direct,
          proxyMs: measured?.proxy,
        );
        if (auto) {
          place(rule, rule.value);
        } else {
          pendingRaw.add(rule.raw.toUpperCase());
          pending.add(
            AiPendingRule(
              rule: rule,
              site: site.key,
              category: category,
              about: about,
              current: site.current,
              direct: measured?.direct,
              proxy: measured?.proxy,
              at: now,
            ),
          );
        }
      }
    }

    return _complete(
      ref,
      state,
      known: known,
      proxyGroup: proxyGroup,
      toApply: toApply,
      replaceValues: replaceValues,
      pending: pending,
      rematch: rematch,
      report: AiReport(
        at: now,
        hosts: hosts.length,
        unknown: chosen.length + presets.length,
        measured: measurements.length,
        summary: summaries.join('\n'),
      ),
    );
  }

  Future<AiReport> _complete(
    WidgetRef ref,
    Map<String, Object?> state, {
    required Map<String, AiKnownSite> known,
    required String proxyGroup,
    required List<AiProposedRule> toApply,
    required Set<String> replaceValues,
    required List<AiPendingRule> pending,
    required bool rematch,
    required AiReport report,
  }) async {
    await _writeKnown(known);
    state['proxyGroup'] = proxyGroup;
    final replaced = replaceValues.isEmpty
        ? 0
        : await _removeRulesFor(ref, replaceValues, keepUser: true);
    if (toApply.isNotEmpty) {
      await applyRules(ref, toApply, tag: rematch ? '重新判断' : '每日体检');
    }
    final kept = pending.length > _maxPending
        ? pending.sublist(pending.length - _maxPending)
        : pending;
    state['pending'] = [for (final item in kept) item.toJson()];
    return _finish(
      state,
      AiReport(
        at: report.at,
        hosts: report.hosts,
        unknown: report.unknown == 0 ? toApply.length : report.unknown,
        measured: report.measured,
        applied: [for (final rule in toApply) rule.raw],
        replaced: replaced,
        pending: kept.length,
        summary: report.summary,
      ),
    );
  }

  Future<AiReport> _finish(Map<String, Object?> state, AiReport report) async {
    final reports = await readReports();
    state
      ..['lastRun'] = report.at.toIso8601String()
      ..remove('retryAt')
      ..['reports'] = [
        report.toJson(),
        for (final item in reports.take(_maxReports - 1)) item.toJson(),
      ];
    await _writeState(state);
    await _notify(report.headline);
    return report;
  }

  /// Puts off the next try after a failed run, so a missing key or an empty
  /// balance doesn't notify every few minutes.
  Future<void> recordFailure(Object error) async {
    final state = await readState();
    state['retryAt'] = DateTime.now().add(_retryAfter).toIso8601String();
    final reports = await readReports();
    state['reports'] = [
      AiReport(at: DateTime.now(), error: error.toString()).toJson(),
      for (final item in reports.take(_maxReports - 1)) item.toJson(),
    ];
    await _writeState(state);
    await _notify('每日体检没有完成：$error');
  }

  Future<void> _notify(String message) async {
    if (!system.isMacOS) {
      return;
    }
    final text = message.replaceAll(RegExp(r'["\\]'), ' ');
    try {
      await Process.run('/usr/bin/osascript', [
        '-e',
        'display notification "$text" with title "FlClash AI 每日体检"',
      ]);
    } catch (_) {}
  }

  /// Adds rules the way the assistant does and keeps them in its undo list.
  static Future<void> applyRules(
    WidgetRef ref,
    List<AiProposedRule> selected, {
    required String tag,
  }) async {
    final rules = [for (final item in selected) Rule.parse(item.raw)];
    ref.read(globalRulesProvider.notifier).putAll(rules);
    final store = AiStore.instance;
    final now = DateTime.now();
    await store.saveRecords([
      for (final (index, item) in selected.indexed)
        AiRuleRecord(
          ruleId: rules[index].id,
          raw: item.raw,
          reason: '［$tag］${item.reason}',
          addedAt: now,
        ),
      ...await store.loadRecords(),
    ]);
    instance.changes.value++;
  }

  static String ruleValueOf(String raw) {
    final parts = raw.split(',');
    return parts.length > 1 ? parts[1].trim().toLowerCase() : '';
  }

  static String ruleTargetOf(String raw) {
    final parts = raw.split(',');
    return parts.length > 2 ? parts[2].trim() : '';
  }

  Future<String> proxyGroupFor(WidgetRef ref) async {
    final saved = (await readState())['proxyGroup'] as String?;
    if (saved != null && saved.isNotEmpty) {
      return saved;
    }
    return pickProxyGroup({}, [
      for (final group in ref.read(groupsProvider)) group.name,
    ]);
  }

  static AiProposedRule? _ruleFor(
    String site,
    String verdict,
    String proxyGroup,
    String reason,
  ) {
    final isIp = InternetAddress.tryParse(site) != null;
    return validateAiRule(
      {
        'type': isIp ? 'IP-CIDR' : 'DOMAIN-SUFFIX',
        'value': site,
        'target': verdict,
        'reason': reason,
      },
      proxyGroup: proxyGroup,
      existing: const {},
      allowBlock: true,
    );
  }

  /// Takes off the rules the assistant added for [sites]; with [keepUser],
  /// not the ones the user chose.
  Future<int> _removeRulesFor(
    WidgetRef ref,
    Set<String> sites, {
    bool keepUser = false,
  }) async {
    final store = AiStore.instance;
    final records = await store.loadRecords();
    final removed = {
      for (final record in records)
        if (sites.contains(ruleValueOf(record.raw).replaceAll('/32', '')) &&
            !(keepUser && _isUserRecord(record)))
          record.ruleId,
    };
    if (removed.isEmpty) {
      return 0;
    }
    ref.read(globalRulesProvider.notifier).delAll(removed);
    await store.saveRecords([
      for (final record in records)
        if (!removed.contains(record.ruleId)) record,
    ]);
    return removed.length;
  }

  /// Settles [items] the user picked: [action] is AI for each one's own
  /// suggestion, or DIRECT, PROXY, BLOCK or KEEP for all of them. Returns
  /// how many could not take it (blocking a site pages need).
  Future<int> decidePending(
    WidgetRef ref,
    List<AiPendingRule> items,
    String action,
  ) async {
    final known = await readKnown();
    final now = DateTime.now();
    final proxyGroup = await proxyGroupFor(ref);
    final toApply = <AiProposedRule>[];
    final done = <String>{};
    final sites = <String>{};
    var skipped = 0;
    for (final item in items) {
      final verdict = action == 'AI' ? item.verdict : action;
      AiProposedRule? rule;
      if (verdict != 'KEEP') {
        rule = action == 'AI'
            ? item.rule
            : _ruleFor(
                item.site,
                verdict,
                proxyGroup,
                '你选择${aiVerdictLabel(verdict)}',
              );
        if (rule == null) {
          skipped++;
          continue;
        }
        toApply.add(rule);
        sites.add(item.site);
      }
      done.add(item.rule.raw);
      known[item.site] = AiKnownSite(
        verdict: verdict,
        source: 'user',
        reason: action == 'AI'
            ? '你采纳了 AI 的建议'
            : '你选择${aiVerdictLabel(verdict)}',
        category: item.category,
        about: item.about,
        at: now,
      );
    }
    await _writeKnown(known);
    if (sites.isNotEmpty) {
      await _removeRulesFor(ref, sites);
    }
    if (toApply.isNotEmpty) {
      await applyRules(ref, toApply, tag: '你确认的');
    }
    final state = await readState();
    final pending = await readPending();
    state['pending'] = [
      for (final item in pending)
        if (!done.contains(item.rule.raw)) item.toJson(),
    ];
    await _writeState(state);
    return skipped;
  }

  /// [verdict] is DIRECT, PROXY, BLOCK, KEEP, or FORGET to have the next
  /// review judge the site again.
  Future<void> changeSite(WidgetRef ref, String site, String verdict) async {
    final known = await readKnown();
    final previous = known[site];
    await _removeRulesFor(ref, {site});
    if (verdict == 'FORGET') {
      known.remove(site);
    } else {
      if ({'DIRECT', 'PROXY', 'BLOCK'}.contains(verdict)) {
        final rule = _ruleFor(
          site,
          verdict,
          await proxyGroupFor(ref),
          '你手动改成${aiVerdictLabel(verdict)}',
        );
        if (rule == null) {
          throw AiException(
            '$site 不能${aiVerdictLabel(verdict)}（可能是网页或账号必需的地址）。',
          );
        }
        await applyRules(ref, [rule], tag: '你改的');
      }
      known[site] = AiKnownSite(
        verdict: verdict,
        source: 'user',
        reason: '你手动改成${aiVerdictLabel(verdict)}',
        category: previous?.category ?? '',
        about: previous?.about ?? '',
        at: DateTime.now(),
      );
    }
    await _writeKnown(known);
    changes.value++;
  }

  /// The sites the assistant blocked that connections hit since [since].
  Future<Map<String, int>> blockedHits(
    List<TrackerInfo> connections,
    DateTime since,
  ) async {
    final blocked = {
      for (final record in await AiStore.instance.loadRecords())
        if (ruleTargetOf(record.raw) == 'REJECT') ruleValueOf(record.raw),
    };
    final hits = <String, int>{};
    for (final info in connections) {
      final outbound = info.chains.isEmpty ? '' : info.chains.first;
      if (!outbound.startsWith('REJECT') || info.start.isBefore(since)) {
        continue;
      }
      final host = info.metadata.host.toLowerCase();
      for (final value in blocked) {
        if (host == value || host.endsWith('.$value')) {
          hits[value] = (hits[value] ?? 0) + 1;
        }
      }
    }
    return hits;
  }

  Future<({String summary, Set<String> picks})> askUnblock({
    required String keyword,
    required Map<String, int> hits,
  }) async {
    final settings = await AiStore.instance.loadSettings();
    final known = await readKnown();
    final answer = AiClient.parseJson(
      await AiClient.ask(
        settings,
        system: '''
The user blocked advertising and tracking domains in FlClash. A website now shows or works wrongly. You get the blocked domains that connections hit in the last minutes (with how many times, and what each one is) and the site the user names, if any.
Pick the blocked domains most likely to break that site: things the page needs to show, play, log in, pay or load fonts and scripts. Pure ad, ad tracking and analytics domains rarely break a page. If unsure, include the domain: it is better to unblock a few too many.
Reply with one JSON object only: {"summary": "1-2 句简体中文，说明你的判断", "unblock": ["domain", ...]}''',
        user: jsonEncode({
          'site': keyword.trim().isEmpty ? '（没有说是哪个网站）' : keyword.trim(),
          'blockedHits': [
            for (final entry in hits.entries)
              {
                'domain': entry.key,
                'hits': entry.value,
                if (known[entry.key]?.about case final about?
                    when about.isNotEmpty)
                  'about': about,
              },
          ],
        }),
      ),
    );
    final picks = {
      for (final item in (answer['unblock'] as List?) ?? const [])
        if (item is String && hits.containsKey(item.toLowerCase()))
          item.toLowerCase(),
    };
    return (summary: (answer['summary'] as String? ?? '').trim(), picks: picks);
  }

  Future<void> unblock(WidgetRef ref, Set<String> sites) async {
    await _removeRulesFor(ref, sites);
    final known = await readKnown();
    final now = DateTime.now();
    for (final site in sites) {
      known[site] = AiKnownSite(
        verdict: 'KEEP',
        source: 'user',
        reason: '屏蔽后网页不正常，你恢复了',
        category: known[site]?.category ?? 'ads',
        about: known[site]?.about ?? '',
        at: now,
      );
    }
    await _writeKnown(known);
    changes.value++;
  }

  String _systemPrompt(String proxyGroup, {required bool proxyUp}) =>
      '''
You are the daily routing reviewer built into FlClash (a mihomo / Clash Meta client) on a Mac in Guangdong, mainland China.
Each item is a site (registrable domain, or a bare IP) that no explicit rule decided recently: it either fell through to the final MATCH rule and went through the proxy group "$proxyGroup", or it went DIRECT and most of its connections got no reply.
For each site you get: sample hosts, the apps that used it, outbound (DIRECT or the proxy node it used), ipCountry, connection count, noReply (connections that got no data back), downKB, and one test made now: directMs and proxyMs (milliseconds; -1 timeout, -2 failed, null not tested).${proxyUp ? '' : '\nThe proxy failed a basic test right now, so proxyMs values may all be failures: do not conclude a site needs DIRECT just because the proxy failed.'}

Decide for every site:
- "DIRECT": DIRECT works and is clearly faster than the proxy, or it is a Chinese service (Chinese company, Chinese CDN, .cn, ipCountry CN). Servers in Hong Kong, Macau, Taiwan or nearby Asia that are not blocked in China usually belong here when the test agrees.
- "PROXY": it went DIRECT but DIRECT fails or times out while the proxy works, or it is a service blocked in China (Google, YouTube, Telegram, X, Facebook, Instagram, WhatsApp, Discord, Reddit and the like).
- "BLOCK": only for category "ads" (see below): the user chose to block advertising, ad tracking, analytics and telemetry beacons, and click-fraud scripts. Never BLOCK anything a page or an account needs to work: fonts, scripts and libraries, CDNs, images and video, captchas, logins, payments, shops, maps, chat.
- "KEEP": leave it as it is: already routed right, unclear, or too minor to need a rule.
category, one of: "site" (a website or service the user opened on purpose), "ads" (advertising, ad tracking, analytics, telemetry, click-fraud detection), "infra" (shared resources and services pages load in the background: fonts, CDNs, cloud and API endpoints), "ip" (a bare IP whose purpose is unclear).
about: one short plain Simplified Chinese sentence saying what the site is, for a non-technical reader (e.g. "谷歌的网页广告服务").
For "BLOCK", confidence "high" when you are sure it is purely ads or tracking.
For DIRECT and PROXY, confidence is "high" only when the test clearly supports the verdict. Use "low" for anything to do with payments, banking, logins or accounts, advertising platforms, shop admin panels, and whenever the test is missing or mixed: the user confirms those by hand.
Rule shape: DOMAIN-SUFFIX on the site itself for domains, IP-CIDR with /32 for bare IPs. Never send openai.com, chatgpt.com, oaistatic.com or oaiusercontent.com DIRECT.
The user only reads Simplified Chinese and is not technical: summary and reason in plain Simplified Chinese.

Reply with one JSON object only, with a decision for every site:
{"summary": "2-3 句简体中文，总结今天发现了什么", "decisions": [{"site": "example.com", "category": "site", "about": "一句简体中文：这是什么", "verdict": "DIRECT", "confidence": "high", "type": "DOMAIN-SUFFIX", "value": "example.com", "reason": "一句简体中文：为什么这样处理"}]}''';
}
