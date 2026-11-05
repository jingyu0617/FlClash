import 'dart:async';

import 'package:fl_clash/features/ai/daily.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AiDailyManager extends ConsumerStatefulWidget {
  final Widget child;

  const AiDailyManager({super.key, required this.child});

  @override
  ConsumerState<AiDailyManager> createState() => _AiDailyManagerState();
}

class _AiDailyManagerState extends ConsumerState<AiDailyManager> {
  Timer? _timer;
  Timer? _first;

  @override
  void initState() {
    super.initState();
    AiTrafficLog.instance.start();
    _first = Timer(const Duration(minutes: 1), _check);
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _check());
  }

  void _check() {
    if (!mounted) {
      return;
    }
    unawaited(() async {
      try {
        await AiDaily.instance.maybeRun(ref);
      } catch (error) {
        await AiDaily.instance.recordFailure(error);
      }
    }());
  }

  @override
  void dispose() {
    _first?.cancel();
    _timer?.cancel();
    AiTrafficLog.instance.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
