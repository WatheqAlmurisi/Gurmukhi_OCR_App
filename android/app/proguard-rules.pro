# Keep all ONNX Runtime classes and native methods
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepclassmembers class * {
    native <methods>;
}
