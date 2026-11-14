import 'package:flutter/material.dart';
import 'package:pica_comic/foundation/startup.dart';

class StartupGate extends StatefulWidget {
  const StartupGate({
    super.key,
    required this.initialResult,
    required this.retry,
    required this.applicationBuilder,
  });

  final StartupResult initialResult;
  final Future<StartupResult> Function() retry;
  final Widget Function() applicationBuilder;

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  late StartupResult result = widget.initialResult;
  bool retrying = false;

  Future<void> retry() async {
    setState(() => retrying = true);
    StartupResult updated;
    try {
      updated = await widget.retry();
    } catch (error, stack) {
      updated = StartupResult(failure: StartupFailure('startup', error, stack));
    }
    if (!mounted) return;
    setState(() {
      result = updated;
      retrying = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (result.ready) return widget.applicationBuilder();
    final chinese =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'zh';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme:
          ThemeData(useMaterial3: true, splashFactory: NoSplash.splashFactory),
      darkTheme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Builder(builder: (context) {
                  final theme = Theme.of(context);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline,
                          size: 40, color: theme.colorScheme.error),
                      const SizedBox(height: 16),
                      Text(chinese ? '启动失败' : 'Unable to start',
                          style: theme.textTheme.titleLarge,
                          textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      Text(
                        chinese
                            ? '未能完成初始化：${result.failure!.stage}'
                            : 'Initialization failed: ${result.failure!.stage}',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        key: const ValueKey('startup-retry'),
                        onPressed: retrying ? null : retry,
                        icon: retrying
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.refresh),
                        label: Text(chinese ? '重试' : 'Retry'),
                      ),
                    ],
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
