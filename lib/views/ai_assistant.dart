import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/ai/assistant.dart';
import 'package:fl_clash/features/ai/daily.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AiAssistantItem extends StatelessWidget {
  const AiAssistantItem({super.key});

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.sparkle),
      title: const Text('AI 分流助手'),
      widget: const AiAssistantView(),
    );
  }
}

class AiAssistantView extends ConsumerStatefulWidget {
  const AiAssistantView({super.key});

  @override
  ConsumerState<AiAssistantView> createState() => _AiAssistantViewState();
}

class _AiAssistantViewState extends ConsumerState<AiAssistantView> {
  final _store = AiStore.instance;
  AiSettings _settings = const AiSettings();
  List<AiRuleRecord> _records = [];
  bool _dailyEnabled = true;
  List<AiPendingRule> _pending = [];
  List<AiReport> _reports = [];
  String? _status;

  @override
  void initState() {
    super.initState();
    AiDaily.instance.changes.addListener(_onDailyChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    AiDaily.instance.changes.removeListener(_onDailyChanged);
    super.dispose();
  }

  void _onDailyChanged() => unawaited(_load());

  Future<void> _load() async {
    final daily = AiDaily.instance;
    final settings = await _store.loadSettings();
    final records = await _store.loadRecords();
    final enabled = await daily.isEnabled();
    final pending = await daily.readPending();
    final reports = await daily.readReports();
    if (!mounted) {
      return;
    }
    setState(() {
      _settings = settings;
      _records = records;
      _dailyEnabled = enabled;
      _pending = pending;
      _reports = reports;
    });
  }

  Future<void> _runDaily() async {
    if (AiDaily.instance.running || _status != null) {
      return;
    }
    if (!_settings.ready && !await _editKey()) {
      return;
    }
    _setStatus('正在体检：整理日志、测速、请 AI 判断…（地址多的话要一两分钟）');
    try {
      final report = await AiDaily.instance.run(ref, manual: true);
      _setStatus(null);
      if (report != null && mounted) {
        await BaseNavigator.push<void>(context, AiReportView(report: report));
      }
    } catch (error) {
      _setStatus(null);
      await AiDaily.instance.recordFailure(error);
      await dialogs.showAlert(
        title: '体检没有完成',
        message: TextSpan(text: error.toString()),
      );
    }
  }

  Future<void> _openPending() async {
    if (_pending.isEmpty) {
      return;
    }
    final accepted = await BaseNavigator.push<List<AiPendingRule>>(
      context,
      AiPendingView(pending: _pending),
    );
    if (accepted == null) {
      return;
    }
    final acceptedRaw = {for (final item in accepted) item.rule.raw};
    await AiDaily.instance.resolvePending(
      ref,
      accepted: accepted,
      declined: [
        for (final item in _pending)
          if (!acceptedRaw.contains(item.rule.raw)) item,
      ],
    );
    dialogs.showBanner('已采纳 ${accepted.length} 条，其余的不再提醒。');
  }

  void _setStatus(String? status) {
    if (mounted) {
      setState(() => _status = status);
    }
  }

  Future<bool> _editKey() async {
    final value = await dialogs.showCommonDialog<String>(
      child: const InputDialog(
        title: 'OpenAI API Key',
        value: '',
        labelText: 'sk-...',
        obscureText: true,
      ),
    );
    if (value == null) {
      return false;
    }
    try {
      await _store.saveApiKey(value);
    } catch (error) {
      await dialogs.showAlert(message: TextSpan(text: error.toString()));
      return false;
    }
    await _load();
    return _settings.ready;
  }

  Future<void> _diagnose(AiProblem problem) async {
    if (_status != null) {
      return;
    }
    if (!_settings.ready && !await _editKey()) {
      return;
    }
    if (ref.read(patchClashConfigProvider).mode != Mode.rule) {
      final switchMode = await dialogs.showMessage(
        title: '先切换到「规则」模式？',
        message: const TextSpan(text: '现在不是「规则」模式，分流规则不会生效，AI 的建议也用不上。'),
        confirmText: '切换',
      );
      if (switchMode != true) {
        return;
      }
      ref.read(setupActionProvider.notifier).changeMode(Mode.rule);
    }
    final keyword = await dialogs.showCommonDialog<String>(
      child: const InputDialog(
        title: '是哪个网站或软件？',
        value: '',
        hintText: '例如：淘宝、Telegram，或直接填网址（不填也行）',
      ),
    );
    if (keyword == null) {
      return;
    }
    try {
      _setStatus('正在收集最近的连接记录…');
      final diagnosis = AiDiagnosis(
        problem: problem,
        keyword: keyword,
        settings: _settings,
        groupNames: [for (final group in ref.read(groupsProvider)) group.name],
      );
      final live = await coreController.getConnections();
      final count = diagnosis.collect(ref.read(requestsProvider).list, live);
      if (count == 0 && diagnosis.target == null) {
        _setStatus(null);
        await dialogs.showAlert(
          message: const TextSpan(
            text:
                '最近 5 分钟没有抓到连接记录。请先打开出问题的网站或软件，等几秒钟再来点；或者直接填网址，比如 http://1.2.3.4/。',
          ),
        );
        return;
      }
      _setStatus('正在测速：直连 vs 代理…');
      final measurements = await diagnosis.measure();
      _setStatus('正在请 AI 分析…');
      final existing = {
        for (final rule in ref.read(globalRulesProvider).value ?? <Rule>[])
          rule.rawValue,
      };
      final proposal = await diagnosis.propose(
        measurements: measurements,
        mode: ref.read(patchClashConfigProvider).mode.name,
        existingRules: existing,
      );
      _setStatus(null);
      if (!mounted) {
        return;
      }
      if (proposal.rules.isEmpty) {
        final tests = [
          for (final item in proposal.measurements.take(3))
            '${item.host}：直连 ${AiMeasurement.label(item.direct)}，代理 ${AiMeasurement.label(item.proxy)}',
        ];
        await dialogs.showAlert(
          title: 'AI 的结论',
          message: TextSpan(
            text: [
              proposal.summary,
              if (tests.isNotEmpty) '\n测速：\n${tests.join('\n')}',
            ].join('\n'),
          ),
        );
        return;
      }
      final selected = await BaseNavigator.push<List<AiProposedRule>>(
        context,
        AiProposalView(proposal: proposal),
      );
      if (selected == null || selected.isEmpty) {
        return;
      }
      await _apply(selected, live);
    } catch (error) {
      _setStatus(null);
      await dialogs.showAlert(
        title: '没有完成',
        message: TextSpan(text: error.toString()),
      );
    }
  }

  Future<void> _apply(
    List<AiProposedRule> selected,
    List<TrackerInfo> live,
  ) async {
    await AiDaily.applyRules(ref, selected, tag: '急用');
    await Future<void>.delayed(const Duration(seconds: 2));
    for (final info in live) {
      if (selected.any((rule) => rule.matches(info))) {
        unawaited(coreController.closeConnection(info.id));
      }
    }
    if (mounted) {
      setState(() {});
    }
    dialogs.showBanner('已添加 ${selected.length} 条规则，马上生效。刷新一下网页或重开软件试试。');
  }

  Future<void> _undo(AiRuleRecord record) async {
    final confirmed = await dialogs.showMessage(
      title: '撤销这条规则？',
      message: TextSpan(text: '${record.raw}\n\n${record.reason}'),
      confirmText: '撤销',
      destructive: true,
    );
    if (confirmed != true) {
      return;
    }
    ref.read(globalRulesProvider.notifier).delAll({record.ruleId});
    final records = await _store.loadRecords();
    await _store.saveRecords([
      for (final item in records)
        if (item.ruleId != record.ruleId) item,
    ]);
    await _load();
  }

  static String _date(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.month}月${time.day}日 ${two(time.hour)}:${two(time.minute)}';
  }

