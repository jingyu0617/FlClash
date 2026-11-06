import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/ai/assistant.dart';
import 'package:fl_clash/features/ai/daily.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' show join;

class AiChatMessage {
  /// user, assistant, tool, or card: a confirmation shown to the user.
  final String role;
  final String text;
  final List<Map<String, dynamic>> toolCalls;
  final String? toolCallId;
  final String? toolName;
  final DateTime at;
  String cardState;

  AiChatMessage({
    required this.role,
    this.text = '',
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
    DateTime? at,
    this.cardState = '',
  }) : at = at ?? DateTime.now();

  factory AiChatMessage.fromJson(Map<String, Object?> json) => AiChatMessage(
    role: json['role'] as String? ?? 'assistant',
    text: json['text'] as String? ?? '',
    toolCalls: [
      for (final item in (json['toolCalls'] as List?) ?? const [])
        if (item is Map) Map<String, dynamic>.from(item),
    ],
    toolCallId: json['toolCallId'] as String?,
    toolName: json['toolName'] as String?,
    at: DateTime.tryParse(json['at'] as String? ?? ''),
    cardState: json['cardState'] as String? ?? '',
  );

  Map<String, Object?> toJson() => {
    'role': role,
    if (text.isNotEmpty) 'text': text,
    if (toolCalls.isNotEmpty) 'toolCalls': toolCalls,
    'toolCallId': ?toolCallId,
    'toolName': ?toolName,
    'at': at.toIso8601String(),
    if (cardState.isNotEmpty) 'cardState': cardState,
  };

  Map<String, Object?>? toApi() => switch (role) {
    'user' => {'role': 'user', 'content': text},
    'assistant' => {
      'role': 'assistant',
      'content': text.isEmpty ? null : text,
      if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
    },
    'tool' => {'role': 'tool', 'tool_call_id': toolCallId, 'content': text},
    _ => null,
  };
}

enum _Risk { read, low, high }

class _Tool {
  final String name;
  final String description;
  final Map<String, Object?> parameters;
  final _Risk risk;
  final String label;

  const _Tool(
    this.name,
    this.label,
    this.risk,
    this.description, [
    this.parameters = const {'type': 'object', 'properties': {}},
  ]);

