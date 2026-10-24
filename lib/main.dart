import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const GurmukhiOCRApp());
}

// ─── App Root ────────────────────────────────────────────────────────────────

class GurmukhiOCRApp extends StatelessWidget {
  const GurmukhiOCRApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gurmukhi OCR',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return Directionality(textDirection: TextDirection.rtl, child: child!);
      },
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.dark,
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0F0F1A),
      ),
      home: const OCRHomePage(),
    );
  }
}

// ─── Data Models ─────────────────────────────────────────────────────────────

class Detection {
  final String label;
  final double confidence;
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double origW;
  final double origH;

  const Detection({
    required this.label,
    required this.confidence,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.origW,
    required this.origH,
  });

  factory Detection.fromMap(Map<dynamic, dynamic> map) {
    return Detection(
      label: map['label'] as String,
      confidence: (map['confidence'] as num).toDouble(),
      x1: (map['x1'] as num).toDouble(),
      y1: (map['y1'] as num).toDouble(),
      x2: (map['x2'] as num).toDouble(),
      y2: (map['y2'] as num).toDouble(),
      origW: (map['origW'] as num).toDouble(),
      origH: (map['origH'] as num).toDouble(),
    );
  }

  Rect toRect(Size displaySize) {
    final scaleX = displaySize.width / origW;
    final scaleY = displaySize.height / origH;
    return Rect.fromLTRB(x1 * scaleX, y1 * scaleY, x2 * scaleX, y2 * scaleY);
  }
}

// ─── OCR Service ─────────────────────────────────────────────────────────────

class OCRService {
  static const _channel = MethodChannel('com.example.gurmukhi_ocr/ocr');
  bool _initialized = false;
  String? lastError;

  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      final result = await _channel.invokeMethod<bool>('initModel');
      _initialized = result ?? false;
      return _initialized;
    } catch (e) {
      lastError = e.toString();
      debugPrint('OCR init error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> runInference(
    Uint8List imageBytes,
    double threshold,
  ) async {
    if (!_initialized) {
      final ok = await initialize();
      if (!ok) return null;
    }
    try {
      final result = await _channel.invokeMethod<Map>('runInference', {
        'imageBytes': imageBytes,
        'threshold': threshold,
      });
      return result?.cast<String, dynamic>();
    } catch (e) {
      debugPrint('Inference error: $e');
      rethrow;
    }
  }
}

// ─── App State ────────────────────────────────────────────────────────────────

class OCRState {
  final File? selectedImage;
  final Uint8List? imageBytes;
  final List<Detection> detections;
  final int? inferenceMs;
  final bool isLoading;
  final bool modelReady;
  final String? errorMessage;

  const OCRState({
    this.selectedImage,
    this.imageBytes,
    this.detections = const [],
    this.inferenceMs,
    this.isLoading = false,
    this.modelReady = false,
    this.errorMessage,
  });

