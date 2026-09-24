# WebRTC rules
-keep class org.webrtc.** { *; }
-dontwarn org.webrtc.**

# Firebase rules
-keepattributes *Annotation*
-dontwarn com.google.firebase.**
