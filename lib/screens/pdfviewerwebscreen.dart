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

//loading ok, tapi zoom ngaco

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
    this.maxConcurrentLoads = 3, // Reduced for better memory management
    this.cacheWindowSize = 3, // Reduced to minimize memory usage
    this.cleanupInterval = const Duration(seconds: 5),
    this.maxMemoryMB = 50, // Reduced memory limit
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

  _SmartPageCache({int maxSize = 15, int maxMemoryMB = 30}) // Reduced defaults
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
            if (pageNum != null) {
              // Record previous page view duration
              if (_currentPageViewStart != null && _currentPage != pageNum) {
                final duration = DateTime.now().difference(_currentPageViewStart!);
                _performanceMonitor.recordPageView(_currentPage, duration);
              }

              // Always update when JavaScript reports a new page
              if (pageNum != _currentPage) {
                print('JavaScript reported page change: $_currentPage -> $pageNum');
                setState(() {
                  _currentPage = pageNum;
                  if (!_isEditingPage) {
                    _pageController.text = pageNum.toString();
                  }
                });
                _currentPageViewStart = DateTime.now();
                _updatePageAccess(pageNum);
              }

              // Ensure current page is loaded when it comes into view
              if (!_pageCache.contains(pageNum) && !_loadingPages.contains(pageNum)) {
                print('Page $pageNum in view but not loaded, requesting load');
                _queuePageLoad(pageNum, priority: true);
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
              print('Scroll stopped at page $pageNum');
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
                print('Page $pageNum requested by viewer');
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
      // Cancel non-critical loads during scrolling
      _cancelNonCriticalLoads();

      // Cleanup memory during scroll
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

    // Always update current page to match what JavaScript reports
    if (pageNum != _currentPage) {
      print('Correcting Dart current page from $_currentPage to $pageNum');
      setState(() {
        _currentPage = pageNum;
        if (!_isEditingPage) {
          _pageController.text = pageNum.toString();
        }
      });
      _currentPageViewStart = DateTime.now();
    }

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

    // FIXED: Improved current page tracking
    let lastReportedPage = 1;
    let pageUpdateThrottle = null;
    
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

    // FIXED: Improved page detection logic - no 1-page offset
    function getCurrentVisiblePage() {
      const containerRect = container.getBoundingClientRect();
      const containerTop = containerRect.top;
      const containerHeight = containerRect.height;
      const viewportCenter = containerTop + (containerHeight / 2);
      
      let bestCandidate = currentPage;
      let smallestDistance = Infinity;
      let highestVisibility = 0;
      
      for (let i = 1; i <= totalPages; i++) {
        const pageContainer = document.getElementById('page-' + i);
        if (!pageContainer) continue;
        
        const pageRect = pageContainer.getBoundingClientRect();
        const pageCenter = pageRect.top + (pageRect.height / 2);
        const distanceFromCenter = Math.abs(pageCenter - viewportCenter);
        
        // Calculate how much of the page is visible in the viewport
        const visibleTop = Math.max(containerTop, pageRect.top);
        const visibleBottom = Math.min(containerTop + containerHeight, pageRect.bottom);
        const visibleHeight = Math.max(0, visibleBottom - visibleTop);
        const visibilityRatio = visibleHeight / Math.min(containerHeight, pageRect.height);
        
        // Prefer pages that are more centered AND have good visibility
        const score = distanceFromCenter + (1 - visibilityRatio) * 100;
        
        if (score < smallestDistance) {
          smallestDistance = score;
          bestCandidate = i;
          highestVisibility = visibilityRatio;
        }
      }
      
      return bestCandidate;
    }

    // FIXED: Improved scroll handling with better state management
    function setupScrollListener() {
      let lastScrollTop = container.scrollTop;
      let lastScrollTime = Date.now();
      let scrollVelocity = 0;
      let isFastScrolling = false;
      let scrollDirection = 0;
      
      container.addEventListener('scroll', () => {
        const now = Date.now();
        const scrollTop = container.scrollTop;
        const delta = scrollTop - lastScrollTop;
        const timeDelta = now - lastScrollTime;
        
        scrollVelocity = Math.abs(delta) / Math.max(timeDelta, 1);
        scrollDirection = Math.sign(delta);
        isFastScrolling = scrollVelocity > 2;
        
        lastScrollTop = scrollTop;
        lastScrollTime = now;
        
        if (!isScrolling) {
          isScrolling = true;
          window.parent.postMessage({ 
            type: 'scrollStateChanged', 
            isScrolling: true,
            isFastScrolling: isFastScrolling
          }, '*');
        }
        
        if (scrollStopTimeout) clearTimeout(scrollStopTimeout);
        scrollStopTimeout = setTimeout(() => {
          isScrolling = false;
          const stoppedAtPage = getCurrentVisiblePage();
          window.parent.postMessage({ 
            type: 'scrollStopped', 
            page: stoppedAtPage,
            wasFastScrolling: isFastScrolling
          }, '*');
        }, SCROLL_STOP_DELAY);
        
        // FIXED: More responsive page updates during scroll
        const newPage = getCurrentVisiblePage();
        if (newPage !== currentPage) {
          currentPage = newPage;
          updatePageIndicator();
          
          // Throttle page reporting during scroll
          if (pageUpdateThrottle) clearTimeout(pageUpdateThrottle);
          pageUpdateThrottle = setTimeout(() => {
            if (currentPage !== lastReportedPage) {
              lastReportedPage = currentPage;
              window.parent.postMessage({ 
                type: 'pageInView', 
                page: currentPage 
              }, '*');
            }
          }, 100);
        }
        
        // Show scroll speed indicator for fast scrolling
        if (isFastScrolling) {
          scrollSpeedIndicator.classList.add('visible');
        } else {
          scrollSpeedIndicator.classList.remove('visible');
        }
      });
    }

    function setupZoomControls() {
      let touchStartDistance = 0;
      let initialScale = scale;
      let lastZoomTime = 0;
      const ZOOM_THROTTLE = 50;
      
      // Pinch zoom for touch devices
      container.addEventListener('touchstart', (e) => {
        if (e.touches.length === 2) {
          touchStartDistance = getDistance(e.touches[0], e.touches[1]);
          initialScale = scale;
          isZooming = true;
          window.parent.postMessage({ 
            type: 'zoomStateChanged', 
            isZooming: true 
          }, '*');
          zoomIndicator.textContent = 'Zoom: ' + Math.round(scale * 100) + '%';
          zoomIndicator.classList.add('visible');
        }
      });
      
      container.addEventListener('touchmove', (e) => {
        if (e.touches.length === 2 && isZooming) {
          e.preventDefault();
          
          const now = Date.now();
          if (now - lastZoomTime < ZOOM_THROTTLE) {
            return;
          }
          lastZoomTime = now;
          
          const currentDistance = getDistance(e.touches[0], e.touches[1]);
          const newScale = initialScale * (currentDistance / touchStartDistance);
          const clampedScale = Math.max(0.5, Math.min(maxZoom, newScale));
          
          if (Math.abs(clampedScale - scale) > 0.01) {
            scale = clampedScale;
            applyZoom();
          }
        }
      });
      
      container.addEventListener('touchend', () => {
        if (isZooming) {
          isZooming = false;
          zoomEndTime = Date.now();
          window.parent.postMessage({ 
            type: 'zoomStateChanged', 
            isZooming: false 
          }, '*');
          zoomIndicator.classList.remove('visible');
        }
      });
      
      // Wheel zoom for desktop
      container.addEventListener('wheel', (e) => {
        if (e.ctrlKey || e.metaKey) {
          e.preventDefault();
          const now = Date.now();
          
          if (now - lastZoomTime < ZOOM_THROTTLE) {
            pendingZoomScale = scale * (1 - e.deltaY * 0.01);
            return;
          }
          
          const newScale = scale * (1 - e.deltaY * 0.01);
          const clampedScale = Math.max(0.5, Math.min(maxZoom, newScale));
          
          if (Math.abs(clampedScale - scale) > 0.01) {
            scale = clampedScale;
            lastZoomTime = now;
            applyZoom();
          }
        }
      });
      
      // Process pending zoom if throttle expired
      setInterval(() => {
        if (pendingZoomScale !== null && Date.now() - lastZoomTime >= ZOOM_THROTTLE) {
          const clampedScale = Math.max(0.5, Math.min(maxZoom, pendingZoomScale));
          if (Math.abs(clampedScale - scale) > 0.01) {
            scale = clampedScale;
            lastZoomTime = Date.now();
            applyZoom();
          }
          pendingZoomScale = null;
        }
      }, ZOOM_THROTTLE);
    }

    function getDistance(touch1, touch2) {
      const dx = touch1.clientX - touch2.clientX;
      const dy = touch1.clientY - touch2.clientY;
      return Math.sqrt(dx * dx + dy * dy);
    }

    // FIXED: Improved zoom application with better performance
    function applyZoom() {
      if (zoomThrottle) {
        clearTimeout(zoomThrottle);
      }
      
      zoomThrottle = setTimeout(() => {
        pagesWrapper.style.transform = 'scale(' + scale + ')';
        pagesWrapper.style.transformOrigin = 'center top';
        
        // Update page indicator with zoom info
        zoomIndicator.textContent = 'Zoom: ' + Math.round(scale * 100) + '%';
        
        // Report zoom change
        window.parent.postMessage({ 
          type: 'zoomChanged', 
          zoom: scale 
        }, '*');
        
        // Force re-check of current page after zoom
        setTimeout(() => {
          const newPage = getCurrentVisiblePage();
          if (newPage !== currentPage) {
            currentPage = newPage;
            updatePageIndicator();
            window.parent.postMessage({ 
              type: 'pageInView', 
              page: currentPage 
            }, '*');
          }
        }, 200);
        
        // Schedule re-renders for visible pages with debounce
        const visiblePages = getVisiblePages();
        visiblePages.forEach(pageNum => {
          if (rerenderDebounce.has(pageNum)) {
            clearTimeout(rerenderDebounce.get(pageNum));
          }
          
          rerenderDebounce.set(pageNum, setTimeout(() => {
            const pageData = pageElements.get(pageNum);
            if (pageData && pageData.rendered && pageData.canvas) {
              renderPage(pageNum, pageData.pdf, pageData.canvas);
            }
            rerenderDebounce.delete(pageNum);
          }, 300));
        });
      }, 50);
    }

    function getVisiblePages() {
      const visible = [];
      const containerRect = container.getBoundingClientRect();
      
      for (let i = 1; i <= totalPages; i++) {
        const pageContainer = document.getElementById('page-' + i);
        if (!pageContainer) continue;
        
        const pageRect = pageContainer.getBoundingClientRect();
        if (pageRect.bottom >= containerRect.top && pageRect.top <= containerRect.bottom) {
          visible.push(i);
        }
      }
      
      return visible;
    }

    function setupKeyboardControls() {
      document.addEventListener('keydown', (e) => {
        if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
        
        switch(e.key) {
          case 'ArrowDown':
          case 'ArrowRight':
          case 'PageDown':
            e.preventDefault();
            navigateToPage(Math.min(currentPage + 1, totalPages));
            break;
          case 'ArrowUp':
          case 'ArrowLeft':
          case 'PageUp':
            e.preventDefault();
            navigateToPage(Math.max(currentPage - 1, 1));
            break;
          case 'Home':
            e.preventDefault();
            navigateToPage(1);
            break;
          case 'End':
            e.preventDefault();
            navigateToPage(totalPages);
            break;
          case '+':
          case '=':
            if (e.ctrlKey || e.metaKey) {
              e.preventDefault();
              scale = Math.min(maxZoom, scale + 0.1);
              applyZoom();
            }
            break;
          case '-':
            if (e.ctrlKey || e.metaKey) {
              e.preventDefault();
              scale = Math.max(0.5, scale - 0.1);
              applyZoom();
            }
            break;
          case '0':
            if (e.ctrlKey || e.metaKey) {
              e.preventDefault();
              scale = 1.0;
              applyZoom();
            }
            break;
        }
      });
    }

    function navigateToPage(pageNum) {
      const pageContainer = document.getElementById('page-' + pageNum);
      if (pageContainer) {
        const containerRect = container.getBoundingClientRect();
        const pageRect = pageContainer.getBoundingClientRect();
        const scrollTop = pageRect.top - containerRect.top + container.scrollTop - 20;
        
        container.scrollTo({
          top: scrollTop,
          behavior: 'smooth'
        });
        
        currentPage = pageNum;
        updatePageIndicator();
        window.parent.postMessage({ 
          type: 'pageInView', 
          page: currentPage 
        }, '*');
      }
    }

    function updatePageIndicator() {
      pageIndicatorCurrent.textContent = currentPage;
      pageIndicatorTotal.textContent = 'of ' + totalPages;
      
      // Show indicator briefly when page changes
      pageIndicator.classList.add('visible');
      clearTimeout(pageIndicator.timeout);
      pageIndicator.timeout = setTimeout(() => {
        pageIndicator.classList.remove('visible');
      }, 2000);
    }

    // FIXED: Improved page loading with better error handling
    function loadPage(pageNum, pageData) {
      if (loadingPages.has(pageNum)) return;
      
      loadingPages.add(pageNum);
      console.log('Loading page', pageNum);
      
      window.parent.postMessage({ 
        type: 'requestPage', 
        page: pageNum 
      }, '*');
    }

    // FIXED: Improved page rendering with memory optimization
    function renderPage(pageNum, pdfPage, canvas) {
      const pageElement = pageElements.get(pageNum);
      if (!pageElement) return;
      
      const container = pageElement.container;
      const dimensions = pageElement.dimensions;
      
      if (!dimensions) {
        console.warn('No dimensions for page', pageNum);
        return;
      }
      
      let widthPt = dimensions.width;
      let heightPt = dimensions.height;
      
      if (dimensions.unit === 'mm') {
        widthPt = dimensions.width * 2.83465;
        heightPt = dimensions.height * 2.83465;
      } else if (dimensions.unit === 'in') {
        widthPt = dimensions.width * 72;
        heightPt = dimensions.height * 72;
      }
      
      const viewport = pdfPage.getViewport({ scale: scale * pixelRatio });
      
      canvas.width = Math.floor(viewport.width);
      canvas.height = Math.floor(viewport.height);
      canvas.style.width = Math.floor(viewport.width / pixelRatio) + 'px';
      canvas.style.height = Math.floor(viewport.height / pixelRatio) + 'px';
      
      const context = canvas.getContext('2d', { alpha: false });
      
      const renderContext = {
        canvasContext: context,
        viewport: viewport,
        intent: 'display',
        enableWebGL: false, // Disable WebGL for better memory management
        renderInteractiveForms: false
      };
      
      const renderTask = pdfPage.render(renderContext);
      
      renderTask.promise.then(() => {
        console.log('Rendered page', pageNum, 'at', Math.round(scale * 100) + '%');
        
        // Clean up PDF page to free memory
        pdfPage.cleanup();
        
        // Remove loading state
        container.classList.remove('loading');
        
        // Remove spinner if exists
        const spinner = container.querySelector('.loading-spinner');
        if (spinner) {
          spinner.remove();
        }
        
        pageElement.rendered = true;
        
      }).catch(error => {
        console.error('Error rendering page', pageNum, ':', error);
        container.classList.remove('loading');
        
        const errorMsg = document.createElement('div');
        errorMsg.className = 'error-message';
        errorMsg.textContent = 'Error loading page';
        errorMsg.style.color = '#f44336';
        errorMsg.style.padding = '20px';
        errorMsg.style.textAlign = 'center';
        container.appendChild(errorMsg);
        
        window.parent.postMessage({ 
          type: 'error', 
          message: 'Failed to render page ' + pageNum + ': ' + error.message 
        }, '*');
      });
    }

    // Handle incoming page data from Flutter
    window.addEventListener('message', (event) => {
      const data = event.data;
      
      if (data.type === 'sendPage') {
        const pageNum = data.page;
        const pageData = data.data;
        
        if (pageData && pageElements.has(pageNum)) {
          console.log('Received data for page', pageNum, 'size:', pageData.length, 'bytes');
          
          const pageElement = pageElements.get(pageNum);
          const container = pageElement.container;
          
          // Remove existing canvas if any
          const existingCanvas = container.querySelector('canvas');
          if (existingCanvas) {
            existingCanvas.remove();
          }
          
          // Create new canvas
          const canvas = document.createElement('canvas');
          canvas.style.width = '100%';
          canvas.style.height = '100%';
          container.appendChild(canvas);
          
          // Convert base64 to Uint8Array
          const binaryString = atob(pageData);
          const bytes = new Uint8Array(binaryString.length);
          for (let i = 0; i < binaryString.length; i++) {
            bytes[i] = binaryString.charCodeAt(i);
          }
          
          // Load PDF page
          pdfjsLib.getDocument(bytes).promise.then(pdf => {
            return pdf.getPage(1);
          }).then(pdfPage => {
            pageElement.pdf = pdfPage;
            pageElement.canvas = canvas;
            renderPage(pageNum, pdfPage, canvas);
          }).catch(error => {
            console.error('Error loading PDF for page', pageNum, ':', error);
            window.parent.postMessage({ 
              type: 'error', 
              message: 'Failed to load PDF for page ' + pageNum + ': ' + error.message 
            }, '*');
          });
          
          loadingPages.delete(pageNum);
        }
      }
      
      if (data.type === 'navigateToPage') {
        navigateToPage(data.page);
      }
      
      if (data.type === 'setZoom') {
        scale = Math.max(0.5, Math.min(maxZoom, data.zoom));
        applyZoom();
      }
      
      if (data.type === 'getCurrentPage') {
        const current = getCurrentVisiblePage();
        window.parent.postMessage({ 
          type: 'currentPageReport', 
          page: current 
        }, '*');
      }
      
      if (data.type === 'clearCache') {
        console.log('Clearing page cache');
        for (let [pageNum, element] of pageElements) {
          if (element.canvas) {
            const context = element.canvas.getContext('2d');
            context.clearRect(0, 0, element.canvas.width, element.canvas.height);
            element.canvas.width = 0;
            element.canvas.height = 0;
            element.canvas.remove();
            element.canvas = null;
          }
          element.rendered = false;
          element.container.classList.add('loading');
        }
        
        // Force garbage collection hint
        if (window.gc) {
          window.gc();
        }
        
        window.parent.postMessage({ type: 'cacheCleared' }, '*');
      }
      
      if (data.type === 'lowMemory') {
        memoryWarning.textContent = 'Low Memory - Clearing Cache';
        memoryWarning.classList.add('visible');
        
        setTimeout(() => {
          memoryWarning.classList.remove('visible');
        }, 3000);
        
        // Clear all canvases
        for (let [pageNum, element] of pageElements) {
          if (element.canvas && Math.abs(pageNum - currentPage) > 2) {
            element.canvas.remove();
            element.canvas = null;
            element.rendered = false;
            element.container.classList.add('loading');
          }
        }
      }
    });

    // Initialize when DOM is ready
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', init);
    } else {
      init();
    }
  </script>
</body>
</html>
''';

    // Set the iframe source
    final blob = html.Blob([htmlContent], 'text/html');
    final url = html.Url.createObjectUrlFromBlob(blob);
    _iframeElement.src = url;

    // Clean up blob URL when done
    _iframeElement.onLoad.listen((_) {
      html.Url.revokeObjectUrl(url);
    });
  }

  void _setIframePointerEvents(bool enabled) {
    if (_iframeElement.style != null) {
      _iframeElement.style.pointerEvents = enabled ? 'auto' : 'none';
    }
  }

  void _loadInitialPages() {
    if (_documentInfo == null) return;

    // Load first page immediately
    _queuePageLoad(1, priority: true);

    // Preload next few pages
    for (int i = 2; i <= 3 && i <= _documentInfo!.totalPages; i++) {
      _queuePageLoad(i);
    }
  }

  void _queuePageLoad(int pageNum, {bool priority = false}) {
    if (_loadingPages.contains(pageNum) || _pageCache.contains(pageNum)) {
      return;
    }

    if (priority) {
      _loadQueue.insert(0, pageNum);
    } else {
      _loadQueue.add(pageNum);
    }

    _processLoadQueue();
  }

  void _processLoadQueue() async {
    // Don't process during scroll prevention (except for current page)
    if (_isScrollPrevented && !_loadQueue.contains(_currentPage)) {
      return;
    }

    while (_loadingPages.length < widget.config.maxConcurrentLoads && _loadQueue.isNotEmpty) {
      final pageNum = _loadQueue.removeAt(0);

      if (!_pageCache.contains(pageNum) && !_loadingPages.contains(pageNum)) {
        _loadingPages.add(pageNum);
        _performanceMonitor.startPageLoad(pageNum);

        try {
          await _loadAndSendPage(pageNum);
        } catch (e) {
          print('Error loading page $pageNum: $e');
          _loadingPages.remove(pageNum);
          _handlePageLoadError(pageNum, e);
        }
      }
    }
  }

  Future<void> _loadAndSendPage(int pageNum) async {
    if (!mounted) return;

    try {
      final pageData = await _apiService.getPageAsPdf (
        widget.documentId,
        pageNum,
      );

      if (!mounted) return;

      // Convert to base64 for sending to JavaScript
      final base64Data = base64Encode(pageData);

      // Send to JavaScript
      _iframeElement.contentWindow?.postMessage({
        'type': 'sendPage',
        'page': pageNum,
        'data': base64Data,
      }, '*');

      // Cache the page data
      _pageCache.put(pageNum, pageData);

      _loadingPages.remove(pageNum);
      _performanceMonitor.endPageLoad(pageNum);

      // Process next in queue
      _processLoadQueue();

      _debugLog('Loaded page $pageNum (${pageData.length} bytes)');
    } catch (e) {
      _loadingPages.remove(pageNum);
      rethrow;
    }
  }

  void _handlePageLoadError(int pageNum, dynamic error) {
    _errorCount++;
    _lastErrorTime = DateTime.now();

    print('Failed to load page $pageNum: $error');

    // Auto-retry for transient errors
    if (widget.config.enableAutoRetry && _errorCount <= 3) {
      Future.delayed(Duration(seconds: 1 * _errorCount), () {
        if (mounted && !_pageCache.contains(pageNum) && !_loadingPages.contains(pageNum)) {
          _queuePageLoad(pageNum, priority: true);
        }
      });
    }
  }

  void _preloadNearbyPages(int currentPage) {
    if (_documentInfo == null) return;

    // Don't preload during scroll prevention
    if (_isScrollPrevented) {
      return;
    }

    final pagesToLoad = <int>[];

    // Current page first
    if (!_pageCache.contains(currentPage) && !_loadingPages.contains(currentPage)) {
      pagesToLoad.add(currentPage);
    }

    // Preload nearby pages
    for (int i = 1; i <= widget.config.cacheWindowSize; i++) {
      final nextPage = currentPage + i;
      final prevPage = currentPage - i;

      if (nextPage <= _documentInfo!.totalPages &&
          !_pageCache.contains(nextPage) &&
          !_loadingPages.contains(nextPage)) {
        pagesToLoad.add(nextPage);
      }

      if (prevPage >= 1 &&
          !_pageCache.contains(prevPage) &&
          !_loadingPages.contains(prevPage)) {
        pagesToLoad.add(prevPage);
      }
    }

    for (final page in pagesToLoad) {
      _queuePageLoad(page);
    }

    if (pagesToLoad.isNotEmpty) {
      _debugLog('Preloading ${pagesToLoad.length} pages around page $currentPage');
    }
  }

  void _cleanupDistantPages(int currentPage) {
    final pagesToRemove = _pageCache.getPagesToEvict(
      currentPage,
      widget.config.cacheWindowSize + 1,
    );

    for (final page in pagesToRemove) {
      _removePageFromCache(page);
    }

    if (pagesToRemove.isNotEmpty) {
      _debugLog('Cleaned up ${pagesToRemove.length} distant pages');
    }
  }

  void _removePageFromCache(int pageNum) {
    _pageCache.remove(pageNum);
    _pageAccessTimes.remove(pageNum);
    _pageAccessOrder.remove(pageNum);

    // Tell JavaScript to clear this page
    _iframeElement.contentWindow?.postMessage({
      'type': 'clearPage',
      'page': pageNum,
    }, '*');
  }

  void _updatePageAccess(int pageNum) {
    _pageAccessTimes[pageNum] = DateTime.now();
    _pageAccessOrder.remove(pageNum);
    _pageAccessOrder.add(pageNum);
  }

  void _performPeriodicCleanup() {
    if (!mounted) return;

    final now = DateTime.now();
    final cutoffTime = now.subtract(const Duration(minutes: 2));

    // Remove pages not accessed recently
    final oldPages = _pageAccessTimes.entries
        .where((entry) => entry.value.isBefore(cutoffTime))
        .map((entry) => entry.key)
        .toList();

    for (final page in oldPages) {
      if (page != _currentPage) {
        _removePageFromCache(page);
      }
    }

    if (oldPages.isNotEmpty) {
      _debugLog('Periodic cleanup: removed ${oldPages.length} old pages');
    }

    // Clean up access order list
    if (_pageAccessOrder.length > 100) {
      _pageAccessOrder.removeRange(0, _pageAccessOrder.length - 50);
    }

    // Force garbage collection if available
    _forceGarbageCollection();

    _debugMemoryLog();
  }

  void _forceGarbageCollection() {
    try {
      // Try to trigger garbage collection
      html.window.postMessage({'type': 'gc'}, '*');
    } catch (e) {
      // Ignore errors
    }
  }

  void _monitorMemoryUsage() {
    if (!mounted) return;

    final totalMemory = _pageCache.totalMemory;
    final memoryMB = totalMemory / (1024 * 1024);

    if (memoryMB > widget.config.maxMemoryMB * 0.8) {
      _handleLowMemory();
    }

    // Log performance metrics periodically
    final metrics = _performanceMonitor.getMetrics();
    print('[PERFORMANCE] ${metrics}');
  }

  void _handleLowMemory() {
    _debugLog('LOW MEMORY DETECTED - Performing aggressive cleanup');

    // Keep only current page and immediate neighbors
    final pagesToKeep = {
      _currentPage,
      _currentPage - 1,
      _currentPage + 1,
    }.where((page) => page >= 1 && page <= (_documentInfo?.totalPages ?? 0)).toSet();

    final keysToRemove = _pageCache.keys
        .where((page) => !pagesToKeep.contains(page))
        .toList();

    for (final key in keysToRemove) {
      _removePageFromCache(key);
    }

    // Clear all queues
    _loadQueue.clear();

    // Cancel all loading operations
    _loadingPages.clear();

    // Notify JavaScript
    _iframeElement.contentWindow?.postMessage({
      'type': 'lowMemory',
    }, '*');

    _debugLog('AGGRESSIVE MEMORY CLEANUP: Removed ${keysToRemove.length} pages');
    _debugMemoryLog();

    // Force garbage collection
    _forceGarbageCollection();
  }

  void _cleanupAllResources() {
    _pageCache.clear();
    _loadingPages.clear();
    _loadQueue.clear();
    _pageAccessTimes.clear();
    _pageAccessOrder.clear();

    _scrollPreventionTimer?.cancel();
    _cleanupTimer?.cancel();
    _memoryMonitorTimer?.cancel();

    // Notify JavaScript to clear everything
    _iframeElement.contentWindow?.postMessage({
      'type': 'clearCache',
    }, '*');
  }

  void _navigateToPage(int pageNum) {
    if (_documentInfo == null) return;

    final targetPage = pageNum.clamp(1, _documentInfo!.totalPages);
    setState(() {
      _currentPage = targetPage;
      _pageController.text = targetPage.toString();
    });

    _iframeElement.contentWindow?.postMessage({
      'type': 'navigateToPage',
      'page': targetPage,
    }, '*');

    // Ensure target page is loaded
    if (!_pageCache.contains(targetPage) && !_loadingPages.contains(targetPage)) {
      _queuePageLoad(targetPage, priority: true);
    }
  }

  void _handlePageInput() {
    final input = _pageController.text;
    final pageNum = int.tryParse(input);

    if (pageNum != null &&
        _documentInfo != null &&
        pageNum >= 1 &&
        pageNum <= _documentInfo!.totalPages) {
      _navigateToPage(pageNum);
    } else {
      // Reset to current page if invalid
      _pageController.text = _currentPage.toString();
    }
  }

  void _zoomIn() {
    final newZoom = (_zoomLevel + 0.1).clamp(0.5, 3.0);
    _iframeElement.contentWindow?.postMessage({
      'type': 'setZoom',
      'zoom': newZoom,
    }, '*');
  }

  void _zoomOut() {
    final newZoom = (_zoomLevel - 0.1).clamp(0.5, 3.0);
    _iframeElement.contentWindow?.postMessage({
      'type': 'setZoom',
      'zoom': newZoom,
    }, '*');
  }

  void _resetZoom() {
    _iframeElement.contentWindow?.postMessage({
      'type': 'setZoom',
      'zoom': 1.0,
    }, '*');
  }

  @override
  void dispose() {
    _cleanupAllResources();
    _pageController.dispose();
    _pageFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Colors.grey[900],
        foregroundColor: Colors.white,
        actions: [
          // Page navigation
          if (_documentInfo != null) ...[
            IconButton(
              icon: const Icon(Icons.first_page),
              onPressed: _currentPage > 1 ? () => _navigateToPage(1) : null,
              tooltip: 'First page',
            ),
            IconButton(
              icon: const Icon(Icons.navigate_before),
              onPressed: _currentPage > 1 ? () => _navigateToPage(_currentPage - 1) : null,
              tooltip: 'Previous page',
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 50,
                    child: TextField(
                      controller: _pageController,
                      focusNode: _pageFocusNode,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 4),
                      ),
                      onTap: () {
                        setState(() {
                          _isEditingPage = true;
                        });
                      },
                      onEditingComplete: () {
                        setState(() {
                          _isEditingPage = false;
                        });
                        _handlePageInput();
                      },
                      onSubmitted: (_) {
                        setState(() {
                          _isEditingPage = false;
                        });
                        _handlePageInput();
                      },
                    ),
                  ),
                  Text(
                    ' / ${_documentInfo!.totalPages}',
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.navigate_next),
              onPressed: _currentPage < (_documentInfo?.totalPages ?? 0)
                  ? () => _navigateToPage(_currentPage + 1)
                  : null,
              tooltip: 'Next page',
            ),
            IconButton(
              icon: const Icon(Icons.last_page),
              onPressed: _currentPage < (_documentInfo?.totalPages ?? 0)
                  ? () => _navigateToPage(_documentInfo!.totalPages)
                  : null,
              tooltip: 'Last page',
            ),
          ],
          // Zoom controls
          IconButton(
            icon: const Icon(Icons.zoom_out),
            onPressed: _zoomOut,
            tooltip: 'Zoom out',
          ),
          IconButton(
            icon: Text('${(_zoomLevel * 100).round()}%'),
            onPressed: _resetZoom,
            tooltip: 'Reset zoom',
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in),
            onPressed: _zoomIn,
            tooltip: 'Zoom in',
          ),
        ],
      ),
      body: Stack(
        children: [
          // PDF Viewer
          if (_isLoading && _error == null)
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text(
                    'Loading document...',
                    style: TextStyle(fontSize: 16),
                  ),
                ],
              ),
            )
          else if (_error != null)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 64,
                    color: Colors.red[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Error loading document',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.red[400],
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32.0),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: _loadDocument,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            )
          else
            HtmlElementView(
              viewType: _viewId,
            ),

          // Scroll prevention overlay
          if (_isScrollPrevented)
            Container(
              color: Colors.black.withOpacity(0.3),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.touch_app,
                        size: 48,
                        color: Colors.white,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _isMobile ? 'Scroll disabled for 2 seconds' : 'Scroll disabled for 1 second',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'This prevents accidental scrolling after zoom',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Memory usage indicator (debug)
          if (widget.config.enableDebugLogging)
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${(_pageCache.totalMemory / (1024 * 1024)).toStringAsFixed(2)}MB | ${_pageCache.size} cached',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}