  Map<String, Object?> get schema => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

Map<String, Object?> _object(
  Map<String, Object?> properties, [
  List<String> required = const [],
]) => {
  'type': 'object',
  'properties': properties,
  if (required.isNotEmpty) 'required': required,
};

const _string = {'type': 'string'};
const _bool = {'type': 'boolean'};
const _int = {'type': 'integer'};

final _tools = <_Tool>[
  const _Tool(
    'get_status',
    '查看运行状态',
    _Risk.read,
    'Running state, outbound mode, TUN, system proxy, current profile, proxy groups with the selected node, and counts of AI rules and pending suggestions.',
  ),
  _Tool(
    'list_nodes',
    '查看节点',
    _Risk.read,
    'Proxy groups with their nodes and the selected one. Pass group to list only that group.',
    _object({'group': _string}),
  ),
  _Tool(
    'test_delays',
    '测节点延迟',
    _Risk.read,
    'Tests node latency now (ms, -1 timeout, -2 failed). Tests every node of the group, or only the given nodes.',
    _object(
      {
        'group': _string,
        'nodes': {'type': 'array', 'items': _string},
      },
      ['group'],
    ),
  ),
  _Tool(
    'list_connections',
    '查看实时连接',
    _Risk.read,
    'Live connections: host, app, matched rule, outbound and traffic. filter matches host, IP or app name.',
    _object({'filter': _string, 'limit': _int}),
  ),
  _Tool(
    'recent_requests',
    '查看最近请求',
    _Risk.read,
    'Connections of the last minutes merged per host: count, app, rule, outbound, traffic. Good for "what went through the proxy today" or finding an app\'s hosts.',
    _object({'filter': _string, 'minutes': _int, 'limit': _int}),
  ),
  _Tool(
    'list_rules',
    '查看规则',
    _Risk.read,
    'The added rules (they come before the profile\'s own rules), with id and, for rules the assistant added, why.',
    _object({'filter': _string}),
  ),
  _Tool(
    'get_logs',
    '查看日志',
    _Risk.read,
    'The latest core log lines, if logging is on.',
    _object({'limit': _int}),
  ),
  const _Tool(
    'list_profiles',
    '查看配置',
    _Risk.read,
    'Profiles (subscriptions and files) with id, name, last update, data usage and which one is current.',
  ),
  const _Tool(
    'get_dns',
    '查看 DNS 设置',
    _Risk.read,
    'The app-wide DNS overrides laid over the profile\'s DNS: which keys are overridden and their values, and which keys may be overridden.',
  ),
  const _Tool(
    'get_daily_review',
    '查看体检结果',
    _Risk.read,
    'The latest daily review report and the suggestions waiting for the user.',
  ),
  _Tool(
    'list_known_sites',
    '查看已识别名单',
    _Risk.read,
    'Sites already judged (by the AI, the common-knowledge list or the user) with the verdict.',
    _object({'filter': _string}),
  ),
  _Tool(
    'diagnose',
    '诊断',
    _Risk.read,
    'Diagnoses a site or app that does not open (problem "blocked") or is slow (problem "slow"): collects its recent connections, tests each host direct and through the proxy, and returns suggested rules. Changes nothing; apply what fits with add_rules or route_site.',
    _object(
      {
        'problem': {
          'type': 'string',
          'enum': ['blocked', 'slow'],
        },
        'target': {
          'type': 'string',
          'description':
              'site, URL, domain, IP or app name (Chinese names fine)',
        },
      },
      ['problem'],
    ),
  ),
  _Tool(
    'set_mode',
    '切换出站模式',
    _Risk.low,
    'Sets the outbound mode: rule (split by rules, the normal one), global (everything through the proxy) or direct (nothing through the proxy).',
    _object(
      {
        'mode': {
          'type': 'string',
          'enum': ['rule', 'global', 'direct'],
        },
      },
      ['mode'],
    ),
  ),
  _Tool(
    'select_node',
    '切换节点',
    _Risk.low,
    'Selects a node in a selectable proxy group. Reverted on its own if the AI can no longer be reached afterwards.',
    _object({'group': _string, 'node': _string}, ['group', 'node']),
  ),
  _Tool(
    'route_site',
    '修改网站走法',
    _Risk.low,
    'Sets how a site (domain or IP) goes: direct, proxy, block (only ad/tracking domains), keep (remove the assistant\'s rule for it and leave it to the other rules), or forget (let the next review judge it again). Replaces earlier assistant rules for that site. Sites on the common-knowledge list cannot be changed.',
    _object(
      {
        'site': _string,
        'action': {
          'type': 'string',
          'enum': ['direct', 'proxy', 'block', 'keep', 'forget'],
        },
      },
      ['site', 'action'],
    ),
  ),
  _Tool(
    'add_rules',
    '添加规则',
    _Risk.low,
    'Adds rules in mihomo form TYPE,VALUE,TARGET (types DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, PROCESS-NAME, IP-CIDR, GEOSITE, GEOIP; target DIRECT, REJECT or a proxy group name). They go before all other rules. More than 5 at once asks the user first.',
    _object(
      {
        'rules': {'type': 'array', 'items': _string},
        'reason': _string,
      },
      ['rules'],
    ),
  ),
  _Tool(
    'remove_rules',
    '删除规则',
    _Risk.low,
    'Removes added rules by id (from list_rules). More than 5 at once asks the user first.',
    _object(
      {
        'ids': {'type': 'array', 'items': _int},
      },
      ['ids'],
    ),
  ),
  _Tool(
    'decide_pending',
    '处理待确认建议',
    _Risk.low,
    'Settles daily-review suggestions waiting for the user: action ai (take each suggestion), direct, proxy, block or keep. sites lists the sites, or ["all"].',
    _object(
      {
        'sites': {'type': 'array', 'items': _string},
        'action': {
          'type': 'string',
          'enum': ['ai', 'direct', 'proxy', 'block', 'keep'],
        },
      },
      ['sites', 'action'],
    ),
  ),
  _Tool(
    'run_daily_review',
    '运行体检',
    _Risk.low,
    'Runs the daily review now. rematch true re-judges every record of the last 30 days (takes minutes).',
    _object({'rematch': _bool}),
  ),
  _Tool(
    'update_profile',
    '更新订阅',
    _Risk.low,
    'Downloads a subscription profile again. Without id, the current profile.',
    _object({'id': _int}),
  ),
  _Tool(
    'close_connections',
    '断开连接',
    _Risk.low,
    'Closes live connections whose host, IP or app matches filter, so they reconnect under the current rules. Without filter, all.',
    _object({'filter': _string}),
  ),
  _Tool(
    'set_running',
    '启动或停止代理',
    _Risk.high,
    'Starts or stops the proxy. Stopping it also cuts the AI off: it cannot answer again until the user starts it.',
    _object({'on': _bool}, ['on']),
  ),
  _Tool(
    'set_tun',
    '开关虚拟网卡',
    _Risk.high,
    'Turns the virtual network card (TUN, takes over all apps\' traffic) on or off.',
    _object({'on': _bool}, ['on']),
  ),
  _Tool(
    'set_system_proxy',
    '开关系统代理',
    _Risk.high,
    'Turns the macOS system proxy on or off.',
    _object({'on': _bool}, ['on']),
  ),
  _Tool(
    'switch_profile',
    '切换配置',
    _Risk.high,
    'Makes another profile the current one.',
    _object({'id': _int}, ['id']),
  ),
  _Tool(
    'delete_profile',
    '删除配置',
    _Risk.high,
    'Deletes a profile for good.',
    _object({'id': _int}, ['id']),
  ),
  _Tool(
    'set_dns',
    '修改 DNS',
    _Risk.high,
    'Changes app-wide DNS overrides. changes maps a key from get_dns (e.g. nameserver, enhanced-mode, fake-ip-filter) to its new value, or to null to stop overriding it.',
    _object(
      {
        'changes': {'type': 'object'},
      },
      ['changes'],
    ),
  ),
];

final _toolsByName = {for (final tool in _tools) tool.name: tool};

class _Pending {
  final Map<String, dynamic> call;
  final List<Map<String, dynamic>> rest;
  final AiChatMessage card;

  const _Pending(this.call, this.rest, this.card);
}

class AiChat extends ChangeNotifier {
  AiChat._();

  static final instance = AiChat._();

  static const _maxStored = 400;
  static const _maxSent = 60;
  static const _maxSteps = 10;
  static const _maxResult = 8000;

  List<AiChatMessage> messages = [];
  bool busy = false;
  String status = '';
  bool _loaded = false;
  _Pending? _pending;