  List<Widget> _buildProblemItems(Mode mode) {
    final busy = _status != null;
    return [
      if (busy)
        ListItem(
          leading: const ActivityIndicator(size: 20),
          title: Text(_status!),
        ),
      if (mode != Mode.rule)
        ListItem(
          leading: const GlyphIcon(AppGlyphs.warning),
          title: Text('现在是「${mode == Mode.global ? '全局' : '直连'}」模式，分流规则不生效'),
          subtitle: const Text('点这里切换到「规则」模式'),
          onTap: () =>
              ref.read(setupActionProvider.notifier).changeMode(Mode.rule),
        ),
      ListItem(
        leading: const GlyphIcon(AppGlyphs.block),
        title: const Text('网站或软件打不开'),
        subtitle: const Text('让 AI 找出应该走代理的地址'),
        onTap: busy ? null : () => _diagnose(AiProblem.blocked),
      ),
      ListItem(
        leading: const GlyphIcon(AppGlyphs.speed),
        title: const Text('网站或软件太慢'),
        subtitle: const Text('让 AI 找出绕了远路、应该直连的国内地址'),
        onTap: busy ? null : () => _diagnose(AiProblem.slow),
      ),
    ];
  }

  List<Widget> _buildDailyItems() {
    final last = _reports.firstOrNull;
    final running = AiDaily.instance.running;
    return [
      ListItem.toggle(
        leading: const GlyphIcon(AppGlyphs.clock),
        title: const Text('每天自动体检'),
        subtitle: const Text('晚上 11:30；那时合盖的话，下次打开电脑时补上'),
        value: _dailyEnabled,
        onChanged: (value) async {
          await AiDaily.instance.setEnabled(value);
          await _load();
        },
      ),
      ListItem(
        leading: const GlyphIcon(AppGlyphs.info),
        title: const Text('最近一次体检'),
        subtitle: Text(
          last == null ? '还没有体检过' : '${_date(last.at)} · ${last.headline}',
        ),
        onTap: last == null
            ? null
            : () =>
                  BaseNavigator.push<void>(context, AiReportView(report: last)),
      ),
      ListItem(
        leading: const GlyphIcon(AppGlyphs.checkCircle),
        title: Text('等你确认的建议（${_pending.length}）'),
        subtitle: Text(_pending.isEmpty ? '没有' : '点开逐条勾选，没勾的以后不再提醒'),
        onTap: _pending.isEmpty ? null : _openPending,
      ),
      ListItem(
        leading: running
            ? const ActivityIndicator(size: 20)
            : const GlyphIcon(AppGlyphs.sync),
        title: const Text('现在体检一次'),
        subtitle: const Text('分析最近几天记录里还没识别的地址'),
        onTap: running || _status != null ? null : _runDaily,
      ),
    ];
  }

