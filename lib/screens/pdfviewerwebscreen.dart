import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf_image_viewer/appconfig.dart';
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'dart:convert';
import '../services/pdf_api_service.dart';
import '../models/document_info.dart';
import 'dart:math' as math;


//very bad

enum PdfViewMode {
  singlePage,    // View one page at a time
  multiplePages  // View multiple pages in scroll
}

class PdfViewerConfig {
  final int cacheSize;
  final int maxConcurrentLoads;
  final int cacheWindowSize;
  final Duration cleanupInterval;
  final int maxMemoryMB;
  final bool enablePerformanceMonitoring;
  final bool enableAutoRetry;
  final bool enableDebugLogging;
  final PdfViewMode viewMode;
  final int preloadPagesAhead;
  final int preloadPagesBehind;

  const PdfViewerConfig({
    this.cacheSize = 10,
    this.maxConcurrentLoads = 3,
    this.cacheWindowSize = 3,
    this.cleanupInterval = const Duration(seconds: 5),
    this.maxMemoryMB = 50,
    this.enablePerformanceMonitoring = true,
    this.enableAutoRetry = true,
    this.enableDebugLogging = false,
    this.viewMode = PdfViewMode.multiplePages,
    this.preloadPagesAhead = 3,
    this.preloadPagesBehind = 3,
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

  _SmartPageCache({int maxSize = 15, int maxMemoryMB = 30})
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
  PdfViewMode _currentViewMode = PdfViewMode.multiplePages;

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

    _currentViewMode = widget.config.viewMode;
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

        case 'pageRendered':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null) {
              _debugLog('Page $pageNum rendered successfully');
            }
          }
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

    // Smart preloading based on view mode and document size
    _smartPreloadPages(pageNum);

    _cleanupDistantPages(pageNum);
    _debugMemoryLog();
  }

  void _smartPreloadPages(int currentPage) {
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

    final pagesToLoad = <int>[];

    // Current page first
    if (!_pageCache.contains(currentPage) && !_loadingPages.contains(currentPage)) {
      pagesToLoad.add(currentPage);
    }

    // Preload based on view mode and configuration
    if (_currentViewMode == PdfViewMode.multiplePages) {
      // Preload pages ahead
      for (int i = 1; i <= widget.config.preloadPagesAhead; i++) {
        final nextPage = currentPage + i;
        if (nextPage <= _documentInfo!.totalPages &&
            !_pageCache.contains(nextPage) &&
            !_loadingPages.contains(nextPage)) {
          pagesToLoad.add(nextPage);
        }
      }

      // Preload pages behind
      for (int i = 1; i <= widget.config.preloadPagesBehind; i++) {
        final prevPage = currentPage - i;
        if (prevPage >= 1 &&
            !_pageCache.contains(prevPage) &&
            !_loadingPages.contains(prevPage)) {
          pagesToLoad.add(prevPage);
        }
      }
    } else {
      // Single page mode - only load current page
      // No additional preloading
    }

    for (final page in pagesToLoad) {
      _queuePageLoad(page);
    }

    if (pagesToLoad.isNotEmpty) {
      print('Smart preloading ${pagesToLoad.length} pages around page $currentPage');
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
    final viewModeString = _currentViewMode == PdfViewMode.singlePage ? 'singlePage' : 'multiplePages';

    final htmlContent = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes">
  <title>${widget.title}</title>
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
      padding: 0;
    }
    .single-page-view #pdf-container {
      display: flex;
      justify-content: center;
      align-items: center;
      overflow: hidden;
    }
    .multiple-pages-view #pdf-container {
      display: block;
      overflow: auto;
    }
    #pages-wrapper {
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 20px 0;
      gap: 20px;
      min-width: min-content;
    }
    .single-page-view #pages-wrapper {
      padding: 0;
      height: 100%;
      justify-content: center;
    }
    .page-container {
      position: relative;
      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
      background: white;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0 auto;
    }
    .page-container.loading {
      background: #f5f5f5;
      min-height: 200px;
      min-width: 200px;
    }
    .page-canvas {
      display: block;
      max-width: 100%;
      height: auto;
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
    
    /* Enhanced loading spinner */
    .enhanced-spinner {
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      z-index: 5;
      text-align: center;
    }
    .spinner {
      width: 40px;
      height: 40px;
      border: 4px solid #f3f3f3;
      border-top: 4px solid #3498db;
      border-radius: 50%;
      animation: spin 1s linear infinite;
      margin: 0 auto;
    }
    @keyframes spin {
      0% { transform: rotate(0deg); }
      100% { transform: rotate(360deg); }
    }
    .loading-text {
      margin-top: 10px;
      color: #666;
      font-size: 14px;
      text-align: center;
    }
    
    @media (max-width: 768px) {
      .page-indicator {
        right: 20px;
        padding: 10px 14px;
      }
      .page-indicator .current {
        font-size: 20px;
      }
      .multiple-pages-view #pages-wrapper {
        padding: 10px 0;
        gap: 10px;
      }
    }
  </style>