  Future<File> _file() async {
    final dir = Directory(join(await appPath.homeDirPath, 'ai', 'state'));
    await dir.create(recursive: true);
    return File(join(dir.path, 'chat.json'));
  }

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final file = await _file();
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        final list = data is Map ? data['messages'] : null;
        if (list is List) {
          messages = [
            for (final item in list.whereType<Map>())
              AiChatMessage.fromJson(Map<String, Object?>.from(item)),
          ];
        }
      }
    } catch (_) {}
    _repair();
    notifyListeners();
  }

  /// A confirmation left open when the app quit is closed as cancelled, and
  /// every tool call gets an answer, as the API requires.
  void _repair() {
    final answered = {
      for (final message in messages)
        if (message.role == 'tool') message.toolCallId,
    };
    final repaired = <AiChatMessage>[];
    for (final message in messages) {
      if (message.role == 'card' && message.cardState == 'pending') {
        message.cardState = 'cancelled';
      }
      repaired.add(message);
      for (final call in message.toolCalls) {
        final id = call['id'] as String?;
        if (id != null && !answered.contains(id)) {
          repaired.add(
            AiChatMessage(
              role: 'tool',
              toolCallId: id,
              toolName: (call['function'] as Map?)?['name'] as String?,
              text: jsonEncode({'ok': false, 'error': '没有执行（已取消）'}),
            ),
          );
        }
      }
    }
    messages = repaired;
  }

  Future<void> _save() async {
    if (messages.length > _maxStored) {
      messages = messages.sublist(messages.length - _maxStored);
      while (messages.isNotEmpty && messages.first.role != 'user') {
        messages.removeAt(0);
      }
    }
    try {
      await (await _file()).writeAsString(
        jsonEncode({
          'messages': [for (final message in messages) message.toJson()],
        }),
      );
    } catch (_) {}
  }

  Future<void> clear() async {
    if (busy) {
      return;
    }
    messages = [];
    _pending = null;
    await _save();
    notifyListeners();
  }

  void _add(AiChatMessage message) {
    messages.add(message);
    notifyListeners();
  }

  void _setStatus(String value) {
    status = value;
    notifyListeners();
  }

  Future<void> send(WidgetRef ref, String text) async {
    final content = text.trim();
    if (content.isEmpty || busy) {
      return;
    }
    await load();
    _dropPending();
    _add(AiChatMessage(role: 'user', text: content));
    await _run(ref, () => _loop(ref));
  }

  /// A new message while a confirmation is open answers it with no.
  void _dropPending() {
    final pending = _pending;
    if (pending == null) {
      return;
    }
    _pending = null;
    pending.card.cardState = 'cancelled';
    for (final call in [pending.call, ...pending.rest]) {
      _addResult(call, {'ok': false, 'error': '用户没有确认，转而说了别的'});
    }
  }

  Future<void> confirm(WidgetRef ref, {required bool approve}) async {
    final pending = _pending;
    if (pending == null) {
      return;
    }
    _pending = null;
    pending.card.cardState = approve ? 'done' : 'cancelled';
    await _run(ref, () async {
      final result = approve
          ? await _execute(ref, pending.call)
          : {'ok': false, 'error': '用户取消了这个操作'};
      _addResult(pending.call, result);
      if (approve && _cutsAiOff(pending.call)) {
        _finishOffline(pending.rest);
        return;
      }
      if (await _runCalls(ref, pending.rest)) {
        await _loop(ref);
      }
    });
  }

  Future<void> _run(WidgetRef ref, Future<void> Function() body) async {
    busy = true;
    _setStatus('AI 正在处理…');
    try {
      await body();
    } catch (error) {
      _add(AiChatMessage(role: 'assistant', text: '出错了：$error'));
    } finally {
      busy = false;
      status = '';
      await _save();
      notifyListeners();
    }
  }

  List<Map<String, Object?>> _history() {
    var start = messages.length > _maxSent ? messages.length - _maxSent : 0;
    while (start > 0 && messages[start].role != 'user') {
      start--;
    }
    return [for (final message in messages.skip(start)) ?message.toApi()];
  }

  Future<String> _systemPrompt(WidgetRef ref) async {
    final status = await _status(ref);
    return '''
You are the assistant inside FlClash AI, the proxy and split-routing app on the user's Mac in Guangdong, mainland China. The user is not technical and reads only Simplified Chinese: answer briefly in plain Simplified Chinese, explain any term you must use, no Markdown tables.
Use the tools to look things up and to act. Never guess the app's state; check it. When the user asks for a change, call the tool right away: the app itself asks the user to confirm risky changes, so do not ask for permission in text first. After acting, say in one or two sentences what changed and how to undo it if that matters.
Routing basics: in rule mode, rules decide per connection. Chinese sites go DIRECT. A common-knowledge list fixes foreign AI services, cross-border business platforms (Shopify, PayPal, Stripe, Amazon and similar back offices) and services blocked in China to the proxy, and big Chinese platforms to DIRECT; you cannot change those. When a site or app does not work or is slow, use diagnose, then apply fitting rules with route_site or add_rules. Bare IPs that should go direct take IP-CIDR x.x.x.x/32.
You reach OpenAI through the proxy: stopping the proxy or picking a dead node cuts you off. Node and routing changes are checked and undone on their own if you can no longer be reached.
Now: ${jsonEncode(status)}''';
  }

  Future<void> _loop(WidgetRef ref) async {
    final settings = await AiStore.instance.loadSettings();
    if (!settings.ready) {
      _add(
        AiChatMessage(
          role: 'assistant',
          text: '还没有填 OpenAI API Key。请到 工具 → AI 分流助手 → 设置 里填写。',
        ),
      );
      return;
    }
    for (var step = 0; step < _maxSteps; step++) {
      final reply = await AiClient.chat(
        settings,
        messages: [
          {'role': 'system', 'content': await _systemPrompt(ref)},
          ..._history(),
        ],
        tools: [for (final tool in _tools) tool.schema],
      );
      final calls = [
        for (final item in (reply['tool_calls'] as List?) ?? const [])
          if (item is Map) Map<String, dynamic>.from(item),
      ];
      final text = (reply['content'] as String? ?? '').trim();
      _add(AiChatMessage(role: 'assistant', text: text, toolCalls: calls));
      if (calls.isEmpty) {
        return;
      }
      if (!await _runCalls(ref, calls)) {
        return;
      }
    }
    _add(
      AiChatMessage(
        role: 'assistant',
        text: '这件事步骤太多，我先停在这里。你可以再说一次，或者说得更具体一点。',
      ),
    );
  }

  /// Runs tool calls in order; false when one waits for the user or cut the
  /// AI off.
  Future<bool> _runCalls(
    WidgetRef ref,
    List<Map<String, dynamic>> calls,
  ) async {
    for (var index = 0; index < calls.length; index++) {
      final call = calls[index];
      final description = _needsConfirm(call);
      if (description != null) {
        final card = AiChatMessage(
          role: 'card',
          text: description,
          cardState: 'pending',
        );
        _add(card);
        _pending = _Pending(call, calls.sublist(index + 1), card);
        return false;
      }
      _setStatus('正在${_toolsByName[_nameOf(call)]?.label ?? '处理'}…');
      _addResult(call, await _execute(ref, call));
      if (_cutsAiOff(call)) {
        _finishOffline(calls.sublist(index + 1));
        return false;
      }
    }
    return true;
  }

  void _finishOffline(List<Map<String, dynamic>> rest) {
    for (final call in rest) {
      _addResult(call, {'ok': false, 'error': '代理已停止，没有执行'});
    }
    _add(
      AiChatMessage(
        role: 'assistant',
        text: '代理已经停了。我要靠代理才能联网，所以先停在这里。要恢复的话，到仪表盘点一下开始按钮，再回来找我。',
      ),
    );
  }

  static String _nameOf(Map<String, dynamic> call) =>
      (call['function'] as Map?)?['name'] as String? ?? '';

  static Map<String, dynamic> _argsOf(Map<String, dynamic> call) {
    final raw = (call['function'] as Map?)?['arguments'];
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final data = jsonDecode(raw);
        if (data is Map) {
          return Map<String, dynamic>.from(data);
        }
      } catch (_) {}
    }
    return {};
  }

  static bool _cutsAiOff(Map<String, dynamic> call) =>
      _nameOf(call) == 'set_running' && _argsOf(call)['on'] == false;

  void _addResult(Map<String, dynamic> call, Object? result) {
    var text = jsonEncode(result);
    if (text.length > _maxResult) {
      text = '${text.substring(0, _maxResult)}…(truncated)';
    }
    _add(
      AiChatMessage(
        role: 'tool',
        toolCallId: call['id'] as String?,
        toolName: _nameOf(call),
        text: text,
      ),
    );
  }

  /// The question shown to the user before a risky call, or null to run it.
  String? _needsConfirm(Map<String, dynamic> call) {
    final name = _nameOf(call);
    final args = _argsOf(call);
    final tool = _toolsByName[name];
    if (tool == null) {
      return null;
    }
    final many = switch (name) {
      'add_rules' => ((args['rules'] as List?)?.length ?? 0) > 5,
      'remove_rules' => ((args['ids'] as List?)?.length ?? 0) > 5,
      _ => false,
    };
    if (tool.risk != _Risk.high && !many) {
      return null;
    }
    final on = args['on'] == true;
    return switch (name) {
      'set_running' =>
        on ? '启动代理？' : '停止代理？\n停止后所有走代理的网站都会断开，AI 也会断开，要你在仪表盘手动重新开始。',
      'set_tun' =>
        on
            ? '打开虚拟网卡？\n打开后所有软件的流量都由 FlClash 接管。'
            : '关闭虚拟网卡？\n关闭后不走系统代理的软件（比如有些聊天软件）会绕过分流。',
      'set_system_proxy' => on ? '打开系统代理？' : '关闭系统代理？',
      'switch_profile' => '切换到配置 #${args['id']}？',
      'delete_profile' => '删除配置 #${args['id']}？\n删除后不能恢复。',
      'set_dns' =>
        '修改 DNS 设置？\n${const JsonEncoder.withIndent('  ').convert(args['changes'])}',
      'add_rules' =>
        '一次添加 ${(args['rules'] as List).length} 条规则？\n${(args['rules'] as List).join('\n')}',
      'remove_rules' => '一次删除 ${(args['ids'] as List).length} 条规则？',
      _ => '执行「${tool.label}」？',
    };
  }

  Future<Object?> _execute(WidgetRef ref, Map<String, dynamic> call) async {
    final name = _nameOf(call);
    final args = _argsOf(call);
    try {
      return await _dispatch(ref, name, args);
    } catch (error) {
      return {'ok': false, 'error': error.toString()};
    }
  }

  Future<Object?> _dispatch(
    WidgetRef ref,
    String name,
    Map<String, dynamic> args,
  ) async {
    String text(String key) => (args[key] as String? ?? '').trim();
    final filter = text('filter').toLowerCase();
    bool matches(String value) =>
        filter.isEmpty || value.toLowerCase().contains(filter);
    return switch (name) {
      'get_status' => _status(ref),
      'list_nodes' => _nodes(ref, text('group')),
      'test_delays' => _testDelays(ref, text('group'), args['nodes']),
      'list_connections' => _connections(matches, args['limit']),
      'recent_requests' => _requests(ref, matches, args),
      'list_rules' => _rules(ref, matches),
      'get_logs' => [
        for (final log
            in ref
                .read(logsProvider)
                .list
                .reversed
                .take((args['limit'] as num?)?.toInt() ?? 50))
          '${log.dateTime} ${log.logLevel.name} ${log.payload}',
      ],
      'list_profiles' => _profiles(ref),
      'get_dns' => _dns(ref),
      'get_daily_review' => _dailyReview(),
      'list_known_sites' => _known(matches),
      'diagnose' => _diagnose(ref, text('problem'), text('target')),
      'set_mode' => _guarded(ref, () {
        final previous = ref.read(patchClashConfigProvider).mode;
        final mode = Mode.values.firstWhere(
          (item) => item.name == text('mode'),
          orElse: () => throw const AiException('不认识的模式'),
        );
        ref.read(setupActionProvider.notifier).changeMode(mode);
        return () =>
            ref.read(setupActionProvider.notifier).changeMode(previous);
      }),
      'select_node' => _selectNode(ref, text('group'), text('node')),
      'route_site' => _routeSite(ref, text('site'), text('action')),
      'add_rules' => _addRules(ref, args),
      'remove_rules' => _removeRules(ref, args),
      'decide_pending' => _decidePending(ref, args),
      'run_daily_review' => _runReview(ref, args['rematch'] == true),
      'update_profile' => _updateProfile(ref, (args['id'] as num?)?.toInt()),
      'close_connections' => _closeConnections(matches),
      'set_running' => _setRunning(ref, args['on'] == true),
      'set_tun' => _guarded(ref, () {
        final previous = ref.read(patchClashConfigProvider).tun.enable;
        void apply(bool value) => ref
            .read(patchClashConfigProvider.notifier)
            .update((state) => state.copyWith.tun(enable: value));
        apply(args['on'] == true);
        return () => apply(previous);
      }),
      'set_system_proxy' => _guarded(ref, () {
        final previous = ref.read(networkSettingProvider).systemProxy;
        void apply(bool value) => ref
            .read(networkSettingProvider.notifier)
            .update((state) => state.copyWith(systemProxy: value));
        apply(args['on'] == true);
        return () => apply(previous);
      }),
      'switch_profile' => _guarded(ref, () {
        final id = (args['id'] as num?)?.toInt();
        final previous = ref.read(currentProfileIdProvider);
        if (!ref.read(profilesProvider).any((item) => item.id == id)) {
          throw const AiException('没有这个配置');
        }
        ref.read(currentProfileIdProvider.notifier).value = id;
        return () =>
            ref.read(currentProfileIdProvider.notifier).value = previous;
      }, wait: const Duration(seconds: 6)),
      'delete_profile' => _deleteProfile(ref, (args['id'] as num?)?.toInt()),
      'set_dns' => _setDns(ref, args['changes']),
      _ => {'ok': false, 'error': '没有这个操作：$name'},
    };
  }

  /// Applies a change and checks the AI can still be reached; if not, puts
  /// it back.
  Future<Object?> _guarded(
    WidgetRef ref,
    void Function() Function() apply, {
    Duration wait = const Duration(seconds: 2),
  }) async {
    final undo = apply();
    await Future<void>.delayed(wait);
    final settings = await AiStore.instance.loadSettings();
    if (await AiClient.reachable(settings)) {
      return {'ok': true};
    }
    undo();
    await Future<void>.delayed(wait);
    return {
      'ok': false,
      'reverted': true,
      'error': '改完以后 AI 连不上 OpenAI 了，已经自动改回原来的设置。',
    };
  }

  Future<Map<String, Object?>> _status(WidgetRef ref) async {
    final config = ref.read(patchClashConfigProvider);
    final profileId = ref.read(currentProfileIdProvider);
    final profile = ref
        .read(profilesProvider)
        .where((item) => item.id == profileId)
        .firstOrNull;
    final rules = ref.read(globalRulesProvider).value ?? <Rule>[];
    final pending = await AiDaily.instance.readPending();
    return {
      'running': ref.read(isStartProvider),
      'mode': config.mode.name,
      'tun': config.tun.enable,
      'systemProxy': ref.read(networkSettingProvider).systemProxy,
      'profile': {'id': ?profile?.id, 'name': ?profile?.realLabel},
      'groups': [
        for (final group in ref.read(groupsProvider))
          {'name': group.name, 'type': group.type.value, 'selected': group.now},
      ],
      'addedRules': rules.length,
      'pendingSuggestions': pending.length,
    };
  }

  Object _nodes(WidgetRef ref, String groupName) {
    final groups = ref
        .read(groupsProvider)
        .where((group) => groupName.isEmpty || group.name == groupName);
    return [
      for (final group in groups)
        {
          'group': group.name,
          'type': group.type.value,
          'selectable': group.type == GroupType.Selector,
          'selected': group.now,
          'nodes': [for (final proxy in group.all.take(120)) proxy.name],
        },
    ];
  }

  Future<Object?> _testDelays(
    WidgetRef ref,
    String groupName,
    Object? only,
  ) async {
    final group = ref.read(groupsProvider).getGroup(groupName);
    if (group == null) {
      throw AiException('没有叫「$groupName」的组');
    }
    final wanted = {
      if (only is List)
        for (final item in only)
          if (item is String) item,
    };
    final nodes = group.all
        .where((proxy) => wanted.isEmpty || wanted.contains(proxy.name))
        .take(60)
        .toList();
    final url = group.testUrl?.isNotEmpty == true
        ? group.testUrl!
        : 'https://www.gstatic.com/generate_204';
    final results = await Future.wait([
      for (final proxy in nodes)
        coreController
            .testDelay(
              TestDelayParams(
                proxyName: proxy.name,
                testUrl: url,
                timeout: 5000,
              ),
            )
            .then<Delay?>((delay) {
              ref.read(proxiesActionProvider.notifier).setDelay(delay);
              return delay;
            })
            .catchError((_) => null),
    ]);
    return [
      for (final (index, proxy) in nodes.indexed)
        {'node': proxy.name, 'ms': results[index]?.value},
    ];
  }

  static Map<String, Object?> _connectionInfo(TrackerInfo info) => {
    'host': info.metadata.host.isEmpty
        ? info.metadata.destinationIP
        : info.metadata.host,
    'app': info.metadata.process,
    'rule': info.rulePayload.isEmpty
        ? info.rule
        : '${info.rule},${info.rulePayload}',
    'outbound': info.chains.isEmpty ? '' : info.chains.first,
    'upKB': info.upload ~/ 1024,
    'downKB': info.download ~/ 1024,
  };

  static bool _connectionMatches(
    TrackerInfo info,
    bool Function(String value) matches,
  ) =>
      matches(info.metadata.host) ||
      matches(info.metadata.destinationIP) ||
      matches(info.metadata.process);

  Future<Object?> _connections(
    bool Function(String value) matches,
    Object? limit,
  ) async {
    final live = await coreController.getConnections();
    final picked = live
        .where((info) => _connectionMatches(info, matches))
        .take((limit as num?)?.toInt() ?? 30);
    return {
      'total': live.length,
      'connections': [for (final info in picked) _connectionInfo(info)],
    };
  }

  Object _requests(
    WidgetRef ref,
    bool Function(String value) matches,
    Map<String, dynamic> args,
  ) {
    final since = DateTime.now().subtract(
      Duration(minutes: (args['minutes'] as num?)?.toInt() ?? 30),
    );
    final byHost = <String, Map<String, Object?>>{};
    for (final info in ref.read(requestsProvider).list) {
      if (info.start.isBefore(since) || !_connectionMatches(info, matches)) {
        continue;
      }
      final row = _connectionInfo(info);
      final key = row['host'] as String;
      final current = byHost[key];
      if (current == null) {
        byHost[key] = {...row, 'count': 1};
      } else {
        current['count'] = (current['count'] as int) + 1;
        current['upKB'] = (current['upKB'] as int) + (row['upKB'] as int);
        current['downKB'] = (current['downKB'] as int) + (row['downKB'] as int);
      }
    }
    final rows = byHost.values.toList()
      ..sort(
        (a, b) => ((b['downKB'] as int) + (b['upKB'] as int)).compareTo(
          (a['downKB'] as int) + (a['upKB'] as int),
        ),
      );
    return rows.take((args['limit'] as num?)?.toInt() ?? 40).toList();
  }

  Future<Object?> _rules(
    WidgetRef ref,
    bool Function(String value) matches,
  ) async {
    final notes = {
      for (final record in await AiStore.instance.loadRecords())
        record.ruleId: record.reason,
    };
    return [
      for (final rule in ref.read(globalRulesProvider).value ?? <Rule>[])
        if (matches(rule.rawValue))
          {'id': rule.id, 'rule': rule.rawValue, 'note': ?notes[rule.id]},
    ];
  }

  Object _profiles(WidgetRef ref) {
    final current = ref.read(currentProfileIdProvider);
    return [
      for (final profile in ref.read(profilesProvider))
        {
          'id': profile.id,
          'name': profile.realLabel,
          'type': profile.type.name,
          'current': profile.id == current,
          'lastUpdate': ?profile.lastUpdateDate?.toIso8601String(),
          if (profile.subscriptionInfo case final info?)
            'usageGB': {
              'used': ((info.upload + info.download) / 1e9).toStringAsFixed(1),
              'total': (info.total / 1e9).toStringAsFixed(1),
            },
        },
    ];
  }

  Object _dns(WidgetRef ref) {
    final config = ref.read(patchClashConfigProvider);
    final values = config.dns.toJson();
    return {
      'overridden': {
        for (final key in config.dnsOverrideKeys) key.path: values[key.path],
      },
      'mayOverride': [
        for (final key in DnsOverrideKey.normalProfileKeys) key.path,
      ],
      'note': '没有列在 overridden 里的，用的是配置自带的 DNS。',
    };
  }

  Future<Object?> _setDns(WidgetRef ref, Object? changes) async {
    if (changes is! Map || changes.isEmpty) {
      throw const AiException('changes 不能为空');
    }
    final keys = {
      for (final key in DnsOverrideKey.normalProfileKeys) key.path: key,
    };
    final config = ref.read(patchClashConfigProvider);
    final values = Map<String, Object?>.from(config.dns.toJson());
    final picked = {...config.dnsOverrideKeys};
    for (final MapEntry(:key, :value) in changes.entries) {
      final overrideKey = keys[key];
      if (overrideKey == null) {
        throw AiException('$key 不能改，只能改这些：${keys.keys.join('、')}');
      }
      if (value == null) {
        picked.remove(overrideKey);
      } else {
        values[key as String] = value;
        picked.add(overrideKey);
      }
    }
    final dns = Dns.fromJson(values);
    final previous = (dns: config.dns, keys: config.dnsOverrideKeys);
    return _guarded(ref, () {
      ref
          .read(patchClashConfigProvider.notifier)
          .update((state) => state.copyWith(dns: dns, dnsOverrideKeys: picked));
      return () => ref
          .read(patchClashConfigProvider.notifier)
          .update(
            (state) => state.copyWith(
              dns: previous.dns,
              dnsOverrideKeys: previous.keys,
            ),
          );
    }, wait: const Duration(seconds: 4));
  }

  Future<Object?> _dailyReview() async {
    final daily = AiDaily.instance;
    final report = (await daily.readReports()).firstOrNull;
    return {
      'lastReport': report == null
          ? null
          : {
              'at': report.at.toIso8601String(),
              'headline': report.headline,
              'summary': report.summary,
              'applied': report.applied,
            },
      'pending': [
        for (final item in await daily.readPending())
          {
            'site': item.site,
            'now': item.current,
            'suggestion': item.verdict,
            'about': item.about,
            'reason': item.rule.reason,
          },
      ],
    };
  }

  Future<Object?> _known(bool Function(String value) matches) async {
    final known = await AiDaily.instance.readKnown();
    return [
      for (final MapEntry(key: site, value: item) in known.entries)
        if (matches(site) || matches(item.about))
          {
            'site': site,
            'verdict': item.verdict,
            'by': item.source,
            'about': item.about,
          },
    ].take(150).toList();
  }

  Future<Object?> _diagnose(
    WidgetRef ref,
    String problem,
    String target,
  ) async {
    final settings = await AiStore.instance.loadSettings();
    final diagnosis = AiDiagnosis(
      problem: problem == 'slow' ? AiProblem.slow : AiProblem.blocked,
      keyword: target,
      settings: settings,
      groupNames: [for (final group in ref.read(groupsProvider)) group.name],
    );
    final live = await coreController.getConnections();
    final count = diagnosis.collect(ref.read(requestsProvider).list, live);
    if (count == 0 && diagnosis.target == null) {
      return {'ok': false, 'error': '最近 5 分钟没有相关连接记录，请让用户先打开那个网站或软件再试，或者给出网址。'};
    }
    final measurements = await diagnosis.measure();
    final proposal = await diagnosis.propose(
      measurements: measurements,
      mode: ref.read(patchClashConfigProvider).mode.name,
      existingRules: {
        for (final rule in ref.read(globalRulesProvider).value ?? <Rule>[])
          rule.rawValue,
      },
    );
    return {
      'summary': proposal.summary,
      'suggestedRules': [
        for (final rule in proposal.rules)
          {'rule': rule.raw, 'reason': rule.reason},
      ],
      'tests': [for (final item in measurements) item.toJson()],
    };
  }

  Future<Object?> _selectNode(
    WidgetRef ref,
    String groupName,
    String node,
  ) async {
    final group = ref.read(groupsProvider).getGroup(groupName);
    if (group == null || group.type != GroupType.Selector) {
      throw AiException('「$groupName」不是可以手动选节点的组');
    }
    if (!group.all.any((proxy) => proxy.name == node)) {
      throw AiException('「$groupName」里没有「$node」');
    }
    final previous = group.now;
    final action = ref.read(proxiesActionProvider.notifier);
    await action.changeProxy(groupName: groupName, proxyName: node);
    await action.updateGroups();
    final result = await _guarded(ref, () {
      return () {
        if (previous != null) {
          unawaited(
            action.changeProxy(groupName: groupName, proxyName: previous),
          );
        }
      };
    });
    unawaited(action.updateGroups());
    return result;
  }

  Future<Object?> _routeSite(WidgetRef ref, String site, String action) async {
    final value = site
        .toLowerCase()
        .replaceFirst(RegExp(r'^[a-z]+://'), '')
        .split('/')
        .first;
    if (value.isEmpty) {
      throw const AiException('没有给出网站');
    }
    final preset = aiPresetOf(value);
    final verdict = switch (action) {
      'direct' => 'DIRECT',
      'proxy' => 'PROXY',
      'block' => 'BLOCK',
      'keep' => 'KEEP',
      'forget' => 'FORGET',
      _ => throw AiException('不认识的操作 $action'),
    };
    if (preset != null && verdict != 'KEEP' && verdict != 'FORGET') {
      if (preset.preset.verdict != verdict) {
        throw AiException(
          '$value 在常识名单里（${preset.preset.label}，固定${aiVerdictLabel(preset.preset.verdict)}），不能改。',
        );
      }
    }
    await AiDaily.instance.changeSite(ref, value, verdict);
    return {'ok': true, 'site': value, 'now': aiVerdictLabel(verdict)};
  }

  Future<Object?> _addRules(WidgetRef ref, Map<String, dynamic> args) async {
    final reason = (args['reason'] as String? ?? '').trim();
    final groups = {for (final group in ref.read(groupsProvider)) group.name};
    final existing = {
      for (final rule in ref.read(globalRulesProvider).value ?? <Rule>[])
        rule.rawValue.toUpperCase(),
    };
    final accepted = <AiProposedRule>[];
    final refused = <String>[];
    for (final item in (args['rules'] as List?) ?? const []) {
      if (item is! String) {
        continue;
      }
      final parts = item.split(',').map((part) => part.trim()).toList();
      if (parts.length < 3) {
        refused.add('$item（格式应为 类型,值,去向）');
        continue;
      }
      final type = parts[0].toUpperCase();
      final target = parts[2];
      final word = switch (target.toUpperCase()) {
        'DIRECT' => 'DIRECT',
        'REJECT' || 'REJECT-DROP' => 'BLOCK',
        _ when groups.contains(target) => 'PROXY',
        _ => null,
      };
      if (word == null) {
        refused.add('$item（去向只能是 DIRECT、REJECT 或代理组名）');
        continue;
      }
      if (type == 'GEOSITE' || type == 'GEOIP') {
        final rule = AiProposedRule(
          type: type,
          value: parts[1],
          target: word == 'BLOCK' ? 'REJECT' : target,
          reason: reason.isEmpty ? '对话里添加' : reason,
        );
        if (existing.add(rule.raw.toUpperCase())) {
          accepted.add(rule);
        }
        continue;
      }
      final rule = validateAiRule(
        {
          'type': type,
          'value': parts[1],
          'target': word,
          'reason': reason.isEmpty ? '对话里添加' : reason,
        },
        proxyGroup: word == 'PROXY' ? target : '',
        existing: existing,
        allowBlock: true,
      );
      if (rule == null) {
        refused.add('$item（不合规、已存在、或与常识名单冲突）');
        continue;
      }
      existing.add(rule.raw.toUpperCase());
      accepted.add(rule);
    }
    if (accepted.isNotEmpty) {
      await AiDaily.applyRules(ref, accepted, tag: '对话');
    }
    return {
      'added': [for (final rule in accepted) rule.raw],
      if (refused.isNotEmpty) 'refused': refused,
    };
  }

  Future<Object?> _removeRules(WidgetRef ref, Map<String, dynamic> args) async {
    final ids = {
      for (final item in (args['ids'] as List?) ?? const [])
        if (item is num) item.toInt(),
    };
    final rules = ref.read(globalRulesProvider).value ?? <Rule>[];
    final found = rules.where((rule) => ids.contains(rule.id)).toList();
    if (found.isEmpty) {
      throw const AiException('没找到这些规则，先用 list_rules 查 id');
    }
    ref.read(globalRulesProvider.notifier).delAll({
      for (final rule in found) rule.id,
    });
    final store = AiStore.instance;
    await store.saveRecords([
      for (final record in await store.loadRecords())
        if (!ids.contains(record.ruleId)) record,
    ]);
    AiDaily.instance.changes.value++;
    return {
      'removed': [for (final rule in found) rule.rawValue],
    };
  }

  Future<Object?> _decidePending(
    WidgetRef ref,
    Map<String, dynamic> args,
  ) async {
    final sites = {
      for (final item in (args['sites'] as List?) ?? const [])
        if (item is String) item.toLowerCase(),
    };
    final pending = await AiDaily.instance.readPending();
    final items = [
      for (final item in pending)
        if (sites.contains('all') || sites.contains(item.site)) item,
    ];
    if (items.isEmpty) {
      throw const AiException('待确认列表里没有这些网站');
    }
    final action = (args['action'] as String? ?? 'ai').toUpperCase();
    final skipped = await AiDaily.instance.decidePending(ref, items, action);
    return {'done': items.length - skipped, 'skipped': skipped};
  }

  Future<Object?> _runReview(WidgetRef ref, bool rematch) async {
    _setStatus(rematch ? '正在重新判断所有记录（要几分钟）…' : '正在体检…');
    final report = await AiDaily.instance.run(
      ref,
      manual: true,
      rematch: rematch,
    );
    if (report == null) {
      return {'ok': false, 'error': '体检正在进行或网络不通'};
    }
    return {
      'headline': report.headline,
      'summary': report.summary,
      'applied': report.applied,
    };
  }

  Future<Object?> _updateProfile(WidgetRef ref, int? id) async {
    final targetId = id ?? ref.read(currentProfileIdProvider);
    final profile = ref
        .read(profilesProvider)
        .where((item) => item.id == targetId)
        .firstOrNull;
    if (profile == null) {
      throw const AiException('没有这个配置');
    }
    if (profile.url.isEmpty) {
      throw const AiException('这个配置不是订阅，没法更新');
    }
    await ref.read(profilesActionProvider.notifier).updateProfile(profile);
    return {'ok': true, 'name': profile.realLabel};
  }

  Future<Object?> _closeConnections(bool Function(String value) matches) async {
    final live = await coreController.getConnections();
    final picked = live.where((info) => _connectionMatches(info, matches));
    for (final info in picked) {
      await coreController.closeConnection(info.id);
    }
    return {'closed': picked.length};
  }

  Future<Object?> _setRunning(WidgetRef ref, bool on) async {
    await ref
        .read(setupActionProvider.notifier)
        .setRunning(on, initialize: on && !ref.read(initProvider));
    return {'ok': true, 'running': on};
  }

  Future<Object?> _deleteProfile(WidgetRef ref, int? id) async {
    final profile = ref
        .read(profilesProvider)
        .where((item) => item.id == id)
        .firstOrNull;
    if (profile == null || id == null) {
      throw const AiException('没有这个配置');
    }
    await ref.read(profilesActionProvider.notifier).deleteProfile(id);
    return {'ok': true, 'deleted': profile.realLabel};
  }

  @visibleForTesting
  static String? confirmQuestion(String name, Map<String, dynamic> args) =>
      instance._needsConfirm({
        'function': {'name': name, 'arguments': jsonEncode(args)},
      });

  @visibleForTesting
  static List<String> get toolNames => [for (final tool in _tools) tool.name];

  /// The label of the tool a stored tool message answered.
  static String labelOf(String? name) => _toolsByName[name]?.label ?? '操作';
}
