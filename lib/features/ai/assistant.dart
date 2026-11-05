import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/models/models.dart';
import 'package:path/path.dart' show join;

enum AiProblem {
  blocked('打不开，应该走代理'),
  slow('太慢，国内地址可能绕了代理');

  final String description;

  const AiProblem(this.description);
}

class AiSettings {
  static const defaultBaseUrl = 'https://api.openai.com/v1';
  static const defaultModel = 'gpt-5.4-mini';
  static const fallbackModels = ['gpt-5-mini', 'gpt-4o-mini'];

  final String baseUrl;
  final String model;
  final String apiKey;

  const AiSettings({
    this.baseUrl = defaultBaseUrl,
    this.model = defaultModel,
    this.apiKey = '',
  });

  bool get ready => apiKey.isNotEmpty;

  String get maskedKey {
    if (apiKey.isEmpty) {
      return '未设置';
    }
    final tail = apiKey.length > 4 ? apiKey.substring(apiKey.length - 4) : '';
    return '已设置（••••$tail）';
  }
}

class AiRuleRecord {
  final int ruleId;
  final String raw;
  final String reason;
  final DateTime addedAt;

  const AiRuleRecord({
    required this.ruleId,
    required this.raw,
    required this.reason,
    required this.addedAt,
  });

  factory AiRuleRecord.fromJson(Map<String, Object?> json) {
    return AiRuleRecord(
      ruleId: (json['ruleId'] as num?)?.toInt() ?? -1,
      raw: json['raw'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      addedAt:
          DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  Map<String, Object?> toJson() => {
    'ruleId': ruleId,
    'raw': raw,
    'reason': reason,
    'addedAt': addedAt.toIso8601String(),
  };
}

class AiStore {
  AiStore._();

  static final instance = AiStore._();

  static const _keychainService = 'FlClash AI OpenAI Key';
  static const _keychainAccount = 'flclash-ai';
  static const _security = '/usr/bin/security';

  Future<File> _file() async {
    return File(join(await appPath.homeDirPath, 'ai_assistant.json'));
  }

  Future<Map<String, Object?>> _read() async {
    try {
      final file = await _file();
      if (!await file.exists()) {
        return {};
      }
      final data = jsonDecode(await file.readAsString());
      return data is Map<String, Object?> ? data : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _update(void Function(Map<String, Object?> data) change) async {
    final data = await _read();
    change(data);
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(data));
  }

  Future<String> _readKey(Map<String, Object?> data) async {
    if (system.isMacOS) {
      final result = await Process.run(_security, [
        'find-generic-password',
        '-s',
        _keychainService,
        '-a',
        _keychainAccount,
        '-w',
      ]);
      return result.exitCode == 0 ? (result.stdout as String).trim() : '';
    }
    return data['apiKey'] as String? ?? '';
  }

  Future<AiSettings> loadSettings() async {
    final data = await _read();
    final baseUrl = (data['baseUrl'] as String? ?? '').trim();
    final model = (data['model'] as String? ?? '').trim();
    return AiSettings(
      baseUrl: baseUrl.isEmpty ? AiSettings.defaultBaseUrl : baseUrl,
      model: model.isEmpty ? AiSettings.defaultModel : model,
      apiKey: await _readKey(data),
    );
  }

  Future<void> saveBaseUrl(String value) {
    return _update((data) => data['baseUrl'] = value.trim());
  }

  Future<void> saveModel(String value) {
    return _update((data) => data['model'] = value.trim());
  }

  Future<void> saveApiKey(String value) async {
    final key = value.trim();
    if (!system.isMacOS) {
      return _update((data) => data['apiKey'] = key);
    }
    if (key.isEmpty) {
      await Process.run(_security, [
        'delete-generic-password',
        '-s',
        _keychainService,
        '-a',
        _keychainAccount,
      ]);
      return;
    }
    final result = await Process.run(_security, [
      'add-generic-password',
      '-U',
      '-s',
      _keychainService,
      '-a',
      _keychainAccount,
      '-w',
      key,
    ]);
    if (result.exitCode != 0) {
      throw AiException('Key 没能存进钥匙串：${result.stderr}');
    }
  }

  Future<List<AiRuleRecord>> loadRecords() async {
    final data = await _read();
    final list = data['records'];
    if (list is! List) {
      return [];
    }
    return [
      for (final item in list.whereType<Map>())
        AiRuleRecord.fromJson(Map<String, Object?>.from(item)),
    ];
  }

  Future<void> saveRecords(List<AiRuleRecord> records) {
    return _update(
      (data) => data['records'] = [for (final item in records) item.toJson()],
    );
  }
}

class AiException implements Exception {
  final String message;

  const AiException(this.message);

  @override
  String toString() => message;
}

class AiEvidence {
  final String host;
  final String ip;
  final String port;
  final String process;
  final String rule;
  final String outbound;
  final String group;
  final List<String> geo;
  int upload;
  int download;
  int count;
  DateTime lastSeen;

  AiEvidence({
    required this.host,
    required this.ip,
    required this.port,
    required this.process,
    required this.rule,
    required this.outbound,
    required this.group,
    required this.geo,
    required this.upload,
    required this.download,
    required this.lastSeen,
  }) : count = 1;

  String get key => host.isNotEmpty ? host : ip;

  bool get isDirect => outbound == 'DIRECT';

  Map<String, Object?> toJson(DateTime now) => {
    'host': host,
    'ip': ip,
    'port': port,
    if (process.isNotEmpty) 'process': process,
    'matchedRule': rule,
    'outbound': outbound,
    if (geo.isNotEmpty) 'ipCountry': geo.join('/'),
    'upBytes': upload,
    'downBytes': download,
    'connections': count,
    'secondsAgo': now.difference(lastSeen).inSeconds,
  };
}

class AiMeasurement {
  final String host;
  final int? direct;
  final int? proxy;

  const AiMeasurement({required this.host, this.direct, this.proxy});

  static String label(int? value) => switch (value) {
    null => '未测',
    -1 => '超时',
    < 0 => '失败',
    _ => '${value}ms',
  };

  Map<String, Object?> toJson() => {
    'host': host,
    'directMs': direct,
    'proxyMs': proxy,
  };
}

class AiProposedRule {
  final String type;
  final String value;
  final String target;
  final String reason;

  const AiProposedRule({
    required this.type,
    required this.value,
    required this.target,
    required this.reason,
  });

  String get raw => type == 'IP-CIDR'
      ? '$type,$value,$target,no-resolve'
      : '$type,$value,$target';

  bool matches(TrackerInfo info) {
    final host = info.metadata.host.toLowerCase();
    final v = value.toLowerCase();
    return switch (type) {
      'DOMAIN' => host == v,
      'DOMAIN-SUFFIX' => host == v || host.endsWith('.$v'),
      'DOMAIN-KEYWORD' => host.contains(v),
      'PROCESS-NAME' => info.metadata.process.toLowerCase() == v,
      _ => false,
    };
  }
}

class AiProposal {
  final String summary;
  final List<AiProposedRule> rules;
  final List<AiMeasurement> measurements;
  final String proxyGroup;

  const AiProposal({
    required this.summary,
    required this.rules,
    required this.measurements,
    required this.proxyGroup,
  });
}

const aiAllowedRuleTypes = {
  'DOMAIN',
  'DOMAIN-SUFFIX',
  'DOMAIN-KEYWORD',
  'PROCESS-NAME',
  'IP-CIDR',
};

const _keepProxied = [
  'openai.com',
  'chatgpt.com',
  'oaistatic.com',
  'oaiusercontent.com',
];

bool isLocalAddress(String address) {
  if (address.isEmpty || address == 'localhost') {
    return true;
  }
  final ip = InternetAddress.tryParse(address);
  if (ip == null) {
    return false;
  }
  if (ip.isLoopback || ip.isLinkLocal) {
    return true;
  }
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 198 && (b[1] == 18 || b[1] == 19)) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
  }
  return (b[0] & 0xfe) == 0xfc;
}

// A bare IP has no certificate to match, so its TLS port is asked in plain
// HTTP: the error page a TLS server sends back still times the round trip.
String aiTestUrl(String address, String port) {
  final isIp = InternetAddress.tryParse(address) != null;
  return switch (port) {
    '80' => 'http://$address/',
    '' || '443' when isIp => 'http://$address:443/',
    '' || '443' => 'https://$address/',
    _ => '${isIp ? 'http' : 'https'}://$address:$port/',
  };
}

Future<int?> _delay(String proxyName, String url) async {
  try {
    final delay = await coreController.testDelay(
      TestDelayParams(proxyName: proxyName, testUrl: url, timeout: 5000),
    );
    return delay.value;
  } catch (_) {
    return null;
  }
}

Future<AiMeasurement> aiMeasure({
  required String label,
  required String url,
  required String proxyGroup,
}) async {
  final results = await Future.wait([
    _delay('DIRECT', url),
    _delay(proxyGroup, url),
  ]);
  return AiMeasurement(host: label, direct: results[0], proxy: results[1]);
}

/// The proxy group a rule's PROXY target means: the one most connections went
/// through, else the profile's first group other than GLOBAL.
String pickProxyGroup(Map<String, int> votes, List<String> groupNames) {
  final voted = votes.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (voted.isNotEmpty) {
    return voted.first.key;
  }
  return groupNames.firstWhere(
    (name) => name != 'GLOBAL',
    orElse: () => 'PROXY',
  );
}

AiProposedRule? validateAiRule(
  Map item, {
  required String proxyGroup,
  required Set<String> existing,
}) {
  final type = (item['type'] as String? ?? '').trim().toUpperCase();
  var value = (item['value'] as String? ?? '').trim();
  final target = switch ((item['target'] as String? ?? '')
      .trim()
      .toUpperCase()) {
    'DIRECT' => 'DIRECT',
    'PROXY' => proxyGroup,
    _ => null,
  };
  final reason = (item['reason'] as String? ?? '').trim();
  if (target == null || !aiAllowedRuleTypes.contains(type) || value.isEmpty) {
    return null;
  }
  if (value.contains(',') || value.contains('\n')) {
    return null;
  }
  if (type != 'PROCESS-NAME' && value.contains(' ')) {
    return null;
  }
  switch (type) {
    case 'DOMAIN' || 'DOMAIN-SUFFIX':
      value = value.toLowerCase().replaceFirst(RegExp(r'^\*?\.'), '');
      if (!value.contains('.') || isLocalAddress(value)) {
        return null;
      }
      if (target == 'DIRECT' &&
          _keepProxied.any((d) => value == d || value.endsWith('.$d'))) {
        return null;
      }
    case 'DOMAIN-KEYWORD':
      value = value.toLowerCase();
      if (value.length < 4 ||
          (target == 'DIRECT' && _keepProxied.any((d) => d.contains(value)))) {
        return null;
      }
    case 'IP-CIDR':
      if (!value.contains('/')) {
        value = '$value/32';
      }
      final parts = value.split('/');
      final prefix = int.tryParse(parts.last);
      final ip = InternetAddress.tryParse(parts.first);
      if (ip == null ||
          ip.type != InternetAddressType.IPv4 ||
          prefix == null ||
          prefix < 8 ||
          prefix > 32 ||
          isLocalAddress(parts.first)) {
        return null;
      }
  }
  final rule = AiProposedRule(
    type: type,
    value: value,
    target: target,
    reason: reason.isEmpty ? 'AI 建议' : reason,
  );
  if (existing.contains(rule.raw.toUpperCase())) {
    return null;
  }
  return rule;
}

class AiClient {
  AiClient._();

  static Future<String> _complete(
    AiSettings settings,
    String model,
    String system,
    String user,
  ) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 180),
        sendTimeout: const Duration(seconds: 30),
      ),
    );
    final base = settings.baseUrl.endsWith('/')
        ? settings.baseUrl.substring(0, settings.baseUrl.length - 1)
        : settings.baseUrl;
    final response = await dio.post<Map<String, dynamic>>(
      '$base/chat/completions',
      data: {
        'model': model,
        'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
      },
      options: Options(
        responseType: ResponseType.json,
        headers: {'Authorization': 'Bearer ${settings.apiKey}'},
      ),
    );
    final choices = response.data?['choices'];
    if (choices is List && choices.isNotEmpty) {
      final content = (choices.first as Map)['message']?['content'];
      if (content is String && content.trim().isNotEmpty) {
        return content;
      }
    }
    throw const AiException('AI 没有给出回答，请再试一次。');
  }

  static bool _isModelMissing(DioException error) {
    final status = error.response?.statusCode;
    final body = error.response?.data.toString() ?? '';
    return status == 404 || body.contains('model_not_found');
  }

  static AiException _explain(DioException error) {
    final status = error.response?.statusCode;
    return switch (status) {
      401 => const AiException('API Key 不对或已失效，请在 AI 分流助手的设置里重新填写。'),
      403 => const AiException('OpenAI 拒绝了请求（403），可能是地区限制。请确认代理在运行。'),
      429 => const AiException('OpenAI 额度不足或请求太频繁（429），请检查账户余额或稍后再试。'),
      final int code => AiException(
        'OpenAI 返回错误 $code：${error.response?.data}',
      ),
      null => const AiException('连不上 OpenAI。请确认 FlClash 正在运行、代理节点可用。'),
    };
  }

  static Future<String> ask(
    AiSettings settings, {
    required String system,
    required String user,
  }) async {
    final models = [
      settings.model,
      if (settings.model == AiSettings.defaultModel)
        ...AiSettings.fallbackModels,
    ];
    DioException? last;
    for (final model in models) {
      try {
        return await _complete(settings, model, system, user);
      } on DioException catch (error) {
        last = error;
        if (!_isModelMissing(error)) {
          throw _explain(error);
        }
      }
    }
    throw last == null
        ? const AiException('AI 没有给出回答，请再试一次。')
        : AiException('找不到模型「${settings.model}」，请在设置里换一个模型名。');
  }

  static Map<String, Object?> parseJson(String content) {
    var text = content.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      text = text.substring(start, end + 1);
    }
    try {
      final data = jsonDecode(text);
      if (data is Map<String, Object?>) {
        return data;
      }
    } catch (_) {}
    throw const AiException('AI 的回答格式不对，请再试一次。');
  }
}

