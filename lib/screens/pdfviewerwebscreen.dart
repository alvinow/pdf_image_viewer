import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf_image_viewer/appconfig.dart';
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:typed_data';
import '../services/pdf_api_service.dart';
import '../models/document_info.dart';

class PdfViewerConfig {
  final int cacheSize;
  final int maxConcurrentLoads;
  final int cacheWindowSize;
  final Duration cleanupInterval;
  final int maxMemoryMB;
  final bool enablePerformanceMonitoring;
  final bool enableAutoRetry;
  final bool enableDebugLogging;

  const PdfViewerConfig({
    this.cacheSize = 10,
    this.maxConcurrentLoads = 10,
    this.cacheWindowSize = 10,
    this.cleanupInterval = const Duration(seconds: 3),
    this.maxMemoryMB = 100,
    this.enablePerformanceMonitoring = true,
    this.enableAutoRetry = true,
    this.enableDebugLogging = false,
  });
}

class PdfViewerWebScreen extends StatefulWidget {
  final String documentId;
  final String? apiBaseUrl;
  final String title;
  final PdfViewerConfig config;

  const PdfViewerWebScreen({
    Key? key,
    required this.documentId,
    this.apiBaseUrl,
    required this.title,
    this.config = const PdfViewerConfig(),
  }) : super(key: key);

  @override
  State<PdfViewerWebScreen> createState() => _PdfViewerWebScreenState();
}

class _SmartPageCache {
  final Map<int, Uint8List> _cache = {};
  final List<int> _accessOrder = [];
  final Map<int, DateTime> _accessTimes = {};
  final int _maxSize;
  final int _maxMemoryBytes;

  _SmartPageCache({int maxSize = 20, int maxMemoryMB = 50})
      : _maxSize = maxSize,
        _maxMemoryBytes = maxMemoryMB * 1024 * 1024;

  void put(int page, Uint8List data) {
    while (_shouldEvict(data.length)) {
      _evictOldest();
    }

    _cache[page] = data;
    _updateAccess(page);
  }

  Uint8List? get(int page) {
    final data = _cache[page];
    if (data != null) {
      _updateAccess(page);
    }
    return data;
  }

  bool contains(int page) => _cache.containsKey(page);

  void remove(int page) {
    _cache.remove(page);
    _accessOrder.remove(page);
    _accessTimes.remove(page);
  }

  void clear() {
    _cache.clear();
    _accessOrder.clear();
    _accessTimes.clear();
  }

  Iterable<int> get keys => _cache.keys;

  int get size => _cache.length;

  int get totalMemory => _cache.values.fold<int>(0, (sum, data) => sum + data.length);

  bool _shouldEvict(int newDataSize) {
    if (_cache.length >= _maxSize) return true;
    if (totalMemory + newDataSize > _maxMemoryBytes) return true;
    return false;
  }

  void _evictOldest() {
    if (_accessOrder.isEmpty) {
      if (_cache.isNotEmpty) {
        final firstKey = _cache.keys.first;
        remove(firstKey);
      }
      return;
    }

    final oldestPage = _accessOrder.first;
    remove(oldestPage);
  }

  void _updateAccess(int page) {
    _accessOrder.remove(page);
    _accessOrder.add(page);
    _accessTimes[page] = DateTime.now();
  }

  List<int> getPagesToEvict(int currentPage, int keepWindow) {
    return _cache.keys.where((page) =>
    (page - currentPage).abs() > keepWindow
    ).toList();
  }
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

  // PDF.js specific
  late html.IFrameElement _iframeElement;
  final String _viewId = 'pdf-viewer-${DateTime.now().millisecondsSinceEpoch}';
  bool _viewerInitialized = false;

  // Enhanced caching and memory management
  final _SmartPageCache _pageCache = _SmartPageCache();
  final Set<int> _loadingPages = {};
  final List<int> _loadQueue = [];

  // Scroll control
  int _lastStableCurrentPage = 1;
  DateTime _lastScrollTime = DateTime.now();
  bool _isScrolling = false;
  bool _isZooming = false;

  // Scroll prevention after zoom
  Timer? _scrollPreventionTimer;
  bool _isScrollPrevented = false;
  DateTime? _lastZoomTime;

  // Memory management and error recovery
  Timer? _cleanupTimer;
  Timer? _memoryMonitorTimer;
  final Map<int, DateTime> _pageAccessTimes = {};
  final List<int> _pageAccessOrder = [];
  int _errorCount = 0;
  DateTime? _lastErrorTime;
  bool _isRecovering = false;

  // Performance monitoring
  final _PdfPerformanceMonitor _performanceMonitor = _PdfPerformanceMonitor();
  DateTime? _currentPageViewStart;

  // Page navigation
  final TextEditingController _pageController = TextEditingController();
  final FocusNode _pageFocusNode = FocusNode();
  bool _isEditingPage = false;

  // Mobile detection
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

    // Start periodic cleanup and monitoring
    _cleanupTimer = Timer.periodic(widget.config.cleanupInterval, (_) => _performPeriodicCleanup());
    _memoryMonitorTimer = Timer.periodic(const Duration(seconds: 10), (_) => _monitorMemoryUsage());

    // Update page controller when current page changes
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

  void _debugMemoryLog() {
    if (widget.config.enableDebugLogging) {
      final totalMemory = _pageCache.totalMemory;
      final memoryMB = (totalMemory / (1024 * 1024)).toStringAsFixed(2);
      print('[MEMORY] ${memoryMB}MB | ${_pageCache.size} pages cached | ${_loadingPages.length} loading | ${_loadQueue.length} queued');
    }
  }

