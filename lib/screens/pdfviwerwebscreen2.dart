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

class _SmartPageCache {
  final Map<int, Uint8List> _cache = {};
  final List<int> _accessOrder = [];
  final Map<int, DateTime> _accessTimes = {};
  final int _maxSize;
  final int _maxMemoryBytes;

  _SmartPageCache({int maxSize = 10, int maxMemoryMB = 30})
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

  bool containsKey(int page) => _cache.containsKey(page);

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

class PdfViewerWebScreen2 extends StatefulWidget {
  final String documentId;
  final String? apiBaseUrl;
  final String title;
  final PdfViewerConfig config;

  const PdfViewerWebScreen2({
    Key? key,
    required this.documentId,
    this.apiBaseUrl,
    required this.title,
    required this.config,
  }) : super(key: key);

  @override
  State<PdfViewerWebScreen2> createState() => _PdfViewerWebScreen2State();
}

class _PdfViewerWebScreen2State extends State<PdfViewerWebScreen2> {
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

  // Page cache - cache window lebih kecil
  final _SmartPageCache _pageCache = _SmartPageCache();
  final int _cacheWindowSize = 2; // Dikurangi dari 3 ke 2

  // Loading control - lebih ketat
  final Set<int> _loadingPages = {};
  final int _maxConcurrentLoads = 2; // Dikurangi dari 3 ke 2
  final List<int> _loadQueue = [];

  // Tambahan untuk kontrol scroll yang lebih baik
  int _lastStableCurrentPage = 1;
  DateTime _lastScrollTime = DateTime.now();
  bool _isScrolling = false;

  bool _isZooming = false;

  Timer? _pageLoadDebounceTimer;
  int? _pendingPageLoad;

  // TAMBAH SEMUA INI:
  Timer? _scrollPreventionTimer;
  bool _isScrollPrevented = false;
  DateTime? _lastZoomTime;
  Timer? _cleanupTimer;
  Timer? _memoryMonitorTimer;
  final Map<int, DateTime> _pageAccessTimes = {};
  final List<int> _pageAccessOrder = [];
  int _errorCount = 0;
  DateTime? _lastErrorTime;
  bool _isRecovering = false;
  final _PdfPerformanceMonitor _performanceMonitor = _PdfPerformanceMonitor();
  DateTime? _currentPageViewStart;
  final TextEditingController _pageController = TextEditingController();
  final FocusNode _pageFocusNode = FocusNode();
  bool _isEditingPage = false;
  Timer? _emergencyLoadTimer;

  @override
  void initState() {
    super.initState();
    _apiService = PdfApiService(
      baseUrl: widget.apiBaseUrl ?? AppConfig.baseUrl,
    );

    _initializePdfViewer();
    _loadDocument();
  }

  // TAMBAH METHOD INI:
  void _updatePageAccess(int pageNumber) {
    _pageAccessTimes[pageNumber] = DateTime.now();
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

  void _aggressiveCleanupDuringScroll() {
    if (_documentInfo == null) return;

    _debugLog('Starting aggressive cleanup during scroll');

    // Keep current page + immediate neighbor untuk prevent blank
    final pagesToKeep = {
      _currentPage,
      _currentPage - 1,
      _currentPage + 1,
    }.where((page) => page >= 1 && page <= _documentInfo!.totalPages).toSet();

    final keysToRemove = _pageCache.keys
        .where((page) => !pagesToKeep.contains(page))
        .toList();

    // Remove dari cache
    for (final key in keysToRemove) {
      _removePageFromCache(key);
    }

    // Clear semua queue
    _loadQueue.clear();

    // Cancel semua loading kecuali pages to keep
    final loadingToCancel = _loadingPages
        .where((page) => !pagesToKeep.contains(page))
        .toList();

    for (final page in loadingToCancel) {
      _loadingPages.remove(page);
    }

    if (keysToRemove.isNotEmpty) {
      _debugLog('AGGRESSIVE CLEANUP: Removed ${keysToRemove.length} pages, kept pages $pagesToKeep');
      _debugLog('Cancelled ${loadingToCancel.length} loading operations');
    }

    _debugMemoryLog();
  }

  void _preloadNearbyPagesReduced(int currentPage) {
    if (_documentInfo == null) return;

    if (_isScrollPrevented || (_isScrolling && !_isZooming)) {
      _debugLog('Skipping preload - scroll prevented or scrolling');
      return;
    }

    final pagesToLoad = <int>[];

    // Prioritas 1: Current page
    if (!_pageCache.containsKey(currentPage) && !_loadingPages.contains(currentPage)) {
      pagesToLoad.add(currentPage);
    }

    // Prioritas 2: Load 2 halaman sebelum dan 2 halaman sesudah
    for (int offset = 1; offset <= 2; offset++) {
      // Next pages
      final nextPage = currentPage + offset;
      if (nextPage <= _documentInfo!.totalPages &&
          !_pageCache.containsKey(nextPage) &&
          !_loadingPages.contains(nextPage)) {
        pagesToLoad.add(nextPage);
      }

      // Previous pages
      final prevPage = currentPage - offset;
      if (prevPage >= 1 &&
          !_pageCache.containsKey(prevPage) &&
          !_loadingPages.contains(prevPage)) {
        pagesToLoad.add(prevPage);
      }
    }

    // Queue semua halaman
    for (final page in pagesToLoad) {
      _queuePageLoad(page);
    }

    if (pagesToLoad.isNotEmpty) {
      _debugLog('Preloading ${pagesToLoad.length} pages: $pagesToLoad around page $currentPage');
    } else {
      _debugLog('No pages to preload - all nearby pages already cached/loading');
    }
  }

  void _sendClearPageToViewer(int pageNumber) {
    if (!_viewerInitialized) return;

    _iframeElement.contentWindow?.postMessage({
      'type': 'clearPage',
      'page': pageNumber,
    }, '*');
  }

  void _removePageFromCache(int pageNumber) {
    _pageCache.remove(pageNumber);
    _loadedPages.remove(pageNumber);
    _pageAccessTimes.remove(pageNumber);
    _sendClearPageToViewer(pageNumber);
  }

  void _cleanupAllResources() {
    for (final pageNum in _pageCache.keys.toList()) {
      _sendClearPageToViewer(pageNum);
    }

    _pageCache.clear();
    _loadQueue.clear();
    _loadingPages.clear();
    _loadedPages.clear();
    _pageAccessTimes.clear();
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

      print('Received message: $type');

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

              // IMMEDIATE load jika page visible tapi tidak ada di cache
              if (!_pageCache.containsKey(pageNum) &&
                  !_loadingPages.contains(pageNum) &&
                  !_isScrolling) {
                _debugLog('Page $pageNum visible but not cached - immediate load');
                _loadingPages.add(pageNum);
                _loadAndSendPage(pageNum);
              }
            }
          }
          break;