  List<Widget> _buildRecordItems(Set<int> liveRuleIds) {
    final records = _records
        .where((item) => liveRuleIds.contains(item.ruleId))
        .toList();
    if (records.isEmpty) {
      return [const ListItem(title: Text('还没有'))];
    }
    return [
      for (final record in records)
        ListItem(
          title: Text(record.raw),
          subtitle: Text('${record.reason}\n${_date(record.addedAt)}'),
          onTap: () => _undo(record),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(
      patchClashConfigProvider.select((state) => state.mode),
    );
    final liveRuleIds = {
      for (final rule in ref.watch(globalRulesProvider).value ?? <Rule>[])
        rule.id,
    };
    return Scaffold(
      title: 'AI 分流助手',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: '每日体检',
            items: _buildDailyItems(),
            footer:
                '软件会把每天的连接记成日志（只存在这台电脑，保留 30 天）。体检时只看还没被规则管到、也没判断过的新地址，测速后交给 AI：有把握的直接生效，涉及支付、登录、广告后台或测速不明确的留给你确认。今天已记录 ${AiTrafficLog.instance.todayHosts} 个地址。',
          ),
          generateSection(
            title: '急用：现在就查',
            items: _buildProblemItems(mode),
            footer: '先打开出问题的网站或软件，再点上面的按钮。AI 会先测速再给建议，你确认后才会生效。',
          ),
          generateSection(
            title: 'AI 添加的规则',
            items: _buildRecordItems(liveRuleIds),
            footer: '点一条规则可以撤销。这些规则也会出现在「进阶配置 → 附加规则」里。',
          ),
          generateSection(
            title: '设置',
            items: [
              ListItem(
                leading: const GlyphIcon(AppGlyphs.key),
                title: const Text('OpenAI API Key'),
                subtitle: Text(_settings.maskedKey),
                onTap: _editKey,
              ),
              ListItem.input(
                leading: const GlyphIcon(AppGlyphs.sparkle),
                title: const Text('模型'),
                subtitle: Text(_settings.model),
                dialogTitle: '模型',
                value: _settings.model,
                resetValue: AiSettings.defaultModel,
                onChanged: (value) async {
                  await _store.saveModel(value ?? '');
                  await _load();
                },
              ),
              ListItem.input(
                leading: const GlyphIcon(AppGlyphs.link),
                title: const Text('接口地址'),
                subtitle: Text(_settings.baseUrl),
                dialogTitle: '接口地址',
                value: _settings.baseUrl,
                resetValue: AiSettings.defaultBaseUrl,
                onChanged: (value) async {
                  await _store.saveBaseUrl(value ?? '');
                  await _load();
                },
              ),
            ],
            footer: 'Key 保存在这台 Mac 的钥匙串里，不会上传到别处。接口地址也可以换成兼容 OpenAI 的其他服务。',
          ),
        ],
      ),
    );
  }
}

class AiProposalView extends StatefulWidget {
  final AiProposal proposal;

  const AiProposalView({super.key, required this.proposal});

  @override
  State<AiProposalView> createState() => _AiProposalViewState();
}

