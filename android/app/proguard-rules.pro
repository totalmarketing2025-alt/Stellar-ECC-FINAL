# Keep libsignal's native/reflective entry points intact under R8.
-keep class org.signal.libsignal.** { *; }
-keep class org.whispersystems.** { *; }

# SQLCipher / sqlite3 native bindings
-keep class net.sqlcipher.** { *; }
-keep class io.sqlite3.** { *; }

# WebRTC
-keep class org.webrtc.** { *; }

# Firebase Messaging
-keep class com.google.firebase.messaging.** { *; }

# Do not obfuscate model classes referenced via reflection in plugins
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes Exceptions