        case 'scrollStateChanged':
          final isScrolling = data['isScrolling'];
          if (isScrolling != null) {
            _handleScrollStateChange(isScrolling as bool);
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
              print('Page $pageNum requested');
              _queuePageLoad(pageNum);
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
      }
    } catch (e) {
      print('Error handling PDF.js message: $e');
    }
  }

  void _handleScrollStateChange(bool isScrolling) {
    if (_isScrollPrevented) {
      return;
    }

    _isScrolling = isScrolling;
    _lastScrollTime = DateTime.now();

    if (isScrolling && !_isZooming) {
      _debugLog('Scroll STARTED - cancelling pending loads');

      // Cancel pending page load saat scroll dimulai lagi
      if (_pageLoadDebounceTimer?.isActive ?? false) {
        _pageLoadDebounceTimer?.cancel();
        _pendingPageLoad = null;
        _debugLog('Debounce timer CANCELLED due to new scroll');
      }

      // Cancel ALL loads saat fast scrolling
      _cancelNonCriticalLoads();

      // Cleanup memory SELAMA scrolling
      _aggressiveCleanupDuringScroll();
    } else {
      _debugLog('Scroll state changed but not scrolling or zooming');
    }
  }
  void _handleScrollStopped(int pageNum) {
    if (_isScrollPrevented) {
      _debugLog('Scroll stopped IGNORED - scroll prevention active');
      return;
    }

    _debugLog('=== SCROLL STOPPED at page $pageNum ===');
    _isScrolling = false;
    _lastStableCurrentPage = pageNum;

    // Cancel any existing timers
    _pageLoadDebounceTimer?.cancel();
    _emergencyLoadTimer?.cancel();
    _debugLog('Cancelled previous timers');

    // Check if page is already loaded
    if (_pageCache.containsKey(pageNum)) {
      _debugLog('Page $pageNum already in cache, just preloading nearby');
      _preloadNearbyPagesReduced(pageNum);
      _cleanupDistantPages(pageNum);
      return;
    }

    // IMMEDIATE load if not in cache (no debounce for empty page)
    if (!_loadingPages.contains(pageNum)) {
      _debugLog('Page $pageNum NOT in cache - IMMEDIATE load (no debounce)');
      _loadingPages.add(pageNum);
      _loadAndSendPage(pageNum);
    }

    // DEBOUNCE untuk preload pages sekitar
    _pendingPageLoad = pageNum;
    _debugLog('Starting 200ms debounce for preloading nearby pages...');

    _pageLoadDebounceTimer = Timer(const Duration(milliseconds: 200), () {
      _debugLog('Debounce timer FIRED - preloading nearby pages');
      if (_pendingPageLoad == pageNum && mounted) {
        _preloadNearbyPagesReduced(pageNum);
        _cleanupDistantPages(pageNum);
        _debugMemoryLog();
      }
    });

    // EMERGENCY: If after 1 second page still not loaded, force load
    _emergencyLoadTimer = Timer(const Duration(seconds: 1), () {
      if (mounted && !_pageCache.containsKey(pageNum) && !_loadingPages.contains(pageNum)) {
        _debugLog('EMERGENCY LOAD: Page $pageNum still not loaded after 1s!');
        _loadingPages.add(pageNum);
        _loadAndSendPage(pageNum);
      }
    });
  }

  void _executePageLoad(int pageNum) {
    _debugLog('=== EXECUTING PAGE LOAD for page $pageNum ===');

    // Force immediate load of current page if not loaded
    if (!_pageCache.containsKey(pageNum) && !_loadingPages.contains(pageNum)) {
      _debugLog('Page $pageNum NOT in cache and NOT loading, adding to load queue');
      _loadingPages.add(pageNum);
      _loadAndSendPage(pageNum);
    } else {
      _debugLog('Page $pageNum already loaded or loading. Cache=${_pageCache.containsKey(pageNum)}, Loading=${_loadingPages.contains(pageNum)}');
    }

    // Preload nearby pages
    if (_documentInfo != null && _documentInfo!.totalPages > 100) {
      _debugLog('Document > 100 pages, using reduced preload');
      _preloadNearbyPagesReduced(pageNum);
    } else {
      _debugLog('Document <= 100 pages, using normal preload');
      _preloadNearbyPages(pageNum);
    }

    _cleanupDistantPages(pageNum);
    _debugMemoryLog();
  }

  void _cancelNonCriticalLoads() {
    // Batalkan semua yang di queue
    _loadQueue.clear();

    // Batalkan loading yang jauh dari current page
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
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final info = await _apiService.getDocumentInfo(widget.documentId);
      setState(() {
        _documentInfo = info;
      });

      _initializeViewer();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _initializeViewer() {
    if (_documentInfo == null) return;

    setState(() {
      _isLoading = false;
    });

    // Add this debug logging
    // ADD THESE DEBUG LINES
    print('==========================================');
    print('DEBUG _initializeViewer() called');
    print('DEBUG: totalPages = ${_documentInfo!.totalPages}');
    print('DEBUG: pages list length = ${_documentInfo!.pages?.length ?? "NULL"}');

    if (_documentInfo!.pages != null && _documentInfo!.pages!.isNotEmpty) {
      print('DEBUG: First page number = ${_documentInfo!.pages!.first.pageNumber}');
      print('DEBUG: First page width = ${_documentInfo!.pages!.first.dimensions.width}');
      print('DEBUG: First page height = ${_documentInfo!.pages!.first.dimensions.height}');
      print('DEBUG: First page unit = ${_documentInfo!.pages!.first.dimensions.unit}');
    } else {
      print('DEBUG: pages is NULL or EMPTY!');
    }


    // Build page dimensions JSON for JavaScript
    final pageDimensionsJson = _documentInfo!.pages?.map((page) {
      return {
        'pageNumber': page.pageNumber,
        'width': page.dimensions.width,
        'height': page.dimensions.height,
        'unit': page.dimensions.unit,
        'orientation': page.orientation,
      };
    }).toList() ?? [];

    print('DEBUG: pageDimensionsJson length = ${pageDimensionsJson.length}');
    print('==========================================');



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
    }
    #pages-wrapper {
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 20px 0;
      gap: 20px;
    }
    .page-container {
      position: relative;
      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
      background: white;
      display: flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
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
      text-align: center;
      padding: 20px;
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
    }
  </style>