class _AiProposalViewState extends State<AiProposalView> {
  late final Set<int> _selected = {
    for (var index = 0; index < widget.proposal.rules.length; index++) index,
  };

  String _targetLabel(AiProposedRule rule) =>
      rule.target == 'DIRECT' ? '直连' : '走代理（${rule.target}）';

  String _typeLabel(AiProposedRule rule) => switch (rule.type) {
    'DOMAIN-SUFFIX' => '域名及子域名',
    'DOMAIN' => '单个域名',
    'DOMAIN-KEYWORD' => '包含关键词',
    'PROCESS-NAME' => '整个软件',
    'IP-CIDR' => 'IP 地址',
    _ => rule.type,
  };

  void _confirm() {
    final rules = widget.proposal.rules;
    Navigator.of(context).pop<List<AiProposedRule>>([
      for (final index in _selected.toList()..sort()) rules[index],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final proposal = widget.proposal;
    return Scaffold(
      title: 'AI 的建议',
      confirmationAction: IconButtonData(
        glyph: AppGlyphs.check,
        tooltip: '应用选中的规则',
        onPressed: _selected.isEmpty ? null : _confirm,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: '诊断结论',
            items: [ListItem(title: Text(proposal.summary))],
          ),
          generateSection(
            title: '建议添加的规则',
            items: [
              for (final (index, rule) in proposal.rules.indexed)
                ListItem.checkbox(
                  title: Text('${rule.value} → ${_targetLabel(rule)}'),
                  subtitle: Text('${_typeLabel(rule)}：${rule.reason}'),
                  value: _selected.contains(index),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _selected.add(index);
                    } else {
                      _selected.remove(index);
                    }
                  }),
                ),
            ],
            footer: '勾选要用的规则，点右上角 ✓ 应用。不放心的可以取消勾选。',
          ),
          if (proposal.measurements.isNotEmpty)
            generateSection(
              title: '测速结果',
              items: [
                for (final item in proposal.measurements)
                  ListItem(
                    title: Text(item.host),
                    subtitle: Text(
                      '直连 ${AiMeasurement.label(item.direct)} · '
                      '代理 ${AiMeasurement.label(item.proxy)}',
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class AiPendingView extends StatefulWidget {
  final List<AiPendingRule> pending;

  const AiPendingView({super.key, required this.pending});

  @override
  State<AiPendingView> createState() => _AiPendingViewState();
}

class _AiPendingViewState extends State<AiPendingView> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: '等你确认的建议',
      confirmationAction: IconButtonData(
        glyph: AppGlyphs.check,
        tooltip: '采纳勾选的，其余不再提醒',
        onPressed: () => Navigator.of(context).pop<List<AiPendingRule>>([
          for (final index in _selected.toList()..sort()) widget.pending[index],
        ]),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: '勾选要采纳的',
            items: [
              for (final (index, item) in widget.pending.indexed)
                ListItem.checkbox(
                  title: Text(
                    '${item.rule.value} → '
                    '${item.rule.target == 'DIRECT' ? '直连' : '走代理'}',
                  ),
                  subtitle: Text(
                    '${item.rule.reason}\n'
                    '测速：直连 ${AiMeasurement.label(item.direct)}，'
                    '代理 ${AiMeasurement.label(item.proxy)}',
                  ),
                  value: _selected.contains(index),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _selected.add(index);
                    } else {
                      _selected.remove(index);
                    }
                  }),
                ),
            ],
            footer: '点右上角 ✓：勾选的马上生效；没勾的记为「保持原样」，以后体检不再问。直接返回则什么都不改。',
          ),
        ],
      ),
    );
  }
}

class AiReportView extends StatelessWidget {
  final AiReport report;

  const AiReportView({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: '体检报告',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 20 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: _AiAssistantViewState._date(report.at),
            items: [
              ListItem(title: Text(report.headline)),
              if (report.summary.isNotEmpty)
                ListItem(title: Text(report.summary)),
              ListItem(
                title: const Text('数据'),
                subtitle: Text(
                  '日志里共 ${report.hosts} 个地址，其中 ${report.unknown} 个是新的未识别地址，'
                  '测速 ${report.measured} 个。',
                ),
              ),
            ],
          ),
          if (report.applied.isNotEmpty)
            generateSection(
              title: '自动生效的规则',
              items: [
                for (final raw in report.applied) ListItem(title: Text(raw)),
              ],
              footer: '不对的话，回到 AI 分流助手页面，在「AI 添加的规则」里点一下就能撤销。',
            ),
        ],
      ),
    );
  }
}
