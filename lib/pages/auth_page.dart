import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:pica_comic/foundation/app.dart';
import 'package:pica_comic/foundation/log.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:pica_comic/network/network_logging.dart';
import 'package:pica_comic/pages/main_page.dart';
import 'package:pica_comic/tools/translations.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({Key? key}) : super(key: key);

  static bool lock = false;

  static bool initial = true;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    AuthPage.lock = true;
    WidgetsBinding.instance.addObserver(this);
    if (SchedulerBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      unawaited(auth());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        AuthPage.lock &&
        mounted &&
        !inProgress) {
      unawaited(auth());
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => unawaited(auth()),
      child: Scaffold(
        body: PopScope(
          canPop: false,
          child: SizedBox(
            width: MediaQuery.of(context).size.width,
            height: MediaQuery.of(context).size.height,
            child: Center(
              child: SizedBox(
                height: 100,
                child: Column(
                  children: [
                    Icon(
                      Icons.security,
                      size: 40,
                      color: context.colorScheme.secondary,
                    ),
                    const SizedBox(
                      height: 5,
                    ),
                    Text("点击完成身份验证".tl)
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool inProgress = false;

  Future<void> auth() async {
    if (inProgress) {
      return;
    }
    inProgress = true;
    try {
      final res = await LocalAuthentication()
          .authenticate(localizedReason: "需要身份验证".tl);
      if (!mounted || !res) {
        return;
      }
      AuthPage.lock = false;
      if (AuthPage.initial) {
        App.offAll(() => const MainPage());
      } else {
        App.globalBack();
      }
    } catch (error, stack) {
      Log.warning(
        "Authentication",
        "Local authentication failed: ${safeNetworkError(error)}\n$stack",
      );
    } finally {
      inProgress = false;
    }
  }
}