</head>
<body>
  <div id="pdf-container">
    <div id="pages-wrapper"></div>
  </div>
  <div id="page-indicator" class="page-indicator">
    <span class="current">1</span>
    <span class="total">of 1</span>
  </div>
  <div id="scroll-speed-indicator" class="scroll-speed-indicator">
    Fast Scrolling - Loading Paused
  </div>

  <script type="module">
    const pdfjsLib = await import('https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.min.mjs');
    pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.worker.min.mjs';

    const container = document.getElementById('pdf-container');
    const pagesWrapper = document.getElementById('pages-wrapper');
    const pixelRatio = window.devicePixelRatio || 1;
    
    let scale = 1.0;
    let currentPage = 1;
    const totalPages = ${_documentInfo!.totalPages};
    const pageData = new Map();
    const pageElements = new Map();
    const loadingPages = new Set();
    
    // Page dimensions from DocumentInfo - CRITICAL DATA
    const pageDimensions = ${jsonEncode(pageDimensionsJson)};
    
    // Enhanced scroll control
    let scrollTimeout = null;
    let lastScrollTop = 0;
    let scrollVelocity = 0;
    let isScrolling = false;
    let scrollStopTimeout = null;
    const SCROLL_STOP_DELAY = 500;
    const FAST_SCROLL_THRESHOLD = 500;
    
    // Page visibility timers untuk debounce
    const pageVisibilityTimers = new Map();
    const PAGE_VISIBLE_THRESHOLD = 100;
    
    // Helper function to convert dimensions to pixels
    function convertToPixels(width, height, unit, currentScale) {
  // Use window.innerWidth instead of container.clientWidth for more reliable detection
  const viewportWidth = window.innerWidth || document.documentElement.clientWidth;
  const isMobile = viewportWidth < 768;
  const baseScale = isMobile ? 1.2 : 1.5;
  const finalScale = (currentScale || scale) * baseScale;
  
  let widthPt = width;
  let heightPt = height;
  
  // Convert to points first if needed
  if (unit === 'mm') {
    widthPt = width * 2.83465; // mm to pt
    heightPt = height * 2.83465;
  } else if (unit === 'in') {
    widthPt = width * 72; // in to pt
    heightPt = height * 72;
  }
  
  // Apply scale
  const widthPx = widthPt * finalScale;
  const heightPx = heightPt * finalScale;
  
  return { 
    width: Math.round(widthPx), 
    height: Math.round(heightPx) 
  };
}
    
    // Calculate all page dimensions at current scale
    function calculateAllPageDimensions(currentScale) {
      const dimensions = new Map();
      
      pageDimensions.forEach(function(dimInfo) {
        const dims = convertToPixels(
          dimInfo.width, 
          dimInfo.height, 
          dimInfo.unit,
          currentScale
        );
        dimensions.set(dimInfo.pageNumber, dims);
      });
      
      return dimensions;
    }
    
    function init() {
      console.log('Initializing viewer with', totalPages, 'pages');
      console.log('Page dimensions data available:', pageDimensions.length);
      
      if (pageDimensions.length === 0) {
        console.warn('No page dimension data available! Pages will use fallback sizing.');
      }
      
      // Pre-calculate all page dimensions at initial scale
      const initialDimensions = calculateAllPageDimensions(scale);
      
      // Create ALL page containers with proper dimensions BEFORE loading
      for (let i = 1; i <= totalPages; i++) {
        const pageContainer = document.createElement('div');
        pageContainer.className = 'page-container loading';
        pageContainer.id = 'page-' + i;
        
        // Find dimension info for this page
        const dimInfo = pageDimensions.find(function(d) { return d.pageNumber === i; });
        
        if (dimInfo && initialDimensions.has(i)) {
          // Set exact dimensions from PageInfo
          const dims = initialDimensions.get(i);
          pageContainer.style.width = dims.width + 'px';
          pageContainer.style.height = dims.height + 'px';
          
          console.log('Page', i, 'pre-sized:', dims.width + 'x' + dims.height + 'px', 
                      '(' + dimInfo.orientation + ',', dimInfo.unit + ')');
        } else {
          // Fallback for pages without dimension info
          console.warn('Page', i, 'missing dimension info, using fallback');
          pageContainer.style.width = '595px'; // A4 width at 72 DPI
          pageContainer.style.height = '842px'; // A4 height at 72 DPI
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
        
        // Store page element with dimension info
        pageElements.set(i, { 
          container: pageContainer, 
          canvas: null, 
          pdf: null, 
          rendered: false,
          dimensions: dimInfo 
        });
      }
      
      console.log('All', totalPages, 'page containers created with pre-calculated dimensions');
      console.log('Total document height:', pagesWrapper.scrollHeight + 'px');
      
      setupScrollListener();
      setupZoomControls();
      setupKeyboardControls();
      
      console.log('Sending viewerReady message');
      window.parent.postMessage({ type: 'viewerReady' }, '*');
    }
    
    function setupScrollListener() {
      const pageIndicator = document.getElementById('page-indicator');
      const pageIndicatorCurrent = pageIndicator.querySelector('.current');
      const pageIndicatorTotal = pageIndicator.querySelector('.total');
      const scrollSpeedIndicator = document.getElementById('scroll-speed-indicator');
      
      pageIndicatorTotal.textContent = 'of ' + totalPages;
      
      let indicatorTimeout;
      let lastScrollTime = Date.now();
      let lastTouchEnd = 0;
      let touchScrollTimer = null;
      
      container.addEventListener('touchstart', function(e) {
        console.log('Touch started');
        isScrolling = true;
        clearTimeout(scrollStopTimeout);
        clearTimeout(touchScrollTimer);
      }, { passive: true });

      container.addEventListener('touchmove', function(e) {
        isScrolling = true;
        scrollSpeedIndicator.classList.add('visible');
        
        clearTimeout(scrollStopTimeout);
        clearTimeout(touchScrollTimer);
        
        lastScrollTop = container.scrollTop;
        lastScrollTime = Date.now();
      }, { passive: true });

      container.addEventListener('touchend', function(e) {
        lastTouchEnd = Date.now();
        console.log('Touch ended');
        
        clearTimeout(touchScrollTimer);
        touchScrollTimer = setTimeout(function() {
          const timeSinceLastScroll = Date.now() - lastScrollTime;
          if (timeSinceLastScroll > 200) {
            console.log('Touch scroll stopped (no momentum)');
            isScrolling = false;
            scrollSpeedIndicator.classList.remove('visible');
            triggerScrollStopped();
          }
        }, 200);
      }, { passive: true });
      
      function triggerScrollStopped() {
        console.log('=== TRIGGER SCROLL STOPPED ===');
        console.log('Current page:', currentPage);
        
        window.parent.postMessage({ 
          type: 'scrollStopped', 
          page: currentPage,
          wasFastScrolling: scrollVelocity > FAST_SCROLL_THRESHOLD
        }, '*');
        
        const visiblePagesNow = [];
        const containerRect = container.getBoundingClientRect();
        
        for (let i = 1; i <= totalPages; i++) {
          const pageEl = document.getElementById('page-' + i);
          if (!pageEl) continue;
          
          const pageRect = pageEl.getBoundingClientRect();
          
          if (pageRect.bottom > containerRect.top && pageRect.top < containerRect.bottom) {
            const visibleTop = Math.max(pageRect.top, containerRect.top);
            const visibleBottom = Math.min(pageRect.bottom, containerRect.bottom);
            const visibleHeight = visibleBottom - visibleTop;
            const visibilityRatio = visibleHeight / pageRect.height;
            
            if (visibilityRatio > 0.05) {
              visiblePagesNow.push({ 
                page: i, 
                ratio: visibilityRatio 
              });
              pageVisibilityTimers.set(i, Date.now());
            }
          }
        }
        
        visiblePagesNow.sort(function(a, b) {
          return b.ratio - a.ratio;
        });
        
        console.log('Visible pages:', visiblePagesNow.map(function(p) {
          return p.page + '(' + (p.ratio * 100).toFixed(0) + '%)';
        }).join(', '));
        
        if (isScrolling) {
          console.log('ABORT: Still scrolling flag is true');
          return;
        }
        
        setTimeout(function() {
          if (isScrolling) {
            console.log('ABORT: User scrolling again');
            return;
          }
          
          console.log('--- Requesting visible pages ---');
          
          let retryCount = 0;
          const maxRetries = 4;
          
          const requestVisiblePages = function() {
            retryCount++;
            
            if (isScrolling) {
              console.log('ABORT: Scrolling during retry');
              return;
            }
            
            console.log('Attempt', retryCount);
            
            let requestedCount = 0;
            const stillMissing = [];
            
            visiblePagesNow.forEach(function(pageInfo) {
              const pageNum = pageInfo.page;
              
              if (!pageData.has(pageNum)) {
                if (!loadingPages.has(pageNum)) {
                  console.log('REQ page', pageNum);
                  loadingPages.add(pageNum);
                  window.parent.postMessage({ type: 'requestPage', page: pageNum }, '*');
                  requestedCount++;
                }
                stillMissing.push(pageNum);
              }
            });
            
            console.log('Requested:', requestedCount, 'Missing:', stillMissing.length);
            
            const allLoaded = visiblePagesNow.every(function(pageInfo) {
              return pageData.has(pageInfo.page);
            });
            
            if (!allLoaded && retryCount < maxRetries && !isScrolling) {
              setTimeout(requestVisiblePages, 400);
            } else {
              if (allLoaded) {
                console.log('SUCCESS: All loaded');
              } else {
                console.log('INCOMPLETE after', maxRetries, 'attempts');
              }
            }
          };
          
          requestVisiblePages();
          
        }, 150);
      }
      
      container.addEventListener('scroll', function() {
        const now = Date.now();
        const currentScrollTop = container.scrollTop;
        const timeDelta = now - lastScrollTime;
        
        if (timeDelta > 0) {
          scrollVelocity = Math.abs(currentScrollTop - lastScrollTop) / timeDelta * 1000;
        }
        
        lastScrollTop = currentScrollTop;
        lastScrollTime = now;
        
        const isFastScrolling = scrollVelocity > FAST_SCROLL_THRESHOLD;
        
        if (isFastScrolling && !isScrolling) {
          isScrolling = true;
          scrollSpeedIndicator.classList.add('visible');
          window.parent.postMessage({ type: 'scrollStateChanged', isScrolling: true }, '*');
        }
        
        clearTimeout(scrollStopTimeout);
        clearTimeout(touchScrollTimer);
        
        scrollStopTimeout = setTimeout(function() {
          const timeSinceTouchEnd = Date.now() - lastTouchEnd;
          if (timeSinceTouchEnd > 500) {
            isScrolling = false;
            scrollSpeedIndicator.classList.remove('visible');
            triggerScrollStopped();
          }
        }, SCROLL_STOP_DELAY);
        
        pageIndicator.classList.add('visible');
        clearTimeout(indicatorTimeout);
        indicatorTimeout = setTimeout(function() {
          pageIndicator.classList.remove('visible');
        }, 1500);
      });
      
      const observer = new IntersectionObserver(function(entries) {
        const visiblePages = new Map();
        
        entries.forEach(function(entry) {
          const pageNum = parseInt(entry.target.id.split('-')[1]);
          
          if (entry.isIntersecting && entry.intersectionRatio > 0) {
            visiblePages.set(pageNum, entry.intersectionRatio);
            
            if (!pageVisibilityTimers.has(pageNum)) {
              pageVisibilityTimers.set(pageNum, Date.now());
            }
          } else {
            pageVisibilityTimers.delete(pageNum);
          }
        });
        
        if (visiblePages.size === 0) return;
        
        let mostVisiblePage = currentPage;
        let highestVisibility = 0;
        
        visiblePages.forEach(function(ratio, pageNum) {
          if (ratio > highestVisibility) {
            highestVisibility = ratio;
            mostVisiblePage = pageNum;
          }
        });
        
        if (highestVisibility > 0.3 && mostVisiblePage !== currentPage) {
          console.log('Page changed:', currentPage, '->', mostVisiblePage, '(' + (highestVisibility * 100).toFixed(0) + '% visible)');
          currentPage = mostVisiblePage;
          pageIndicatorCurrent.textContent = currentPage;
          window.parent.postMessage({ type: 'pageInView', page: currentPage }, '*');
        }
        
        if (!isScrolling) {
          const now = Date.now();
          
          visiblePages.forEach(function(ratio, pageNum) {
            if (ratio > 0.1 && !pageData.has(pageNum) && !loadingPages.has(pageNum)) {
              const visibleSince = pageVisibilityTimers.get(pageNum);
              const visibleDuration = visibleSince ? now - visibleSince : 0;
              
              if (visibleDuration >= PAGE_VISIBLE_THRESHOLD) {
                console.log('Auto-requesting page', pageNum, '(visible for ' + visibleDuration + 'ms)');
                loadingPages.add(pageNum);
                window.parent.postMessage({ type: 'requestPage', page: pageNum }, '*');
              }
            }
          });
        }
      }, {
        root: container,
        rootMargin: '100px 0px',
        threshold: [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
      });
      
      pageElements.forEach(function(data, pageNum) {
        observer.observe(data.container);
      });
    }
    
    async function renderPage(pageNum, pdfData) {
      const pageInfo = pageElements.get(pageNum);
      if (!pageInfo || pageInfo.rendered) return;
      
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
        const ctx = canvas.getContext('2d');
        
        const containerWidth = container.clientWidth;
        const isMobile = containerWidth < 768;
        const baseScale = isMobile ? 1.2 : 1.5;
        const finalScale = scale * baseScale;
        
        const viewport = page.getViewport({ scale: finalScale });
        
        canvas.width = viewport.width * pixelRatio;
        canvas.height = viewport.height * pixelRatio;
        canvas.style.width = viewport.width + 'px';
        canvas.style.height = viewport.height + 'px';
        
        ctx.scale(pixelRatio, pixelRatio);
        
        await page.render({
          canvasContext: ctx,
          viewport: viewport,
          background: 'rgba(255, 255, 255, 1)',
        }).promise;
        
        pageInfo.container.innerHTML = '';
        pageInfo.container.appendChild(canvas);
        
        const pageNumber = document.createElement('div');
        pageNumber.className = 'page-number';
        pageNumber.textContent = pageNum + ' / ' + totalPages;
        pageInfo.container.appendChild(pageNumber);
        
        pageInfo.container.classList.remove('loading');
        
        // Update container to exact rendered size
        pageInfo.container.style.width = viewport.width + 'px';
        pageInfo.container.style.height = viewport.height + 'px';
        
        pageInfo.canvas = canvas;
        pageInfo.pdf = pdf;
        pageInfo.page = page;
        pageInfo.rendered = true;
        
        pageData.set(pageNum, { pdf, page, canvas });
        loadingPages.delete(pageNum);
        
      } catch (error) {
        console.error('Error rendering page ' + pageNum + ':', error);
        pageInfo.container.querySelector('.loading-spinner').textContent = 'Error loading page';
        loadingPages.delete(pageNum);
      }
    }
    
    async function rerenderPage(pageNum) {
      const data = pageData.get(pageNum);
      const pageInfo = pageElements.get(pageNum);
      if (!data || !pageInfo) return;
      
      const { page, canvas } = data;
      const ctx = canvas.getContext('2d');
      
      const containerWidth = container.clientWidth;
      const isMobile = containerWidth < 768;
      const baseScale = isMobile ? 1.2 : 1.5;
      const finalScale = scale * baseScale;
      
      const viewport = page.getViewport({ scale: finalScale });
      
      canvas.width = viewport.width * pixelRatio;
      canvas.height = viewport.height * pixelRatio;
      canvas.style.width = viewport.width + 'px';
      canvas.style.height = viewport.height + 'px';
      
      // Update container dimensions to match rendered size
      pageInfo.container.style.width = viewport.width + 'px';
      pageInfo.container.style.height = viewport.height + 'px';
      
      ctx.scale(pixelRatio, pixelRatio);
      
      await page.render({
        canvasContext: ctx,
        viewport: viewport,
        background: 'rgba(255, 255, 255, 1)',
      }).promise;
    }
    
    async function setZoom(newScale) {
      if (newScale === scale) return;
      
      const oldScale = scale;
      const scrollRatio = container.scrollHeight > 0 ? container.scrollTop / container.scrollHeight : 0;
      const oldScrollLeft = container.scrollLeft;
      
      scale = newScale;
      
      // CRITICAL: Update ALL page containers with new dimensions (loaded or not)
      const newDimensions = calculateAllPageDimensions(newScale);
      
      pageElements.forEach(function(pageInfo, pageNum) {
        if (pageInfo.dimensions && newDimensions.has(pageNum)) {
          // Use pre-calculated dimensions
          const dims = newDimensions.get(pageNum);
          pageInfo.container.style.width = dims.width + 'px';
          pageInfo.container.style.height = dims.height + 'px';
        } else if (pageInfo.dimensions) {
          // Fallback to on-the-fly calculation
          const dims = convertToPixels(
            pageInfo.dimensions.width, 
            pageInfo.dimensions.height, 
            pageInfo.dimensions.unit,
            newScale
          );
          pageInfo.container.style.width = dims.width + 'px';
          pageInfo.container.style.height = dims.height + 'px';
        }
      });
      
      console.log('Updated all', pageElements.size, 'page containers to new scale', newScale);
      
      // Re-render loaded pages with new scale
      const renderPromises = [];
      for (const [pageNum, data] of pageData) {
        renderPromises.push(rerenderPage(pageNum));
      }
      
      await Promise.all(renderPromises);
      
      if (container.scrollHeight > 0) {
        container.scrollTop = scrollRatio * container.scrollHeight;
        const scaleRatio = newScale / oldScale;
        container.scrollLeft = oldScrollLeft * scaleRatio;
      }
      
      window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
    }
    
    function scrollToPage(pageNum) {
      const pageContainer = document.getElementById('page-' + pageNum);
      if (pageContainer) {
        const containerRect = container.getBoundingClientRect();
        const pageRect = pageContainer.getBoundingClientRect();
        const scrollOffset = pageRect.top - containerRect.top + container.scrollTop - 20;
        
        container.scrollTo({
          top: scrollOffset,
          behavior: 'smooth'
        });
        
        currentPage = pageNum;
        window.parent.postMessage({ type: 'pageInView', page: pageNum }, '*');
        
        if (!pageData.has(pageNum) && !loadingPages.has(pageNum)) {
          loadingPages.add(pageNum);
          window.parent.postMessage({ type: 'requestPage', page: pageNum }, '*');
        }
      }
    }
    
    function setupKeyboardControls() {
      document.addEventListener('keydown', async function(e) {
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
              const newScale = Math.min(3.0, scale + 0.25);
              await setZoom(newScale);
            }
            break;
          case '-':
          case '_':
            if (e.ctrlKey || e.metaKey) {
              e.preventDefault();
              const newScale = Math.max(0.5, scale - 0.25);
              await setZoom(newScale);
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
      container.addEventListener('wheel', async function(e) {
        if (e.ctrlKey || e.metaKey) {
          e.preventDefault();
          const delta = -Math.sign(e.deltaY);
          const newScale = Math.max(0.5, Math.min(3.0, scale + delta * 0.1));
          if (newScale !== scale) {
            await setZoom(newScale);
          }
        }
      }, { passive: false });
      
      let isPinching = false;
      let initialPinchDistance = 0;
      let initialScale = scale;
      let lastPinchTime = 0;
      
      container.addEventListener('touchstart', function(e) {
        if (e.touches.length === 2) {
          e.preventDefault();
          isPinching = true;
          const touch1 = e.touches[0];
          const touch2 = e.touches[1];
          const dx = touch2.clientX - touch1.clientX;
          const dy = touch2.clientY - touch1.clientY;
          initialPinchDistance = Math.sqrt(dx * dx + dy * dy);
          initialScale = scale;
          lastPinchTime = Date.now();
        }
      }, { passive: false });
      
      container.addEventListener('touchmove', async function(e) {
        if (isPinching && e.touches.length === 2) {
          e.preventDefault();
          
          const touch1 = e.touches[0];
          const touch2 = e.touches[1];
          const dx = touch2.clientX - touch1.clientX;
          const dy = touch2.clientY - touch1.clientY;
          const currentDistance = Math.sqrt(dx * dx + dy * dy);
          const scaleChange = currentDistance / initialPinchDistance;
          const newScale = Math.max(0.5, Math.min(3.0, initialScale * scaleChange));
          
          const now = Date.now();
          if (Math.abs(newScale - scale) > 0.02 && now - lastPinchTime > 50) {
            lastPinchTime = now;
            await setZoom(newScale);
          }
        }
      }, { passive: false });
      
      container.addEventListener('touchend', function(e) {
        if (e.touches.length < 2) {
          isPinching = false;
        }
      });
      
      let lastTap = 0;
      container.addEventListener('touchend', async function(e) {
        if (e.touches.length === 0 && e.changedTouches.length === 1) {
          const now = Date.now();
          const timeSince = now - lastTap;
          
          if (timeSince < 300 && timeSince > 0) {
            e.preventDefault();
            await setZoom(scale === 1.0 ? 2.0 : 1.0);
            lastTap = 0;
          } else {
            lastTap = now;
          }
        }
      });
    }
    
    window.addEventListener('message', async function(event) {
      const data = event.data;
      
      if (data.type === 'loadPage') {
        await renderPage(data.pageNumber, data.pageData);
      } else if (data.type === 'setZoom') {
        await setZoom(data.scale);
      } else if (data.type === 'goToPage') {
        scrollToPage(data.page);
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
          pageInfo.rendered = false;
          pageInfo.canvas = null;
          
          if (pageInfo.pdf) {
            pageInfo.pdf.destroy();
          }
          
          pageData.delete(pageNum);
          
          // Restore pre-sized dimensions if available
          if (pageInfo.dimensions) {
            const dims = convertToPixels(
              pageInfo.dimensions.width,
              pageInfo.dimensions.height,
              pageInfo.dimensions.unit,
              scale
            );
            pageInfo.container.style.width = dims.width + 'px';
            pageInfo.container.style.height = dims.height + 'px';
          } else {
            pageInfo.container.style.width = '595px';
            pageInfo.container.style.height = '842px';
          }
          
          console.log('Cleared page', pageNum, 'from memory, restored pre-sized dimensions');
        }
      }
    });
    
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

    // Load only first page initially
    _queuePageLoad(1);
  }

  void _queuePageLoad(int pageNumber) {
    // Don't queue if already loaded, loading, or in queue
    if (_pageCache.containsKey(pageNumber) ||
        _loadingPages.contains(pageNumber) ||
        _loadQueue.contains(pageNumber)) {
      return;
    }

    // Saat scrolling cepat, JANGAN tambah ke queue
    if (_isScrolling) {
      print('Skipping queue for page $pageNumber (fast scrolling)');
      return;
    }

    _loadQueue.add(pageNumber);
    _processLoadQueue();
  }

  Future<void> _processLoadQueue() async {
    // Process queue if we have capacity
    while (_loadingPages.length < _maxConcurrentLoads && _loadQueue.isNotEmpty) {
      final pageNumber = _loadQueue.removeAt(0);

      if (!_pageCache.containsKey(pageNumber)) {
        _loadingPages.add(pageNumber);
        _loadAndSendPage(pageNumber);
      }
    }
  }

  Future<void> _loadAndSendPage(int pageNumber) async {
    try {
      print('Loading page $pageNumber from API... (${_loadingPages.length} concurrent)');
      final pageData = await _apiService.getPageAsPdf(widget.documentId, pageNumber);

      if (!mounted) return;

      //_pageCache[pageNumber] = pageData;
      _pageCache.put(pageNumber, pageData);
      _loadedPages.add(pageNumber);
      _loadingPages.remove(pageNumber);

      print('Page $pageNumber loaded, sending to viewer (cache size: ${_pageCache.size > 0})');
      _sendPageToViewer(pageNumber);

      if (mounted) {
        setState(() {});
      }

      // Process next item in queue
      _processLoadQueue();
    } catch (e) {
      print('Error loading page $pageNumber: $e');
      _loadingPages.remove(pageNumber);
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

  void _preloadNearbyPages(int currentPage) {
    if (_documentInfo == null) return;

    // Hanya preload jika TIDAK sedang scrolling
    if (_isScrolling) {
      print('Skipping preload (scrolling)');
      return;
    }

    // Queue nearby pages for loading
    for (int i = currentPage - _cacheWindowSize; i <= currentPage + _cacheWindowSize; i++) {
      if (i >= 1 && i <= _documentInfo!.totalPages) {
        _queuePageLoad(i);
      }
    }
  }

  void _cleanupDistantPages(int currentPage) {
    if (_documentInfo == null) return;

    // Keep current page + 2 pages before/after = total 5 pages
    final keepWindow = 2;

    final pagesToKeep = <int>{};
    for (int offset = -keepWindow; offset <= keepWindow; offset++) {
      final page = currentPage + offset;
      if (page >= 1 && page <= _documentInfo!.totalPages) {
        pagesToKeep.add(page);
      }
    }

    final keysToRemove = _pageCache.keys
        .where((page) => !pagesToKeep.contains(page))
        .toList();

    final queueItemsToRemove = _loadQueue
        .where((pageNum) => !pagesToKeep.contains(pageNum))
        .toList();

    for (final key in keysToRemove) {
      _debugLog('Removing page $key from cache (outside keep window)');
      _removePageFromCache(key);
    }

    for (final pageNum in queueItemsToRemove) {
      _loadQueue.remove(pageNum);
      _debugLog('Removed page $pageNum from load queue');
    }

    final loadingToCancel = _loadingPages
        .where((pageNum) => !pagesToKeep.contains(pageNum))
        .toList();

    for (final pageNum in loadingToCancel) {
      _loadingPages.remove(pageNum);
      _debugLog('Cancelled loading page $pageNum');
    }

    if (keysToRemove.isNotEmpty || queueItemsToRemove.isNotEmpty || loadingToCancel.isNotEmpty) {
      if (mounted) setState(() {});
      _debugLog('Cleanup: ${keysToRemove.length} removed, ${queueItemsToRemove.length} queue cleared, ${loadingToCancel.isNotEmpty} loads cancelled');
      _debugLog('Kept pages: $pagesToKeep');
      _debugMemoryLog();
    }
  }

  void _goToPage(int page) {
    if (_documentInfo == null || page < 1 || page > _documentInfo!.totalPages) {
      return;
    }

    HapticFeedback.selectionClick();

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'goToPage',
        'page': page,
      }, '*');

      setState(() {
        _currentPage = page;
        _lastStableCurrentPage = page;
      });

      _preloadNearbyPages(page);
      _cleanupDistantPages(page);
    }
  }

  void _setZoom(double zoom) {
    final clampedZoom = zoom.clamp(0.5, 3.0);

    setState(() {
      _zoomLevel = clampedZoom;
    });

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'setZoom',
        'scale': clampedZoom,
      }, '*');
    }
  }

  void _zoomIn() {
    HapticFeedback.lightImpact();
    _setZoom(_zoomLevel + 0.25);
  }

  void _zoomOut() {
    HapticFeedback.lightImpact();
    _setZoom(_zoomLevel - 0.25);
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
              'Page $_currentPage of ${_documentInfo!.totalPages} • ${_loadedPages.length} loaded • ${_documentInfo!.formattedFileSize}',
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
        ],
        IconButton(
          icon: const Icon(Icons.search),
          onPressed: _showPageSelector,
          tooltip: 'Go to Page',
        ),
      ],
    );
  }

  void _showPageSelector() {
    if (_documentInfo == null) return;

    _setIframePointerEvents(false);

    final controller = TextEditingController(text: _currentPage.toString());
    final isMobile = MediaQuery.of(context).size.width < 768;

    showDialog<int>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.import_contacts, size: 24),
            const SizedBox(width: 12),
            const Text('Go to Page'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Page Number',
                helperText: 'Enter a page number (1 to ${_documentInfo!.totalPages})',
                prefixIcon: const Icon(Icons.description),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => controller.clear(),
                ),
              ),
              autofocus: true,
              onSubmitted: (value) {
                final page = int.tryParse(value);
                if (page != null && page >= 1 && page <= _documentInfo!.totalPages) {
                  Navigator.pop(dialogContext, page);
                }
              },
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Currently on page $_currentPage of ${_documentInfo!.totalPages}',
                          style: TextStyle(
                            fontSize: isMobile ? 12 : 14,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.layers, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${_loadedPages.length} pages in memory',
                          style: TextStyle(
                            fontSize: isMobile ? 12 : 14,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _QuickPageButton(
                  label: 'First',
                  icon: Icons.first_page,
                  onPressed: () => Navigator.pop(dialogContext, 1),
                ),
                _QuickPageButton(
                  label: 'Previous',
                  icon: Icons.navigate_before,
                  onPressed: _currentPage > 1
                      ? () => Navigator.pop(dialogContext, _currentPage - 1)
                      : null,
                ),
                _QuickPageButton(
                  label: 'Next',
                  icon: Icons.navigate_next,
                  onPressed: _currentPage < _documentInfo!.totalPages
                      ? () => Navigator.pop(dialogContext, _currentPage + 1)
                      : null,
                ),
                _QuickPageButton(
                  label: 'Last',
                  icon: Icons.last_page,
                  onPressed: () => Navigator.pop(dialogContext, _documentInfo!.totalPages),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () {
              final page = int.tryParse(controller.text);
              if (page == null || page < 1 || page > _documentInfo!.totalPages) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Please enter a valid page number (1-${_documentInfo!.totalPages})'),
                    duration: const Duration(seconds: 2),
                  ),
                );
                return;
              }
              Navigator.of(dialogContext).pop(page);
            },
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Go'),
          ),
        ],
      ),
    ).then((selectedPage) {
      _setIframePointerEvents(true);
      if (selectedPage != null && mounted) {
        _goToPage(selectedPage);
      }
    });
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
              'Initializing...',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      );
    }

    return HtmlElementView(viewType: _viewId);
  }

  void _setIframePointerEvents(bool enabled) {
    _iframeElement.style.pointerEvents = enabled ? 'auto' : 'none';
  }

  @override
  void dispose() {
    _cleanupTimer?.cancel();
    _memoryMonitorTimer?.cancel();
    _scrollPreventionTimer?.cancel();
    _pageLoadDebounceTimer?.cancel();
    _emergencyLoadTimer?.cancel();  // TAMBAH INI
    _pageController.dispose();
    _pageFocusNode.dispose();

    if (widget.config.enablePerformanceMonitoring) {
      final metrics = _performanceMonitor.getMetrics();
      print('PDF Viewer Session Metrics: $metrics');
    }

    _cleanupAllResources();
    super.dispose();
  }
}

class _QuickPageButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const _QuickPageButton({
    required this.label,
    required this.icon,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }
}