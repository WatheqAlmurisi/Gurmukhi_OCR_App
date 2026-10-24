package com.example.gurmukhi_ocr

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.example.gurmukhi_ocr/ocr"
    private lateinit var onnxHelper: OnnxInferenceHelper
    private val inferenceExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        onnxHelper = OnnxInferenceHelper(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initModel" -> {
                        inferenceExecutor.execute {
                            val success = onnxHelper.initialize()
                            runOnUiThread {
                                if (success) {
                                    result.success(true)
                                } else {
                                    result.error(
                                        "INIT_FAILED",
                                        onnxHelper.lastError ?: "Failed to initialize ONNX model",
                                        null
                                    )
                                }
                            }
                        }
                    }
                    "runInference" -> {
                        val imageBytes = call.argument<ByteArray>("imageBytes")
                        val threshold = (call.argument<Double>("threshold") ?: 0.25).toFloat()
                        if (imageBytes == null) {
                            result.error("NO_IMAGE", "No image bytes provided", null)
                            return@setMethodCallHandler
                        }
                        inferenceExecutor.execute {
                            try {
                                val inferenceResult = onnxHelper.runInference(imageBytes, threshold)
                                runOnUiThread {
                                    result.success(inferenceResult)
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("INFERENCE_ERROR", e.message, e.stackTraceToString())
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        super.onDestroy()
        inferenceExecutor.shutdown()
        onnxHelper.release()
    }
}
