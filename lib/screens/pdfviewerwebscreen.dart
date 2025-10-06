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

class PdfViewerConfig {
  final int maxRenderedPages;
  final int maxCachedPages;
  final int keepRadius;
  final bool enableDebugLogging;
  final double pinchZoomSensitivityMobile;
  final double pinchZoomSensitivityDesktop;

  const PdfViewerConfig({
    this.maxRenderedPages = 15,  // Hard limit on rendered pages in JS
    this.maxCachedPages = 10,    // Hard limit on cached pages in Dart
    this.keepRadius = 2,          // Pages to keep around current page
    this.enableDebugLogging = false,
    this.pinchZoomSensitivityMobile = 0.15,
    this.pinchZoomSensitivityDesktop = 0.0000001,
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

class _PdfViewerWebScreenState extends State<PdfViewerWebScreen> {
  late PdfApiService _apiService;
  DocumentInfo? _documentInfo;
  bool _isLoading = true;
  String? _error;
  int _currentPage = 1;
  double _zoomLevel = 1.0;
  int _rotationDegrees = 0;

  late html.IFrameElement _iframeElement;
  final String _viewId = 'pdf-viewer-${DateTime.now().millisecondsSinceEpoch}';
  bool _viewerInitialized = false;

  final Map<int, Uint8List> _pageCache = {};
  final Set<int> _loadingPages = {};
  Timer? _cleanupTimer;

  final TextEditingController _pageController = TextEditingController();
  final FocusNode _pageFocusNode = FocusNode();

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

    _initializePdfViewer();
    _loadDocument();
    _pageController.text = _currentPage.toString();

    // Aggressive cleanup timer
    _cleanupTimer = Timer.periodic(
        const Duration(seconds: 2),
            (_) => _cleanupDistantPages()
    );
  }

  void _debugLog(String message) {
    if (widget.config.enableDebugLogging) {
      print('[PDF_MEMORY] $message');
    }
  }

  void _handlePdfJsMessage(Map<dynamic, dynamic> data) {
    if (!mounted) return;

    try {
      final type = data['type'];
      if (type == null) return;

      switch (type.toString()) {
        case 'pageChanged':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null && pageNum != _currentPage) {
              setState(() {
                _currentPage = pageNum;
                _pageController.text = pageNum.toString();
              });
              _requestPagesAround(pageNum);
            }
          }
          break;

        case 'requestPage':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null) {
              _loadPage(pageNum);
            }
          }
          break;

        case 'clearPageCache':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null) {
              _pageCache.remove(pageNum);
              _debugLog('Cleared Dart cache for page $pageNum');
            }
          }
          break;

        case 'memoryStats':
          final stats = data['stats'];
          if (stats != null) {
            _debugLog('JS Memory: $stats');
          }
          break;

        case 'viewerReady':
          setState(() {
            _viewerInitialized = true;
          });
          _loadInitialPages();
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

  Future<void> _loadDocument() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final info = await _apiService.getDocumentInfo(widget.documentId)
          .timeout(const Duration(seconds: 30));

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

    final pageDimensionsJson = _documentInfo!.pages?.map((pageInfo) {
      return {
        'pageNumber': pageInfo.pageNumber,
        'width': pageInfo.dimensions.width,
        'height': pageInfo.dimensions.height,
        'unit': pageInfo.dimensions.unit,
      };
    }).toList() ?? [];

    final pageDimensionsJsonString = jsonEncode(pageDimensionsJson);
    final maxRenderedPages = widget.config.maxRenderedPages;
    final keepRadius = widget.config.keepRadius;
    final totalPages = _documentInfo!.totalPages;

    final htmlContent = r'''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5">
  <title>''' + widget.title + r'''</title>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.min.mjs" type="module"></script>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    html, body { width: 100%; height: 100%; overflow: hidden; }
    body { background: #525659; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
    #pdf-container {
      width: 100%;
      height: 100%;
      overflow-y: auto;
      overflow-x: auto;
      -webkit-overflow-scrolling: touch;
      padding: 0 20px;
      overscroll-behavior: contain;
    }
    #virtual-scroller {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 20px;
      padding: 20px 0;
      position: relative;
    }
    .page-wrapper {
      position: relative;
      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
      background: white;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .page-placeholder {
      width: 100%;
      height: 100%;
      position: relative;
      background: white;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .page-content {
      position: absolute;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      z-index: 2;
      background: white;
    }
    .page-content.hidden { display: none; }
    canvas { display: block; background: white; width: 100%; height: 100%; }
    .page-number {
      position: absolute;
      bottom: 10px;
      right: 10px;
      background: rgba(0,0,0,0.7);
      color: white;
      padding: 4px 8px;
      border-radius: 4px;
      font-size: 12px;
      z-index: 10;
      pointer-events: none;
    }
    .loading-spinner {
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      z-index: 1;
    }
    .spinner-icon {
      width: 48px;
      height: 48px;
      position: relative;
    }
    .spinner-icon::before,
    .spinner-icon::after {
      content: '';
      position: absolute;
      border-radius: 50%;
      top: 0;
      left: 0;
    }
    .spinner-icon::before {
      width: 48px;
      height: 48px;
      border: 4px solid rgba(52, 152, 219, 0.2);
    }
    .spinner-icon::after {
      width: 48px;
      height: 48px;
      border: 4px solid transparent;
      border-top-color: #3498db;
      border-right-color: #3498db;
      animation: spin 0.8s cubic-bezier(0.5, 0, 0.5, 1) infinite;
    }
    @keyframes spin {
      0% { transform: rotate(0deg); }
      100% { transform: rotate(360deg); }
    }
    @media (max-width: 768px) {
      #pdf-container { padding: 0 10px; }
      #virtual-scroller { gap: 10px; padding: 10px 0; }
    }
  </style>
</head>
<body>
  <div id="pdf-container">
    <div id="virtual-scroller"></div>
  </div>

  <script type="module">
    (async function() {
      const pdfjsLib = await import('https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.min.mjs');
      pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.worker.min.mjs';

      const isAndroid = /Android/i.test(navigator.userAgent);
      const isIOS = /iPhone|iPad|iPod/i.test(navigator.userAgent);
      const isMobile = isAndroid || isIOS;
      const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);

      const totalPages = ''' + totalPages.toString() + r''';
      const MAX_RENDERED_PAGES = ''' + maxRenderedPages.toString() + r''';
      const KEEP_RADIUS = ''' + keepRadius.toString() + r''';
      const pageDimensions = ''' + pageDimensionsJsonString + r''';

      let container, virtualScroller;
      let scale = 1.0;
      let currentPage = 1;
      let currentRotation = 0;

      const pageWrappers = new Map();
      const pageContentSlots = new Map();
      const renderedPages = new Map();
      const pageAccessTime = new Map();

      function calculatePageSize(pageNum) {
        const pageDim = pageDimensions.find(p => p.pageNumber === pageNum);
        if (!pageDim) return null;

        let widthPt = pageDim.width;
        let heightPt = pageDim.height;

        if (pageDim.unit === 'mm') {
          widthPt *= 2.83465;
          heightPt *= 2.83465;
        } else if (pageDim.unit === 'in') {
          widthPt *= 72;
          heightPt *= 72;
        }

        const baseScale = isMobile ? 1.2 : 1.5;
        const finalScale = scale * baseScale;

        let displayWidth, displayHeight;
        if (currentRotation === 90 || currentRotation === 270) {
          displayWidth = heightPt * finalScale;
          displayHeight = widthPt * finalScale;
        } else {
          displayWidth = widthPt * finalScale;
          displayHeight = heightPt * finalScale;
        }

        return { width: displayWidth, height: displayHeight };
      }

      function createPageStructure() {
        virtualScroller.innerHTML = '';
        pageWrappers.clear();
        pageContentSlots.clear();

        for (let i = 1; i <= totalPages; i++) {
          const size = calculatePageSize(i);
          if (!size) continue;

          const wrapper = document.createElement('div');
          wrapper.className = 'page-wrapper';
          wrapper.id = 'page-' + i;
          wrapper.style.width = size.width + 'px';
          wrapper.style.height = size.height + 'px';

          const placeholder = document.createElement('div');
          placeholder.className = 'page-placeholder';

          const spinner = document.createElement('div');
          spinner.className = 'loading-spinner';
          const spinnerIcon = document.createElement('div');
          spinnerIcon.className = 'spinner-icon';
          spinner.appendChild(spinnerIcon);
          placeholder.appendChild(spinner);

          const pageNum = document.createElement('div');
          pageNum.className = 'page-number';
          pageNum.textContent = i + ' / ' + totalPages;
          placeholder.appendChild(pageNum);

          const content = document.createElement('div');
          content.className = 'page-content hidden';

          wrapper.appendChild(placeholder);
          wrapper.appendChild(content);
          virtualScroller.appendChild(wrapper);

          pageWrappers.set(i, { wrapper, placeholder, spinner });
          pageContentSlots.set(i, content);
        }
      }

      function getVisiblePages() {
        const scrollTop = container.scrollTop;
        const viewportHeight = container.clientHeight;
        const scrollBottom = scrollTop + viewportHeight;
        const visible = [];

        for (let i = 1; i <= totalPages; i++) {
          const wrapper = pageWrappers.get(i)?.wrapper;
          if (!wrapper) continue;

          const rect = wrapper.getBoundingClientRect();
          const containerRect = container.getBoundingClientRect();
          const pageTop = rect.top - containerRect.top + scrollTop;
          const pageBottom = pageTop + rect.height;

          if (pageBottom >= scrollTop - 200 && pageTop <= scrollBottom + 200) {
            visible.push(i);
            pageAccessTime.set(i, Date.now());
          }
        }

        return visible;
      }

      function cleanupPage(pageNum) {
        const data = renderedPages.get(pageNum);
        if (!data) return;

        console.log('Cleaning up page ' + pageNum);

        if (data.page) {
          try { data.page.cleanup(); } catch (e) {}
        }
        if (data.pdf) {
          try { data.pdf.destroy(); } catch (e) {}
        }
        if (data.canvas) {
          const ctx = data.canvas.getContext('2d');
          if (ctx) ctx.clearRect(0, 0, data.canvas.width, data.canvas.height);
          data.canvas.width = 1;
          data.canvas.height = 1;
          data.canvas.remove();
        }

        renderedPages.delete(pageNum);
        pageAccessTime.delete(pageNum);

        window.parent.postMessage({ 
          type: 'clearPageCache', 
          page: pageNum 
        }, '*');

        const contentSlot = pageContentSlots.get(pageNum);
        if (contentSlot) {
          contentSlot.innerHTML = '';
          contentSlot.classList.add('hidden');
        }

        const wrapperData = pageWrappers.get(pageNum);
        if (wrapperData) {
          wrapperData.spinner.style.display = 'block';
        }
      }

      function cleanupDistantPages(visiblePages) {
        if (renderedPages.size <= MAX_RENDERED_PAGES) return;

        const pagesToKeep = new Set();

        for (const vp of visiblePages) {
          for (let offset = -KEEP_RADIUS; offset <= KEEP_RADIUS; offset++) {
            const page = vp + offset;
            if (page >= 1 && page <= totalPages) {
              pagesToKeep.add(page);
            }
          }
        }

        const pagesToCleanup = [];
        for (const pageNum of renderedPages.keys()) {
          if (!pagesToKeep.has(pageNum)) {
            pagesToCleanup.push(pageNum);
          }
        }

        pagesToCleanup.sort((a, b) => {
          const aDist = Math.min(...visiblePages.map(vp => Math.abs(a - vp)));
          const bDist = Math.min(...visiblePages.map(vp => Math.abs(b - vp)));
          return bDist - aDist;
        });

        for (const pageNum of pagesToCleanup) {
          if (renderedPages.size <= MAX_RENDERED_PAGES) break;
          cleanupPage(pageNum);
        }

        if (renderedPages.size > MAX_RENDERED_PAGES) {
          const sortedByTime = Array.from(pageAccessTime.entries())
            .sort((a, b) => a[1] - b[1])
            .map(entry => entry[0]);

          for (const pageNum of sortedByTime) {
            if (renderedPages.size <= MAX_RENDERED_PAGES) break;
            if (!pagesToKeep.has(pageNum)) {
              cleanupPage(pageNum);
            }
          }
        }

        if (pagesToCleanup.length > 0) {
          console.log('Cleaned ' + pagesToCleanup.length + ' pages. Current: ' + renderedPages.size);
          window.parent.postMessage({
            type: 'memoryStats',
            stats: {
              rendered: renderedPages.size,
              limit: MAX_RENDERED_PAGES
            }
          }, '*');
        }
      }

      function updateVisibleContent() {
        const visiblePages = getVisiblePages();

        if (visiblePages.length > 0) {
          const firstVisible = visiblePages[0];
          if (firstVisible !== currentPage) {
            currentPage = firstVisible;
            window.parent.postMessage({ 
              type: 'pageChanged', 
              page: currentPage 
            }, '*');
          }
        }

        for (const pageNum of visiblePages) {
          if (!renderedPages.has(pageNum)) {
            window.parent.postMessage({ 
              type: 'requestPage', 
              page: pageNum 
            }, '*');
          }
        }

        cleanupDistantPages(visiblePages);
      }

      async function renderPage(pageNum, pdfData) {
        if (renderedPages.has(pageNum)) return;

        try {
          const binary = atob(pdfData);
          const bytes = new Uint8Array(binary.length);
          for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
          }

          const loadingTask = pdfjsLib.getDocument({ 
            data: bytes,
            useSystemFonts: true,
          });

          const pdf = await loadingTask.promise;
          const page = await pdf.getPage(1);

          const canvas = document.createElement('canvas');
          const ctx = canvas.getContext('2d', { alpha: false });

          const size = calculatePageSize(pageNum);
          if (!size) return;

          const baseScale = isMobile ? 1.2 : 1.5;
          const finalScale = scale * baseScale;
          const viewport = page.getViewport({ scale: finalScale, rotation: currentRotation });

          canvas.width = viewport.width * pixelRatio;
          canvas.height = viewport.height * pixelRatio;
          canvas.style.width = '100%';
          canvas.style.height = '100%';

          ctx.scale(pixelRatio, pixelRatio);

          await page.render({
            canvasContext: ctx,
            viewport: viewport,
            background: 'white',
          }).promise;

          const contentSlot = pageContentSlots.get(pageNum);
          if (contentSlot) {
            contentSlot.innerHTML = '';
            contentSlot.appendChild(canvas);
            contentSlot.classList.remove('hidden');
          }

          const wrapperData = pageWrappers.get(pageNum);
          if (wrapperData) {
            wrapperData.spinner.style.display = 'none';
          }

          renderedPages.set(pageNum, { pdf, page, canvas });
          pageAccessTime.set(pageNum, Date.now());

          const visiblePages = getVisiblePages();
          cleanupDistantPages(visiblePages);

        } catch (error) {
          console.error('Error rendering page ' + pageNum, error);
        }
      }

      function setZoom(newScale) {
        newScale = Math.max(0.1, Math.min(5.0, newScale));
        if (Math.abs(newScale - scale) < 0.01) return;

        const oldScrollRatio = container.scrollTop / container.scrollHeight;
        scale = newScale;

        for (const [pageNum, data] of renderedPages) {
          if (data.page) {
            try { data.page.cleanup(); } catch (e) {}
          }
          if (data.pdf) {
            try { data.pdf.destroy(); } catch (e) {}
          }
        }
        renderedPages.clear();
        pageAccessTime.clear();

        createPageStructure();

        requestAnimationFrame(() => {
          container.scrollTop = container.scrollHeight * oldScrollRatio;
          updateVisibleContent();
        });

        window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
      }

      function init() {
        container = document.getElementById('pdf-container');
        virtualScroller = document.getElementById('virtual-scroller');

        createPageStructure();

        let scrollTimeout;
        container.addEventListener('scroll', () => {
          clearTimeout(scrollTimeout);
          scrollTimeout = setTimeout(() => {
            updateVisibleContent();
          }, 100);
        }, { passive: true });

        container.addEventListener('wheel', (e) => {
          if (e.ctrlKey || e.metaKey) {
            e.preventDefault();
            const delta = -Math.sign(e.deltaY);
            const newScale = scale + delta * 0.1;
            setZoom(newScale);
          }
        }, { passive: false });

        window.parent.postMessage({ type: 'viewerReady' }, '*');
        updateVisibleContent();
      }

      window.addEventListener('message', async (event) => {
        const data = event.data;

        if (data.type === 'loadPage') {
          await renderPage(data.pageNumber, data.pageData);
        } else if (data.type === 'setZoom') {
          setZoom(data.scale);
        } else if (data.type === 'goToPage') {
          const wrapper = pageWrappers.get(data.page)?.wrapper;
          if (wrapper) {
            wrapper.scrollIntoView({ behavior: 'smooth', block: 'start' });
          }
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

    _loadPage(1);
    if (_documentInfo!.totalPages > 1) {
      _loadPage(2);
    }
  }

  void _requestPagesAround(int centerPage) {
    final radius = widget.config.keepRadius;
    for (int offset = -radius; offset <= radius; offset++) {
      final page = centerPage + offset;
      if (page >= 1 && page <= (_documentInfo?.totalPages ?? 0)) {
        _loadPage(page);
      }
    }
  }

  Future<void> _loadPage(int pageNumber) async {
    if (_pageCache.containsKey(pageNumber) || _loadingPages.contains(pageNumber)) {
      if (_pageCache.containsKey(pageNumber)) {
        _sendPageToViewer(pageNumber, _pageCache[pageNumber]!);
      }
      return;
    }

    _loadingPages.add(pageNumber);

    try {
      final pageData = await _apiService.getPageAsPdf(widget.documentId, pageNumber)
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      _pageCache[pageNumber] = pageData;
      _loadingPages.remove(pageNumber);

      _sendPageToViewer(pageNumber, pageData);

      // Cleanup immediately after adding
      _cleanupDistantPages();
    } catch (e) {
      _debugLog('Error loading page $pageNumber: $e');
      _loadingPages.remove(pageNumber);
    }
  }

  void _cleanupDistantPages() {
    final maxCached = widget.config.maxCachedPages;

    if (_pageCache.length <= maxCached) return;

    final keepRadius = widget.config.keepRadius;
    final pagesToRemove = <int>[];

    for (final pageNum in _pageCache.keys) {
      if ((pageNum - _currentPage).abs() > keepRadius) {
        pagesToRemove.add(pageNum);
      }
    }

    pagesToRemove.sort((a, b) {
      final distA = (a - _currentPage).abs();
      final distB = (b - _currentPage).abs();
      return distB - distA;
    });

    for (final pageNum in pagesToRemove) {
      if (_pageCache.length <= maxCached) break;
      _pageCache.remove(pageNum);
      _debugLog('Removed page $pageNum from Dart cache. Total: ${_pageCache.length}');
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
        _pageController.text = page.toString();
      });

      _requestPagesAround(page);
    }
  }

  void _setZoom(double zoom) {
    final clampedZoom = zoom.clamp(0.1, 5.0);

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_documentInfo?.title ?? widget.title),
            if (_documentInfo != null)
              Text(
                'Cached: ${_pageCache.length}/${widget.config.maxCachedPages} • ${_documentInfo!.formattedFileSize}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_out),
            onPressed: () => _setZoom(_zoomLevel - 0.3),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(child: Text('${(_zoomLevel * 100).toInt()}%')),
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in),
            onPressed: () => _setZoom(_zoomLevel + 0.3),
          ),
          if (_documentInfo != null) _buildPageNav(),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildPageNav() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
        ),
        SizedBox(
          width: 80,
          child: TextField(
            controller: _pageController,
            focusNode: _pageFocusNode,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              isDense: true,
            ),
            onSubmitted: (value) {
              final page = int.tryParse(value);
              if (page != null) _goToPage(page);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(' / ${_documentInfo!.totalPages}'),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: _currentPage < _documentInfo!.totalPages
              ? () => _goToPage(_currentPage + 1)
              : null,
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadDocument,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading PDF...'),
          ],
        ),
      );
    }

    // ignore: undefined_prefixed_name
    return HtmlElementView(viewType: _viewId);
  }

  @override
  void dispose() {
    _cleanupTimer?.cancel();
    _pageController.dispose();
    _pageFocusNode.dispose();
    _pageCache.clear();
    super.dispose();
  }
}