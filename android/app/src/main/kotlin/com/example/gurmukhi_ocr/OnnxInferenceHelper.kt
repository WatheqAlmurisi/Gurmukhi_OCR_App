package com.example.gurmukhi_ocr

import ai.onnxruntime.*
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import io.flutter.FlutterInjector
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min

/**
 * ONNX inference helper for Gurmukhi OCR using YOLOv8-style model.
 * Handles model loading, image preprocessing, inference, and NMS.
 */
class OnnxInferenceHelper(private val context: Context) {

    private var ortSession: OrtSession? = null
    private var ortEnv: OrtEnvironment? = null
    private var classLabels: List<String> = emptyList()

    var lastError: String? = null
        private set

    companion object {
        private const val TAG = "OnnxInferenceHelper"
        private const val MODEL_INPUT_SIZE = 960
        private const val MODEL_ASSET = "assets/best.onnx"
        private const val CLASSES_ASSET = "assets/gurmukhi_classes.txt"
    }

    /**
     * Helper to open assets packaged by Flutter or Android.
     */
    private fun openAsset(assetPath: String): InputStream {
        val candidates = mutableListOf<String>()

        try {
            val flutterLoader = FlutterInjector.instance().flutterLoader()
            val k1 = flutterLoader.getLookupKeyForAsset(assetPath)
            if (!k1.isNullOrBlank()) candidates.add(k1)
            val k2 = flutterLoader.getLookupKeyForAsset("assets/$assetPath")
            if (!k2.isNullOrBlank()) candidates.add(k2)
        } catch (e: Exception) {
            Log.w(TAG, "FlutterInjector lookup error: ${e.message}")
        }

        val pureName = assetPath.substringAfterLast('/')
        candidates.add("flutter_assets/$assetPath")
        candidates.add("flutter_assets/assets/$pureName")
        candidates.add("flutter_assets/$pureName")
        candidates.add(assetPath)
        candidates.add("assets/$pureName")
        candidates.add(pureName)

        val triedPaths = mutableListOf<String>()
        for (candidate in candidates.distinct()) {
            triedPaths.add(candidate)
            try {
                val stream = context.assets.open(candidate)
                Log.i(TAG, "Successfully loaded asset from: $candidate")
                return stream
            } catch (_: Exception) {
            }
        }
        throw java.io.FileNotFoundException("Could not open asset '$assetPath'. Tried paths: $triedPaths")
    }

    /**
     * Initialize ONNX Runtime session and load class labels.
     */
    fun initialize(): Boolean {
        return try {
            lastError = null
            ortEnv = OrtEnvironment.getEnvironment()
            val modelBytes = openAsset(MODEL_ASSET).use { it.readBytes() }
            val sessionOptions = OrtSession.SessionOptions()
            ortSession = ortEnv!!.createSession(modelBytes, sessionOptions)

            // Load class labels
            classLabels = openAsset(CLASSES_ASSET).use { stream ->
                stream.bufferedReader(Charsets.UTF_8).readLines().filter { it.isNotBlank() }
            }

            Log.i(TAG, "Model and classes loaded successfully. Total classes: ${classLabels.size}")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize model", e)
            lastError = "${e.javaClass.simpleName}: ${e.message}"
            false
        }
    }

