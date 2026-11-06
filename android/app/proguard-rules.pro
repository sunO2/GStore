# GStore release R8 rules.
#
# The Flutter Gradle plugin already injects flutter_proguard_rules.pro (which
# keeps io.flutter.embedding.engine.plugins.FlutterPlugin implementations) and
# proguard-android-optimize.txt. This file only adds application/plugin
# reflection boundaries that are not covered by consumer rules.

# Flutter embedding classes are referenced from the engine and by plugins.
-keep class io.flutter.** { *; }

# Application code: manifest components, MethodChannel handlers, and the JNI
# bridge used by the Rust host (ProxyVpnService.packagesForUid).
-keep class com.suno2.gstore.** { *; }

# Shizuku API + the git-hosted installed_apps plugin.
-keep class rikka.shizuku.** { *; }
-keep class com.sharmadhiraj.installed_apps.** { *; }

# Plugins that deserialize persisted/scheduled models through Gson.
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class com.pravera.flutter_foreground_task.** { *; }

# Keep metadata required by Gson and other reflective serializers.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-dontwarn com.google.android.play.core.**
-dontwarn com.google.gson.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
