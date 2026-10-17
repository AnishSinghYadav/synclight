import 'package:flutter/material.dart';

import 'screens/connect.dart';

void main() => runApp(const SyncLightApp());

class SyncLightApp extends StatelessWidget {
  const SyncLightApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFFF7A1A);
    return MaterialApp(
      title: 'SyncLight',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const ConnectScreen(),
    );
  }
}