</head>
<body class="${viewModeString}-view">
  <div id="pdf-container" role="main" aria-label="PDF Document">
    <div id="pages-wrapper"></div>
  </div>
  <div id="page-indicator" class="page-indicator" role="status" aria-live="polite" aria-atomic="true">
    <span class="current" id="current-page">1</span>
    <span class="total">of ${_documentInfo!.totalPages}</span>
  </div>

  <script type="module">
    const pdfjsLib = await import('https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.min.mjs');
    pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.worker.min.mjs';

    // Mobile detection
    const isAndroid = /Android/i.test(navigator.userAgent);
    const isIOS = /iPhone|iPad|iPod/i.test(navigator.userAgent);
    const isMobile = isAndroid || isIOS;
    
    const basePixelRatio = window.devicePixelRatio || 1;
    const pixelRatio = isMobile ? Math.min(basePixelRatio, 1.5) : basePixelRatio;

    // Zoom limits
    const maxZoomMobile = 3.0;
    const maxZoomDesktop = 5.0;
    const maxZoom = isMobile ? maxZoomMobile : maxZoomDesktop;
    const minZoom = 0.25;

    console.log('Device detected:', { isAndroid, isIOS, isMobile, pixelRatio, maxZoom });

    let scale = 1.0;
    let currentPage = 1;
    const totalPages = ${_documentInfo!.totalPages};
    const pageDimensions = ${pageDimensionsJsonString};
    let currentViewMode = '${viewModeString}';
    
    const container = document.getElementById('pdf-container');
    const pagesWrapper = document.getElementById('pages-wrapper');
    const body = document.body;
    const pageIndicator = document.getElementById('page-indicator');
    const pageIndicatorCurrent = pageIndicator.querySelector('.current');
    const pageIndicatorTotal = pageIndicator.querySelector('.total');
    
    const pageElements = new Map();
    const loadingPages = new Set();
    const renderedPages = new Map(); // Store PDF page objects
    const pdfDocuments = new Map(); // Store PDF documents for each page
    
    let scrollStopTimeout = null;
    const SCROLL_STOP_DELAY = 150;

    function init() {
      console.log('Initializing viewer with', totalPages, 'pages');
      console.log('View mode:', currentViewMode);
      console.log('Page dimensions available:', pageDimensions.length, 'pages');
      
      // Calculate optimal initial scale
      const optimalScale = calculateOptimalScale();
      scale = optimalScale;
      console.log('Initial scale:', optimalScale);
      
      // Create page containers
      for (let i = 1; i <= totalPages; i++) {
        createPageElement(i, optimalScale);
      }
      
      // Set up event listeners
      setupEventListeners();
      
      // Initialize page indicator
      pageIndicatorTotal.textContent = 'of ' + totalPages;
      updatePageIndicator(1);
      
      // Notify Flutter that viewer is ready
      sendMessageToFlutter({ type: 'viewerReady' });
      
      // Load initial pages
      loadInitialPages();
    }
    
    function calculateOptimalScale() {
      if (pageDimensions.length === 0) return 1.0;
      
      const containerWidth = container.clientWidth - 40;
      const containerHeight = container.clientHeight - 40;
      const firstPage = pageDimensions[0];
      
      const pageWidth = firstPage.width;
      const pageHeight = firstPage.height;
      
      const widthScale = (containerWidth * 0.9) / pageWidth;
      const heightScale = (containerHeight * 0.9) / pageHeight;
      
      let optimalScale = Math.min(widthScale, heightScale);
      optimalScale = Math.max(0.5, Math.min(optimalScale, 3.0));
      optimalScale = Math.round(optimalScale * 100) / 100;
      
      console.log('Scale calculation:', {
        containerWidth, containerHeight,
        pageWidth, pageHeight,
        widthScale, heightScale,
        optimalScale
      });
      
      return optimalScale;
    }
    
    function createPageElement(pageNum, initialScale) {
      const pageContainer = document.createElement('div');
      pageContainer.className = 'page-container loading';
      pageContainer.id = 'page-' + pageNum;
      pageContainer.dataset.pageNumber = pageNum.toString();
      
      const pageDim = pageDimensions.find(p => p.pageNumber === pageNum);
      if (pageDim) {
        const displayWidth = Math.floor(pageDim.width * initialScale);
        const displayHeight = Math.floor(pageDim.height * initialScale);
        
        pageContainer.style.width = displayWidth + 'px';
        pageContainer.style.height = displayHeight + 'px';
        
        console.log('Page', pageNum, 'size:', displayWidth + 'x' + displayHeight);
      } else {
        pageContainer.style.width = '100%';
        pageContainer.style.height = '400px';
      }
      
      // Add loading spinner
      const spinner = document.createElement('div');
      spinner.className = 'enhanced-spinner';
      spinner.innerHTML = \`
        <div class="spinner"></div>
        <div class="loading-text">Loading page \${pageNum}</div>
      \`;
      pageContainer.appendChild(spinner);
      
      pagesWrapper.appendChild(pageContainer);
      pageElements.set(pageNum, pageContainer);
    }
    
    function setupEventListeners() {
      // Scroll events
      container.addEventListener('scroll', handleScroll, { passive: true });
      
      // Message events from Flutter
      window.addEventListener('message', handleFlutterMessage);
    }
    
    function handleScroll() {
      clearTimeout(scrollStopTimeout);
      
      scrollStopTimeout = setTimeout(() => {
        const finalPage = calculateCurrentPage();
        sendMessageToFlutter({ 
          type: 'scrollStopped', 
          page: finalPage
        });
        updateCurrentPage(finalPage);
      }, SCROLL_STOP_DELAY);
      
      // Update current page during scroll
      updateCurrentPage();
    }
    
    function calculateCurrentPage() {
      const scrollTop = container.scrollTop;
      const containerHeight = container.clientHeight;
      const scrollCenter = scrollTop + (containerHeight / 2);
      
      let closestPage = 1;
      let minDistance = Infinity;
      
      for (let i = 1; i <= totalPages; i++) {
        const pageElement = pageElements.get(i);
        if (!pageElement) continue;
        
        const pageTop = pageElement.offsetTop;
        const pageBottom = pageTop + pageElement.offsetHeight;
        const pageCenter = (pageTop + pageBottom) / 2;
        
        const distance = Math.abs(scrollCenter - pageCenter);
        if (distance < minDistance) {
          minDistance = distance;
          closestPage = i;
        }
      }
      
      return closestPage;
    }
    
    function updateCurrentPage(forcePage = null) {
      const page = forcePage || calculateCurrentPage();
      
      if (page !== currentPage && page >= 1 && page <= totalPages) {
        currentPage = page;
        updatePageIndicator(page);
        sendMessageToFlutter({ type: 'pageInView', page: page });
        
        // Load nearby pages when page changes
        loadNearbyPages(page);
      }
    }
    
    function updatePageIndicator(page) {
      pageIndicatorCurrent.textContent = page;
      pageIndicator.classList.add('visible');
      
      clearTimeout(pageIndicator.hideTimeout);
      pageIndicator.hideTimeout = setTimeout(() => {
        pageIndicator.classList.remove('visible');
      }, 2000);
    }
    
    function loadInitialPages() {
      console.log('Loading initial pages');
      // Load first page immediately
      loadPage(1);
      
      // Preload nearby pages
      if (currentViewMode === 'multiplePages') {
        for (let i = 2; i <= Math.min(5, totalPages); i++) {
          loadPage(i);
        }
      }
    }
    
    function loadNearbyPages(centerPage) {
      if (currentViewMode !== 'multiplePages') return;
      
      const preloadRange = 2;
      for (let i = centerPage - preloadRange; i <= centerPage + preloadRange; i++) {
        if (i >= 1 && i <= totalPages && i !== centerPage) {
          loadPage(i);
        }
      }
    }
    
    function loadPage(pageNum) {
      if (pageNum < 1 || pageNum > totalPages) return;
      if (loadingPages.has(pageNum) || renderedPages.has(pageNum)) return;
      
      console.log('Requesting page', pageNum);
      loadingPages.add(pageNum);
      sendMessageToFlutter({ type: 'requestPage', page: pageNum });
    }
    
    async function renderPage(pageNum, pdfData) {
      console.log('Rendering page', pageNum, 'with PDF data length:', pdfData.length);
      
      if (!pageElements.has(pageNum)) {
        console.error('Page element not found for page', pageNum);
        return;
      }
      
      const pageContainer = pageElements.get(pageNum);
      
      try {
        // Remove loading spinner
        const spinner = pageContainer.querySelector('.enhanced-spinner');
        if (spinner) {
          spinner.remove();
        }
        
        // Remove existing canvas if any
        const existingCanvas = pageContainer.querySelector('.page-canvas');
        if (existingCanvas) {
          existingCanvas.remove();
        }
        
        // Convert base64 to Uint8Array
        const binaryString = atob(pdfData);
        const bytes = new Uint8Array(binaryString.length);
        for (let i = 0; i < binaryString.length; i++) {
          bytes[i] = binaryString.charCodeAt(i);
        }
        
        console.log('Loading PDF document for page', pageNum);
        
        // Load PDF document
        const pdfDoc = await pdfjsLib.getDocument(bytes).promise;
        pdfDocuments.set(pageNum, pdfDoc);
        
        // Get the first page (since each page is a separate PDF)
        const pdfPage = await pdfDoc.getPage(1);
        renderedPages.set(pageNum, pdfPage);
        
        // Create canvas
        const canvas = document.createElement('canvas');
        canvas.className = 'page-canvas';
        
        const pageDim = pageDimensions.find(p => p.pageNumber === pageNum);
        if (pageDim) {
          const displayWidth = Math.floor(pageDim.width * scale);
          const displayHeight = Math.floor(pageDim.height * scale);
          
          // Set canvas dimensions for high DPI displays
          const renderScale = scale * pixelRatio;
          const viewport = pdfPage.getViewport({ scale: renderScale });
          
          canvas.width = viewport.width;
          canvas.height = viewport.height;
          canvas.style.width = displayWidth + 'px';
          canvas.style.height = displayHeight + 'px';
        }
        
        // Render PDF page to canvas
        const renderContext = {
          canvasContext: canvas.getContext('2d'),
          viewport: pdfPage.getViewport({ scale: scale * pixelRatio }),
        };
        
        console.log('Rendering PDF page', pageNum, 'at scale', scale);
        
        await pdfPage.render(renderContext).promise;
        
        pageContainer.appendChild(canvas);
        pageContainer.classList.remove('loading');
        loadingPages.delete(pageNum);
        
        // Add page number if not exists
        if (!pageContainer.querySelector('.page-number')) {
          const pageNumber = document.createElement('div');
          pageNumber.className = 'page-number';
          pageNumber.textContent = pageNum + ' / ' + totalPages;
          pageContainer.appendChild(pageNumber);
        }
        
        console.log('Page', pageNum, 'rendered successfully');
        sendMessageToFlutter({ type: 'pageRendered', page: pageNum });
        
      } catch (error) {
        console.error('Error rendering page', pageNum, ':', error);
        loadingPages.delete(pageNum);
        
        // Show error message
        const errorMsg = document.createElement('div');
        errorMsg.style.color = 'red';
        errorMsg.style.padding = '20px';
        errorMsg.style.textAlign = 'center';
        errorMsg.textContent = 'Failed to render page ' + pageNum + ': ' + error.message;
        pageContainer.appendChild(errorMsg);
        pageContainer.classList.remove('loading');
      }
    }
    
    async function rerenderPage(pageNum) {
      if (!renderedPages.has(pageNum)) return;
      
      const pageContainer = pageElements.get(pageNum);
      const pdfPage = renderedPages.get(pageNum);
      const canvas = pageContainer.querySelector('.page-canvas');
      
      if (!canvas || !pdfPage) return;
      
      try {
        const pageDim = pageDimensions.find(p => p.pageNumber === pageNum);
        if (pageDim) {
          const displayWidth = Math.floor(pageDim.width * scale);
          const displayHeight = Math.floor(pageDim.height * scale);
          
          // Update canvas dimensions
          const renderScale = scale * pixelRatio;
          const viewport = pdfPage.getViewport({ scale: renderScale });
          
          canvas.width = viewport.width;
          canvas.height = viewport.height;
          canvas.style.width = displayWidth + 'px';
          canvas.style.height = displayHeight + 'px';
          
          // Re-render with new scale
          const renderContext = {
            canvasContext: canvas.getContext('2d'),
            viewport: viewport,
          };
          
          await pdfPage.render(renderContext).promise;
          console.log('Re-rendered page', pageNum, 'at scale', scale);
        }
      } catch (error) {
        console.error('Error re-rendering page', pageNum, ':', error);
      }
    }
    
    function handleFlutterMessage(event) {
      const data = event.data;
      if (!data || !data.type) return;
      
      console.log('Received message from Flutter:', data.type);
      
      switch(data.type) {
        case 'sendPage':
          if (data.page && data.data) {
            console.log('Processing PDF data for page', data.page);
            renderPage(data.page, data.data);
          } else {
            console.error('Invalid sendPage data:', data);
          }
          break;
          
        case 'navigateToPage':
          if (data.page) {
            const pageNum = parseInt(data.page);
            if (pageNum >= 1 && pageNum <= totalPages) {
              const pageElement = pageElements.get(pageNum);
              if (pageElement) {
                container.scrollTo({
                  top: pageElement.offsetTop - 20,
                  behavior: 'smooth'
                });
                currentPage = pageNum;
                updatePageIndicator(pageNum);
              }
            }
          }
          break;
          
        case 'setZoom':
          if (data.zoom !== undefined) {
            console.log('Setting zoom to:', data.zoom);
            scale = data.zoom;
            updateAllPageSizes();
            
            // Re-render all visible pages with new zoom
            rerenderVisiblePages();
          }
          break;
          
        case 'changeViewMode':
          if (data.viewMode) {
            body.className = data.viewMode + '-view';
            currentViewMode = data.viewMode;
            console.log('View mode changed to:', data.viewMode);
          }
          break;
          
        case 'clearPage':
          if (data.page) {
            const pageElement = pageElements.get(data.page);
            if (pageElement) {
              const canvas = pageElement.querySelector('.page-canvas');
              if (canvas) {
                canvas.remove();
              }
              pageElement.classList.add('loading');
              renderedPages.delete(data.page);
              pdfDocuments.delete(data.page);
            }
          }
          break;
          
        case 'getCurrentPage':
          sendMessageToFlutter({ type: 'currentPageReport', page: currentPage });
          break;
      }
    }
    
    function updateAllPageSizes() {
      console.log('Updating all page sizes to scale:', scale);
      for (let i = 1; i <= totalPages; i++) {
        const pageContainer = pageElements.get(i);
        const pageDim = pageDimensions.find(p => p.pageNumber === i);
        
        if (pageContainer && pageDim) {
          const displayWidth = Math.floor(pageDim.width * scale);
          const displayHeight = Math.floor(pageDim.height * scale);
          
          pageContainer.style.width = displayWidth + 'px';
          pageContainer.style.height = displayHeight + 'px';
          
          // Update canvas size if exists
          const canvas = pageContainer.querySelector('.page-canvas');
          if (canvas) {
            canvas.style.width = displayWidth + 'px';
            canvas.style.height = displayHeight + 'px';
          }
        }
      }
    }
    
    async function rerenderVisiblePages() {
      const visiblePages = getVisiblePages();
      console.log('Re-rendering visible pages:', visiblePages);
      
      for (const pageNum of visiblePages) {
        if (renderedPages.has(pageNum)) {
          await rerenderPage(pageNum);
        }
      }
    }
    
    function getVisiblePages() {
      const visiblePages = [];
      const scrollTop = container.scrollTop;
      const scrollBottom = scrollTop + container.clientHeight;
      
      for (let i = 1; i <= totalPages; i++) {
        const pageElement = pageElements.get(i);
        if (!pageElement) continue;
        
        const pageTop = pageElement.offsetTop;
        const pageBottom = pageTop + pageElement.offsetHeight;
        
        if (pageBottom >= scrollTop && pageTop <= scrollBottom) {
          visiblePages.push(i);
        }
      }
      
      return visiblePages;
    }
    
    function sendMessageToFlutter(message) {
      if (window.parent) {
        window.parent.postMessage(message, '*');
      }
    }
    
    // Initialize when ready
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
    _iframeElement.style.pointerEvents = enabled ? 'auto' : 'none';
  }

  void _loadInitialPages() {
    if (_documentInfo == null) return;

    // Load first page immediately
    _queuePageLoad(1, priority: true);

    // Preload nearby pages based on view mode
    if (_currentViewMode == PdfViewMode.multiplePages) {
      for (int i = 2; i <= math .min(3, _documentInfo!.totalPages); i++) {
        _queuePageLoad(i);
      }
    }

    // Center page 1 after initial load
    _centerPage1();
  }

  void _centerPage1() {
    // Wait for viewer to be ready and page to load
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted && _viewerInitialized) {
        // Send message to JavaScript to center page 1
        _iframeElement.contentWindow?.postMessage({
          'type': 'centerPage1',
        }, '*');

        print('Centering page 1...');
      }
    });
  }

  void _queuePageLoad(int page, {bool priority = false}) {
    if (_loadingPages.contains(page) || _pageCache.contains(page)) {
      return;
    }

    if (priority) {
      _loadQueue.insert(0, page);
    } else {
      _loadQueue.add(page);
    }

    _processLoadQueue();
  }

  void _processLoadQueue() {
    if (_loadingPages.length >= widget.config.maxConcurrentLoads) {
      return;
    }

    if (_loadQueue.isEmpty) {
      return;
    }

    final page = _loadQueue.removeAt(0);
    _loadingPages.add(page);

    _debugLog('Starting load for page $page (${_loadingPages.length} concurrent, ${_loadQueue.length} queued)');

    _loadAndSendPage(page);
  }

  Future<void> _loadAndSendPage(int pageNum) async {
    if (!mounted) return;

    _performanceMonitor.startPageLoad(pageNum);

    try {
      // This should return PDF data for the specific page
      final pdfData = await _apiService.getPageAsPdf(
        widget.documentId,
        pageNum,
      ).timeout(const Duration(seconds: 30));

      if (!mounted) return;

      _pageCache.put(pageNum, pdfData);
      _loadedPages.add(pageNum);
      _updatePageAccess(pageNum);

      // Send PDF data to JavaScript viewer
      _sendPageToViewer(pageNum, pdfData);

      _performanceMonitor.endPageLoad(pageNum);

    } catch (e) {
      print('Error loading page $pageNum: $e');
      _handlePageLoadError(pageNum, e);
    } finally {
      _loadingPages.remove(pageNum);
      _processLoadQueue();
    }
  }

  void _sendPageToViewer(int pageNum, Uint8List pdfData) {
    if (!_viewerInitialized) return;

    final base64Data = base64Encode(pdfData);

    _iframeElement.contentWindow?.postMessage({
      'type': 'sendPage',
      'page': pageNum,
      'data': base64Data,
    }, '*');

    _debugLog('Sent PDF data for page $pageNum to viewer (${pdfData.length} bytes)');
  }



  void _handlePageLoadError(int page, dynamic error) {
    _errorCount++;
    _lastErrorTime = DateTime.now();

    print('Page $page load error: $error (error count: $_errorCount)');

    // Auto-retry for transient errors
    if (widget.config.enableAutoRetry && _errorCount <= 3) {
      Future.delayed(Duration(seconds: _errorCount), () {
        if (mounted && !_pageCache.contains(page)) {
          _queuePageLoad(page);
        }
      });
    }
  }

  void _updatePageAccess(int page) {
    _pageAccessTimes[page] = DateTime.now();
    _pageAccessOrder.remove(page);
    _pageAccessOrder.add(page);
  }

  void _cleanupDistantPages(int currentPage) {
    final pagesToEvict = _pageCache.getPagesToEvict(
      currentPage,
      widget.config.cacheWindowSize,
    );

    for (final page in pagesToEvict) {
      _removePageFromCache(page);
    }

    if (pagesToEvict.isNotEmpty) {
      _debugLog('Cleaned up ${pagesToEvict.length} distant pages');
    }
  }

  void _removePageFromCache(int page) {
    _pageCache.remove(page);
    _loadedPages.remove(page);
    _pageAccessOrder.remove(page);
    _pageAccessTimes.remove(page);

    // Notify JavaScript to clear canvas
    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'clearPage',
        'page': page,
      }, '*');
    }
  }

  void _performPeriodicCleanup() {
    if (!mounted) return;

    final now = DateTime.now();
    final pagesToEvict = <int>[];

    for (final entry in _pageAccessTimes.entries) {
      final page = entry.key;
      final accessTime = entry.value;

      if (now.difference(accessTime) > const Duration(minutes: 2)) {
        pagesToEvict.add(page);
      }
    }

    for (final page in pagesToEvict) {
      _removePageFromCache(page);
    }

    if (pagesToEvict.isNotEmpty) {
      _debugLog('Periodic cleanup: removed ${pagesToEvict.length} old pages');
    }

    // Force garbage collection if available
    //_forceGarbageCollection();
  }

  void _monitorMemoryUsage() {
    if (!widget.config.enablePerformanceMonitoring) return;

    final memoryMB = _pageCache.totalMemory / (1024 * 1024);

    if (memoryMB > widget.config.maxMemoryMB * 0.8) {
      _handleLowMemory();
    }

    // Log performance metrics periodically
    if (widget.config.enableDebugLogging) {
      final metrics = _performanceMonitor.getMetrics();
      print('Performance Metrics: $metrics');
      _debugMemoryLog();
    }
  }

  void _handleLowMemory() {
    _debugLog('LOW MEMORY DETECTED - Performing aggressive cleanup');

    // Keep only current page and immediate neighbors
    final pagesToKeep = {
      _currentPage,
      _currentPage - 1,
      _currentPage + 1,
    }.where((page) => page >= 1 && page <= _documentInfo!.totalPages).toSet();

    final keysToRemove = _pageCache.keys
        .where((page) => !pagesToKeep.contains(page))
        .toList();

    for (final key in keysToRemove) {
      _removePageFromCache(key);
    }

    // Clear queues
    _loadQueue.clear();

    // Cancel loading pages
    final loadingToCancel = _loadingPages
        .where((page) => !pagesToKeep.contains(page))
        .toList();

    for (final page in loadingToCancel) {
      _loadingPages.remove(page);
    }

    // Notify JavaScript
    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'lowMemory',
      }, '*');
    }

    _debugLog('LOW MEMORY CLEANUP: Removed ${keysToRemove.length} pages, kept ${pagesToKeep.length} pages');
  }



  void _cleanupAllResources() {
    _pageCache.clear();
    _loadedPages.clear();
    _loadingPages.clear();
    _loadQueue.clear();
    _pageAccessTimes.clear();
    _pageAccessOrder.clear();

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'clearAll',
      }, '*');
    }
  }

  void _navigateToPage(int page) {
    if (page < 1 || page > _documentInfo!.totalPages) return;

    setState(() {
      _currentPage = page;
      _pageController.text = page.toString();
    });

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'setPage',
        'page': page,
      }, '*');
    }

    // Ensure page is loaded
    if (!_pageCache.contains(page) && !_loadingPages.contains(page)) {
      _queuePageLoad(page, priority: true);
    }

    _updatePageAccess(page);
  }

  void _changeViewMode(PdfViewMode newMode) {
    setState(() {
      _currentViewMode = newMode;
    });

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'changeViewMode',
        'viewMode': newMode == PdfViewMode.singlePage ? 'singlePage' : 'multiplePages', // Make sure this is a string
      }, '*');
    }

    // Re-center current page
    _navigateToPage(_currentPage);
  }

  void _zoomIn() {
    final newZoom = (_zoomLevel * 1.2).clamp(0.25, 5.0);
    _setZoom(newZoom);
  }

  void _zoomOut() {
    final newZoom = (_zoomLevel / 1.2).clamp(0.25, 5.0);
    _setZoom(newZoom);
  }

  void _resetZoom() {
    _setZoom(1.0);
  }

  void _setZoom(double zoom) {
    setState(() {
      _zoomLevel = zoom;
    });

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'setZoom',
        'zoom': zoom,
      }, '*');
    }

    // Reload current page with new zoom
    if (_pageCache.contains(_currentPage)) {
      _pageCache.remove(_currentPage);
      _queuePageLoad(_currentPage, priority: true);
    }
  }

  @override
  void dispose() {
    _cleanupTimer?.cancel();
    _memoryMonitorTimer?.cancel();
    _scrollPreventionTimer?.cancel();
    _pageController.dispose();
    _pageFocusNode.dispose();
    _cleanupAllResources();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // View mode toggle
          PopupMenuButton<PdfViewMode>(
            icon: const Icon(Icons.view_day),
            onSelected: _changeViewMode,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: PdfViewMode.singlePage,
                child: Row(
                  children: [
                    Icon(
                      Icons.view_day,
                      color: _currentViewMode == PdfViewMode.singlePage
                          ? Theme.of(context).primaryColor
                          : null,
                    ),
                    const SizedBox(width: 8),
                    const Text('Single Page'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: PdfViewMode.multiplePages,
                child: Row(
                  children: [
                    Icon(
                      Icons.view_week,
                      color: _currentViewMode == PdfViewMode.multiplePages
                          ? Theme.of(context).primaryColor
                          : null,
                    ),
                    const SizedBox(width: 8),
                    const Text('Multiple Pages'),
                  ],
                ),
              ),
            ],
          ),
          // Zoom controls
          PopupMenuButton<double>(
            icon: const Icon(Icons.zoom_in),
            itemBuilder: (context) => [
              PopupMenuItem(
                child: const Text('Zoom In'),
                onTap: _zoomIn,
              ),
              PopupMenuItem(
                child: const Text('Zoom Out'),
                onTap: _zoomOut,
              ),
              PopupMenuItem(
                child: const Text('Reset Zoom'),
                onTap: _resetZoom,
              ),
              PopupMenuItem(
                enabled: false,
                child: Text('Current: ${(_zoomLevel * 100).round()}%'),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _buildBottomNavigation(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading document...'),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: Colors.red,
              ),
              SizedBox(height: 16),
              Text(
                'Error loading document',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadDocument,
                child: Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        // PDF Viewer
        HtmlElementView(
          viewType: _viewId,
        ),

        // Loading overlay for current page
        if (_loadingPages.contains(_currentPage))
          Positioned(
            top: 100,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Loading page $_currentPage...',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          ),

        // Scroll prevention overlay
        if (_isScrollPrevented)
          Positioned.fill(
            child: Container(
              color: Colors.transparent,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.zoom_in, color: Colors.white, size: 32),
                      SizedBox(height: 8),
                      Text(
                        'Zooming...\nScroll disabled temporarily',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // Memory warning
        if (_pageCache.totalMemory > widget.config.maxMemoryMB * 0.9 * 1024 * 1024)
          Positioned(
            top: 20,
            left: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.9),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.memory, color: Colors.white),
                  SizedBox(width: 8),
                  Text(
                    'High memory usage',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBottomNavigation() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).bottomAppBarTheme.color,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.chevron_left),
            onPressed: _currentPage > 1
                ? () => _navigateToPage(_currentPage - 1)
                : null,
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 60,
                  child: TextField(
                    controller: _pageController,
                    focusNode: _pageFocusNode,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onTap: () {
                      setState(() {
                        _isEditingPage = true;
                      });
                    },
                    onSubmitted: (value) {
                      setState(() {
                        _isEditingPage = false;
                      });
                      final page = int.tryParse(value);
                      if (page != null) {
                        _navigateToPage(page);
                      } else {
                        _pageController.text = _currentPage.toString();
                      }
                    },
                    onEditingComplete: () {
                      setState(() {
                        _isEditingPage = false;
                      });
                      final page = int.tryParse(_pageController.text);
                      if (page != null) {
                        _navigateToPage(page);
                      } else {
                        _pageController.text = _currentPage.toString();
                      }
                    },
                  ),
                ),
                Text(
                  ' of ${_documentInfo?.totalPages ?? '?'}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.chevron_right),
            onPressed: _currentPage < (_documentInfo?.totalPages ?? 1)
                ? () => _navigateToPage(_currentPage + 1)
                : null,
          ),
        ],
      ),
    );
  }
}