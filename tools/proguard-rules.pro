# Keep Flutter plugin classes. Some (shared_preferences) are called from native code by name,
# which the release shrinker can't see, so it removed them ("NoSuchMethodError ... getAll").
-keep class io.flutter.plugins.** { *; }
-keep class com.navideck.universal_ble.** { *; }
-keep class * implements io.flutter.embedding.engine.plugins.FlutterPlugin { *; }
-keepclassmembers class * implements io.flutter.embedding.engine.plugins.FlutterPlugin { *; }
