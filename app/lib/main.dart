import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/connect.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: SL.bg,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const SyncLightApp());
}

class SyncLightApp extends StatelessWidget {
  const SyncLightApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SyncLight',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      home: const ConnectScreen(),
    );
  }
}