class AiDiagnosis {
  static const _window = Duration(minutes: 5);
  static const _maxEvidence = 40;
  static const _maxMeasured = 12;
  static const _maxRules = 10;

  final AiProblem problem;
  final String keyword;
  final AiSettings settings;
  final List<String> groupNames;

  AiDiagnosis({
    required this.problem,
    required this.keyword,
    required this.settings,
    required this.groupNames,
  });

  late final List<AiEvidence> _evidence;
  late final String _proxyGroup;
  late final Uri? target = _targetOf(keyword);

  /// What the user typed, when it names a site: a URL, a domain or an IP.
  static Uri? _targetOf(String keyword) {
    final text = keyword.trim();
    if (text.isEmpty || text.contains(RegExp(r'\s'))) {
      return null;
    }
    final isIp = InternetAddress.tryParse(text) != null;
    final uri = Uri.tryParse(
      text.contains('://') ? text : '${isIp ? 'http' : 'https'}://$text',
    );
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        !uri.host.contains('.') ||
        isLocalAddress(uri.host)) {
      return null;
    }
    return uri.replace(path: uri.path.isEmpty ? '/' : uri.path);
  }

  bool _matchesKeyword(AiEvidence item) {
    final terms = {
      ...keyword
          .toLowerCase()
          .split(RegExp(r'[\s,，]+'))
          .where((term) => term.isNotEmpty),
      ?target?.host.toLowerCase(),
    };
    return terms.any(
      (term) =>
          item.host.toLowerCase().contains(term) ||
          item.ip == term ||
          item.process.toLowerCase().contains(term),
    );
  }

  int collect(List<TrackerInfo> recent, List<TrackerInfo> live) {
    final cutoff = DateTime.now().subtract(_window);
    final byKey = <String, AiEvidence>{};
    final groupVotes = <String, int>{};
    final candidates = [
      ...recent.where((info) => info.start.isAfter(cutoff)),
      ...live,
    ];
    for (final info in candidates) {
      final meta = info.metadata;
      final address = meta.host.isNotEmpty ? meta.host : meta.destinationIP;
      if (isLocalAddress(address)) {
        continue;
      }
      final outbound = info.chains.isEmpty ? '' : info.chains.first;
      final group = info.chains.isEmpty ? '' : info.chains.last;
      if (outbound != 'DIRECT' && group.isNotEmpty && group != 'REJECT') {
        groupVotes[group] = (groupVotes[group] ?? 0) + 1;
      }
      final existing = byKey[address];
      if (existing != null) {
        existing
          ..count += 1
          ..upload += info.upload
          ..download += info.download;
        if (info.start.isAfter(existing.lastSeen)) {
          existing.lastSeen = info.start;
        }
        continue;
      }
      byKey[address] = AiEvidence(
        host: meta.host,
        ip: meta.destinationIP,
        port: meta.destinationPort,
        process: meta.process,
        rule: info.rulePayload.isEmpty
            ? info.rule
            : '${info.rule},${info.rulePayload}',
        outbound: outbound,
        group: group,
        geo: meta.destinationGeoIP,
        upload: info.upload,
        download: info.download,
        lastSeen: info.start,
      );
    }
    var items = byKey.values.toList();
    if (keyword.trim().isNotEmpty) {
      final matched = items.where(_matchesKeyword).toList();
      if (matched.isNotEmpty) {
        items = matched;
      }
    }
    int priority(AiEvidence item) => switch (problem) {
      AiProblem.blocked => item.isDirect || item.download < 1024 ? 0 : 1,
      AiProblem.slow => item.isDirect ? 1 : 0,
    };
    items.sort((a, b) {
      final byPriority = priority(a).compareTo(priority(b));
      return byPriority != 0 ? byPriority : b.lastSeen.compareTo(a.lastSeen);
    });
    _evidence = items.take(_maxEvidence).toList();
    _proxyGroup = pickProxyGroup(groupVotes, groupNames);
    return _evidence.length;
  }

  String get proxyGroup => _proxyGroup;

  Future<List<AiMeasurement>> measure() {
    final target = this.target;
    final targetHost = target?.host.toLowerCase();
    final evidence = _evidence
        .where((item) => item.key.isNotEmpty && item.key != targetHost)
        .take(target == null ? _maxMeasured : _maxMeasured - 1);
    return Future.wait([
      if (target != null)
        aiMeasure(
          label: target.authority,
          url: target.toString(),
          proxyGroup: _proxyGroup,
        ),
      for (final item in evidence)
        aiMeasure(
          label: item.key,
          url: aiTestUrl(item.key, item.port),
          proxyGroup: _proxyGroup,
        ),
    ]);
  }

  String get _systemPrompt =>
      '''
You are the routing assistant built into FlClash (a mihomo / Clash Meta client) on a Mac in mainland China.
Chinese websites and apps should go DIRECT. Sites blocked in China or hosted abroad should go through the proxy group "$_proxyGroup".
The user reports: ${problem.description}.
You receive the recent connections (matchedRule = the rule that routed it, outbound = DIRECT or a proxy node, ipCountry = where the server is) and a reachability test of the main hosts, measured DIRECT and through the proxy: milliseconds, -1 = timeout, -2 = failed, null = not tested.
When the user named a site (userTarget), its test result comes first in reachability and it is the one to fix; the measurement already answers whether DIRECT is faster, so decide from it instead of asking the user to test.
Rules you return are inserted before all existing rules.

Guidelines:
- Fix only what explains the reported problem. No rules is better than a guess.
- Problem "打不开": a host that fails or times out DIRECT but works through the proxy, or a well-known service blocked in China (Google, YouTube, Telegram, X/Twitter, Facebook, Instagram, WhatsApp, Discord, Reddit, GitHub raw content and the like), should go PROXY.
- Problem "太慢": a host whose DIRECT test succeeds and is clearly faster than the proxy should go DIRECT. That covers Chinese services and also servers in Hong Kong, Macau, Taiwan or nearby Asia that are not blocked in China (for example Alibaba Cloud or Tencent Cloud servers abroad): sending them through a far-away proxy only adds distance. A Chinese service (Chinese company, Chinese CDN, .cn domain, ipCountry CN) going through the proxy should go DIRECT even without a test. If DIRECT fails or times out, keep it on the proxy.
- Prefer DOMAIN-SUFFIX on the registrable domain (taobao.com, alicdn.com) so related subdomains are covered. Use PROCESS-NAME only when a whole app should take one route and its process name appears in the data. Use DOMAIN-KEYWORD rarely. Use IP-CIDR (the single address as /32) only for hosts without a domain.
- Never route openai.com, chatgpt.com, oaistatic.com or oaiusercontent.com DIRECT. Never add rules for private or LAN addresses.
- If the proxy test fails for nearly every host, the proxy server itself is down: return no rules and say so.
- Skip hosts that are already routed correctly.
- At most $_maxRules rules. target is "DIRECT" or "PROXY".
- The user only reads Simplified Chinese and is not technical: write summary and reason in plain Simplified Chinese.

Reply with one JSON object only:
{"summary": "2-3 句简体中文：发现了什么，建议怎么改", "rules": [{"type": "DOMAIN-SUFFIX", "value": "example.com", "target": "DIRECT", "reason": "一句简体中文"}]}''';

  Future<AiProposal> propose({
    required List<AiMeasurement> measurements,
    required String mode,
    required Set<String> existingRules,
  }) async {
    final now = DateTime.now();
    final userContent = jsonEncode({
      'problem': problem.description,
      'userSays': keyword.trim().isEmpty ? '（没有指明）' : keyword.trim(),
      'userTarget': ?target?.toString(),
      'outboundMode': mode,
      'proxyGroup': _proxyGroup,
      'connections': [for (final item in _evidence) item.toJson(now)],
      'reachability': [for (final item in measurements) item.toJson()],
    });
    return parseAnswer(
      await AiClient.ask(settings, system: _systemPrompt, user: userContent),
      measurements: measurements,
      existingRules: existingRules,
    );
  }

  AiProposal parseAnswer(
    String content, {
    required List<AiMeasurement> measurements,
    required Set<String> existingRules,
  }) {
    final data = AiClient.parseJson(content);
    final existing = {for (final raw in existingRules) raw.toUpperCase()};
    final rules = <AiProposedRule>[];
    final list = data['rules'];
    if (list is List) {
      for (final item in list.whereType<Map>()) {
        final rule = validateAiRule(
          item,
          proxyGroup: _proxyGroup,
          existing: existing,
        );
        if (rule != null && existing.add(rule.raw.toUpperCase())) {
          rules.add(rule);
        }
        if (rules.length >= _maxRules) {
          break;
        }
      }
    }
    final summary = (data['summary'] as String? ?? '').trim();
    return AiProposal(
      summary: summary.isEmpty ? 'AI 没有给出说明。' : summary,
      rules: rules,
      measurements: measurements,
      proxyGroup: _proxyGroup,
    );
  }
}
