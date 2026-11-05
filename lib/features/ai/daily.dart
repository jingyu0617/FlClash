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

  static const _keepDays = 30;
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
        DateTime.now().subtract(const Duration(days: _keepDays)),
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

class AiKnownSite {
  final String verdict;
  final String source;
  final String reason;
  final DateTime at;

  const AiKnownSite({
    required this.verdict,
    required this.source,
    required this.reason,
    required this.at,
  });

  factory AiKnownSite.fromJson(Map<String, Object?> json) => AiKnownSite(
    verdict: json['v'] as String? ?? 'KEEP',
    source: json['s'] as String? ?? 'ai',
    reason: json['r'] as String? ?? '',
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
  );

  Map<String, Object?> toJson() => {
    'v': verdict,
    's': source,
    'r': reason,
    'at': at.toIso8601String(),
  };
}

class AiPendingRule {
  final AiProposedRule rule;
  final String site;
  final int? direct;
  final int? proxy;
  final DateTime at;

  const AiPendingRule({
    required this.rule,
    required this.site,
    this.direct,
    this.proxy,
    required this.at,
  });

  factory AiPendingRule.fromJson(Map<String, Object?> json) => AiPendingRule(
    rule: AiProposedRule(
      type: json['type'] as String? ?? '',
      value: json['value'] as String? ?? '',
      target: json['target'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
    ),
    site: json['site'] as String? ?? '',
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
  final int pending;
  final String summary;
  final String? error;

  const AiReport({
    required this.at,
    this.hosts = 0,
    this.unknown = 0,
    this.measured = 0,
    this.applied = const [],
    this.pending = 0,
    this.summary = '',
    this.error,
  });

  String get headline {
    if (error != null) {
      return '没有完成：$error';
    }
    if (unknown == 0) {
      return '没有新的未识别地址，一切正常。';
    }
    return '检查了 $unknown 个新地址，自动加了 ${applied.length} 条规则，'
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
    required bool high,
    required bool sensitive,
    required int? directMs,
    required int? proxyMs,
  }) {
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

  Future<AiReport?> run(WidgetRef ref, {bool manual = false}) async {
    if (running) {
      return null;
    }
    running = true;
    changes.value++;
    try {
      return await _run(ref, manual: manual);
    } finally {
      running = false;
      changes.value++;
    }
  }

  Future<AiReport?> _run(WidgetRef ref, {required bool manual}) async {
    final now = DateTime.now();
    final state = await readState();
    final settings = await AiStore.instance.loadSettings();
    if (!settings.ready) {
      throw const AiException('还没有填 OpenAI API Key。');
    }
    final lastRun =
        DateTime.tryParse(state['lastRun'] as String? ?? '') ??
        now.subtract(const Duration(days: 1));
    final from = lastRun.isBefore(now.subtract(const Duration(days: 3)))
        ? now.subtract(const Duration(days: 3))
        : lastRun;
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
      return item.source == 'user' || now.difference(item.at) < _knownFor;
    }

    final sites = <String, _Site>{};
    for (final log in hosts.values) {
      final directFailing =
          log.isDirect && log.count >= 3 && log.noReply * 2 >= log.count;
      if (!log.isFallback && !directFailing) {
        continue;
      }
      final site = siteOf(log.host);
      if (isLocalAddress(site) || isKnown(site)) {
        continue;
      }
      sites.putIfAbsent(site, () => _Site(site)).add(log);
    }
    final ranked = sites.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    final chosen = ranked.take(_maxSites).toList();

    if (chosen.isEmpty) {
      return _finish(state, AiReport(at: now, hosts: hosts.length));
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

    final measurements = <String, AiMeasurement>{};
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

    final existing = {
      for (final rule in ref.read(globalRulesProvider).value ?? <Rule>[])
        rule.rawValue.toUpperCase(),
    };
    final summaries = <String>[];
    final toApply = <AiProposedRule>[];
    final pending = await readPending();
    final pendingRaw = {
      for (final item in pending) item.rule.raw.toUpperCase(),
    };

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
        known[site.key] = AiKnownSite(
          verdict: verdict.isEmpty ? 'KEEP' : verdict,
          source: 'ai',
          reason: reason,
          at: now,
        );
        if (verdict != 'DIRECT' && verdict != 'PROXY') {
          continue;
        }
        final rule = validateAiRule(
          {
            'type': item['type'],
            'value': item['value'] ?? site.key,
            'target': verdict,
            'reason': reason,
          },
          proxyGroup: proxyGroup,
          existing: existing,
        );
        if (rule == null || pendingRaw.contains(rule.raw.toUpperCase())) {
          continue;
        }
        existing.add(rule.raw.toUpperCase());
        final measured = measurements[site.key];
        final auto = shouldAutoApply(
          verdict: verdict,
          high: (item['confidence'] as String? ?? '').toLowerCase() == 'high',
          sensitive: _sensitive.hasMatch(site.key),
          directMs: measured?.direct,
          proxyMs: measured?.proxy,
        );
        if (auto) {
          toApply.add(rule);
        } else {
          pendingRaw.add(rule.raw.toUpperCase());
          pending.add(
            AiPendingRule(
              rule: rule,
              site: site.key,
              direct: measured?.direct,
              proxy: measured?.proxy,
              at: now,
            ),
          );
        }
      }
    }

    await _writeKnown(known);
    if (toApply.isNotEmpty) {
      await applyRules(ref, toApply, tag: '每日体检');
    }
    final kept = pending.length > _maxPending
        ? pending.sublist(pending.length - _maxPending)
        : pending;
    state['pending'] = [for (final item in kept) item.toJson()];
    return _finish(
      state,
      AiReport(
        at: now,
        hosts: hosts.length,
        unknown: chosen.length,
        measured: measurements.length,
        applied: [for (final rule in toApply) rule.raw],
        pending: kept.length,
        summary: summaries.join('\n'),
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

  Future<void> resolvePending(
    WidgetRef ref, {
    required List<AiPendingRule> accepted,
    required List<AiPendingRule> declined,
  }) async {
    if (accepted.isNotEmpty) {
      await applyRules(ref, [
        for (final item in accepted) item.rule,
      ], tag: '你确认的');
    }
    if (declined.isNotEmpty) {
      final known = await readKnown();
      final now = DateTime.now();
      for (final item in declined) {
        known[item.site] = AiKnownSite(
          verdict: 'KEEP',
          source: 'user',
          reason: '你没有采纳：${item.rule.raw}',
          at: now,
        );
      }
      await _writeKnown(known);
    }
    final done = {
      for (final item in [...accepted, ...declined]) item.rule.raw,
    };
    final state = await readState();
    final pending = await readPending();
    state['pending'] = [
      for (final item in pending)
        if (!done.contains(item.rule.raw)) item.toJson(),
    ];
    await _writeState(state);
  }

  String _systemPrompt(String proxyGroup, {required bool proxyUp}) =>
      '''
You are the daily routing reviewer built into FlClash (a mihomo / Clash Meta client) on a Mac in Guangdong, mainland China.
Each item is a site (registrable domain, or a bare IP) that no explicit rule decided recently: it either fell through to the final MATCH rule and went through the proxy group "$proxyGroup", or it went DIRECT and most of its connections got no reply.
For each site you get: sample hosts, the apps that used it, outbound (DIRECT or the proxy node it used), ipCountry, connection count, noReply (connections that got no data back), downKB, and one test made now: directMs and proxyMs (milliseconds; -1 timeout, -2 failed, null not tested).${proxyUp ? '' : '\nThe proxy failed a basic test right now, so proxyMs values may all be failures: do not conclude a site needs DIRECT just because the proxy failed.'}

Decide for every site:
- "DIRECT": DIRECT works and is clearly faster than the proxy, or it is a Chinese service (Chinese company, Chinese CDN, .cn, ipCountry CN). Servers in Hong Kong, Macau, Taiwan or nearby Asia that are not blocked in China usually belong here when the test agrees.
- "PROXY": it went DIRECT but DIRECT fails or times out while the proxy works, or it is a service blocked in China (Google, YouTube, Telegram, X, Facebook, Instagram, WhatsApp, Discord, Reddit and the like).
- "KEEP": leave it as it is: already routed right, unclear, or too minor to need a rule.
confidence is "high" only when the test clearly supports the verdict. Use "low" for anything to do with payments, banking, logins or accounts, advertising platforms, shop admin panels, and whenever the test is missing or mixed: the user confirms those by hand.
Rule shape: DOMAIN-SUFFIX on the site itself for domains, IP-CIDR with /32 for bare IPs. Never send openai.com, chatgpt.com, oaistatic.com or oaiusercontent.com DIRECT.
The user only reads Simplified Chinese and is not technical: summary and reason in plain Simplified Chinese.

Reply with one JSON object only, with a decision for every site:
{"summary": "2-3 句简体中文，总结今天发现了什么", "decisions": [{"site": "example.com", "verdict": "DIRECT", "confidence": "high", "type": "DOMAIN-SUFFIX", "value": "example.com", "reason": "一句简体中文"}]}''';
}
