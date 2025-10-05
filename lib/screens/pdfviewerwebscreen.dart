import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf_image_viewer/appconfig.dart';
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:typed_data';
import '../services/pdf_api_service.dart';
import '../models/document_info.dart';

// hampir bener, 10 % lagi

// Separate widget class for the loading icon
class PdfPageLoadingIcon extends StatefulWidget {
  final double size;
  final Color? color;

  const PdfPageLoadingIcon({
    Key? key,
    this.size = 48.0,
    this.color,
  }) : super(key: key);

  @override
  State<PdfPageLoadingIcon> createState() => _PdfPageLoadingIconState();
}

class _PdfPageLoadingIconState extends State<PdfPageLoadingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _LoadingIconPainter(
            animationValue: _controller.value,
            color: widget.color ?? Theme.of(context).primaryColor,
          ),
        );
      },
    );
  }
}

class _LoadingIconPainter extends CustomPainter {
  final double animationValue;
  final Color color;

  _LoadingIconPainter({
    required this.animationValue,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.08
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.35;

    for (int i = 0; i < 3; i++) {
      final startAngle = (animationValue * 2 * math.pi) + (i * 2 * math.pi / 3);
      final sweepAngle = math.pi * 0.6;

      final opacity = (math.sin(animationValue * 2 * math.pi + i * 2 * math.pi / 3) + 1) / 2;
      paint.color = color.withOpacity(0.3 + opacity * 0.7);

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LoadingIconPainter oldDelegate) {
    return oldDelegate.animationValue != animationValue ||
        oldDelegate.color != color;
  }
}

class PdfViewerConfig {
  final int maxConcurrentLoads;
  final bool enablePerformanceMonitoring;
  final bool enableAutoRetry;
  final bool enableDebugLogging;
  final double pinchZoomSensitivityMobile;
  final double pinchZoomSensitivityDesktop;
  final int fastScrollPageThreshold;
  final int slowScrollPrefetchCount;
  final int idlePrefetchAheadCount;
  final int idlePrefetchBehindCount;

  // Re-render configuration
  final int maxConcurrentRerenders;
  final int immediateRerenderRadius;
  final int slowScrollRerenderCount;
  final int idleRerenderCount;
  final int zoomRerenderNeighborRadius;

  // Memory management
  final int memoryKeepRadius;
  final bool cleanupAfterScroll;
  final bool cleanupAfterZoom;
  final int cleanupDelayMs;

  const PdfViewerConfig({
    this.maxConcurrentLoads = 10,
    this.enablePerformanceMonitoring = true,
    this.enableAutoRetry = true,
    this.enableDebugLogging = false,
    this.pinchZoomSensitivityMobile = 0.15,
    this.pinchZoomSensitivityDesktop = 0.0000001,
    this.fastScrollPageThreshold = 5,
    this.slowScrollPrefetchCount = 8,
    this.idlePrefetchAheadCount = 5,
    this.idlePrefetchBehindCount = 2,

    // Re-render defaults
    this.maxConcurrentRerenders = 3,
    this.immediateRerenderRadius = 0,
    this.slowScrollRerenderCount = 8,
    this.idleRerenderCount = 10,
    this.zoomRerenderNeighborRadius = 2,

    // Memory defaults
    this.memoryKeepRadius = 5,
    this.cleanupAfterScroll = true,
    this.cleanupAfterZoom = true,
    this.cleanupDelayMs = 150,
  });
}

class PdfViewerWebScreen extends StatefulWidget {
  final String documentId;
  final String? apiBaseUrl;
  final String title;
  final PdfViewerConfig config;
  final Widget? loadingIconWidget;

  const PdfViewerWebScreen({
    Key? key,
    required this.documentId,
    this.apiBaseUrl,
    required this.title,
    this.config = const PdfViewerConfig(),
    this.loadingIconWidget,
  }) : super(key: key);

  @override
  State<PdfViewerWebScreen> createState() => _PdfViewerWebScreenState();
}

class _PdfPerformanceMonitor {
  final Map<int, DateTime> _loadStartTimes = {};
  final Map<int, int> _loadDurations = {};
  final List<double> _zoomLevels = [];
  final List<int> _pageViewDurations = [];
  DateTime? _sessionStart;

  void startSession() {
    _sessionStart = DateTime.now();
  }

  void startPageLoad(int page) {
    _loadStartTimes[page] = DateTime.now();
  }

  void endPageLoad(int page) {
    final start = _loadStartTimes[page];
    if (start != null) {
      final duration = DateTime.now().difference(start);
      _loadDurations[page] = duration.inMilliseconds;
      _loadStartTimes.remove(page);
      print('Page $page loaded in ${duration.inMilliseconds}ms');
    }
  }

  void recordZoom(double zoomLevel) {
    _zoomLevels.add(zoomLevel);
  }

  void recordPageView(int page, Duration duration) {
    _pageViewDurations.add(duration.inSeconds);
  }

  Map<String, dynamic> getMetrics() {
    final avgLoadTime = _loadDurations.values.isEmpty
        ? 0
        : _loadDurations.values.reduce((a, b) => a + b) / _loadDurations.values.length;

    final avgViewTime = _pageViewDurations.isEmpty
        ? 0
        : _pageViewDurations.reduce((a, b) => a + b) / _pageViewDurations.length;

    return {
      'totalPagesLoaded': _loadDurations.length,
      'averageLoadTimeMs': avgLoadTime.round(),
      'averageViewTimeSeconds': avgViewTime.round(),
      'zoomLevelsUsed': _zoomLevels.length,
      'sessionDuration': _sessionStart != null
          ? DateTime.now().difference(_sessionStart!).inSeconds
          : 0,
    };
  }
}

class _PdfViewerWebScreenState extends State<PdfViewerWebScreen> {
  late PdfApiService _apiService;
  DocumentInfo? _documentInfo;
  bool _isLoading = true;
  String? _error;
  int _currentPage = 1;
  final Set<int> _loadedPages = {};
  double _zoomLevel = 1.0;
  int _rotationDegrees = 0;

  // ADD THESE MISSING VARIABLES:
  double _scrollVelocity = 0.0;
  String _scrollDirection = 'none'; // 'up', 'down', 'none'
  Timer? _idleScrollTimer;
  bool _isScrollIdle = true;

  late html.IFrameElement _iframeElement;
  final String _viewId = 'pdf-viewer-${DateTime.now().millisecondsSinceEpoch}';
  bool _viewerInitialized = false;

  final Set<int> _loadingPages = {};
  final List<int> _loadQueue = [];

  int _lastStableCurrentPage = 1;
  DateTime _lastScrollTime = DateTime.now();
  bool _isScrolling = false;
  bool _isZooming = false;
  bool _isFastScrolling = false;

  Timer? _visiblePageCheckTimer;
  Timer? _memoryStatsTimer;
  int _errorCount = 0;
  DateTime? _lastErrorTime;
  bool _isRecovering = false;

  final _PdfPerformanceMonitor _performanceMonitor = _PdfPerformanceMonitor();
  DateTime? _currentPageViewStart;

  final TextEditingController _pageController = TextEditingController();
  final FocusNode _pageFocusNode = FocusNode();
  bool _isEditingPage = false;

  Set<int> _visiblePages = {};

  bool get _isMobile {
    final data = MediaQuery.of(context);
    return data.size.shortestSide < 600;
  }

  @override
  void initState() {
    super.initState();
    _apiService = PdfApiService(
      baseUrl: widget.apiBaseUrl ?? AppConfig.baseUrl,
    );

    _performanceMonitor.startSession();
    _initializePdfViewer();
    _loadDocument();

    _visiblePageCheckTimer = Timer.periodic(
        const Duration(milliseconds: 300),
            (_) => _checkVisiblePagesLoaded()
    );

    if (widget.config.enablePerformanceMonitoring) {
      _memoryStatsTimer = Timer.periodic(
          const Duration(seconds: 10),
              (_) => _logMemoryStats()
      );
    }

    _pageController.text = _currentPage.toString();
  }

  @override
  void didUpdateWidget(PdfViewerWebScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pageController.text = _currentPage.toString();
  }

  void _debugLog(String message) {
    if (widget.config.enableDebugLogging) {
      print('[PDF_VIEWER_DEBUG] $message');
    }
  }

  void _initializePdfViewer() {
    _iframeElement = html.IFrameElement()
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%'
    // ANDROID FIX: Add touch-action attribute
      ..setAttribute('touch-action', 'pan-x pan-y pinch-zoom');

    // ignore: undefined_prefixed_name
    ui.platformViewRegistry.registerViewFactory(
      _viewId,
          (int viewId) => _iframeElement,
    );

    html.window.onMessage.listen((event) {
      if (event.data is Map) {
        final data = event.data as Map;
        _handlePdfJsMessage(data);
      }
    });
  }

  void _handlePdfJsMessage(Map<dynamic, dynamic> data) {
    if (!mounted) return;

    try {
      final type = data['type'];
      if (type == null) return;

      switch (type.toString()) {
        case 'pageInView':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null && pageNum != _currentPage) {
              if (_currentPageViewStart != null) {
                final duration = DateTime.now().difference(_currentPageViewStart!);
                _performanceMonitor.recordPageView(_currentPage, duration);
              }

              setState(() {
                _currentPage = pageNum;
                if (!_isEditingPage) {
                  _pageController.text = pageNum.toString();
                }
              });
              _currentPageViewStart = DateTime.now();

              _ensurePageLoaded(pageNum);
            }
          }
          break;

        case 'scrollStateChanged':
          final isScrolling = data['isScrolling'];
          final isFastScrolling = data['isFastScrolling'];
          final direction = data['direction'];
          if (isScrolling != null) {
            if (direction != null) {
              _scrollDirection = direction.toString();
            }
            _handleScrollStateChange(isScrolling as bool, isFastScrolling as bool);
          }
          break;

        case 'scrollStopped':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null) {
              _handleScrollStopped(pageNum);
            }
          }
          break;

        case 'viewerReady':
          setState(() {
            _viewerInitialized = true;
          });
          _loadInitialPages();
          break;

        case 'requestPage':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null) {
              _ensurePageLoaded(pageNum);
            }
          }
          break;

        case 'zoomChanged':
          final zoom = data['zoom'];
          if (zoom != null) {
            final zoomValue = zoom is double ? zoom : double.tryParse(zoom.toString());
            if (zoomValue != null) {
              setState(() {
                _zoomLevel = zoomValue;
              });
              _performanceMonitor.recordZoom(zoomValue);
            }
          }
          break;

        case 'currentPageReport':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null && pageNum != _currentPage) {
              setState(() {
                _currentPage = pageNum;
                if (!_isEditingPage) {
                  _pageController.text = pageNum.toString();
                }
              });
            }
          }
          break;

        case 'zoomStateChanged':
          final isZooming = data['isZooming'];
          if (isZooming != null) {
            setState(() {
              _isZooming = isZooming as bool;
            });
          }
          break;

        case 'visiblePagesChanged':
          final pages = data['pages'];
          if (pages is List) {
            _handleVisiblePagesChanged(pages.cast<int>());
          }
          break;

        case 'error':
          final errorMessage = data['message'];
          if (errorMessage != null) {
            setState(() {
              _error = errorMessage.toString();
              _isLoading = false;
            });
          }
          break;
      }
    } catch (e) {
      print('Error handling PDF.js message: $e');
    }
  }

  void _handleVisiblePagesChanged(List<int> visiblePages) {
    _visiblePages = visiblePages.toSet();
    _debugLog('Visible pages changed: $visiblePages, isFastScrolling: $_isFastScrolling');

    if (!_isFastScrolling) {
      for (final pageNum in visiblePages) {
        _ensurePageLoaded(pageNum);
      }
    }
  }

  void _checkVisiblePagesLoaded() {
    if (!mounted || _isFastScrolling) return;

    for (final pageNum in _visiblePages) {
      if (!_loadedPages.contains(pageNum) && !_loadingPages.contains(pageNum)) {
        _debugLog('Visible page $pageNum not loaded, queuing immediately');
        _ensurePageLoaded(pageNum);
      }
    }
  }

  void _ensurePageLoaded(int pageNumber) {
    if (!_loadedPages.contains(pageNumber) && !_loadingPages.contains(pageNumber)) {
      _queuePageLoad(pageNumber);
    }
  }

  void _handleScrollStateChange(bool isScrolling, bool isFastScrolling) {
    setState(() {
      _isScrolling = isScrolling;
      _isFastScrolling = isFastScrolling;
    });
    _lastScrollTime = DateTime.now();

    if (isScrolling) {
      _isScrollIdle = false;
      _idleScrollTimer?.cancel();

      if (isFastScrolling) {
        _debugLog('Fast scrolling detected - canceling all loads');
        _cancelAllLoads();
      } else {
        // Slow scroll - prefetch based on direction
        _debugLog('Slow scroll detected (direction: $_scrollDirection)');
        _loadPriorityPages(_currentPage);
      }
    } else {
      // Start idle timer
      _idleScrollTimer?.cancel();
      _idleScrollTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() {
            _isScrollIdle = true;
          });
          _debugLog('Scroll idle - aggressive prefetch');
          _prefetchAggressively(_currentPage);
        }
      });
    }
  }

  void _handleScrollStopped(int pageNum) {
    setState(() {
      _isScrolling = false;
      _isFastScrolling = false;
    });
    _lastStableCurrentPage = pageNum;

    _debugLog('Scroll stopped at page $pageNum');

    Future.delayed(const Duration(milliseconds: 50), () {
      if (!mounted) return;

      _ensurePageLoaded(pageNum);
      _loadPriorityPages(pageNum);
    });
  }

  void _prefetchAggressively(int centerPage) {
    if (_documentInfo == null) return;

    final pagesToPrefetch = <int>[];
    final totalPages = _documentInfo!.totalPages;
    final aheadCount = widget.config.idlePrefetchAheadCount;    // Use config
    final behindCount = widget.config.idlePrefetchBehindCount;  // Use config

    if (_scrollDirection == 'down') {
      // User scrolling down - prioritize pages ahead
      for (int i = 1; i <= aheadCount; i++) { // Use config value
        final page = centerPage + i;
        if (page <= totalPages && page >= 1 &&
            !_loadedPages.contains(page) &&
            !_loadingPages.contains(page)) {
          pagesToPrefetch.add(page);
        }
      }
      // Also prefetch pages behind
      for (int i = 1; i <= behindCount; i++) { // Use config value
        final page = centerPage - i;
        if (page >= 1 && page <= totalPages &&
            !_loadedPages.contains(page) &&
            !_loadingPages.contains(page)) {
          pagesToPrefetch.add(page);
        }
      }
    } else if (_scrollDirection == 'up') {
      // User scrolling up - prioritize pages behind
      for (int i = 1; i <= aheadCount; i++) { // Use config value
        final page = centerPage - i;
        if (page >= 1 && page <= totalPages &&
            !_loadedPages.contains(page) &&
            !_loadingPages.contains(page)) {
          pagesToPrefetch.add(page);
        }
      }
      // Also prefetch pages ahead
      for (int i = 1; i <= behindCount; i++) { // Use config value
        final page = centerPage + i;
        if (page <= totalPages && page >= 1 &&
            !_loadedPages.contains(page) &&
            !_loadingPages.contains(page)) {
          pagesToPrefetch.add(page);
        }
      }
    } else {
      // No clear direction - prefetch symmetrically
      for (int i = 1; i <= aheadCount; i++) { // Use config value
        final nextPage = centerPage + i;
        final prevPage = centerPage - i;

        if (nextPage <= totalPages && nextPage >= 1 &&
            !_loadedPages.contains(nextPage) &&
            !_loadingPages.contains(nextPage)) {
          pagesToPrefetch.add(nextPage);
        }

        if (prevPage >= 1 && prevPage <= totalPages &&
            !_loadedPages.contains(prevPage) &&
            !_loadingPages.contains(prevPage)) {
          pagesToPrefetch.add(prevPage);
        }
      }
    }

    _debugLog('Aggressive prefetch: ${pagesToPrefetch.length} pages - $pagesToPrefetch');

    for (final page in pagesToPrefetch) {
      _queuePageLoad(page);
    }
  }

  void _loadPriorityPages(int currentPage) {
    if (_documentInfo == null || _isFastScrolling) return;

    final pagesToLoad = <int>[];
    final totalPages = _documentInfo!.totalPages;
    final prefetchCount = widget.config.slowScrollPrefetchCount;

    // Current page first
    if (!_loadedPages.contains(currentPage) && !_loadingPages.contains(currentPage)) {
      pagesToLoad.add(currentPage);
    }

    if (!_isFastScrolling) {
      if (_scrollDirection == 'down') {
        for (int i = 1; i <= prefetchCount; i++) {
          final page = currentPage + i;
          if (page <= totalPages && page >= 1 &&
              !_loadedPages.contains(page) &&
              !_loadingPages.contains(page)) {
            pagesToLoad.add(page);
          }
        }
        final prevPage = currentPage - 1;
        if (prevPage >= 1 && prevPage <= totalPages &&
            !_loadedPages.contains(prevPage) &&
            !_loadingPages.contains(prevPage)) {
          pagesToLoad.add(prevPage);
        }
      } else if (_scrollDirection == 'up') {
        for (int i = 1; i <= prefetchCount; i++) {
          final page = currentPage - i;
          if (page >= 1 && page <= totalPages &&
              !_loadedPages.contains(page) &&
              !_loadingPages.contains(page)) {
            pagesToLoad.add(page);
          }
        }
        final nextPage = currentPage + 1;
        if (nextPage <= totalPages && nextPage >= 1 &&
            !_loadedPages.contains(nextPage) &&
            !_loadingPages.contains(nextPage)) {
          pagesToLoad.add(nextPage);
        }
      } else {
        for (int i = 1; i <= prefetchCount; i++) {
          final prevPage = currentPage - i;
          final nextPage = currentPage + i;

          if (nextPage <= totalPages && nextPage >= 1 &&
              !_loadedPages.contains(nextPage) &&
              !_loadingPages.contains(nextPage)) {
            pagesToLoad.add(nextPage);
          }

          if (prevPage >= 1 && prevPage <= totalPages &&
              !_loadedPages.contains(prevPage) &&
              !_loadingPages.contains(prevPage)) {
            pagesToLoad.add(prevPage);
          }
        }
      }
    }

    _debugLog('Loading priority pages: $pagesToLoad (direction: $_scrollDirection)');

    // FIX: Use queue system to respect maxConcurrentLoads
    for (final page in pagesToLoad) {
      _queuePageLoad(page);
    }
  }

  void _cancelAllLoads() {
    _loadQueue.clear();
    final loadingToCancel = _loadingPages.toList();
    for (final pageNum in loadingToCancel) {
      _loadingPages.remove(pageNum);
    }
    _debugLog('Cancelled all page loads');
  }

  Future<void> _loadDocument() async {
    if (_isRecovering) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final info = await _apiService.getDocumentInfo(widget.documentId)
          .timeout(const Duration(seconds: 30));

      setState(() {
        _documentInfo = info;
        _errorCount = 0;
      });

      _initializeViewer();
    } catch (e) {
      _handleLoadError(e);
    }
  }

  void _handleLoadError(dynamic error) {
    _errorCount++;
    _lastErrorTime = DateTime.now();

    final errorMessage = error is TimeoutException
        ? 'Request timeout. Please check your connection.'
        : error.toString();

    setState(() {
      _error = errorMessage;
      _isLoading = false;
    });

    if (widget.config.enableAutoRetry && _errorCount <= 3 && error is! FormatException) {
      Future.delayed(Duration(seconds: 2 * _errorCount), () {
        if (mounted && _error != null) {
          _recoverFromError();
        }
      });
    }
  }

  void _recoverFromError() async {
    if (_isRecovering) return;

    setState(() {
      _isRecovering = true;
      _error = null;
      _isLoading = true;
    });

    try {
      _initializePdfViewer();
      await _loadDocument();

      setState(() {
        _isRecovering = false;
      });
    } catch (e) {
      setState(() {
        _isRecovering = false;
        _error = 'Recovery failed: $e';
        _isLoading = false;
      });
    }
  }

  void _initializeViewer() {
    if (_documentInfo == null) return;

    setState(() {
      _isLoading = false;
    });

    final pageDimensionsJson = _documentInfo!.pages?.map((pageInfo) {
      return {
        'pageNumber': pageInfo.pageNumber,
        'width': pageInfo.dimensions.width,
        'height': pageInfo.dimensions.height,
        'unit': pageInfo.dimensions.unit,
      };
    }).toList() ?? [];

    final pageDimensionsJsonString = jsonEncode(pageDimensionsJson);
    final fastScrollThreshold = widget.config.fastScrollPageThreshold;

    final maxConcurrentRerenders = widget.config.maxConcurrentRerenders;
    final immediateRerenderRadius = widget.config.immediateRerenderRadius;
    final slowScrollRerenderCount = widget.config.slowScrollRerenderCount;
    final idleRerenderCount = widget.config.idleRerenderCount;

    final htmlContent = r'''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes">
  <title>''' + widget.title + r'''</title>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.min.mjs" type="module"></script>
  <style>
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    html, body {
      width: 100%;
      height: 100%;
      overflow: hidden;
      /* ANDROID FIX: Add touch-action to html and body */
      touch-action: pan-x pan-y pinch-zoom;
    }
    body {
      background: #525659;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    }
    #pdf-container {
      width: 100%;
      height: 100%;
      overflow-y: auto;
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
      scroll-behavior: auto;
      padding: 0 20px;
      /* ANDROID FIX: Critical touch-action property */
      touch-action: pan-x pan-y pinch-zoom;
      /* ANDROID FIX: Disable momentum scrolling interference */
      overscroll-behavior: contain;
    }
    #pages-wrapper {
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 20px 0;
      gap: 20px;
      min-width: min-content;
      transform-origin: center top;
      will-change: transform;
      transition: transform 0.15s cubic-bezier(0.4, 0.0, 0.2, 1);
      /* ANDROID FIX: Allow touch gestures */
      touch-action: pan-x pan-y pinch-zoom;
    }
    .page-container {
      position: relative;
      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
      background: white;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0 auto;
      max-width: 100%;
      transition: width 0.15s cubic-bezier(0.4, 0.0, 0.2, 1), height 0.15s cubic-bezier(0.4, 0.0, 0.2, 1);
      /* ANDROID FIX: Enable touch on pages */
      touch-action: pan-x pan-y pinch-zoom;
    }
    .page-container.loading {
      background: #f5f5f5;
    }
    canvas {
      display: block;
      background: white;
      image-rendering: -webkit-optimize-contrast;
      image-rendering: crisp-edges;
      /* ANDROID FIX: Allow all pan gestures and pinch zoom */
      touch-action: pan-x pan-y pinch-zoom;
      pointer-events: auto;
      /* ANDROID FIX: Ensure canvas doesn't interfere with scrolling */
      -webkit-user-select: none;
      user-select: none;
    }
    canvas.needs-rerender {
      display: none;
    }
    .page-number {
      position: absolute;
      bottom: 10px;
      right: 10px;
      background: rgba(0,0,0,0.7);
      color: white;
      padding: 4px 8px;
      border-radius: 4px;
      font-size: 12px;
      font-weight: 500;
      z-index: 10;
      /* ANDROID FIX: Don't block touch events */
      pointer-events: none;
    }
    .loading-spinner {
      color: #666;
      font-size: 14px;
      display: flex;
      align-items: center;
      justify-content: center;
      width: 100%;
      height: 100%;
      pointer-events: none;
    }
    .spinner-icon {
      width: 48px;
      height: 48px;
      border: 4px solid rgba(0, 0, 0, 0.1);
      border-top-color: #3498db;
      border-radius: 50%;
      animation: spin 1s linear infinite;
    }
    @keyframes spin {
      to { transform: rotate(360deg); }
    }
    .rerender-spinner {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      background: white;
      z-index: 5;
      pointer-events: none;
    }
    .page-indicator {
      position: fixed;
      right: 60px;
      top: 50%;
      transform: translateY(-50%);
      background: rgba(0, 0, 0, 0.85);
      color: white;
      padding: 12px 16px;
      border-radius: 8px;
      font-size: 16px;
      font-weight: 600;
      box-shadow: 0 4px 12px rgba(0,0,0,0.3);
      opacity: 0;
      transition: opacity 0.3s ease;
      pointer-events: none;
      z-index: 1000;
      min-width: 80px;
      text-align: center;
    }
    .page-indicator.visible {
      opacity: 1;
    }
    .page-indicator .current {
      font-size: 24px;
      display: block;
      margin-bottom: 4px;
    }
    .page-indicator .total {
      font-size: 12px;
      opacity: 0.8;
    }
    .scroll-speed-indicator {
      position: fixed;
      top: 20px;
      right: 20px;
      background: rgba(255, 87, 34, 0.9);
      color: white;
      padding: 8px 12px;
      border-radius: 6px;
      font-size: 12px;
      font-weight: 600;
      opacity: 0;
      transition: opacity 0.3s ease;
      pointer-events: none;
      z-index: 1001;
    }
    .scroll-speed-indicator.visible {
      opacity: 1;
    }
    .zoom-indicator {
      position: fixed;
      top: 20px;
      left: 20px;
      background: rgba(0, 0, 0, 0.85);
      color: white;
      padding: 8px 12px;
      border-radius: 6px;
      font-size: 12px;
      font-weight: 600;
      opacity: 0;
      transition: opacity 0.3s ease;
      pointer-events: none;
      z-index: 1001;
    }
    .zoom-indicator.visible {
      opacity: 1;
    }
    @media (max-width: 768px) {
      .page-indicator {
        right: 20px;
        padding: 10px 14px;
      }
      .page-indicator .current {
        font-size: 20px;
      }
      #pages-wrapper {
        padding: 10px 0;
        gap: 10px;
      }
      #pdf-container {
        padding: 0 10px;
      }
    }
  </style>
</head>
<body>
  <div id="pdf-container" role="main" aria-label="PDF Document">
    <div id="pages-wrapper"></div>
  </div>
  <div id="page-indicator" class="page-indicator" role="status" aria-live="polite" aria-atomic="true">
    <span class="current" id="current-page">1</span>
    <span class="total">of 1</span>
  </div>
  <div id="scroll-speed-indicator" class="scroll-speed-indicator" role="alert" aria-live="assertive">
    Fast Scrolling - Loading Paused
  </div>
  <div id="zoom-indicator" class="zoom-indicator" role="alert" aria-live="assertive">
    Zooming...
  </div>

  <script type="module">
    (async function() {
      const pdfjsLib = await import('https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.min.mjs');
      pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.worker.min.mjs';

      const isAndroid = /Android/i.test(navigator.userAgent);
      const isIOS = /iPhone|iPad|iPod/i.test(navigator.userAgent);
      const isMobile = isAndroid || isIOS;
      
      const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);

      const maxZoomMobile = 3.0;
      const maxZoomDesktop = 5.0;
      const maxZoom = isMobile ? maxZoomMobile : maxZoomDesktop;
      const pinchZoomSensitivity = isMobile ? ''' + widget.config.pinchZoomSensitivityMobile.toString() + r''' : ''' + widget.config.pinchZoomSensitivityDesktop.toString() + r''';
      const fastScrollPageThreshold = ''' + fastScrollThreshold.toString() + r''';
      
      const maxConcurrentRerenders = ''' + maxConcurrentRerenders.toString() + r''';
      const immediateRerenderRadius = ''' + immediateRerenderRadius.toString() + r''';
      const slowScrollRerenderCount = ''' + slowScrollRerenderCount.toString() + r''';
      const idleRerenderCount = ''' + idleRerenderCount.toString() + r''';
      const zoomRerenderNeighborRadius = ''' + widget.config.zoomRerenderNeighborRadius.toString() + r''';

      let container;
      let pagesWrapper;
      let pageIndicator;
      let pageIndicatorCurrent;
      let pageIndicatorTotal;
      let scrollSpeedIndicator;
      let zoomIndicator;
      
      let scale = 1.0;
      let currentPage = 1;
      const totalPages = ''' + _documentInfo!.totalPages.toString() + r''';
      const pageDimensions = ''' + pageDimensionsJsonString + r''';
      const pageData = new Map();
      const pageElements = new Map();
      const loadingPages = new Set();
      
      let isZooming = false;
      let activeZoomAnimation = null;
      let currentRotation = 0;
      let isPinchZooming = false;
      let pinchZoomScale = 1.0;
      
      const pageZoomScales = new Map();
      
      // Store original rendered dimensions for scaling calculations
      const originalPageDimensions = new Map(); // pageNum -> { width, height, scale }
      
      // Track pages that need reload after deletion
      const needsReload = new Set();
      
      // Priority queue system
      const rerenderQueue = [];
      const rerenderPriority = new Map();
      const rerenderingPages = new Map(); // pageNum -> { priority, renderTask }
      let lastRerenderDirection = 'none';
      let isFastScrolling = false;
      let isScrollingNow = false;
      
      let visiblePagesObserver;
      
      function getPriorityValue(priority) {
        return { visible: 3, scroll: 2, immediate: 1, idle: 0 }[priority] || 0;
      }
      
      function needsRerender(pageNum) {
        const lastScale = pageZoomScales.get(pageNum);
        const pageInfo = pageElements.get(pageNum);
        return pageInfo && 
               pageInfo.rendered && 
               pageData.has(pageNum) &&
               lastScale !== undefined && 
               Math.abs(lastScale - scale) > 0.01;
      }
      
      function showSpinner(pageNum) {
        const pageInfo = pageElements.get(pageNum);
        if (!pageInfo || !pageInfo.canvas) return;
        
        pageInfo.canvas.classList.add('needs-rerender');
        
        if (!pageInfo.container.querySelector('.rerender-spinner')) {
          const spinner = document.createElement('div');
          spinner.className = 'loading-spinner rerender-spinner';
          const spinnerIcon = document.createElement('div');
          spinnerIcon.className = 'spinner-icon';
          spinner.appendChild(spinnerIcon);
          pageInfo.container.appendChild(spinner);
        }
      }
      
      function hideSpinner(pageNum) {
        const pageInfo = pageElements.get(pageNum);
        if (!pageInfo) return;
        
        if (pageInfo.canvas) {
          pageInfo.canvas.classList.remove('needs-rerender');
        }
        
        const spinner = pageInfo.container.querySelector('.rerender-spinner');
        if (spinner) {
          spinner.remove();
        }
      }
      
      function addToRerenderQueue(pages, priority) {
        for (const page of pages) {
          if (!needsRerender(page)) continue;
          
          const existingPriority = rerenderPriority.get(page);
          const existingValue = getPriorityValue(existingPriority);
          const newValue = getPriorityValue(priority);
          
          if (existingPriority && newValue <= existingValue) {
            continue;
          }
          
          rerenderPriority.set(page, priority);
          
          if (!rerenderQueue.includes(page)) {
            rerenderQueue.push(page);
          }
        }
        
        rerenderQueue.sort((a, b) => {
          return getPriorityValue(rerenderPriority.get(b)) - getPriorityValue(rerenderPriority.get(a));
        });
        
        processRerenderQueue();
      }
      
      async function processRerenderQueue() {
        if (isFastScrolling) {
          return;
        }
        
        while (rerenderingPages.size < maxConcurrentRerenders && rerenderQueue.length > 0) {
          const pageNum = rerenderQueue.shift();
          
          if (!needsRerender(pageNum)) continue;
          
          const priority = rerenderPriority.get(pageNum);
          
          showSpinner(pageNum);
          
          rerenderingPages.set(pageNum, { priority });
          
          rerenderPageForZoom(pageNum, scale).then(() => {
            rerenderingPages.delete(pageNum);
            rerenderPriority.delete(pageNum);
            hideSpinner(pageNum);
            processRerenderQueue();
          }).catch(err => {
            console.error('Rerender error for page ' + pageNum + ':', err);
            rerenderingPages.delete(pageNum);
            rerenderPriority.delete(pageNum);
            hideSpinner(pageNum);
            processRerenderQueue();
          });
        }
      }
      
      function cancelLowerPriorityRerenders(minPriority) {
        const minValue = getPriorityValue(minPriority);
        const toCancel = [];
        
        for (const [pageNum, info] of rerenderingPages) {
          if (getPriorityValue(info.priority) < minValue) {
            toCancel.push(pageNum);
          }
        }
        
        for (const pageNum of toCancel) {
          const data = pageData.get(pageNum);
          if (data && data.renderTask) {
            try {
              data.renderTask.cancel();
            } catch (e) {}
          }
          rerenderingPages.delete(pageNum);
          hideSpinner(pageNum);
        }
        
        const queuedToRemove = [];
        for (const pageNum of rerenderQueue) {
          const priority = rerenderPriority.get(pageNum);
          if (getPriorityValue(priority) < minValue) {
            queuedToRemove.push(pageNum);
          }
        }
        
        for (const pageNum of queuedToRemove) {
          const index = rerenderQueue.indexOf(pageNum);
          if (index > -1) {
            rerenderQueue.splice(index, 1);
            rerenderPriority.delete(pageNum);
          }
        }
      }
      
      function cancelRerenders(newDirection) {
        if (newDirection !== lastRerenderDirection && lastRerenderDirection !== 'none') {
          cancelLowerPriorityRerenders('scroll');
        }
        lastRerenderDirection = newDirection;
      }
      
      function queueImmediateRerenders(centerPage, radius) {
        if (isScrollingNow) {
          return;
        }
        
        const pages = [];
        for (let i = -radius; i <= radius; i++) {
          if (i === 0) continue;
          const page = centerPage + i;
          if (page >= 1 && page <= totalPages && needsRerender(page)) {
            pages.push(page);
          }
        }
        addToRerenderQueue(pages, 'immediate');
      }
      
      function queueDirectionalRerenders(centerPage, direction, count, priority) {
        const pages = [];
        
        if (direction === 'down') {
          for (let i = 1; i <= count; i++) {
            const page = centerPage + i;
            if (page <= totalPages && needsRerender(page)) {
              pages.push(page);
            }
          }
          const prevPage = centerPage - 1;
          if (prevPage >= 1 && needsRerender(prevPage)) {
            pages.push(prevPage);
          }
        } else if (direction === 'up') {
          for (let i = 1; i <= count; i++) {
            const page = centerPage - i;
            if (page >= 1 && needsRerender(page)) {
              pages.push(page);
            }
          }
          const nextPage = centerPage + 1;
          if (nextPage <= totalPages && needsRerender(nextPage)) {
            pages.push(nextPage);
          }
        } else {
          for (let i = 1; i <= count; i++) {
            const nextPage = centerPage + i;
            const prevPage = centerPage - i;
            
            if (nextPage <= totalPages && needsRerender(nextPage)) {
              pages.push(nextPage);
            }
            if (prevPage >= 1 && needsRerender(prevPage)) {
              pages.push(prevPage);
            }
          }
        }
        
        addToRerenderQueue(pages, priority || 'scroll');
      }
      
      function init() {
        container = document.getElementById('pdf-container');
        pagesWrapper = document.getElementById('pages-wrapper');
        pageIndicator = document.getElementById('page-indicator');
        pageIndicatorCurrent = pageIndicator.querySelector('.current');
        pageIndicatorTotal = pageIndicator.querySelector('.total');
        scrollSpeedIndicator = document.getElementById('scroll-speed-indicator');
        zoomIndicator = document.getElementById('zoom-indicator');
        
        visiblePagesObserver = new IntersectionObserver((entries) => {
          const visiblePages = [];
          
          entries.forEach(entry => {
            const pageNum = parseInt(entry.target.id.split('-')[1]);
            
            if (entry.isIntersecting && entry.intersectionRatio >= 0.05) {
              visiblePages.push(pageNum);
              
              // Reload pages that were cleaned up during zoom
              if (needsReload.has(pageNum)) {
                needsReload.delete(pageNum);
                window.parent.postMessage({ 
                  type: 'requestPage', 
                  page: pageNum 
                }, '*');
              }
            }
          });
          
          if (visiblePages.length > 0) {
            const newCurrentPage = Math.min(...visiblePages);
            if (newCurrentPage !== currentPage) {
              currentPage = newCurrentPage;
              pageIndicatorCurrent.textContent = currentPage;
              
              window.parent.postMessage({ 
                type: 'pageInView', 
                page: currentPage 
              }, '*');
            }
            
            window.parent.postMessage({
              type: 'visiblePagesChanged',
              pages: visiblePages
            }, '*');
            
            visiblePages.forEach(pageNum => {
              if (needsRerender(pageNum)) {
                addToRerenderQueue([pageNum], 'visible');
              }
            });
          }
        }, {
          root: container,
          threshold: [0.05, 0.1, 0.3, 0.5],
          rootMargin: '200px 0px 200px 0px'
        });
        
        const baseScale = isMobile ? 1.2 : 1.5;
        
        for (let i = 1; i <= totalPages; i++) {
          const pageContainer = document.createElement('div');
          pageContainer.className = 'page-container loading';
          pageContainer.id = 'page-' + i;
          pageContainer.dataset.pageNumber = i.toString();
          
          const pageDim = pageDimensions.find(p => p.pageNumber === i);
          if (pageDim) {
            let widthPt = pageDim.width;
            let heightPt = pageDim.height;
            
            if (pageDim.unit === 'mm') {
              widthPt = pageDim.width * 2.83465;
              heightPt = pageDim.height * 2.83465;
            } else if (pageDim.unit === 'in') {
              widthPt = pageDim.width * 72;
              heightPt = pageDim.height * 72;
            }
            
            const displayWidth = widthPt * baseScale;
            const displayHeight = heightPt * baseScale;
            
            pageContainer.style.width = displayWidth + 'px';
            pageContainer.style.height = displayHeight + 'px';
          } else {
            pageContainer.style.width = '100%';
            pageContainer.style.height = 'auto';
            pageContainer.style.minHeight = '400px';
          }
          
          const spinner = document.createElement('div');
          spinner.className = 'loading-spinner';
          const spinnerIcon = document.createElement('div');
          spinnerIcon.className = 'spinner-icon';
          spinner.appendChild(spinnerIcon);
          pageContainer.appendChild(spinner);
          
          const pageNumber = document.createElement('div');
          pageNumber.className = 'page-number';
          pageNumber.textContent = i + ' / ' + totalPages;
          pageContainer.appendChild(pageNumber);
          
          pagesWrapper.appendChild(pageContainer);
          pageElements.set(i, { 
            container: pageContainer, 
            canvas: null, 
            pdf: null, 
            rendered: false,
            dimensions: pageDim
          });
        }
        
        setupScrollListener();
        setupZoomControls();
        setupKeyboardControls();
        
        pageElements.forEach((data, pageNum) => {
          visiblePagesObserver.observe(data.container);
        });
        
        window.parent.postMessage({ type: 'viewerReady' }, '*');
      }

      function getCurrentVisiblePage() {
        const containerRect = container.getBoundingClientRect();
        const containerTop = containerRect.top;
        const containerHeight = containerRect.height;
        const containerCenter = containerTop + (containerHeight / 2);
        
        let bestCandidate = currentPage;
        let smallestDistance = Infinity;
        
        for (let i = 1; i <= totalPages; i++) {
          const pageContainer = document.getElementById('page-' + i);
          if (!pageContainer) continue;
          
          const pageRect = pageContainer.getBoundingClientRect();
          const pageCenter = pageRect.top + (pageRect.height / 2);
          const distanceFromCenter = Math.abs(pageCenter - containerCenter);
          
          if (distanceFromCenter < smallestDistance) {
            smallestDistance = distanceFromCenter;
            bestCandidate = i;
          }
        }
        
        return bestCandidate;
      }

      function setupScrollListener() {
        pageIndicatorTotal.textContent = 'of ' + totalPages;
        
        let scrollState = {
          isScrolling: false,
          isFastScrolling: false,
          lastScrollTime: 0,
          lastPageNumber: 1,
          lastDirection: 'none',
          scrollTimeout: null,
          pageChangesInInterval: 0,
          pageChangeCheckInterval: null,
        };
        
        container.addEventListener('scroll', () => {
          const now = Date.now();
          const visiblePage = getCurrentVisiblePage();
          
          const direction = visiblePage > scrollState.lastPageNumber ? 'down' : 
                           visiblePage < scrollState.lastPageNumber ? 'up' : 
                           scrollState.lastDirection;
          
          if (visiblePage !== scrollState.lastPageNumber) {
            scrollState.pageChangesInInterval++;
            scrollState.lastPageNumber = visiblePage;
            
            clearTimeout(scrollState.pageChangeCheckInterval);
            scrollState.pageChangeCheckInterval = setTimeout(() => {
              scrollState.pageChangesInInterval = 0;
            }, 300);
            
            const isFast = scrollState.pageChangesInInterval >= fastScrollPageThreshold;
            
            if (isFast && !scrollState.isFastScrolling) {
              scrollState.isFastScrolling = true;
              isFastScrolling = true;
              isScrollingNow = true;
              scrollSpeedIndicator.classList.add('visible');
              
              cancelLowerPriorityRerenders('visible');
              
              window.parent.postMessage({
                type: 'scrollStateChanged',
                isScrolling: true,
                isFastScrolling: true,
                direction: direction
              }, '*');
            } else if (!isFast && scrollState.isFastScrolling) {
              scrollState.isFastScrolling = false;
              isFastScrolling = false;
              scrollSpeedIndicator.classList.remove('visible');
              
              cancelRerenders(direction);
              queueDirectionalRerenders(currentPage, direction, slowScrollRerenderCount, 'scroll');
              
              window.parent.postMessage({
                type: 'scrollStateChanged',
                isScrolling: true,
                isFastScrolling: false,
                direction: direction
              }, '*');
            }
          }
          
          if (!scrollState.isFastScrolling && scrollState.isScrolling && direction !== scrollState.lastDirection) {
            cancelRerenders(direction);
            queueDirectionalRerenders(currentPage, direction, slowScrollRerenderCount, 'scroll');
          }
          
          scrollState.lastScrollTime = now;
          scrollState.lastDirection = direction;
          scrollState.isScrolling = true;
          isScrollingNow = true;
          
          if (visiblePage !== currentPage) {
            currentPage = visiblePage;
            pageIndicatorCurrent.textContent = currentPage;
            window.parent.postMessage({ 
              type: 'pageInView', 
              page: currentPage 
            }, '*');
          }
          
          clearTimeout(scrollState.scrollTimeout);
          scrollState.scrollTimeout = setTimeout(() => {
            scrollState.isScrolling = false;
            scrollState.isFastScrolling = false;
            isFastScrolling = false;
            isScrollingNow = false;
            scrollState.pageChangesInInterval = 0;
            scrollSpeedIndicator.classList.remove('visible');
            
            const currentPage = getCurrentVisiblePage();
            
            queueDirectionalRerenders(currentPage, scrollState.lastDirection, idleRerenderCount, 'idle');
            
            window.parent.postMessage({
              type: 'scrollStopped',
              page: currentPage,
              direction: scrollState.lastDirection
            }, '*');
          }, 150);
          
          pageIndicator.classList.add('visible');
          setTimeout(() => {
            if (!scrollState.isScrolling) {
              pageIndicator.classList.remove('visible');
            }
          }, 1500);
        }, { passive: true }); // ANDROID FIX: Use passive listener
      }
      
      async function renderPage(pageNum, pdfData) {
        const pageInfo = pageElements.get(pageNum);
        if (!pageInfo) {
          console.error('No pageInfo for page ' + pageNum);
          return;
        }
        
        const lastScale = pageZoomScales.get(pageNum);
        const isFirstRender = !pageInfo.rendered;
        const needsRerender = lastScale !== undefined && Math.abs(lastScale - scale) > 0.01;
        
        if (pageInfo.rendered && !needsRerender) {
          return;
        }
        
        try {
          if (!pdfData) {
            console.error('Page ' + pageNum + ': No PDF data received');
            return;
          }
          
          const binary = atob(pdfData);
          const bytes = new Uint8Array(binary.length);
          for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
          }
          
          const loadingTask = pdfjsLib.getDocument({ 
            data: bytes,
            useSystemFonts: true,
            standardFontDataUrl: 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/standard_fonts/',
          });
          
          const pdf = await loadingTask.promise;
          const page = await pdf.getPage(1);
          
          const canvas = document.createElement('canvas');
          const ctx = canvas.getContext('2d', { 
            alpha: false,
            desynchronized: true,
            willReadFrequently: false
          });
          
          const baseScale = isMobile ? 1.2 : 1.5;
          const finalScale = scale * baseScale;
          
          const viewport = page.getViewport({ scale: finalScale, rotation: currentRotation });
          
          canvas.width = viewport.width * pixelRatio;
          canvas.height = viewport.height * pixelRatio;
          canvas.style.width = viewport.width + 'px';
          canvas.style.height = viewport.height + 'px';
          
          ctx.scale(pixelRatio, pixelRatio);
          
          const renderTask = page.render({
            canvasContext: ctx,
            viewport: viewport,
            background: 'rgba(255, 255, 255, 1)',
            intent: 'display',
          });
          
          try {
            await renderTask.promise;
          } catch (error) {
            if (error.name === 'RenderingCancelledException') {
              loadingPages.delete(pageNum);
              return;
            }
            throw error;
          }
          
          requestAnimationFrame(() => {
            pageInfo.container.innerHTML = '';
            pageInfo.container.appendChild(canvas);
            
            const pageNumber = document.createElement('div');
            pageNumber.className = 'page-number';
            pageNumber.textContent = pageNum + ' / ' + totalPages;
            pageInfo.container.appendChild(pageNumber);
            
            pageInfo.container.classList.remove('loading');
            pageInfo.container.style.width = viewport.width + 'px';
            pageInfo.container.style.height = viewport.height + 'px';
          });
          
          pageInfo.canvas = canvas;
          pageInfo.pdf = pdf;
          pageInfo.page = page;
          pageInfo.rendered = true;
          
          pageData.set(pageNum, { 
            pdf, 
            page, 
            canvas, 
            viewport,
            renderTask: null 
          });
          
          pageZoomScales.set(pageNum, scale);
          
          loadingPages.delete(pageNum);
          
        } catch (error) {
          console.error('Error rendering page ' + pageNum + ':', error);
          
          const spinner = pageInfo.container.querySelector('.loading-spinner');
          if (spinner) {
            spinner.textContent = 'Error loading page';
          }
          
          loadingPages.delete(pageNum);
        }
      }
      
      async function rerenderPageForZoom(pageNum, targetScale) {
        const data = pageData.get(pageNum);
        const pageInfo = pageElements.get(pageNum);
        if (!data || !pageInfo) return;
        
        const { page } = data;
        
        if (data.renderTask) {
          try {
            await data.renderTask.cancel();
          } catch (e) {}
        }
        
        const baseScale = isMobile ? 1.2 : 1.5;
        const finalScale = targetScale * baseScale;
        
        const viewport = page.getViewport({ scale: finalScale, rotation: currentRotation });
        
        const canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d', { 
          alpha: false,
          desynchronized: true,
          willReadFrequently: false
        });
        
        canvas.width = viewport.width * pixelRatio;
        canvas.height = viewport.height * pixelRatio;
        canvas.style.width = viewport.width + 'px';
        canvas.style.height = viewport.height + 'px';
        
        ctx.scale(pixelRatio, pixelRatio);
        
        const renderTask = page.render({
          canvasContext: ctx,
          viewport: viewport,
          background: 'rgba(255, 255, 255, 1)',
          intent: 'display',
        });
        
        data.renderTask = renderTask;
        
        try {
          await renderTask.promise;
          
          requestAnimationFrame(() => {
            const pageNumberDiv = pageInfo.container.querySelector('.page-number');
            
            pageInfo.container.innerHTML = '';
            pageInfo.container.appendChild(canvas);
            
            if (pageNumberDiv) {
              pageInfo.container.appendChild(pageNumberDiv);
            }
            
            pageInfo.container.style.width = viewport.width + 'px';
            pageInfo.container.style.height = viewport.height + 'px';
            
            pageInfo.canvas = canvas;
            data.canvas = canvas;
            data.viewport = viewport;
          });
          
          pageZoomScales.set(pageNum, targetScale);
          
        } catch (error) {
          if (error.name !== 'RenderingCancelledException') {
            console.error('Render error:', error);
          }
        } finally {
          data.renderTask = null;
        }
      }
      
      async function rotatePage(rotation) {
        currentRotation = rotation;
        
        pageZoomScales.clear();
        
        const baseScale = isMobile ? 1.2 : 1.5;
        const finalScale = scale * baseScale;
        
        for (let i = 1; i <= totalPages; i++) {
          const pageInfo = pageElements.get(i);
          if (pageInfo && pageInfo.dimensions) {
            const pageDim = pageInfo.dimensions;
            
            let widthPt = pageDim.width;
            let heightPt = pageDim.height;
            
            if (pageDim.unit === 'mm') {
              widthPt = pageDim.width * 2.83465;
              heightPt = pageDim.height * 2.83465;
            } else if (pageDim.unit === 'in') {
              widthPt = pageDim.width * 72;
              heightPt = pageDim.height * 72;
            }
            
            let displayWidth, displayHeight;
            if (rotation === 90 || rotation === 270) {
              displayWidth = heightPt * finalScale;
              displayHeight = widthPt * finalScale;
            } else {
              displayWidth = widthPt * finalScale;
              displayHeight = heightPt * finalScale;
            }
            
            pageInfo.container.style.width = displayWidth + 'px';
            pageInfo.container.style.height = displayHeight + 'px';
          }
        }
        
        const pagesToRerender = [];
        for (const [pageNum, data] of pageData) {
          if (data.page) {
            pagesToRerender.push(pageNum);
          }
        }
        
        for (const pageNum of pagesToRerender) {
          await rerenderPageForZoom(pageNum, scale);
        }
      }
      
      async function setZoom(newScale, animate = false) {
        const effectiveMaxZoom = isMobile ? maxZoomMobile : maxZoomDesktop;
        newScale = Math.max(0.1, Math.min(effectiveMaxZoom, newScale));
        
        if (Math.abs(newScale - scale) < 0.01) return;
        
        if (activeZoomAnimation) {
          cancelAnimationFrame(activeZoomAnimation);
          activeZoomAnimation = null;
        }
        
        isZooming = true;
        zoomIndicator.classList.add('visible');
        window.parent.postMessage({ type: 'zoomStateChanged', isZooming: true }, '*');
        
        const oldScale = scale;
        
        const currentPageEl = document.getElementById('page-' + currentPage);
        let scrollAnchor = null;
        
        if (currentPageEl) {
          const containerRect = container.getBoundingClientRect();
          const pageRect = currentPageEl.getBoundingClientRect();
          const relativeTop = pageRect.top - containerRect.top;
          const relativeCenter = relativeTop + (pageRect.height / 2);
          scrollAnchor = {
            pageTop: relativeTop,
            scrollTop: container.scrollTop,
            centerOffset: relativeCenter
          };
        }
        
        if (animate) {
          await animateZoomSmooth(oldScale, newScale, scrollAnchor, currentPageEl);
        } else {
          scale = newScale;
          applyZoomToAllPages(scale);
          
          if (scrollAnchor && currentPageEl) {
            const scaleRatio = scale / oldScale;
            const newScrollTop = scrollAnchor.scrollTop * scaleRatio;
            container.scrollTop = newScrollTop;
          }
          
          window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
          
          // Clean up distant pages and re-render neighbors only
          cleanupAndRerenderAfterZoom(currentPage, oldScale, newScale);
          
          isZooming = false;
          zoomIndicator.classList.remove('visible');
          window.parent.postMessage({ type: 'zoomStateChanged', isZooming: false }, '*');
        }
      }
      
      async function animateZoomSmooth(startScale, endScale, scrollAnchor, currentPageEl) {
        const duration = 200;
        const startTime = performance.now();
        
        return new Promise((resolve) => {
          function animate(currentTime) {
            const elapsed = currentTime - startTime;
            const progress = Math.min(elapsed / duration, 1);
            
            const easeProgress = 1 - Math.pow(1 - progress, 3);
            
            scale = startScale + (endScale - startScale) * easeProgress;
            
            applyZoomToAllPages(scale);
            
            if (scrollAnchor && currentPageEl) {
              const scaleRatio = scale / startScale;
              const newScrollTop = scrollAnchor.scrollTop * scaleRatio;
              container.scrollTop = newScrollTop;
            }
            
            window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
            
            if (progress < 1) {
              activeZoomAnimation = requestAnimationFrame(animate);
            } else {
              activeZoomAnimation = null;
              scale = endScale;
              
              isZooming = false;
              zoomIndicator.classList.remove('visible');
              window.parent.postMessage({ type: 'zoomStateChanged', isZooming: false }, '*');
              
              setTimeout(async () => {
                // Clean up distant pages and re-render neighbors only
                cleanupAndRerenderAfterZoom(currentPage, startScale, endScale);
                
                resolve();
              }, 50);
            }
          }
          
          activeZoomAnimation = requestAnimationFrame(animate);
        });
      }
      
      function cleanupAndRerenderAfterZoom(centerPage, oldScale, newScale) {
        const scaleRatio = newScale / oldScale;
        
        // Define neighbor range to keep and re-render
        const keepStart = centerPage - zoomRerenderNeighborRadius;
        const keepEnd = centerPage + zoomRerenderNeighborRadius;
        
        const pagesToRerender = [];
        const pagesToCleanup = [];
        
        // Categorize all pages
        for (let pageNum = 1; pageNum <= totalPages; pageNum++) {
          const pageInfo = pageElements.get(pageNum);
          if (!pageInfo || !pageInfo.rendered) continue;
          
          const lastScale = pageZoomScales.get(pageNum);
          const needsRerenderCheck = lastScale !== undefined && Math.abs(lastScale - newScale) > 0.01;
          
          if (!needsRerenderCheck) continue;
          
          // Keep and re-render neighbors
          if (pageNum >= keepStart && pageNum <= keepEnd) {
            pagesToRerender.push(pageNum);
          } else {
            // Cleanup distant pages
            pagesToCleanup.push(pageNum);
          }
        }
        
        // Re-render neighbor pages immediately
        for (const pageNum of pagesToRerender) {
          rerenderPageForZoom(pageNum, newScale);
        }
        
        // Cleanup distant pages
        for (const pageNum of pagesToCleanup) {
          const pageInfo = pageElements.get(pageNum);
          const data = pageData.get(pageNum);
          
          if (!pageInfo) continue;
          
          // Store original dimensions before cleanup
          if (data && data.viewport) {
            originalPageDimensions.set(pageNum, {
              width: data.viewport.width,
              height: data.viewport.height,
              scale: oldScale
            });
          }
          
          // Calculate new scaled dimensions
          const originalDims = originalPageDimensions.get(pageNum);
          if (originalDims) {
            const scaledWidth = originalDims.width * scaleRatio;
            const scaledHeight = originalDims.height * scaleRatio;
            
            // Update container size
            pageInfo.container.style.width = scaledWidth + 'px';
            pageInfo.container.style.height = scaledHeight + 'px';
          }
          
          // Delete PDF objects and canvas
          if (data) {
            pageData.delete(pageNum);
          }
          
          // Clear container and show loading spinner
          pageInfo.container.innerHTML = '';
          pageInfo.container.classList.add('loading');
          
          const spinner = document.createElement('div');
          spinner.className = 'loading-spinner';
          const spinnerIcon = document.createElement('div');
          spinnerIcon.className = 'spinner-icon';
          spinner.appendChild(spinnerIcon);
          pageInfo.container.appendChild(spinner);
          
          const pageNumber = document.createElement('div');
          pageNumber.className = 'page-number';
          pageNumber.textContent = pageNum + ' / ' + totalPages;
          pageInfo.container.appendChild(pageNumber);
          
          // Mark page info as not rendered
          pageInfo.canvas = null;
          pageInfo.pdf = null;
          pageInfo.page = null;
          pageInfo.rendered = false;
          
          // Mark for reload when scrolled to
          needsReload.add(pageNum);
          pageZoomScales.delete(pageNum);
        }
        
        console.log('Zoom cleanup: Re-rendered ' + pagesToRerender.length + ' neighbors, cleaned up ' + pagesToCleanup.length + ' distant pages');
      }
      
      function applyZoomToAllPages(targetScale) {
        const baseScale = isMobile ? 1.2 : 1.5;
        const finalScale = targetScale * baseScale;
        
        for (let i = 1; i <= totalPages; i++) {
          const pageInfo = pageElements.get(i);
          if (pageInfo && pageInfo.dimensions) {
            const pageDim = pageInfo.dimensions;
            
            let widthPt = pageDim.width;
            let heightPt = pageDim.height;
            
            if (pageDim.unit === 'mm') {
              widthPt = pageDim.width * 2.83465;
              heightPt = pageDim.height * 2.83465;
            } else if (pageDim.unit === 'in') {
              widthPt = pageDim.width * 72;
              heightPt = pageDim.height * 72;
            }
            
            let displayWidth, displayHeight;
            if (currentRotation === 90 || currentRotation === 270) {
              displayWidth = heightPt * finalScale;
              displayHeight = widthPt * finalScale;
            } else {
              displayWidth = widthPt * finalScale;
              displayHeight = heightPt * finalScale;
            }
            
            pageInfo.container.style.width = displayWidth + 'px';
            pageInfo.container.style.height = displayHeight + 'px';
          }
        }
      }
      
      async function rerenderVisiblePages() {
        const containerRect = container.getBoundingClientRect();
        const renderPromises = [];
        
        for (const [pageNum, data] of pageData) {
          const pageEl = document.getElementById('page-' + pageNum);
          if (pageEl) {
            const rect = pageEl.getBoundingClientRect();
            if (rect.bottom > containerRect.top && rect.top < containerRect.bottom) {
              renderPromises.push(rerenderPageForZoom(pageNum, scale));
            }
          }
        }
        
        await Promise.all(renderPromises);
      }

      function scrollToPage(pageNum) {
        const pageContainer = document.getElementById('page-' + pageNum);
        if (pageContainer) {
          const pageAbsoluteTop = pageContainer.offsetTop;
          
          container.scrollTo({
            top: pageAbsoluteTop,
            behavior: 'auto'
          });
          
          currentPage = pageNum;
          pageIndicatorCurrent.textContent = currentPage;
          window.parent.postMessage({ type: 'pageInView', page: pageNum }, '*');
        }
      }
      
      function setupKeyboardControls() {
        document.addEventListener('keydown', async (e) => {
          switch(e.key) {
            case 'ArrowDown':
            case 'PageDown':
              e.preventDefault();
              container.scrollBy({
                top: container.clientHeight * 0.9,
                behavior: 'smooth'
              });
              break;
            case 'ArrowUp':
            case 'PageUp':
              e.preventDefault();
              container.scrollBy({
                top: -container.clientHeight * 0.9,
                behavior: 'smooth'
              });
              break;
            case 'ArrowRight':
              e.preventDefault();
              if (currentPage < totalPages) {
                scrollToPage(currentPage + 1);
              }
              break;
            case 'ArrowLeft':
              e.preventDefault();
              if (currentPage > 1) {
                scrollToPage(currentPage - 1);
              }
              break;
            case 'Home':
              e.preventDefault();
              scrollToPage(1);
              break;
            case 'End':
              e.preventDefault();
              scrollToPage(totalPages);
              break;
            case '+':
            case '=':
              if (e.ctrlKey || e.metaKey) {
                e.preventDefault();
                const newScale = Math.min(maxZoom, scale + 0.2);
                await setZoom(newScale, true);
              }
              break;
            case '-':
            case '_':
              if (e.ctrlKey || e.metaKey) {
                e.preventDefault();
                const newScale = Math.max(0.1, scale - 0.2);
                await setZoom(newScale, true);
              }
              break;
            case '0':
              if (e.ctrlKey || e.metaKey) {
                e.preventDefault();
                await setZoom(1.0, true);
              }
              break;
          }
        });
      }
      
      function setupZoomControls() {
        let pinchStartDistance = 0;
        let pinchStartScale = 1.0;
        let isPinching = false;
        let pinchStarted = false;
        const pinchDeadZone = 15;
        
        // ANDROID FIX: Use passive: false only where preventDefault is needed
        container.addEventListener('wheel', async (e) => {
          if (e.ctrlKey || e.metaKey) {
            e.preventDefault();
            
            const delta = -Math.sign(e.deltaY);
            const zoomStep = 0.1;
            const newScale = Math.max(0.1, Math.min(maxZoom, scale + delta * zoomStep));
            await setZoom(newScale, false);
          }
        }, { passive: false });
        
        // ANDROID FIX: Conditional touch event handling
        container.addEventListener('touchstart', (e) => {
          if (e.touches.length === 2) {
            e.preventDefault();
            isPinching = true;
            pinchStarted = false;
            
            const touch1 = e.touches[0];
            const touch2 = e.touches[1];
            const dx = touch2.clientX - touch1.clientX;
            const dy = touch2.clientY - touch1.clientY;
            pinchStartDistance = Math.sqrt(dx * dx + dy * dy);
            pinchStartScale = scale;
            
            isPinchZooming = false;
            
            isZooming = true;
            zoomIndicator.classList.add('visible');
            window.parent.postMessage({ type: 'zoomStateChanged', isZooming: true }, '*');
          }
          // ANDROID FIX: Don't interfere with single touch (scrolling)
        }, { passive: false }); // Non-passive only for 2-finger pinch preventDefault
        
        container.addEventListener('touchmove', async (e) => {
          if (isPinching && e.touches.length === 2) {
            e.preventDefault();
            
            const touch1 = e.touches[0];
            const touch2 = e.touches[1];
            const dx = touch2.clientX - touch1.clientX;
            const dy = touch2.clientY - touch1.clientY;
            const currentDistance = Math.sqrt(dx * dx + dy * dy);
            
            const distanceChange = Math.abs(currentDistance - pinchStartDistance);
            
            if (!pinchStarted && distanceChange < pinchDeadZone) {
              return;
            }
            
            if (!pinchStarted) {
              pinchStarted = true;
              isPinchZooming = true;
            }
            
            const distanceRatio = currentDistance / pinchStartDistance;
            const scaleDelta = (distanceRatio - 1) * pinchZoomSensitivity;
            const targetScale = pinchStartScale * (1 + scaleDelta);
            const newScale = Math.max(0.1, Math.min(maxZoom, targetScale));
            
            pinchZoomScale = newScale / scale;
            
            for (const [pageNum, data] of pageData) {
              if (data.canvas) {
                data.canvas.classList.add('zooming');
                data.canvas.style.transform = 'scale(' + pinchZoomScale + ')';
              }
            }
            
            applyZoomToAllPages(newScale);
            scale = newScale;
            
            window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
          }
        }, { passive: false }); // ANDROID FIX: Non-passive for preventDefault
        
        container.addEventListener('touchend', async (e) => {
          if (isPinching && e.touches.length < 2) {
            isPinching = false;
            
            if (isPinchZooming) {
              for (const [pageNum, data] of pageData) {
                if (data.canvas) {
                  data.canvas.style.transform = '';
                  data.canvas.classList.remove('zooming');
                }
              }
              
              isPinchZooming = false;
              pinchZoomScale = 1.0;
              
              setTimeout(async () => {
                await rerenderVisiblePages();
                
                if (immediateRerenderRadius > 0) {
                  setTimeout(() => {
                    queueImmediateRerenders(currentPage, immediateRerenderRadius);
                  }, 50);
                }
                
                isZooming = false;
                zoomIndicator.classList.remove('visible');
                window.parent.postMessage({ type: 'zoomStateChanged', isZooming: false }, '*');
              }, 50);
            } else {
              isZooming = false;
              zoomIndicator.classList.remove('visible');
              window.parent.postMessage({ type: 'zoomStateChanged', isZooming: false }, '*');
            }
          }
        }, { passive: true }); // ANDROID FIX: Can be passive since no preventDefault
      }
      
      window.addEventListener('message', async (event) => {
        const data = event.data;
        
        if (data.type === 'loadPage') {
          await renderPage(data.pageNumber, data.pageData);
        } else if (data.type === 'setZoom') {
          const animate = data.animate !== undefined ? data.animate : false;
          await setZoom(data.scale, animate);
        } else if (data.type === 'rotatePage') {
          const rotation = data.rotation || 0;
          await rotatePage(rotation);
        } else if (data.type === 'goToPage') {
          scrollToPage(data.page);
        }
      });
      
      init();
    })();
  </script>
</body>
</html>
''';

    _iframeElement.srcdoc = htmlContent;
  }

  Future<void> _loadInitialPages() async {
    if (_documentInfo == null) return;

    setState(() {
      _isLoading = false;
    });

    _queuePageLoad(1);
    if (_documentInfo!.totalPages > 1) {
      _queuePageLoad(2);
    }
  }

  void _queuePageLoad(int pageNumber) {
    // Add boundary check FIRST
    if (_documentInfo != null && (pageNumber < 1 || pageNumber > _documentInfo!.totalPages)) {
      _debugLog('Skipping invalid page number: $pageNumber (total pages: ${_documentInfo!.totalPages})');
      return;
    }

    if (_loadedPages.contains(pageNumber) ||
        _loadingPages.contains(pageNumber) ||
        _loadQueue.contains(pageNumber)) {
      return;
    }

    if (_isFastScrolling) {
      _debugLog('Skipping page load during fast scroll: $pageNumber');
      return;
    }

    if (_documentInfo != null) {
      final distanceFromCurrent = (pageNumber - _currentPage).abs();
      if (distanceFromCurrent > 5) {
        return;
      }
    }

    _loadQueue.add(pageNumber);
    _processLoadQueue();
  }

  Future<void> _processLoadQueue() async {
    while (_loadingPages.length < widget.config.maxConcurrentLoads && _loadQueue.isNotEmpty) {
      final pageNumber = _loadQueue.removeAt(0);

      if (!_loadedPages.contains(pageNumber)) {
        _loadingPages.add(pageNumber);
        _loadAndSendPage(pageNumber);
      }
    }
  }

  Future<void> _loadAndSendPage(int pageNumber) async {
    if (_isRecovering) return;

    try {
      _performanceMonitor.startPageLoad(pageNumber);

      // Browser handles all caching automatically via Cache-Control headers
      final pageData = await _apiService.getPageAsPdf(widget.documentId, pageNumber)
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      _loadedPages.add(pageNumber);
      _loadingPages.remove(pageNumber);
      _performanceMonitor.endPageLoad(pageNumber);

      _sendPageToViewer(pageNumber, pageData);

      if (mounted) {
        setState(() {});
      }

      _processLoadQueue();
    } catch (e) {
      print('Error loading page $pageNumber: $e');
      _loadingPages.remove(pageNumber);
      _performanceMonitor.endPageLoad(pageNumber);

      // Retry with backoff
      Future.delayed(const Duration(seconds: 3), ()
      {
        if (mounted && !_isFastScrolling) {
          _queuePageLoad(pageNumber);
        }
      });

      _processLoadQueue();
    }
  }

  void _sendPageToViewer(int pageNumber, Uint8List pageData) {
    if (!_viewerInitialized) return;

    final base64Data = base64Encode(pageData);
    _iframeElement.contentWindow?.postMessage({
      'type': 'loadPage',
      'pageData': base64Data,
      'pageNumber': pageNumber,
    }, '*');
  }

  void _logMemoryStats() {
    if (!mounted) return;

    print('=== Memory Stats ===');
    print('Loaded Pages: ${_loadedPages.length}');
    print('Loading: ${_loadingPages.length}');
    print('Queue: ${_loadQueue.length}');
    print('Scroll: direction=$_scrollDirection, idle=$_isScrollIdle, fast=$_isFastScrolling');
    print('Browser cache handles disk storage automatically');
    print('==================');
  }

  void _goToPage(int page) {
    if (_documentInfo == null || page < 1 || page > _documentInfo!.totalPages) {
      _showPageErrorSnackbar();
      return;
    }

    HapticFeedback.selectionClick();

    if (!_loadedPages.contains(page) && !_loadingPages.contains(page)) {
      _queuePageLoad(page);
    }

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'goToPage',
        'page': page,
      }, '*');

      setState(() {
        _currentPage = page;
        _lastStableCurrentPage = page;
        _pageController.text = page.toString();
        _isEditingPage = false;
      });

      _loadPriorityPages(page);

      _pageFocusNode.unfocus();
    }
  }

  void _handlePageInput() {
    final pageText = _pageController.text.trim();
    if (pageText.isEmpty) return;

    final page = int.tryParse(pageText);
    if (page != null) {
      _goToPage(page);
    } else {
      _showPageErrorSnackbar();
    }
  }

  void _showPageErrorSnackbar() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Please enter a valid page number (1-${_documentInfo!.totalPages})'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _setZoom(double zoom, {bool animate = false}) {
    final maxZoom = _isMobile ? 3.0 : 5.0;
    final clampedZoom = zoom.clamp(0.1, maxZoom);

    setState(() {
      _zoomLevel = clampedZoom;
      _isZooming = true;
    });

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'setZoom',
        'scale': clampedZoom,
        'animate': animate,
      }, '*');
    }

    final delay = animate ? const Duration(milliseconds: 250) : const Duration(milliseconds: 150);
    Future.delayed(delay, () {
      if (mounted) {
        setState(() {
          _isZooming = false;
        });
      }
    });
  }

  void _zoomIn() {
    HapticFeedback.lightImpact();
    final newZoom = (_zoomLevel + 0.3).clamp(0.1, _isMobile ? 3.0 : 5.0);
    _setZoom(newZoom, animate: true);
  }

  void _zoomOut() {
    HapticFeedback.lightImpact();
    final newZoom = (_zoomLevel - 0.3).clamp(0.1, _isMobile ? 3.0 : 5.0);
    _setZoom(newZoom, animate: true);
  }

  void _resetZoom() {
    HapticFeedback.mediumImpact();
    _setZoom(1.0, animate: true);
  }

  void _rotatePages() {
    HapticFeedback.lightImpact();

    setState(() {
      _rotationDegrees = (_rotationDegrees + 90) % 360;
    });

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'rotatePage',
        'rotation': _rotationDegrees,
      }, '*');
    }

    _debugLog('Rotated pages to $_rotationDegrees degrees');
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 768;

    return Scaffold(
      appBar: _buildAppBar(context, isMobile),
      body: _buildBody(),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, bool isMobile) {
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _documentInfo?.title ?? widget.title,
            style: TextStyle(fontSize: isMobile ? 16 : 20),
            overflow: TextOverflow.ellipsis,
          ),
          if (_documentInfo != null)
            Text(
              '${_loadedPages.length} pages loaded • ${_documentInfo!.formattedFileSize}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: isMobile ? 11 : 13,
              ),
            ),
        ],
      ),
      actions: [
        if (!isMobile) ...[
          IconButton(
            icon: const Icon(Icons.zoom_out),
            onPressed: _zoomOut,
            tooltip: 'Zoom Out',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Center(
              child: Text(
                '${(_zoomLevel * 100).toInt()}%',
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in),
            onPressed: _zoomIn,
            tooltip: 'Zoom In',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _resetZoom,
            tooltip: 'Reset Zoom',
          ),
          const SizedBox(width: 8),
          _buildRotationButton(context),
          const SizedBox(width: 8),
        ],

        if (_documentInfo != null) _buildPageNavigation(context, isMobile),
      ],
    );
  }

  Widget _buildRotationButton(BuildContext context) {
    return Tooltip(
      message: 'Rotate Page ($_rotationDegrees°)',
      child: InkWell(
        onTap: _rotatePages,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(8),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.rotate(
                angle: _rotationDegrees * math.pi / 180,
                child: Icon(
                  Icons.crop_rotate,
                  size: 24,
                  color: Theme.of(context).iconTheme.color,
                ),
              ),
              if (_rotationDegrees > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: Theme.of(context).primaryColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_rotationDegrees}°',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageNavigation(BuildContext context, bool isMobile) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMobile)
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: _currentPage > 1
                  ? () => _goToPage(_currentPage - 1)
                  : null,
              tooltip: 'Previous Page',
              iconSize: 20,
            ),

          Container(
            width: isMobile ? 80 : 100,
            height: 36,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isEditingPage
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outline.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pageController,
                    focusNode: _pageFocusNode,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: isMobile ? 14 : 16,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      isDense: true,
                    ),
                    onTap: () {
                      setState(() {
                        _isEditingPage = true;
                      });
                      _pageController.selection = TextSelection(
                        baseOffset: 0,
                        extentOffset: _pageController.text.length,
                      );
                    },
                    onSubmitted: (value) => _handlePageInput(),
                    onEditingComplete: _handlePageInput,
                  ),
                ),

                if (_isEditingPage || isMobile)
                  Container(
                    width: 24,
                    height: 24,
                    margin: const EdgeInsets.only(right: 4),
                    child: IconButton(
                      icon: Icon(
                        Icons.arrow_forward,
                        size: 16,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      onPressed: _handlePageInput,
                      padding: EdgeInsets.zero,
                      tooltip: 'Go to Page',
                    ),
                  ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'of ${_documentInfo!.totalPages}',
              style: TextStyle(
                fontSize: isMobile ? 12 : 14,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
          ),

          if (!isMobile)
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: _currentPage < _documentInfo!.totalPages
                  ? () => _goToPage(_currentPage + 1)
                  : null,
              tooltip: 'Next Page',
              iconSize: 20,
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Error loading PDF',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadDocument,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              if (_errorCount > 1) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _recoverFromError,
                  icon: const Icon(Icons.autorenew),
                  label: const Text('Advanced Recovery'),
                ),
              ]
            ],
          ),
        ),
      );
    }

    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _isRecovering ? 'Recovering...' : 'Initializing...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      );
    }

    // ignore: undefined_prefixed_name
    return HtmlElementView(viewType: _viewId);
  }

  @override
  void dispose() {
    _visiblePageCheckTimer?.cancel();
    _memoryStatsTimer?.cancel();
    _pageController.dispose();
    _pageFocusNode.dispose();

    if (widget.config.enablePerformanceMonitoring) {
      final metrics = _performanceMonitor.getMetrics();
      print('PDF Viewer Session Metrics: $metrics');
      _logMemoryStats();
    }

    super.dispose();
  }
}