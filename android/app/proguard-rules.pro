# XMTP / Protobuf rules
# Keep all protobuf-generated classes and their fields
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }
-keep class * extends com.google.protobuf.GeneratedMessage { *; }

# Keep protobuf field names for reflection
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}
-keepclassmembers class * extends com.google.protobuf.GeneratedMessage {
    <fields>;
}

# Keep all classes in the xmtp packages
-keep class org.xmtp.** { *; }
-keep class xmtp.** { *; }

# Keep libxmtp native bindings
-keep class uniffi.** { *; }

# Keep all protobuf lite classes
-keep class com.google.protobuf.** { *; }

# Prevent obfuscation of classes with native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Ignore missing j2objc annotations (compile-time only, not needed at runtime)
-dontwarn com.google.j2objc.annotations.**

# BouncyCastle crypto library
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# Guava
-dontwarn com.google.common.**
-keep class com.google.common.** { *; }

# Ignore other common missing annotations
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn sun.misc.Unsafe

# JNA (Java Native Access) - Required for XMTP native bindings
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }

# JNA references AWT classes for desktop - not available on Android
-dontwarn java.awt.**
-dontwarn com.sun.jna.Native$AWT

# Keep the Pointer class and its peer field specifically
-keepclassmembers class com.sun.jna.Pointer {
    long peer;
}

# Keep all JNA callback interfaces
-keep interface com.sun.jna.** { *; }

# UniFFI generated bindings for XMTP
-keep class uniffi.xmtpv3.** { *; }
-keepclassmembers class uniffi.xmtpv3.** { *; }