  OCRState copyWith({
    File? selectedImage,
    Uint8List? imageBytes,
    List<Detection>? detections,
    int? inferenceMs,
    bool? isLoading,
    bool? modelReady,
    String? errorMessage,
    bool clearError = false,
    bool clearInference = false,
  }) {
    return OCRState(
      selectedImage: selectedImage ?? this.selectedImage,
      imageBytes: imageBytes ?? this.imageBytes,
      detections: detections ?? this.detections,
      inferenceMs: clearInference ? null : (inferenceMs ?? this.inferenceMs),
      isLoading: isLoading ?? this.isLoading,
      modelReady: modelReady ?? this.modelReady,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  double get avgConfidence {
    if (detections.isEmpty) return 0;
    return detections.map((d) => d.confidence).reduce((a, b) => a + b) /
        detections.length;
  }
}

// ─── Home Page (with Bottom Navigation) ──────────────────────────────────────

class OCRHomePage extends StatefulWidget {
  const OCRHomePage({super.key});

  @override
  State<OCRHomePage> createState() => _OCRHomePageState();
}

class _OCRHomePageState extends State<OCRHomePage>
    with TickerProviderStateMixin {
  final OCRService _ocrService = OCRService();
  final ImagePicker _picker = ImagePicker();

  OCRState _state = const OCRState();
  double _confidenceThreshold = 0.30;
  int _currentNavIndex = 0;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _initModel();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _initModel() async {
    setState(() => _state = _state.copyWith(isLoading: true));
    final ok = await _ocrService.initialize();
    setState(() {
      _state = _state.copyWith(
        modelReady: ok,
        isLoading: false,
        errorMessage: ok
            ? null
            : (_ocrService.lastError ?? 'فشل تحميل النموذج'),
      );
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(source: source, imageQuality: 95);
      if (picked == null) return;
      final file = File(picked.path);
      final bytes = await file.readAsBytes();
      setState(() {
        _state = _state.copyWith(
          selectedImage: file,
          imageBytes: bytes,
          detections: [],
          clearInference: true,
          clearError: true,
        );
      });
      _fadeController.reset();
      _fadeController.forward();
    } catch (e) {
      setState(
        () =>
            _state = _state.copyWith(errorMessage: 'خطأ في اختيار الصورة: $e'),
      );
    }
  }

  Future<void> _runInference() async {
    final bytes = _state.imageBytes;
    if (bytes == null) return;

    setState(() => _state = _state.copyWith(isLoading: true, clearError: true));

    try {
      final result = await _ocrService.runInference(
        bytes,
        _confidenceThreshold,
      );
      if (result == null) {
        setState(
          () => _state = _state.copyWith(
            isLoading: false,
            errorMessage:
                'فشل تشغيل النموذج. تحقق من أن النموذج محمل بشكل صحيح.',
          ),
        );
        return;
      }

      final rawDetections = result['detections'] as List<dynamic>? ?? [];
      final detections = rawDetections
          .map((d) => Detection.fromMap(d as Map<dynamic, dynamic>))
          .toList();

      setState(() {
        _state = _state.copyWith(
          detections: detections,
          inferenceMs: result['inferenceMs'] as int?,
          isLoading: false,
        );
      });
    } catch (e) {
      setState(
        () => _state = _state.copyWith(
          isLoading: false,
          errorMessage: 'خطأ في الاستدلال: $e',
        ),
      );
    }
  }

  // ─── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1A),
      body: IndexedStack(
        index: _currentNavIndex,
        children: [
          _buildMainPage(),
          const _AboutLanguagePage(),
          const _AboutDeveloperPage(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFF2A2A45), width: 1)),
        ),
        child: NavigationBar(
          backgroundColor: const Color(0xFF12122A),
          surfaceTintColor: Colors.transparent,
          indicatorColor: const Color(0xFF6C63FF).withOpacity(0.2),
          selectedIndex: _currentNavIndex,
          onDestinationSelected: (i) => setState(() => _currentNavIndex = i),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          height: 70,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined, color: Color(0xFF9B9BB4)),
              selectedIcon: Icon(Icons.home_rounded, color: Color(0xFF6C63FF)),
              label: 'الرئيسية',
            ),
            NavigationDestination(
              icon: Icon(Icons.language_outlined, color: Color(0xFF9B9BB4)),
              selectedIcon: Icon(
                Icons.language_rounded,
                color: Color(0xFF6C63FF),
              ),
              label: 'حول اللغة',
            ),
            NavigationDestination(
              icon: Icon(
                Icons.person_outline_rounded,
                color: Color(0xFF9B9BB4),
              ),
              selectedIcon: Icon(
                Icons.person_rounded,
                color: Color(0xFF6C63FF),
              ),
              label: 'حول المطور',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainPage() {
    return CustomScrollView(
      slivers: [
        _buildAppBar(),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildStatusBadge(),
                const SizedBox(height: 16),
                _buildImagePickerCard(),
                const SizedBox(height: 16),
                _buildThresholdCard(),
                const SizedBox(height: 16),
                _buildRunButton(),
                if (_state.errorMessage != null) ...[
                  const SizedBox(height: 12),
                  _buildErrorCard(),
                ],
                if (_state.selectedImage != null) ...[
                  const SizedBox(height: 20),
                  _buildImagesSection(),
                ],
                if (_state.detections.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _buildStatsRow(),
                  const SizedBox(height: 16),
                  _buildDetectionsList(),
                ],
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 120,
      pinned: true,
      backgroundColor: const Color(0xFF0F0F1A),
      surfaceTintColor: Colors.transparent,
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsetsDirectional.only(start: 16, bottom: 16),
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF6C63FF), Color(0xFFFF6584)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.document_scanner,
                color: Colors.white,
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Gurmukhi OCR',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                Text(
                  'Character Recognition',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9B9BB4)),
                ),
              ],
            ),
          ],
        ),
      ),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF6C63FF), Color(0xFFFF6584)],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge() {
    final ready = _state.modelReady;
    final loading = _state.isLoading;
    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (ctx, child) {
        return Transform.scale(
          scale: loading ? _pulseAnimation.value : 1.0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: loading
                  ? const Color(0xFF1A1A35)
                  : ready
                  ? const Color(0xFF0D2A1D)
                  : const Color(0xFF2A0D1A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: loading
                    ? const Color(0xFF6C63FF).withOpacity(0.4)
                    : ready
                    ? const Color(0xFF2ECC71).withOpacity(0.4)
                    : const Color(0xFFE74C3C).withOpacity(0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: loading
                        ? const Color(0xFF6C63FF)
                        : ready
                        ? const Color(0xFF2ECC71)
                        : const Color(0xFFE74C3C),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  loading
                      ? 'جاري تحميل النموذج...'
                      : ready
                      ? '✓ النموذج جاهز للاستخدام'
                      : '✗ فشل تحميل النموذج',
                  style: TextStyle(
                    fontSize: 13,
                    color: loading
                        ? const Color(0xFF6C63FF)
                        : ready
                        ? const Color(0xFF2ECC71)
                        : const Color(0xFFE74C3C),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildImagePickerCard() {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            icon: Icons.photo_library_rounded,
            label: 'اختيار الصورة',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _ActionButton(
                  icon: Icons.photo_library_rounded,
                  label: 'المعرض',
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6C63FF), Color(0xFF5A52D5)],
                  ),
                  onTap: () => _pickImage(ImageSource.gallery),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActionButton(
                  icon: Icons.camera_alt_rounded,
                  label: 'الكاميرا',
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF6584), Color(0xFFD94F6A)],
                  ),
                  onTap: () => _pickImage(ImageSource.camera),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildThresholdCard() {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SectionHeader(
                icon: Icons.tune_rounded,
                label: 'عتبة الثقة',
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6C63FF), Color(0xFFFF6584)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${(_confidenceThreshold * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: const Color(0xFF6C63FF),
              inactiveTrackColor: const Color(0xFF2A2A45),
              thumbColor: const Color(0xFF6C63FF),
              overlayColor: const Color(0xFF6C63FF).withOpacity(0.15),
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
            ),
            child: Slider(
              value: _confidenceThreshold,
              min: 0.05,
              max: 0.95,
              divisions: 90,
              onChanged: (v) => setState(() => _confidenceThreshold = v),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text(
                '5%',
                style: TextStyle(color: Color(0xFF9B9BB4), fontSize: 12),
              ),
              Text(
                'أكثر كشفاً ← ← →  أكثر دقةً',
                style: TextStyle(color: Color(0xFF9B9BB4), fontSize: 11),
              ),
              Text(
                '95%',
                style: TextStyle(color: Color(0xFF9B9BB4), fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRunButton() {
    final canRun =
        _state.modelReady && _state.imageBytes != null && !_state.isLoading;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      child: ElevatedButton(
        onPressed: canRun ? _runInference : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: Ink(
          decoration: BoxDecoration(
            gradient: canRun
                ? const LinearGradient(
                    colors: [Color(0xFF6C63FF), Color(0xFFFF6584)],
                  )
                : null,
            color: canRun ? null : const Color(0xFF1A1A35),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Container(
            height: 56,
            alignment: Alignment.center,
            child: _state.isLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.play_arrow_rounded,
                        color: canRun ? Colors.white : const Color(0xFF4A4A6A),
                        size: 24,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'تشغيل التعرف على الحروف',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: canRun
                              ? Colors.white
                              : const Color(0xFF4A4A6A),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2A0D1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE74C3C).withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFE74C3C), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _state.errorMessage!,
              style: const TextStyle(color: Color(0xFFFF8A9B), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImagesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('معاينة الصور'),
        const SizedBox(height: 12),
        if (_state.detections.isEmpty)
          _buildOriginalImageFull()
        else
          Column(
            children: [
              _buildOriginalImageFull(),
              const SizedBox(height: 12),
              const _SectionTitle('الصورة بعد المعالجة'),
              const SizedBox(height: 12),
              _buildAnnotatedImage(),
            ],
          ),
      ],
    );
  }

  Widget _buildOriginalImageFull() {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            icon: Icons.image_rounded,
            label: 'الصورة الأصلية',
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: Image.file(
                _state.selectedImage!,
                fit: BoxFit.contain,
                width: double.infinity,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnnotatedImage() {
    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SectionHeader(
                icon: Icons.find_in_page_rounded,
                label: 'الصورة المُعالَجة',
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF6C63FF).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.zoom_in_rounded,
                      color: Color(0xFF9B9BB4),
                      size: 14,
                    ),
                    SizedBox(width: 4),
                    Text(
                      'كبّر وحرّك',
                      style: TextStyle(color: Color(0xFF9B9BB4), fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: InteractiveViewer(
              minScale: 1.0,
              maxScale: 5.0,
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  return Stack(
                    children: [
                      Image.file(
                        _state.selectedImage!,
                        fit: BoxFit.contain,
                        width: constraints.maxWidth,
                      ),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: DetectionPainter(
                            detections: _state.detections,
                            imageFile: _state.selectedImage!,
                            containerWidth: constraints.maxWidth,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    final ms = _state.inferenceMs;
    final count = _state.detections.length;
    final avg = _state.avgConfidence;

    return Row(
      children: [
        Expanded(
          child: _StatCard(
            icon: Icons.numbers_rounded,
            label: 'حروف مُكتشَفة',
            value: '$count',
            color: const Color(0xFF6C63FF),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            icon: Icons.percent_rounded,
            label: 'متوسط الدقة',
            value: '${(avg * 100).toStringAsFixed(1)}%',
            color: const Color(0xFF2ECC71),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            icon: Icons.timer_rounded,
            label: 'وقت المعالجة',
            value: ms != null ? '${ms}ms' : '-',
            color: const Color(0xFFFF6584),
          ),
        ),
      ],
    );
  }

  Widget _buildDetectionsList() {
    // Group same labels for summary
    final labelMap = <String, List<double>>{};
    for (final d in _state.detections) {
      labelMap.putIfAbsent(d.label, () => []).add(d.confidence);
    }
    final sorted = labelMap.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    return _GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            icon: Icons.list_alt_rounded,
            label: 'الحروف المُتعرَّف عليها',
          ),
          const SizedBox(height: 16),
          // All individual detections
          ...List.generate(_state.detections.length, (i) {
            final d = _state.detections[i];
            return _DetectionRow(index: i + 1, detection: d);
          }),
          if (sorted.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Divider(color: Color(0xFF2A2A45)),
            const SizedBox(height: 12),
            const _SectionHeader(
              icon: Icons.bar_chart_rounded,
              label: 'ملخص الإحصائيات',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: sorted.map((entry) {
                final avgConf =
                    entry.value.reduce((a, b) => a + b) / entry.value.length;
                return _LabelChip(
                  label: entry.key,
                  count: entry.value.length,
                  avgConf: avgConf,
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Detection Painter ────────────────────────────────────────────────────────

class DetectionPainter extends CustomPainter {
  final List<Detection> detections;
  final File imageFile;
  final double containerWidth;

  DetectionPainter({
    required this.detections,
    required this.imageFile,
    required this.containerWidth,
  });

  // Palette of vivid colors for boxes
  static const List<Color> _boxColors = [
    Color(0xFF6C63FF),
    Color(0xFFFF6584),
    Color(0xFF2ECC71),
    Color(0xFFFFD93D),
    Color(0xFF00C9FF),
    Color(0xFFFF8C00),
    Color(0xFFE84393),
    Color(0xFF00E5FF),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty) return;

    final boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final bgPaint = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < detections.length; i++) {
      final det = detections[i];
      final color = _boxColors[i % _boxColors.length];
      final displaySize = Size(containerWidth, size.height);
      final rect = det.toRect(displaySize);

      // Draw semi-transparent fill
      bgPaint.color = color.withOpacity(0.05);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        bgPaint,
      );

      // Draw border
      boxPaint.color = color.withOpacity(0.85);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        boxPaint,
      );

      // Small label background
      final labelText =
          '${det.label} ${(det.confidence * 100).toStringAsFixed(0)}%';
      final tp = TextPainter(
        text: TextSpan(
          text: labelText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 7,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final labelBgRect = Rect.fromLTWH(
        rect.left,
        rect.top - tp.height - 3,
        tp.width + 6,
        tp.height + 3,
      );

      final labelBgPaint = Paint()..color = color.withOpacity(0.85);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          labelBgRect,
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        ),
        labelBgPaint,
      );

      tp.paint(canvas, Offset(rect.left + 3, rect.top - tp.height - 1.5));
    }
  }

  @override
  bool shouldRepaint(DetectionPainter old) =>
      old.detections != detections || old.containerWidth != containerWidth;
}

// ─── Reusable Widgets ─────────────────────────────────────────────────────────

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF16162A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A2A45)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6C63FF).withOpacity(0.05),
            blurRadius: 20,
            spreadRadius: 0,
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SectionHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF6C63FF), size: 18),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w700,
        fontSize: 16,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final LinearGradient gradient;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.gradient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Container(
          height: 48,
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(color: Color(0xFF9B9BB4), fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _DetectionRow extends StatelessWidget {
  final int index;
  final Detection detection;

  const _DetectionRow({required this.index, required this.detection});

  @override
  Widget build(BuildContext context) {
    final pct = (detection.confidence * 100);
    final color = pct >= 80
        ? const Color(0xFF2ECC71)
        : pct >= 60
        ? const Color(0xFFFFD93D)
        : const Color(0xFFFF6584);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F0F1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2A2A45)),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: const Color(0xFF6C63FF).withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              '$index',
              style: const TextStyle(
                color: Color(0xFF6C63FF),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Label with big font for Gurmukhi
          Text(
            detection.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: detection.confidence,
                          backgroundColor: const Color(0xFF2A2A45),
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                          minHeight: 5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${pct.toStringAsFixed(1)}%',
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'x: ${detection.x1.toStringAsFixed(0)}, y: ${detection.y1.toStringAsFixed(0)} '
                  '→ ${detection.x2.toStringAsFixed(0)}, ${detection.y2.toStringAsFixed(0)}',
                  style: const TextStyle(
                    color: Color(0xFF9B9BB4),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LabelChip extends StatelessWidget {
  final String label;
  final int count;
  final double avgConf;

  const _LabelChip({
    required this.label,
    required this.count,
    required this.avgConf,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF6C63FF).withOpacity(0.2),
            const Color(0xFFFF6584).withOpacity(0.2),
          ],
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.35)),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '×$count | ${(avgConf * 100).toStringAsFixed(0)}%',
            style: const TextStyle(color: Color(0xFF9B9BB4), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ─── About Language Page ──────────────────────────────────────────────────────

class _AboutLanguagePage extends StatelessWidget {
  const _AboutLanguagePage();

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 120,
          pinned: true,
          backgroundColor: const Color(0xFF0F0F1A),
          surfaceTintColor: Colors.transparent,
          flexibleSpace: FlexibleSpaceBar(
            titlePadding: const EdgeInsetsDirectional.only(
              start: 16,
              bottom: 16,
            ),
            title: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6C63FF), Color(0xFF00C9FF)],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.language_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                const Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'حول اللغة',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'Gurmukhi Script',
                      style: TextStyle(fontSize: 11, color: Color(0xFF9B9BB4)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(
              height: 1,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF6C63FF), Color(0xFF00C9FF)],
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _buildAlphabetCard(),
                const SizedBox(height: 12),
                _buildLanguageInfoCard(
                  icon: Icons.history_rounded,
                  title: 'التاريخ',
                  content:
                      'خط Gurmukhi (ਗੁਰਮੁਖੀ) هو نظام كتابة أبجدي مقطعي يُستخدم لكتابة اللغة البنجابية التأريخية.\n تم تطويره في القرن السادس عشر الميلادي.',
                ),
                const SizedBox(height: 12),
                _buildLanguageInfoCard(
                  icon: Icons.text_fields_rounded,
                  title: 'خصائص الخط',
                  content:
                      '• يحتوي على 35 حرفاً أساسياً (ਅ ਆ ਇ ...)\n'
                      '• يُكتب من اليسار إلى اليمين\n'
                      '• يتميز بخط أفقي علوي يربط الحروف\n'
                      '• يحتوي على حروف متحركة مستقلة وعلامات تشكيل\n'
                      '• يستخدم نظام أرقام خاص به\n'
                      '• ينتمي إلى عائلة الخطوط البراهمية',
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlphabetCard() {
    const letters = [
      'ੳ',
      'ਅ',
      'ੲ',
      'ਸ',
      'ਹ',
      'ਕ',
      'ਖ',
      'ਗ',
      'ਘ',
      'ਙ',
      'ਚ',
      'ਛ',
      'ਜ',
      'ਝ',
      'ਞ',
      'ਟ',
      'ਠ',
      'ਡ',
      'ਢ',
      'ਣ',
      'ਤ',
      'ਥ',
      'ਦ',
      'ਧ',
      'ਨ',
      'ਪ',
      'ਫ',
      'ਬ',
      'ਭ',
      'ਮ',
      'ਯ',
      'ਰ',
      'ਲ',
      'ਵ',
      'ੜ',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF16162A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A2A45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF6C63FF).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.grid_view_rounded,
                  color: Color(0xFF6C63FF),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'حروف الأبجدية (35 حرفاً)',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Center(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: letters.map((char) {
                return Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F0F1A),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFF6C63FF).withOpacity(0.3),
                    ),
                  ),
                  child: Text(
                    char,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageInfoCard({
    required IconData icon,
    required String title,
    required String content,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF16162A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A2A45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF6C63FF).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: const Color(0xFF6C63FF), size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            content,
            style: const TextStyle(
              color: Color(0xFFB8B8D0),
              fontSize: 14,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── About Developer Page ─────────────────────────────────────────────────────

class _AboutDeveloperPage extends StatelessWidget {
  const _AboutDeveloperPage();

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 120,
          pinned: true,
          backgroundColor: const Color(0xFF0F0F1A),
          surfaceTintColor: Colors.transparent,
          flexibleSpace: FlexibleSpaceBar(
            titlePadding: const EdgeInsetsDirectional.only(
              start: 16,
              bottom: 16,
            ),
            title: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFF6584), Color(0xFFFFD93D)],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.person_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                const Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'حول المطور',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'Developer Info',
                      style: TextStyle(fontSize: 11, color: Color(0xFF9B9BB4)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(
              height: 1,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFFF6584), Color(0xFFFFD93D)],
                ),
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const SizedBox(height: 20),
                // Avatar
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6C63FF), Color(0xFFFF6584)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF6C63FF).withOpacity(0.3),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.code_rounded,
                    color: Colors.white,
                    size: 48,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'واثق المريسي',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Gurmukhi OCR - الإصدار 1.0.0',
                  style: TextStyle(color: Color(0xFF9B9BB4), fontSize: 13),
                ),
                const SizedBox(height: 26),
                _buildDevInfoCard(
                  icon: Icons.person_outline_rounded,
                  title: 'المطور',
                  content:
                      'واثق المريسي\n\n'
                      'تم تطوير هذا التطبيق كمشروع بحثي متقدم في مجال معالجة الصور والرؤية الحاسوبية والذكاء الاصطناعي للتعرف على خط Gurmukhi.',
                ),
                const SizedBox(height: 12),
                _buildDevInfoCard(
                  icon: Icons.info_outline_rounded,
                  title: 'حول التطبيق',
                  content:
                      'تطبيق للتعرف على حروف خط Gurmukhi (البنجابية) باستخدام الذكاء الاصطناعي.\n\n'
                      'يعتمد التطبيق على نموذج YOLO مُدرَّب خصيصاً للكشف عن الحروف وتصنيفها بدقة عالية باستخدام محرك ONNX Runtime.',
                ),
                const SizedBox(height: 12),
                _buildDevInfoCard(
                  icon: Icons.build_circle_outlined,
                  title: 'التقنيات المستخدمة',
                  content:
                      '• Flutter - إطار تطوير التطبيقات\n'
                      '• ONNX Runtime - محرك الذكاء الاصطناعي\n'
                      '• YOLOv8 - نموذج الكشف عن الكائنات\n',
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDevInfoCard({
    required IconData icon,
    required String title,
    required String content,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF16162A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A2A45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6584).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: const Color(0xFFFF6584), size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            content,
            style: const TextStyle(
              color: Color(0xFFB8B8D0),
              fontSize: 14,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }
}