    /**
     * Run inference on image bytes.
     * Returns a map with detections and metadata.
     */
    fun runInference(imageBytes: ByteArray, confidenceThreshold: Float): Map<String, Any> {
        val startTime = System.currentTimeMillis()

        val session = ortSession ?: return mapOf("error" to (lastError ?: "Model not initialized"))
        val env = ortEnv ?: return mapOf("error" to "ORT env not initialized")

        // Decode bitmap
        val originalBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
            ?: return mapOf("error" to "Failed to decode image")

        val origW = originalBitmap.width.toFloat()
        val origH = originalBitmap.height.toFloat()

        // Compute scale factors (letterbox style)
        val scale = min(
            MODEL_INPUT_SIZE.toFloat() / origW,
            MODEL_INPUT_SIZE.toFloat() / origH
        )
        val scaledW = (origW * scale).toInt()
        val scaledH = (origH * scale).toInt()
        val padLeft = (MODEL_INPUT_SIZE - scaledW) / 2
        val padTop = (MODEL_INPUT_SIZE - scaledH) / 2

        // Create letterboxed 640x640 bitmap
        val scaledBitmap = Bitmap.createScaledBitmap(originalBitmap, scaledW, scaledH, true)
        val inputBitmap = Bitmap.createBitmap(MODEL_INPUT_SIZE, MODEL_INPUT_SIZE, Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(inputBitmap)
        canvas.drawColor(android.graphics.Color.argb(255, 114, 114, 114)) // gray padding
        canvas.drawBitmap(scaledBitmap, padLeft.toFloat(), padTop.toFloat(), null)

        // Convert to direct float buffer [1, 3, 640, 640] normalized
        val pixels = IntArray(MODEL_INPUT_SIZE * MODEL_INPUT_SIZE)
        inputBitmap.getPixels(pixels, 0, MODEL_INPUT_SIZE, 0, 0, MODEL_INPUT_SIZE, MODEL_INPUT_SIZE)
        inputBitmap.recycle()
        if (scaledBitmap != originalBitmap) {
            scaledBitmap.recycle()
        }
        originalBitmap.recycle()

        val floatBuffer = ByteBuffer.allocateDirect(4 * 3 * MODEL_INPUT_SIZE * MODEL_INPUT_SIZE)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()

        val rChannel = FloatArray(MODEL_INPUT_SIZE * MODEL_INPUT_SIZE)
        val gChannel = FloatArray(MODEL_INPUT_SIZE * MODEL_INPUT_SIZE)
        val bChannel = FloatArray(MODEL_INPUT_SIZE * MODEL_INPUT_SIZE)

        for (i in pixels.indices) {
            val px = pixels[i]
            rChannel[i] = ((px shr 16) and 0xFF) / 255f
            gChannel[i] = ((px shr 8) and 0xFF) / 255f
            bChannel[i] = (px and 0xFF) / 255f
        }
        floatBuffer.put(rChannel)
        floatBuffer.put(gChannel)
        floatBuffer.put(bChannel)
        floatBuffer.rewind()

        // Build OnnxTensor and run inference safely
        val inputShape = longArrayOf(1, 3, MODEL_INPUT_SIZE.toLong(), MODEL_INPUT_SIZE.toLong())
        val inputTensor = OnnxTensor.createTensor(env, floatBuffer, inputShape)

        val inputName = session.inputNames.first()
        val detections = try {
            inputTensor.use { tensor ->
                session.run(mapOf(inputName to tensor)).use { output ->
                    val outputTensor = output[0].value
                    parseYoloOutput(outputTensor, confidenceThreshold, classLabels.size)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Inference execution error", e)
            return mapOf("error" to (e.message ?: "Inference error"))
        }

        // Scale boxes back to original image coordinates
        val scaledDetections = detections.map { det ->
            val x1Raw = det[0] - padLeft
            val y1Raw = det[1] - padTop
            val x2Raw = det[2] - padLeft
            val y2Raw = det[3] - padTop

            val x1 = max(0f, x1Raw / scale)
            val y1 = max(0f, y1Raw / scale)
            val x2 = min(origW, x2Raw / scale)
            val y2 = min(origH, y2Raw / scale)
            val conf = det[4]
            val classId = det[5].toInt()

            listOf(x1, y1, x2, y2, conf, classId.toFloat())
        }.filter { it[0] < it[2] && it[1] < it[3] } // valid boxes only

        val elapsed = System.currentTimeMillis() - startTime

        // Build result map
        val detectionList = scaledDetections.map { det ->
            val classId = det[5].toInt()
            val label = if (classId < classLabels.size) classLabels[classId] else "?"
            mapOf(
                "label" to label,
                "confidence" to det[4].toDouble(),
                "x1" to det[0].toDouble(),
                "y1" to det[1].toDouble(),
                "x2" to det[2].toDouble(),
                "y2" to det[3].toDouble(),
                "origW" to origW.toDouble(),
                "origH" to origH.toDouble()
            )
        }

        return mapOf(
            "detections" to detectionList,
            "count" to detectionList.size,
            "inferenceMs" to elapsed,
            "origW" to origW.toDouble(),
            "origH" to origH.toDouble()
        )
    }

    /**
     * Parse YOLO output tensor in either [1, C+4, N] or [1, N, C+4] format.
     * Returns list of [x1, y1, x2, y2, confidence, classId].
     */
    private fun parseYoloOutput(
        outputValue: Any,
        confThreshold: Float,
        numClasses: Int
    ): List<List<Float>> {
        val detections = mutableListOf<List<Float>>()

        try {
            // ONNX output is a float array; shape depends on model
            val rawArray = outputValue as? Array<*> ?: return detections
            val batch = rawArray[0] as? Array<*> ?: return detections

            val dim0 = batch.size
            val firstRow = batch[0]

            if (firstRow is FloatArray) {
                val dim1 = firstRow.size
                // Determine format
                if (dim0 == numClasses + 4) {
                    // Format: [C+4, N] - columns are anchors
                    val numAnchors = dim1
                    val rows = Array(dim0) { i -> (batch[i] as FloatArray) }
                    for (n in 0 until numAnchors) {
                        val xc = rows[0][n]
                        val yc = rows[1][n]
                        val w = rows[2][n]
                        val h = rows[3][n]
                        val classScores = FloatArray(numClasses) { c -> rows[4 + c][n] }
                        val maxScore = classScores.max()
                        val classId = classScores.indexOfFirst { it == maxScore }
                        if (maxScore >= confThreshold) {
                            val x1 = xc - w / 2f
                            val y1 = yc - h / 2f
                            val x2 = xc + w / 2f
                            val y2 = yc + h / 2f
                            detections.add(listOf(x1, y1, x2, y2, maxScore, classId.toFloat()))
                        }
                    }
                } else {
                    // Format: [N, C+4] - rows are anchors
                    for (n in 0 until dim0) {
                        val row = batch[n] as FloatArray
                        val xc = row[0]
                        val yc = row[1]
                        val w = row[2]
                        val h = row[3]
                        val classScores = FloatArray(numClasses) { c -> row[4 + c] }
                        val maxScore = classScores.max()
                        val classId = classScores.indexOfFirst { it == maxScore }
                        if (maxScore >= confThreshold) {
                            val x1 = xc - w / 2f
                            val y1 = yc - h / 2f
                            val x2 = xc + w / 2f
                            val y2 = yc + h / 2f
                            detections.add(listOf(x1, y1, x2, y2, maxScore, classId.toFloat()))
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }

        return nonMaxSuppression(detections, iouThreshold = 0.45f)
    }

    /**
     * Non-Maximum Suppression to filter overlapping bounding boxes.
     */
    private fun nonMaxSuppression(
        detections: List<List<Float>>,
        iouThreshold: Float
    ): List<List<Float>> {
        if (detections.isEmpty()) return emptyList()

        val sorted = detections.sortedByDescending { it[4] }
        val kept = mutableListOf<List<Float>>()

        val suppressed = BooleanArray(sorted.size)
        for (i in sorted.indices) {
            if (suppressed[i]) continue
            kept.add(sorted[i])
            for (j in i + 1 until sorted.size) {
                if (suppressed[j]) continue
                if (iou(sorted[i], sorted[j]) > iouThreshold) {
                    suppressed[j] = true
                }
            }
        }
        return kept
    }

    private fun iou(a: List<Float>, b: List<Float>): Float {
        val interX1 = max(a[0], b[0])
        val interY1 = max(a[1], b[1])
        val interX2 = min(a[2], b[2])
        val interY2 = min(a[3], b[3])
        val interArea = max(0f, interX2 - interX1) * max(0f, interY2 - interY1)
        val aArea = (a[2] - a[0]) * (a[3] - a[1])
        val bArea = (b[2] - b[0]) * (b[3] - b[1])
        return interArea / (aArea + bArea - interArea + 1e-6f)
    }

    fun release() {
        ortSession?.close()
        ortEnv?.close()
    }
}