  void _initializePdfViewer() {
    _iframeElement = html.IFrameElement()
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%';

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
              // Record previous page view duration
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
              _updatePageAccess(pageNum);

              // Ensure current page is loaded when it comes into view
              if (!_pageCache.contains(pageNum) && !_loadingPages.contains(pageNum)) {
                print('Page $pageNum in view but not loaded, requesting load');
                _queuePageLoad(pageNum);
              }
            }
          }
          break;

        case 'scrollStateChanged':
          final isScrolling = data['isScrolling'];
          final isFastScrolling = data['isFastScrolling'];
          if (isScrolling != null) {
            _handleScrollStateChange(isScrolling as bool);
          }
          break;

        case 'scrollStopped':
          final page = data['page'];
          final wasFastScrolling = data['wasFastScrolling'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null) {
              _handleScrollStopped(pageNum);
            }
          }
          break;

        case 'viewerReady':
          print('Viewer ready, initializing pages');
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
              // Only queue if not already cached or loading
              if (!_pageCache.contains(pageNum) && !_loadingPages.contains(pageNum)) {
                print('Page $pageNum requested');
                _queuePageLoad(pageNum);
              }
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

              // Prevent scrolling for 2 seconds after zoom
              _preventScrollingAfterZoom();

              // Force a re-check of the current page after zoom
              if (_viewerInitialized) {
                Timer(const Duration(milliseconds: 300), () {
                  _iframeElement.contentWindow?.postMessage({
                    'type': 'getCurrentPage',
                  }, '*');
                });
              }
            }
          }
          break;

        case 'currentPageReport':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null && pageNum != _currentPage) {
              print('Zoom corrected page from $_currentPage to $pageNum');
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
            _setIframePointerEvents(!_isZooming);
            if (_isZooming) {
              print('Zooming started - disabling non-critical operations');
              // Cancel any existing prevention timer when new zoom starts
              _scrollPreventionTimer?.cancel();
            } else {
              print('Zooming ended - scroll prevention active for 2 seconds');
              // Start scroll prevention when zoom ends
              _preventScrollingAfterZoom();
            }
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

        case 'lowMemory':
          _handleLowMemory();
          break;
      }
    } catch (e) {
      print('Error handling PDF.js message: $e');
    }
  }

  void _preventScrollingAfterZoom() {
    _scrollPreventionTimer?.cancel();

    // Longer prevention on mobile
    final preventionDuration = _isMobile
        ? const Duration(seconds: 2)
        : const Duration(seconds: 1);

    setState(() {
      _isScrollPrevented = true;
      _lastZoomTime = DateTime.now();
    });

    print('Scroll prevention activated for ${preventionDuration.inSeconds} seconds');

    _scrollPreventionTimer = Timer(preventionDuration, () {
      if (mounted) {
        setState(() {
          _isScrollPrevented = false;
        });
        print('Scroll prevention deactivated');
      }
    });
  }

  void _handleScrollStateChange(bool isScrolling) {
    // Don't process scroll events during scroll prevention
    if (_isScrollPrevented) {
      return;
    }

    _isScrolling = isScrolling;
    _lastScrollTime = DateTime.now();

    if (isScrolling && !_isZooming) {
      // AGGRESSIVE: Cancel ALL loads saat fast scrolling
      _cancelNonCriticalLoads();

      // BARU: Cleanup memory SELAMA scrolling, tidak tunggu stop
      _aggressiveCleanupDuringScroll();
    }
  }

  void _aggressiveCleanupDuringScroll() {
    if (_documentInfo == null) return;

    _debugLog('Starting aggressive cleanup during scroll');

    // Keep ONLY current page during fast scroll
    final pagesToKeep = {_currentPage};

    final keysToRemove = _pageCache.keys
        .where((page) => !pagesToKeep.contains(page))
        .toList();

    // Remove dari cache
    for (final key in keysToRemove) {
      _removePageFromCache(key);
    }

    // Clear semua queue
    _loadQueue.clear();

    // Cancel semua loading kecuali current page
    final loadingToCancel = _loadingPages
        .where((page) => page != _currentPage)
        .toList();

    for (final page in loadingToCancel) {
      _loadingPages.remove(page);
    }

    if (keysToRemove.isNotEmpty) {
      _debugLog('AGGRESSIVE CLEANUP: Removed ${keysToRemove.length} pages, kept only page $_currentPage');
      _debugLog('Cancelled ${loadingToCancel.length} loading operations');
    }

    _debugMemoryLog();
  }

  void _handleScrollStopped(int pageNum) {
    _debugLog('Scroll stopped at page $pageNum');
    _isScrolling = false;
    _lastStableCurrentPage = pageNum;

    // Force immediate load of current page if not loaded
    if (!_pageCache.contains(pageNum) && !_loadingPages.contains(pageNum)) {
      _debugLog('Current page $pageNum not loaded, forcing immediate load');
      _loadingPages.add(pageNum);
      _loadAndSendPage(pageNum);
    }

    // REDUCED: Hanya preload 1 halaman ke depan/belakang untuk dokumen besar
    if (_documentInfo != null && _documentInfo!.totalPages > 100) {
      _preloadNearbyPagesReduced(pageNum);
    } else {
      _preloadNearbyPages(pageNum);
    }

    _cleanupDistantPages(pageNum);
    _debugMemoryLog();
  }

  void _preloadNearbyPagesReduced(int currentPage) {
    if (_documentInfo == null) return;

    // Only check scroll prevention if we're CURRENTLY scrolling
    if (_isScrollPrevented && _isScrolling) {
      print('Skipping preload (scroll prevention active during scroll)');
      return;
    }

    if (_isScrolling && !_isZooming) {
      print('Skipping preload (scrolling)');
      return;
    }

    // REDUCED: Hanya 1 halaman depan/belakang untuk dokumen besar
    final pagesToLoad = <int>[];

    // Current page first
    if (!_pageCache.contains(currentPage) && !_loadingPages.contains(currentPage)) {
      pagesToLoad.add(currentPage);
    }

    // Only next page
    final nextPage = currentPage + 1;
    if (nextPage <= _documentInfo!.totalPages &&
        !_pageCache.contains(nextPage) &&
        !_loadingPages.contains(nextPage)) {
      pagesToLoad.add(nextPage);
    }

    // Only previous page
    final prevPage = currentPage - 1;
    if (prevPage >= 1 &&
        !_pageCache.contains(prevPage) &&
        !_loadingPages.contains(prevPage)) {
      pagesToLoad.add(prevPage);
    }

    for (final page in pagesToLoad) {
      _queuePageLoad(page);
    }

    if (pagesToLoad.isNotEmpty) {
      print('Preloading (reduced) ${pagesToLoad.length} pages around page $currentPage');
    }
  }

  void _cancelNonCriticalLoads() {
    _loadQueue.clear();

    final toCancel = <int>[];
    for (final pageNum in _loadingPages) {
      if ((pageNum - _currentPage).abs() > 1) {
        toCancel.add(pageNum);
      }
    }

    for (final pageNum in toCancel) {
      _loadingPages.remove(pageNum);
    }

    print('Cancelled ${toCancel.length} non-critical loads');
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
        _errorCount = 0; // Reset error count on success
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

    // Auto-retry for transient errors
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
      // Clear all state
      _cleanupAllResources();

      // Re-initialize
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

    // Prepare page dimensions data from DocumentInfo
    final pageDimensionsJson = _documentInfo!.pages?.map((pageInfo) {
      return {
        'pageNumber': pageInfo.pageNumber,
        'width': pageInfo.dimensions.width,
        'height': pageInfo.dimensions.height,
        'unit': pageInfo.dimensions.unit,
      };
    }).toList() ?? [];

    final pageDimensionsJsonString = jsonEncode(pageDimensionsJson);

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
      scroll-behavior: smooth;
      padding: 0 20px;
    }
    #pages-wrapper {
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 20px 0;
      gap: 20px;
      min-width: min-content;
      transform-origin: center top;
      backface-visibility: hidden;
      -webkit-backface-visibility: hidden;
      perspective: 1000px;
      -webkit-perspective: 1000px;
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
    }
    .page-container.loading {
      background: #f5f5f5;
    }
    canvas {
      display: block;
      background: white;
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
    }
    .loading-spinner {
      color: #666;
      font-size: 14px;
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
    .memory-warning {
      position: fixed;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      background: rgba(255, 152, 0, 0.95);
      color: white;
      padding: 16px 24px;
      border-radius: 8px;
      font-size: 14px;
      font-weight: 600;
      box-shadow: 0 4px 12px rgba(0,0,0,0.3);
      opacity: 0;
      transition: opacity 0.3s ease;
      pointer-events: none;
      z-index: 1002;
      text-align: center;
    }
    .memory-warning.visible {
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
    Zooming - Scroll Disabled
  </div>
  <div id="memory-warning" class="memory-warning" role="alert" aria-live="assertive">
    Low Memory - Clearing Cache
  </div>

  <script type="module">
    const pdfjsLib = await import('https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.min.mjs');
    pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.worker.min.mjs';

    // Mobile detection and memory optimization
    const isAndroid = /Android/i.test(navigator.userAgent);
    const isIOS = /iPhone|iPad|iPod/i.test(navigator.userAgent);
    const isMobile = isAndroid || isIOS;
    
    // Reduce pixel ratio for mobile to save memory
    const pixelRatio = isMobile ? 
      Math.min(window.devicePixelRatio || 1, 1.5) : 
      window.devicePixelRatio || 1;

    // Mobile-specific zoom limits
    const maxZoomMobile = 2.0;
    const maxZoomDesktop = 3.0;
    const maxZoom = isMobile ? maxZoomMobile : maxZoomDesktop;

    console.log('Device detected:', { isAndroid, isIOS, isMobile, pixelRatio, maxZoom });

    const container = document.getElementById('pdf-container');
    const pagesWrapper = document.getElementById('pages-wrapper');
    
    let scale = 1.0;
    let currentPage = 1;
    const totalPages = ''' + _documentInfo!.totalPages.toString() + r''';
    const pageDimensions = ''' + pageDimensionsJsonString + r''';
    const pageData = new Map();
    const pageElements = new Map();
    const loadingPages = new Set();
    const pageIndicator = document.getElementById('page-indicator');
    const pageIndicatorCurrent = pageIndicator.querySelector('.current');
    const pageIndicatorTotal = pageIndicator.querySelector('.total');
    const scrollSpeedIndicator = document.getElementById('scroll-speed-indicator');
    const zoomIndicator = document.getElementById('zoom-indicator');
    const memoryWarning = document.getElementById('memory-warning');
    
    let scrollTimeout = null;
    let isScrolling = false;
    let scrollStopTimeout = null;
    const SCROLL_STOP_DELAY = 600;
    
    let isZooming = false;
    let zoomEndTime = 0;
    const SCROLL_PREVENTION_DURATION = isMobile ? 2000 : 1000;
    
    const rerenderDebounce = new Map();
    let zoomThrottle = null;
    let pendingZoomScale = null;
    
    function init() {
      console.log('Initializing viewer with', totalPages, 'pages');
      console.log('Page dimensions available:', pageDimensions.length, 'pages');
      
      const containerWidth = container.clientWidth - 40;
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
          pageContainer.style.minHeight = 'auto';
          pageContainer.style.maxHeight = 'none';
          
          console.log('Page', i, 'pre-sized:', displayWidth.toFixed(0), 'x', displayHeight.toFixed(0), 'px');
        } else {
          pageContainer.style.width = '100%';
          pageContainer.style.height = 'auto';
          pageContainer.style.minHeight = '400px';
          console.warn('No dimension data for page', i);
        }
        
        const spinner = document.createElement('div');
        spinner.className = 'loading-spinner';
        spinner.textContent = 'Loading page ' + i + '...';
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
      
      console.log('Viewer ready with pre-sized pages');
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

    function reportCurrentPage() {
      const visiblePage = getCurrentVisiblePage();
      window.parent.postMessage({ 
        type: 'currentPageReport', 
        page: visiblePage 
      }, '*');
    }

    function clearPreviousPages(targetPage) {
      for (let i = 1; i < targetPage; i++) {
        const pageContainer = document.getElementById('page-' + i);
        if (pageContainer && pageContainer.offsetHeight > 0) {
          if (pageElements.get(i)?.rendered) {
            pageContainer.innerHTML = '';
            const spinner = document.createElement('div');
            spinner.className = 'loading-spinner';
            spinner.textContent = 'Loading page ' + i + '...';
            pageContainer.appendChild(spinner);
            
            const pageNumber = document.createElement('div');
            pageNumber.className = 'page-number';
            pageNumber.textContent = i + ' / ' + totalPages;
            pageContainer.appendChild(pageNumber);
            
            pageContainer.classList.add('loading');
            
            const pageInfo = pageElements.get(i);
            if (pageInfo && pageInfo.dimensions) {
              const pageDim = pageInfo.dimensions;
              const containerWidth = container.clientWidth;
              const baseScale = isMobile ? 1.2 : 1.5;
              const finalScale = scale * baseScale;
              
              let widthPt = pageDim.width;
              let heightPt = pageDim.height;
              
              if (pageDim.unit === 'mm') {
                widthPt = pageDim.width * 2.83465;
                heightPt = pageDim.height * 2.83465;
              } else if (pageDim.unit === 'in') {
                widthPt = pageDim.width * 72;
                heightPt = pageDim.height * 72;
              }
              
              const displayWidth = widthPt * finalScale;
              const displayHeight = heightPt * finalScale;
              
              pageContainer.style.width = displayWidth + 'px';
              pageContainer.style.height = displayHeight + 'px';
              pageContainer.style.minHeight = 'auto';
              pageContainer.style.maxHeight = 'none';
            } else {
              pageContainer.style.height = 'auto';
              pageContainer.style.minHeight = '400px';
            }
            
            if (pageInfo) {
              pageInfo.rendered = false;
              pageInfo.canvas = null;
              if (pageInfo.pdf) {
                pageInfo.pdf.destroy();
                pageInfo.pdf = null;
              }
            }
            pageData.delete(i);
          }
        }
      }
      
      container.scrollTop = container.scrollTop;
    }
    
    function setupScrollListener() {
  pageIndicatorTotal.textContent = 'of ' + totalPages;
  
  let indicatorTimeout;
  let lastReportedPage = currentPage;
  let rapidPageChangeCount = 0;
  let lastPageChangeTime = 0;
  const RAPID_CHANGE_THRESHOLD = 3;
  const RAPID_CHANGE_TIMEFRAME = 1000;
  let isFastScrolling = false;
  
  // Track pending requests to prevent duplicates
  const pendingRequests = new Set();
  let requestDebounceTimers = new Map();
  
  function forceUpdateCurrentPage() {
    const visiblePage = getCurrentVisiblePage();
    if (visiblePage !== currentPage) {
      currentPage = visiblePage;
      pageIndicatorCurrent.textContent = currentPage;
      window.parent.postMessage({ type: 'pageInView', page: currentPage }, '*');
      lastReportedPage = currentPage;
      console.log('Forced page update to:', currentPage);
    }
  }
  
  window.forceUpdateCurrentPage = forceUpdateCurrentPage;
  
  // Helper function to request page with debouncing
  function requestPageLoad(pageNum) {
    // Skip if already loaded, loading, or pending request
    if (pageData.has(pageNum) || loadingPages.has(pageNum) || pendingRequests.has(pageNum)) {
      return;
    }
    
    // Clear any existing debounce timer for this page
    if (requestDebounceTimers.has(pageNum)) {
      clearTimeout(requestDebounceTimers.get(pageNum));
    }
    
    // Debounce the request
    const timer = setTimeout(() => {
      if (!pageData.has(pageNum) && !loadingPages.has(pageNum)) {
        pendingRequests.add(pageNum);
        loadingPages.add(pageNum);
        console.log('Page', pageNum, 'visible but not loaded, requesting');
        window.parent.postMessage({ type: 'requestPage', page: pageNum }, '*');
        
        // Clear pending flag after a delay (in case request fails)
        setTimeout(() => {
          pendingRequests.delete(pageNum);
        }, 5000);
      }
      requestDebounceTimers.delete(pageNum);
    }, 100); // 100ms debounce
    
    requestDebounceTimers.set(pageNum, timer);
  }
  
  const observer = new IntersectionObserver((entries) => {
    if (isZooming || isFastScrolling || (Date.now() - zoomEndTime) < SCROLL_PREVENTION_DURATION) {
      return;
    }
    
    let mostVisiblePage = currentPage;
    let highestVisibility = 0;
    
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        const pageNum = parseInt(entry.target.id.split('-')[1]);
        const visibility = entry.intersectionRatio;
        
        if (visibility > highestVisibility) {
          highestVisibility = visibility;
          mostVisiblePage = pageNum;
        }
        
        // Use debounced request function instead of direct postMessage
        if (visibility > 0.1) {
          requestPageLoad(pageNum);
        }
      }
    });
    
    if (mostVisiblePage !== currentPage && highestVisibility > 0.3) {
      const now = Date.now();
      const timeSinceLastChange = now - lastPageChangeTime;
      
      if (timeSinceLastChange < 200) {
        rapidPageChangeCount++;
        
        if (rapidPageChangeCount >= RAPID_CHANGE_THRESHOLD && !isFastScrolling) {
          isFastScrolling = true;
          scrollSpeedIndicator.classList.add('visible');
          window.parent.postMessage({ 
            type: 'scrollStateChanged', 
            isScrolling: true,
            isFastScrolling: true 
          }, '*');
          console.log('Fast scrolling detected');
        }
      } else {
        if (timeSinceLastChange > 500) {
          rapidPageChangeCount = 0;
        }
      }
      
      lastPageChangeTime = now;
      currentPage = mostVisiblePage;
      updatePageIndicator();
      
      if (Math.abs(currentPage - lastReportedPage) >= 1) {
        window.parent.postMessage({ type: 'pageInView', page: currentPage }, '*');
        lastReportedPage = currentPage;
      }
    }
  }, {
    root: container,
    rootMargin: '0px',
    threshold: [0.1, 0.3, 0.5, 0.7, 0.9]
  });
  
  let scrollStopTimeout;
  
  container.addEventListener('scroll', () => {
    const isScrollPrevented = isZooming || (Date.now() - zoomEndTime) < SCROLL_PREVENTION_DURATION;
    
    if (isScrollPrevented) {
      return;
    }
    
    pageIndicator.classList.add('visible');
    clearTimeout(indicatorTimeout);
    indicatorTimeout = setTimeout(() => {
      pageIndicator.classList.remove('visible');
    }, 1500);
    
    clearTimeout(scrollStopTimeout);
    
    scrollStopTimeout = setTimeout(() => {
      if (isFastScrolling) {
        isFastScrolling = false;
        rapidPageChangeCount = 0;
        scrollSpeedIndicator.classList.remove('visible');
        window.parent.postMessage({ 
          type: 'scrollStopped', 
          page: currentPage,
          wasFastScrolling: true 
        }, '*');
        console.log('Fast scrolling stopped at page', currentPage);
      } else {
        window.parent.postMessage({ 
          type: 'scrollStopped', 
          page: currentPage,
          wasFastScrolling: false 
        }, '*');
        console.log('Scroll stopped at page', currentPage);
      }
      
      // Use debounced request
      requestPageLoad(currentPage);
    }, SCROLL_STOP_DELAY);
  });
  
  pageElements.forEach((data, pageNum) => {
    observer.observe(data.container);
  });
  
  function updatePageIndicator() {
    pageIndicatorCurrent.textContent = currentPage;
  }
  
  // Clear pending flag when page is actually loaded
  window.clearPendingRequest = function(pageNum) {
    pendingRequests.delete(pageNum);
    loadingPages.delete(pageNum);
  };
}
    
    async function renderPage(pageNum, pdfData) {
  const pageInfo = pageElements.get(pageNum);
  if (!pageInfo || pageInfo.rendered) {
    if (window.clearPendingRequest) {
      window.clearPendingRequest(pageNum);
    }
    return;
  }
  
  try {
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
    const ctx = canvas.getContext('2d', { alpha: false });
    
    const containerWidth = container.clientWidth;
    const baseScale = isMobile ? 1.2 : 1.5;
    const finalScale = scale * baseScale;
    
    const viewport = page.getViewport({ scale: finalScale });
    
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
        console.log('Render cancelled for page', pageNum);
        loadingPages.delete(pageNum);
        if (window.clearPendingRequest) {
          window.clearPendingRequest(pageNum);
        }
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
      pageInfo.container.style.minHeight = 'auto';
      pageInfo.container.style.maxHeight = 'none';
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
    
    loadingPages.delete(pageNum);
    if (window.clearPendingRequest) {
      window.clearPendingRequest(pageNum);
    }
    
  } catch (error) {
    console.error('Error rendering page ' + pageNum + ':', error);
    
    const spinner = pageInfo.container.querySelector('.loading-spinner');
    if (spinner) {
      spinner.textContent = 'Error loading page';
    }
    
    loadingPages.delete(pageNum);
    if (window.clearPendingRequest) {
      window.clearPendingRequest(pageNum);
    }
  }
}
    
    async function rerenderPage(pageNum) {
      return rerenderPageWithoutReflow(pageNum);
    }
    
    async function setZoomThrottled(newScale) {
      pendingZoomScale = newScale;
      
      if (zoomThrottle) return;
      
      zoomThrottle = setTimeout(() => {
        if (pendingZoomScale !== null) {
          setZoom(pendingZoomScale);
          pendingZoomScale = null;
        }
        zoomThrottle = null;
      }, 50);
    }
    
    async function setZoom(newScale) {
      // Use mobile-specific max zoom
      const effectiveMaxZoom = isMobile ? maxZoomMobile : maxZoomDesktop;
      if (newScale === scale || Math.abs(newScale - scale) < 0.01) return;
      if (isZooming) return;
      
      // Clamp zoom for mobile
      newScale = Math.max(0.5, Math.min(effectiveMaxZoom, newScale));
      
      isZooming = true;
      zoomIndicator.classList.add('visible');
      
      const oldScale = scale;
      const scaleChange = newScale / oldScale;

      // For mobile: Clear distant pages before zoom to free memory
      if (isMobile) {
        const currentPage = getCurrentVisiblePage();
        for (let [pageNum, data] of pageData) {
          if (Math.abs(pageNum - currentPage) > 2) {
            // Clear canvas to free memory
            if (data.canvas) {
              const ctx = data.canvas.getContext('2d');
              if (ctx) {
                ctx.clearRect(0, 0, data.canvas.width, data.canvas.height);
              }
            }
          }
        }
      }

      const containerRect = container.getBoundingClientRect();
      const scrollTop = container.scrollTop;
      const scrollLeft = container.scrollLeft;
      const viewportCenterY = scrollTop + (containerRect.height / 2);
      
      let anchorPageNum = currentPage;
      let anchorPageTop = 0;
      const anchorPageEl = document.getElementById('page-' + currentPage);
      
      if (anchorPageEl) {
        anchorPageTop = anchorPageEl.offsetTop;
      }
      
      const offsetFromPageTop = viewportCenterY - anchorPageTop;
      
      pagesWrapper.style.transform = `scale(${scaleChange})`;
      pagesWrapper.style.transformOrigin = `center ${viewportCenterY}px`;
      pagesWrapper.style.transition = 'none';
      
      scale = newScale;
      
      setTimeout(() => {
        const containerWidth = container.clientWidth;
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
            
            const displayWidth = widthPt * finalScale;
            const displayHeight = heightPt * finalScale;
            
            if (!pageInfo.rendered) {
              pageInfo.container.style.width = displayWidth + 'px';
              pageInfo.container.style.height = displayHeight + 'px';
              pageInfo.container.style.minHeight = 'auto';
              pageInfo.container.style.maxHeight = 'none';
            }
          }
        }
        
        pagesWrapper.style.transform = '';
        pagesWrapper.style.transformOrigin = '';
        
        const newAnchorPageEl = document.getElementById('page-' + anchorPageNum);
        if (newAnchorPageEl) {
          const newAnchorPageTop = newAnchorPageEl.offsetTop;
          const newOffsetFromPageTop = offsetFromPageTop * scaleChange;
          const newScrollTop = newAnchorPageTop + newOffsetFromPageTop - (containerRect.height / 2);
          
          container.scrollTop = Math.max(0, newScrollTop);
          container.scrollLeft = scrollLeft;
        }
        
        setTimeout(async () => {
          const visiblePages = [];
          const currentRect = container.getBoundingClientRect();
          
          for (const [pageNum, data] of pageData) {
            const pageEl = document.getElementById('page-' + pageNum);
            if (pageEl) {
              const rect = pageEl.getBoundingClientRect();
              if (rect.bottom > currentRect.top && rect.top < currentRect.bottom) {
                visiblePages.push(pageNum);
              }
            }
          }
          
          for (const pageNum of visiblePages) {
            await rerenderPageWithoutReflow(pageNum);
          }
          
          setTimeout(() => {
            for (const [pageNum, data] of pageData) {
              if (!visiblePages.includes(pageNum) && Math.abs(pageNum - currentPage) <= 3) {
                rerenderPageWithoutReflow(pageNum);
              }
            }
          }, 100);
          
          isZooming = false;
          zoomEndTime = Date.now();
          zoomIndicator.classList.remove('visible');
          
          window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
          
          // Force page indicator update after zoom
          setTimeout(() => {
            if (window.forceUpdateCurrentPage) {
              window.forceUpdateCurrentPage();
            }
          }, 100);
        }, 50);
      }, 16);
    }

    async function rerenderPageWithoutReflow(pageNum) {
      const data = pageData.get(pageNum);
      const pageInfo = pageElements.get(pageNum);
      if (!data || !pageInfo) return;
      
      const { page, canvas } = data;
      
      if (data.renderTask) {
        try {
          await data.renderTask.cancel();
        } catch (e) {}
      }
      
      const containerWidth = container.clientWidth;
      const baseScale = isMobile ? 1.2 : 1.5;
      const finalScale = scale * baseScale;
      
      const viewport = page.getViewport({ scale: finalScale });
      
      const offscreenCanvas = document.createElement('canvas');
      const ctx = offscreenCanvas.getContext('2d', { 
        alpha: false,
        desynchronized: true 
      });
      
      offscreenCanvas.width = viewport.width * pixelRatio;
      offscreenCanvas.height = viewport.height * pixelRatio;
      offscreenCanvas.style.width = viewport.width + 'px';
      offscreenCanvas.style.height = viewport.height + 'px';
      
      ctx.scale(pixelRatio, pixelRatio);
      
      const renderTask = page.render({
        canvasContext: ctx,
        viewport: viewport,
        background: 'rgba(255, 255, 255, 1)',
      });
      
      data.renderTask = renderTask;
      
      try {
        await renderTask.promise;
        
        const pageNumberDiv = pageInfo.container.querySelector('.page-number');
        pageInfo.container.innerHTML = '';
        
        pageInfo.container.appendChild(offscreenCanvas);
        
        if (pageNumberDiv) {
          pageInfo.container.appendChild(pageNumberDiv);
        }
        
        pageInfo.container.style.width = viewport.width + 'px';
        pageInfo.container.style.height = viewport.height + 'px';
        pageInfo.container.style.minHeight = 'auto';
        pageInfo.container.style.maxHeight = 'none';
        
        pageInfo.canvas = offscreenCanvas;
        data.canvas = offscreenCanvas;
        
      } catch (error) {
        if (error.name !== 'RenderingCancelledException') {
          console.error('Render error:', error);
        }
      } finally {
        data.renderTask = null;
      }
      
      if (data) {
        data.viewport = viewport;
      }
    }
    
    function scrollToPage(pageNum) {
      const pageContainer = document.getElementById('page-' + pageNum);
      if (pageContainer) {
        console.log('Navigating to page', pageNum);
        
        clearPreviousPages(pageNum);
        
        container.scrollTop = 0;
        pagesWrapper.offsetHeight;
        
        const pageAbsoluteTop = pageContainer.offsetTop;
        const scrollOffset = pageAbsoluteTop;
        
        container.scrollTo({
          top: scrollOffset,
          behavior: 'auto'
        });
        
        currentPage = pageNum;
        pageIndicatorCurrent.textContent = currentPage;
        window.parent.postMessage({ type: 'pageInView', page: pageNum }, '*');
        
        if (!pageData.has(pageNum) && !loadingPages.has(pageNum)) {
          loadingPages.add(pageNum);
          window.parent.postMessage({ type: 'requestPage', page: pageNum }, '*');
        }
        
        setTimeout(() => {
          const currentScroll = container.scrollTop;
          const expectedScroll = pageAbsoluteTop;
          const scrollDifference = Math.abs(currentScroll - expectedScroll);
          
          if (scrollDifference > 1) {
            container.scrollTo({
              top: expectedScroll,
              behavior: 'auto'
            });
          }
        }, 50);
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
              const newScale = Math.min(maxZoom, scale + 0.1);
              await setZoomThrottled(newScale);
            }
            break;
          case '-':
          case '_':
            if (e.ctrlKey || e.metaKey) {
              e.preventDefault();
              const newScale = Math.max(0.5, scale - 0.1);
              await setZoomThrottled(newScale);
            }
            break;
          case '0':
            if (e.ctrlKey || e.metaKey) {
              e.preventDefault();
              await setZoom(1.0);
            }
            break;
        }
      });
    }
    
    function setupZoomControls() {
      let pinchCenter = { x: 0, y: 0 };
      let lastScale = scale;
      
      container.addEventListener('wheel', async (e) => {
        if (e.ctrlKey || e.metaKey) {
          e.preventDefault();
          
          const delta = -Math.sign(e.deltaY);
          const newScale = Math.max(0.5, Math.min(maxZoom, scale + delta * 0.02));
          if (newScale !== scale) {
            await setZoomThrottled(newScale);
          }
        }
      }, { passive: false });
      
      let isPinching = false;
      let initialPinchDistance = 0;
      let initialScale = scale;
      let pinchStartTime = 0;
      let pinchStartScrollTop = 0;
      let pinchStartScrollLeft = 0;
      const PINCH_SMOOTHING_FACTOR = 0.05;
      let lastPinchUpdate = 0;
      const PINCH_THROTTLE = isMobile ? 32 : 0; // Throttle more on mobile
      let pinchCenterOffset = { x: 0, y: 0 };
      let rafId = null;
      
      container.addEventListener('touchstart', (e) => {
        if (e.touches.length === 2) {
          e.preventDefault();
          isPinching = true;
          isZooming = true;
          pinchStartTime = Date.now();
          zoomIndicator.classList.add('visible');
          
          pinchStartScrollTop = container.scrollTop;
          pinchStartScrollLeft = container.scrollLeft;
          
          const touch1 = e.touches[0];
          const touch2 = e.touches[1];
          
          pinchCenter.x = (touch1.clientX + touch2.clientX) / 2;
          pinchCenter.y = (touch1.clientY + touch2.clientY) / 2;
          
          const containerRect = container.getBoundingClientRect();
          pinchCenterOffset.x = pinchCenter.x - containerRect.left;
          pinchCenterOffset.y = pinchCenter.y - containerRect.top;
          
          const dx = touch2.clientX - touch1.clientX;
          const dy = touch2.clientY - touch1.clientY;
          initialPinchDistance = Math.sqrt(dx * dx + dy * dy);
          initialScale = scale;
          lastScale = scale;
          
          container.style.overflow = 'hidden';
          container.style.touchAction = 'none';
          
          window.parent.postMessage({ type: 'zoomStateChanged', isZooming: true }, '*');
        }
      }, { passive: false });
      
      container.addEventListener('touchmove', (e) => {
        if (isPinching && e.touches.length === 2) {
          e.preventDefault();
          
          // Throttle pinch updates on mobile
          const now = Date.now();
          if (isMobile && (now - lastPinchUpdate < PINCH_THROTTLE)) {
            return;
          }
          lastPinchUpdate = now;
          
          if (rafId) {
            cancelAnimationFrame(rafId);
          }
          
          const touch1 = e.touches[0];
          const touch2 = e.touches[1];
          
          const dx = touch2.clientX - touch1.clientX;
          const dy = touch2.clientY - touch1.clientY;
          const currentDistance = Math.sqrt(dx * dx + dy * dy);
          
          if (initialPinchDistance > 0) {
            const rawScaleChange = currentDistance / initialPinchDistance;
            
            const smoothedScaleChange = 1 + (rawScaleChange - 1) * (1 - PINCH_SMOOTHING_FACTOR);
            lastScale = Math.max(0.5, Math.min(maxZoom, initialScale * smoothedScaleChange));
            
            const visualScale = lastScale / scale;
            
            rafId = requestAnimationFrame(() => {
              pagesWrapper.style.transform = 'scale(' + visualScale + ')';
              pagesWrapper.style.transformOrigin = pinchCenterOffset.x + 'px ' + pinchCenterOffset.y + 'px';
              pagesWrapper.style.willChange = 'transform';
            });
          }
        } else if (isPinching) {
          isPinching = false;
          if (rafId) {
            cancelAnimationFrame(rafId);
            rafId = null;
          }
          pagesWrapper.style.transform = '';
          pagesWrapper.style.transformOrigin = '';
          pagesWrapper.style.willChange = '';
        }
      }, { passive: false });
      
      container.addEventListener('touchend', async (e) => {
        if (isPinching) {
          e.preventDefault();
          
          const snapLevels = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0];
          const snapThreshold = 0.08;
          let targetScale = lastScale;
          
          let minDiff = Infinity;
          for (const snapLevel of snapLevels) {
            const diff = Math.abs(lastScale - snapLevel);
            if (diff < minDiff) {
              minDiff = diff;
              if (diff < snapThreshold) {
                targetScale = snapLevel;
              }
            }
          }
          
          // Ensure we don't exceed mobile max zoom
          targetScale = Math.min(maxZoom, targetScale);
          
          if (Math.abs(targetScale - scale) > 0.01) {
            const oldScale = scale;
            scale = targetScale;
            
            const scaleRatio = targetScale / oldScale;
            
            const currentPageEl = document.getElementById('page-' + currentPage);
            let anchorScrollTop = container.scrollTop;
            let anchorPageTop = 0;
            
            if (currentPageEl) {
              anchorPageTop = currentPageEl.offsetTop;
              anchorScrollTop = container.scrollTop + pinchCenterOffset.y;
            }
            
            const relativePosition = anchorScrollTop - anchorPageTop;
            
            pagesWrapper.style.transition = 'none';
            pagesWrapper.style.transform = '';
            pagesWrapper.style.transformOrigin = '';
            pagesWrapper.style.willChange = '';
            
            // On mobile, only render visible pages immediately
            const visiblePages = [];
            for (const [pageNum, data] of pageData) {
              if (Math.abs(pageNum - currentPage) <= (isMobile ? 1 : 2)) {
                visiblePages.push(pageNum);
              }
            }
            
            const renderPromises = visiblePages.map(pageNum => rerenderPageWithoutReflow(pageNum));
            await Promise.all(renderPromises);
            
            await new Promise(resolve => requestAnimationFrame(() => {
              requestAnimationFrame(resolve);
            }));
            
            const newPageEl = document.getElementById('page-' + currentPage);
            if (newPageEl) {
              const newPageTop = newPageEl.offsetTop;
              const newRelativePosition = relativePosition * scaleRatio;
              const newScrollTop = newPageTop + newRelativePosition - pinchCenterOffset.y;
              
              container.scrollTop = Math.max(0, newScrollTop);
            }
            
            window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
            
            // Render other pages with delay on mobile
            setTimeout(() => {
              for (const [pageNum, data] of pageData) {
                if (!visiblePages.includes(pageNum) && Math.abs(pageNum - currentPage) <= (isMobile ? 2 : 3)) {
                  rerenderPageWithoutReflow(pageNum);
                }
              }
            }, isMobile ? 200 : 50);
          } else {
            pagesWrapper.style.transform = '';
            pagesWrapper.style.transformOrigin = '';
            pagesWrapper.style.willChange = '';
          }
          
          isPinching = false;
          
          setTimeout(() => {
            container.style.overflow = '';
            container.style.touchAction = '';
            zoomEndTime = Date.now();
            isZooming = false;
            zoomIndicator.classList.remove('visible');
            window.parent.postMessage({ type: 'zoomStateChanged', isZooming: false }, '*');
            
            // Force page indicator update after pinch zoom
            if (window.forceUpdateCurrentPage) {
              window.forceUpdateCurrentPage();
            }
          }, 100);
        }
      }, { passive: false });
      
      container.addEventListener('touchcancel', () => {
        if (isPinching) {
          isPinching = false;
          isZooming = false;
          if (rafId) {
            cancelAnimationFrame(rafId);
            rafId = null;
          }
          pagesWrapper.style.transform = '';
          pagesWrapper.style.transformOrigin = '';
          pagesWrapper.style.willChange = '';
          container.style.overflow = '';
          container.style.touchAction = '';
          zoomIndicator.classList.remove('visible');
          window.parent.postMessage({ type: 'zoomStateChanged', isZooming: false }, '*');
        }
      });
      
      let lastTap = 0;
      let lastTapLocation = { x: 0, y: 0 };
      const doubleTapThreshold = 350;
      const tapMoveThreshold = 40;
      
      container.addEventListener('touchend', async (e) => {
        if (!isPinching && e.touches.length === 0 && e.changedTouches.length === 1) {
          const touch = e.changedTouches[0];
          const now = Date.now();
          const timeSince = now - lastTap;
          
          const tapX = touch.clientX;
          const tapY = touch.clientY;
          const distance = Math.sqrt(
            Math.pow(tapX - lastTapLocation.x, 2) + 
            Math.pow(tapY - lastTapLocation.y, 2)
          );
          
          if (timeSince < doubleTapThreshold && timeSince > 0 && distance < tapMoveThreshold) {
            e.preventDefault();
            
            let targetZoom;
            if (scale < 1.0) {
              targetZoom = 1.0;
            } else if (scale < 1.5) {
              targetZoom = 1.5;
            } else if (scale < 2.0 && !isMobile) {
              targetZoom = 2.0;
            } else {
              targetZoom = 1.0;
            }
            
            // Don't exceed mobile max zoom
            targetZoom = Math.min(maxZoom, targetZoom);
            
            await setZoom(targetZoom);
            lastTap = 0;
          } else {
            lastTap = now;
            lastTapLocation = { x: tapX, y: tapY };
          }
        }
      });
      
      container.addEventListener('scroll', (e) => {
        if (isZooming || (Date.now() - zoomEndTime) < SCROLL_PREVENTION_DURATION) {
          container.scrollTop = container.scrollTop;
          container.scrollLeft = container.scrollLeft;
        }
      });
      
      return {
        get isZooming() { return isZooming; }
      };
    }
    
    // Add memory warning function
    function showMemoryWarning() {
      memoryWarning.classList.add('visible');
      setTimeout(() => {
        memoryWarning.classList.remove('visible');
      }, 3000);
    }
    
    // Add low memory detection
    function checkMemoryPressure() {
      if (isMobile && pageData.size > 5) {
        showMemoryWarning();
        window.parent.postMessage({ type: 'lowMemory' }, '*');
        
        // Clear some pages
        const current = getCurrentVisiblePage();
        let cleared = 0;
        for (let [pageNum, data] of pageData) {
          if (Math.abs(pageNum - current) > 2 && cleared < 3) {
            if (data.canvas) {
              const ctx = data.canvas.getContext('2d');
              ctx.clearRect(0, 0, data.canvas.width, data.canvas.height);
            }
            cleared++;
          }
        }
      }
    }
    
    window.addEventListener('message', async (event) => {
      const data = event.data;
      
      if (data.type === 'loadPage') {
      await renderPage(data.pageNumber, data.pageData);
    // Update current page after loading
    if (data.pageNumber === currentPage) {
      setTimeout(() => {
        if (window.forceUpdateCurrentPage) {
          window.forceUpdateCurrentPage();
        }
      }, 100);
    }
      } else if (data.type === 'setZoom') {
        await setZoom(data.scale);
      } else if (data.type === 'goToPage') {
        scrollToPage(data.page);
      } else if (data.type === 'forcePageUpdate') {
        if (window.forceUpdateCurrentPage) {
          window.forceUpdateCurrentPage();
        }
      } else if (data.type === 'clearPage') {
        const pageNum = data.page;
        const pageInfo = pageElements.get(pageNum);
        if (pageInfo && pageInfo.rendered) {
          pageInfo.container.innerHTML = '';
          const spinner = document.createElement('div');
          spinner.className = 'loading-spinner';
          spinner.textContent = 'Loading page ' + pageNum + '...';
          pageInfo.container.appendChild(spinner);
          
          const pageNumber = document.createElement('div');
          pageNumber.className = 'page-number';
          pageNumber.textContent = pageNum + ' / ' + totalPages;
          pageInfo.container.appendChild(pageNumber);
          
          pageInfo.container.classList.add('loading');
          
          if (pageInfo.dimensions) {
            const pageDim = pageInfo.dimensions;
            const containerWidth = container.clientWidth;
            const baseScale = isMobile ? 1.2 : 1.5;
            const finalScale = scale * baseScale;
            
            let widthPt = pageDim.width;
            let heightPt = pageDim.height;
            
            if (pageDim.unit === 'mm') {
              widthPt = pageDim.width * 2.83465;
              heightPt = pageDim.height * 2.83465;
            } else if (pageDim.unit === 'in') {
              widthPt = pageDim.width * 72;
              heightPt = pageDim.height * 72;
            }
            
            const displayWidth = widthPt * finalScale;
            const displayHeight = heightPt * finalScale;
            
            pageInfo.container.style.width = displayWidth + 'px';
            pageInfo.container.style.height = displayHeight + 'px';
            pageInfo.container.style.minHeight = 'auto';
            pageInfo.container.style.maxHeight = 'none';
          } else {
            pageInfo.container.style.height = 'auto';
            pageInfo.container.style.minHeight = '400px';
          }
          pageInfo.canvas = null;
          
          if (pageInfo.pdf) {
            pageInfo.pdf.destroy();
          }
          
          pageData.delete(pageNum);
          console.log('Cleared page', pageNum, 'from memory');
        }
      } else if (data.type === 'getCurrentPage') {
        reportCurrentPage();
      } else if (data.type === 'forceGarbageCollection') {
        checkMemoryPressure();
      }
    });
    
    // Periodically check memory on mobile
    if (isMobile) {
      setInterval(checkMemoryPressure, 10000);
    }
    
    init();
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
  }

  void _queuePageLoad(int pageNumber) {
    if (_pageCache.contains(pageNumber) ||
        _loadingPages.contains(pageNumber) ||
        _loadQueue.contains(pageNumber)) {
      return;
    }

    // Don't queue pages during scroll prevention after zoom OR during active zooming
    if (_isScrollPrevented || _isZooming) {
      print('Skipping queue for page $pageNumber (zoom operation in progress)');
      return;
    }

    if (_isScrolling && !_isZooming) {
      print('Skipping queue for page $pageNumber (fast scrolling)');
      return;
    }

    _loadQueue.add(pageNumber);
    _processLoadQueue();
  }

  Future<void> _processLoadQueue() async {
    while (_loadingPages.length < widget.config.maxConcurrentLoads && _loadQueue.isNotEmpty) {
      final pageNumber = _loadQueue.removeAt(0);

      if (!_pageCache.contains(pageNumber)) {
        _loadingPages.add(pageNumber);
        _loadAndSendPage(pageNumber);
      }
    }
  }

  Future<void> _loadAndSendPage(int pageNumber) async {
    if (_isRecovering) return;

    try {
      _debugLog('Loading page $pageNumber from API... (${_loadingPages.length} concurrent)');
      _performanceMonitor.startPageLoad(pageNumber);

      final pageData = await _apiService.getPageAsPdf(widget.documentId, pageNumber)
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      _pageCache.put(pageNumber, pageData);
      _loadedPages.add(pageNumber);
      _loadingPages.remove(pageNumber);
      _updatePageAccess(pageNumber);
      _performanceMonitor.endPageLoad(pageNumber);

      _debugLog('Page $pageNumber loaded successfully');
      _debugMemoryLog();

      _sendPageToViewer(pageNumber);

      if (mounted) {
        setState(() {});
      }

      _processLoadQueue();
    } catch (e) {
      _debugLog('ERROR loading page $pageNumber: $e');
      _loadingPages.remove(pageNumber);
      _performanceMonitor.endPageLoad(pageNumber);

      // Don't retry immediately for this page to avoid flooding
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted && !_pageCache.contains(pageNumber)) {
          _queuePageLoad(pageNumber);
        }
      });

      _processLoadQueue();
    }
  }

  void _sendPageToViewer(int pageNumber) {
    if (!_viewerInitialized) return;

    final pageData = _pageCache.get(pageNumber);
    if (pageData == null) return;

    final base64Data = base64Encode(pageData);
    _iframeElement.contentWindow?.postMessage({
      'type': 'loadPage',
      'pageData': base64Data,
      'pageNumber': pageNumber,
    }, '*');
  }

  void _sendClearPageToViewer(int pageNumber) {
    if (!_viewerInitialized) return;

    _iframeElement.contentWindow?.postMessage({
      'type': 'clearPage',
      'page': pageNumber,
    }, '*');
  }

  void _preloadNearbyPages(int currentPage) {
    if (_documentInfo == null) return;

    // Only check scroll prevention if we're CURRENTLY scrolling
    if (_isScrollPrevented && _isScrolling) {
      print('Skipping preload (scroll prevention active during scroll)');
      return;
    }

    if (_isScrolling && !_isZooming) {
      print('Skipping preload (scrolling)');
      return;
    }

    // Load pages in priority order: current page first, then nearby pages
    final pagesToLoad = <int>[];

    // Highest priority: current page
    if (!_pageCache.contains(currentPage) && !_loadingPages.contains(currentPage)) {
      pagesToLoad.add(currentPage);
    }

    // Then load surrounding pages
    for (int i = 1; i <= widget.config.cacheWindowSize; i++) {
      final prevPage = currentPage - i;
      final nextPage = currentPage + i;

      if (nextPage >= 1 && nextPage <= _documentInfo!.totalPages) {
        if (!_pageCache.contains(nextPage) && !_loadingPages.contains(nextPage)) {
          pagesToLoad.add(nextPage);
        }
      }

      if (prevPage >= 1 && prevPage <= _documentInfo!.totalPages) {
        if (!_pageCache.contains(prevPage) && !_loadingPages.contains(prevPage)) {
          pagesToLoad.add(prevPage);
        }
      }
    }

    // Queue all pages
    for (final page in pagesToLoad) {
      _queuePageLoad(page);
    }

    if (pagesToLoad.isNotEmpty) {
      print('Preloading ${pagesToLoad.length} pages around page $currentPage');
    }
  }

  void _cleanupDistantPages(int currentPage) {
    if (_documentInfo == null) return;

    final keysToRemove = _pageCache.getPagesToEvict(currentPage, widget.config.cacheWindowSize);
    final queueItemsToRemove = _loadQueue.where((pageNum) =>
    (pageNum - currentPage).abs() > widget.config.cacheWindowSize
    ).toList();

    for (final key in keysToRemove) {
      _debugLog('Removing page $key from cache (too far from page $currentPage)');
      _removePageFromCache(key);
    }

    for (final pageNum in queueItemsToRemove) {
      _loadQueue.remove(pageNum);
      _debugLog('Removed page $pageNum from load queue (too far from page $currentPage)');
    }

    final loadingToCancel = <int>[];
    for (final pageNum in _loadingPages) {
      if ((pageNum - currentPage).abs() > widget.config.cacheWindowSize) {
        loadingToCancel.add(pageNum);
      }
    }

    for (final pageNum in loadingToCancel) {
      _loadingPages.remove(pageNum);
      _debugLog('Cancelled loading page $pageNum (too far from page $currentPage)');
    }

    if (keysToRemove.isNotEmpty || queueItemsToRemove.isNotEmpty || loadingToCancel.isNotEmpty) {
      if (mounted) setState(() {});
      _debugLog('Cleanup summary: ${keysToRemove.length} removed, ${queueItemsToRemove.length} queue cleared, ${loadingToCancel.length} loads cancelled');
      _debugMemoryLog();
    }
  }

  void _performPeriodicCleanup() {
    if (!mounted || _documentInfo == null) return;

    final now = DateTime.now();
    final keysToRemove = <int>[];

    // Remove pages not accessed in last 5 minutes
    for (final entry in _pageAccessTimes.entries) {
      if (now.difference(entry.value) > const Duration(minutes: 5)) {
        keysToRemove.add(entry.key);
      }
    }

    for (final key in keysToRemove) {
      _removePageFromCache(key);
    }

    if (keysToRemove.isNotEmpty) {
      print('Periodic cleanup: Removed ${keysToRemove.length} stale pages');
    }
  }

  void _monitorMemoryUsage() {
    if (!mounted) return;

    final totalMemory = _pageCache.totalMemory;
    print('Memory usage: ${(totalMemory / (1024 * 1024)).toStringAsFixed(2)} MB, ${_pageCache.size} pages cached');

    // If memory usage exceeds limit, force cleanup
    if (totalMemory > widget.config.maxMemoryMB * 1024 * 1024) {
      print('High memory usage detected, forcing cleanup');
      _forceAggressiveCleanup();
    }
  }

  void _forceAggressiveCleanup() {
    if (_documentInfo == null) return;

    // Keep only current page and immediate neighbors
    final pagesToKeep = {
      _currentPage,
      _currentPage - 1,
      _currentPage + 1
    }.where((page) => page >= 1 && page <= _documentInfo!.totalPages).toSet();

    final keysToRemove = _pageCache.keys.where((page) => !pagesToKeep.contains(page)).toList();

    for (final key in keysToRemove) {
      _removePageFromCache(key);
    }

    print('Aggressive cleanup: Removed ${keysToRemove.length} pages, keeping ${pagesToKeep.length}');
  }

  void _handleLowMemory() {
    if (!mounted) return;

    print('Low memory detected, performing emergency cleanup');

    // Keep only current page
    final current = _currentPage;
    final keysToRemove = _pageCache.keys
        .where((page) => page != current)
        .toList();

    for (final key in keysToRemove) {
      _removePageFromCache(key);
    }

    // Clear all queues
    _loadQueue.clear();
    _loadingPages.clear();

    // Force garbage collection hint
    _iframeElement.contentWindow?.postMessage({
      'type': 'forceGarbageCollection',
    }, '*');

    print('Emergency cleanup completed: removed ${keysToRemove.length} pages');
  }

  void _removePageFromCache(int pageNumber) {
    _pageCache.remove(pageNumber);
    _loadedPages.remove(pageNumber);
    _pageAccessTimes.remove(pageNumber);
    _pageAccessOrder.remove(pageNumber);
    _sendClearPageToViewer(pageNumber);
  }

  void _updatePageAccess(int pageNumber) {
    _pageAccessTimes[pageNumber] = DateTime.now();
    _pageAccessOrder.remove(pageNumber);
    _pageAccessOrder.add(pageNumber);

    // Limit access order tracking to prevent memory growth
    if (_pageAccessOrder.length > 100) {
      final removed = _pageAccessOrder.removeAt(0);
      _pageAccessTimes.remove(removed);
    }
  }

  void _goToPage(int page) {
    if (_documentInfo == null || page < 1 || page > _documentInfo!.totalPages) {
      _showPageErrorSnackbar();
      return;
    }

    HapticFeedback.selectionClick();

    // Ensure the page is loaded before scrolling
    if (!_pageCache.contains(page) && !_loadingPages.contains(page)) {
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

      _preloadNearbyPages(page);
      _cleanupDistantPages(page);

      // Remove focus from text field
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

  void _setZoom(double zoom) {
    // Use more conservative zoom limits for mobile
    final maxZoom = _isMobile ? 2.0 : 4.5;
    final clampedZoom = zoom.clamp(0.25, maxZoom);

    setState(() {
      _zoomLevel = clampedZoom;
      _isZooming = true;
    });

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'setZoom',
        'scale': clampedZoom,
        'isMobile': _isMobile, // Pass mobile flag to JS
      }, '*');

      // Longer delay for mobile to ensure zoom completes
      final delay = _isMobile
          ? const Duration(milliseconds: 1200)
          : const Duration(milliseconds: 800);

      Timer(delay, () {
        if (mounted) {
          setState(() {
            _isZooming = false;
          });
        }
      });
    }
  }

  void _zoomIn() {
    HapticFeedback.lightImpact();
    final newZoom = (_zoomLevel + 0.25).clamp(0.25, _isMobile ? 2.0 : 4.5);
    _setZoom(newZoom);
  }

  void _zoomOut() {
    HapticFeedback.lightImpact();
    final newZoom = (_zoomLevel - 0.25).clamp(0.25, _isMobile ? 2.0 : 4.5);
    _setZoom(newZoom);
  }

  void _resetZoom() {
    HapticFeedback.mediumImpact();
    _setZoom(1.0);
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
        ],

        // Page Navigation Widget
        if (_documentInfo != null) _buildPageNavigation(context, isMobile),
      ],
    );
  }

  Widget _buildPageNavigation(BuildContext context, bool isMobile) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Previous Page Button
          if (!isMobile)
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: _currentPage > 1
                  ? () => _goToPage(_currentPage - 1)
                  : null,
              tooltip: 'Previous Page',
              iconSize: 20,
            ),

          // Page Input Field
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

                // Go Button (only show when editing or on mobile)
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

          // Total Pages Label
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

          // Next Page Button
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

  void _setIframePointerEvents(bool enabled) {
    _iframeElement.style.pointerEvents = enabled ? 'auto' : 'none';
  }

  void _cleanupAllResources() {
    // Clear all pages from viewer
    for (final pageNum in _pageCache.keys.toList()) {
      _sendClearPageToViewer(pageNum);
    }

    _pageCache.clear();
    _loadQueue.clear();
    _loadingPages.clear();
    _loadedPages.clear();
    _pageAccessTimes.clear();
    _pageAccessOrder.clear();

    // Clean up iframe
    if (_iframeElement.contentWindow != null) {
      try {
        _iframeElement.removeAttribute('src');
        _iframeElement.srcdoc = '';
      } catch (e) {
        print('Error cleaning up iframe: $e');
      }
    }
  }

  @override
  void dispose() {
    _cleanupTimer?.cancel();
    _memoryMonitorTimer?.cancel();
    _scrollPreventionTimer?.cancel();
    _pageController.dispose();
    _pageFocusNode.dispose();

    // Print performance metrics before disposal
    if (widget.config.enablePerformanceMonitoring) {
      final metrics = _performanceMonitor.getMetrics();
      print('PDF Viewer Session Metrics: $metrics');
    }

    // Clean up all resources
    _cleanupAllResources();

    super.dispose();
  }
}