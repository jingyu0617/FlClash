import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/ai/chat.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _examples = [
  '现在走的哪个节点？延迟多少？',
  '帮我测一下节点，换到最快的',
  '微信打不开',
  '今天哪些网站走代理的流量最多？',
  '看看有哪些等我确认的建议',
  '跑一次体检',
];

class AiChatView extends ConsumerStatefulWidget {
  const AiChatView({super.key});

  @override
  ConsumerState<AiChatView> createState() => _AiChatViewState();
}

class _AiChatViewState extends ConsumerState<AiChatView> {
  final _chat = AiChat.instance;
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _chat.addListener(_changed);
    unawaited(_chat.load());
  }

  @override
  void dispose() {
    _chat.removeListener(_changed);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  void _send([String? text]) {
    final content = (text ?? _controller.text).trim();
    if (content.isEmpty || _chat.busy) {
      return;
    }
    _controller.clear();
    unawaited(_chat.send(ref, content));
    _focusNode.requestFocus();
  }

  Future<void> _clear() async {
    final confirmed = await dialogs.showMessage(
      title: '清空聊天记录？',
      message: const TextSpan(text: '清空后不能恢复。已经做过的设置改动不受影响。'),
      confirmText: '清空',
      destructive: true,
    );
    if (confirmed == true) {
      await _chat.clear();
    }
  }

  List<AiChatMessage> get _shown => [
    for (final message in _chat.messages)
      if (message.role != 'assistant' || message.text.isNotEmpty) message,
  ];

  Widget _buildItem(BuildContext context, AiChatMessage message) {
    return switch (message.role) {
      'user' => _Bubble(text: message.text, mine: true),
      'assistant' => _Bubble(text: message.text, mine: false),
      'card' => _ConfirmCard(
        message: message,
        onAnswer: (approve) => unawaited(_chat.confirm(ref, approve: approve)),
      ),
      _ => _ToolLine(message: message),
    };
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final busy = _chat.busy;
    return Scaffold(
      title: 'AI',
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.delete,
          tooltip: '清空聊天记录',
          onPressed: busy || _chat.messages.isEmpty ? null : _clear,
        ),
      ],
      body: Column(
        children: [
          Expanded(
            child: shown.isEmpty && !busy
                ? _Welcome(onPick: _send)
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: shown.length + (busy ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (busy && index == 0) {
                        return _StatusLine(text: _chat.status);
                      }
                      final message =
                          shown[shown.length - 1 - (index - (busy ? 1 : 0))];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: _buildItem(context, message),
                      );
                    },
                  ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + context.bottomInset),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    textInputAction: TextInputAction.send,
                    decoration: const InputDecoration(
                      hintText: '想让我做什么？比如：微信打不开、换个快点的节点',
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: '发送',
                  onPressed: busy ? null : _send,
                  icon: const GlyphIcon(AppGlyphs.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  final bool mine;

  const _Bubble({required this.text, required this.mine});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Card(
          isSelected: mine,
          fillsSelection: mine,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: SelectableText(
              text,
              style: AppTextStyle.body
                  .of(context)
                  .copyWith(color: mine ? context.colorScheme.onPrimary : null),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolLine extends StatelessWidget {
  final AiChatMessage message;

  const _ToolLine({required this.message});

  String get _outcome {
    try {
      final data = jsonDecode(message.text);
      if (data is Map && data['reverted'] == true) {
        return '（AI 连不上了，已自动改回）';
      }
      if (data is Map && data['ok'] == false) {
        return '（没成功）';
      }
    } catch (_) {}
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Text(
        '· ${AiChat.labelOf(message.toolName)}$_outcome',
        style: AppTextStyle.caption1
            .of(context)
            .copyWith(color: context.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  final String text;

  const _StatusLine({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const ActivityIndicator(size: 16),
          const SizedBox(width: 8),
          Text(
            text.isEmpty ? 'AI 正在处理…' : text,
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ConfirmCard extends StatelessWidget {
  final AiChatMessage message;
  final ValueChanged<bool> onAnswer;

  const _ConfirmCard({required this.message, required this.onAnswer});

  @override
  Widget build(BuildContext context) {
    final pending = message.cardState == 'pending';
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '需要你确认',
                  style: AppTextStyle.caption1
                      .of(context, emphasized: true)
                      .copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 6),
                Text(message.text, style: AppTextStyle.body.of(context)),
                const SizedBox(height: 12),
                if (pending)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => onAnswer(false),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => onAnswer(true),
                        child: const Text('执行'),
                      ),
                    ],
                  )
                else
                  Text(
                    message.cardState == 'done' ? '已执行' : '已取消',
                    style: AppTextStyle.caption1
                        .of(context)
                        .copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  final ValueChanged<String> onPick;

  const _Welcome({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(16, context.sectionsTopPadding, 16, 16),
      children: [
        generateSection(
          title: '直接说你想做什么，比如：',
          items: [
            for (final example in _examples)
              ListItem(
                leading: const GlyphIcon(AppGlyphs.sparkle),
                title: Text(example),
                onTap: () => onPick(example),
              ),
          ],
          footer:
              '查看类的直接做；切节点、切模式、改规则这类直接改，改完告诉你；停止代理、开关虚拟网卡、切换或删除配置、改 DNS 会先弹出确认。聊天记录会保存在这台电脑上。',
        ),
      ],
    );
  }
}
