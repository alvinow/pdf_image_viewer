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
  final int pagePoolSize;
  final int prefetchRadius;
  final bool enableDebugLogging;
  final double pinchZoomSensitivityMobile;
  final double pinchZoomSensitivityDesktop;

  const PdfViewerConfig({
    this.pagePoolSize = 12,
    this.prefetchRadius = 3,
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
  final Set<int> _sentPages = {};  // NEW: Track sent pages
  Timer? _prefetchTimer;

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
  }

  void _debugLog(String message) {
    if (widget.config.enableDebugLogging) {
      print('[PDF_VIRTUAL] $message');
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
              _prefetchAroundPage(pageNum);
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
    final pagePoolSize = widget.config.pagePoolSize;
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
      padding: 0 20px;
      overscroll-behavior: contain;
    }
    #virtual-scroller {
      position: relative;
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 20px;
      padding: 20px 0;
    }
    .page-placeholder {
      background: white;
      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
      display: flex;
      align-items: center;
      justify-content: center;
      position: relative;
      width: 100%;
    }
    .page-slot {
      position: absolute;
      left: 50%;
      transform: translateX(-50%);
      top: 0;
      width: 100%;
      height: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: opacity 0.2s;
      z-index: 2;
    }
    .page-slot.hidden {
      opacity: 0;
      pointer-events: none;
    }
    canvas {
      display: block;
      background: white;
      width: 100%;
      height: 100%;
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
      z-index: 10;
      pointer-events: none;
    }
    .loading-spinner {
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      z-index: 5;
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
      #pdf-container {
        padding: 0 10px;
      }
      #virtual-scroller {
        gap: 10px;
        padding: 10px 0;
      }
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
      
      // Suppress font warnings (only show errors)
      pdfjsLib.GlobalWorkerOptions.verbosity = pdfjsLib.VerbosityLevel.ERRORS;

      const isAndroid = /Android/i.test(navigator.userAgent);
      const isIOS = /iPhone|iPad|iPod/i.test(navigator.userAgent);
      const isMobile = isAndroid || isIOS;
      const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);

      const totalPages = ''' + totalPages.toString() + r''';
      const pagePoolSize = ''' + pagePoolSize.toString() + r''';
      const pageDimensions = ''' + pageDimensionsJsonString + r''';
      const pinchZoomSensitivity = isMobile ? ''' + widget.config.pinchZoomSensitivityMobile.toString() + r''' : ''' + widget.config.pinchZoomSensitivityDesktop.toString() + r''';

      let container, virtualScroller;
      let scale = 1.0;
      let currentPage = 1;
      let currentRotation = 0;
      let isZooming = false;

      const pagePool = [];
      const pageSlotMap = new Map();
      const slotDataMap = new Map();
      const placeholders = [];
      const pendingPages = new Map();
      let totalHeight = 0;

      function calculateLayout() {
        const baseScale = isMobile ? 1.2 : 1.5;
        const finalScale = scale * baseScale;
        
        for (let i = 0; i < totalPages; i++) {
          const pageNum = i + 1;
          const pageDim = pageDimensions.find(p => p.pageNumber === pageNum);
          if (!pageDim) continue;

          let widthPt = pageDim.width;
          let heightPt = pageDim.height;

          if (pageDim.unit === 'mm') {
            widthPt *= 2.83465;
            heightPt *= 2.83465;
          } else if (pageDim.unit === 'in') {
            widthPt *= 72;
            heightPt *= 72;
          }

          let displayWidth, displayHeight;
          if (currentRotation === 90 || currentRotation === 270) {
            displayWidth = heightPt * finalScale;
            displayHeight = widthPt * finalScale;
          } else {
            displayWidth = widthPt * finalScale;
            displayHeight = heightPt * finalScale;
          }

          if (placeholders[i]) {
            placeholders[i].style.width = displayWidth + 'px';
            placeholders[i].style.height = displayHeight + 'px';
          }
        }
      }

      function createPlaceholders() {
        const baseScale = isMobile ? 1.2 : 1.5;
        const finalScale = scale * baseScale;

        for (let i = 0; i < totalPages; i++) {
          const pageNum = i + 1;
          const pageDim = pageDimensions.find(p => p.pageNumber === pageNum);
          if (!pageDim) continue;

          let widthPt = pageDim.width;
          let heightPt = pageDim.height;

          if (pageDim.unit === 'mm') {
            widthPt *= 2.83465;
            heightPt *= 2.83465;
          } else if (pageDim.unit === 'in') {
            widthPt *= 72;
            heightPt *= 72;
          }

          let displayWidth, displayHeight;
          if (currentRotation === 90 || currentRotation === 270) {
            displayWidth = heightPt * finalScale;
            displayHeight = widthPt * finalScale;
          } else {
            displayWidth = widthPt * finalScale;
            displayHeight = heightPt * finalScale;
          }

          const placeholder = document.createElement('div');
          placeholder.className = 'page-placeholder';
          placeholder.style.width = displayWidth + 'px';
          placeholder.style.height = displayHeight + 'px';
          placeholder.dataset.pageNumber = pageNum;

          const spinner = document.createElement('div');
          spinner.className = 'loading-spinner';
          const spinnerIcon = document.createElement('div');
          spinnerIcon.className = 'spinner-icon';
          spinner.appendChild(spinnerIcon);
          placeholder.appendChild(spinner);

          virtualScroller.appendChild(placeholder);
          placeholders.push(placeholder);
        }
      }

      function createPageSlot(index) {
        const slot = document.createElement('div');
        slot.className = 'page-slot hidden';
        slot.id = 'slot-' + index;
        
        return { element: slot, inUse: false, pageNumber: null };
      }

      function getVisiblePageRange() {
        const scrollTop = container.scrollTop;
        const viewportHeight = container.clientHeight;
        const scrollBottom = scrollTop + viewportHeight;

        const visible = [];
        for (let i = 0; i < placeholders.length; i++) {
          const placeholder = placeholders[i];
          const rect = placeholder.getBoundingClientRect();
          const containerRect = container.getBoundingClientRect();
          
          const elemTop = rect.top - containerRect.top + container.scrollTop;
          const elemBottom = elemTop + rect.height;
          
          if (elemBottom >= scrollTop && elemTop <= scrollBottom) {
            visible.push(parseInt(placeholder.dataset.pageNumber));
          }
        }

        return visible;
      }

      function findAvailableSlot() {
        for (let i = 0; i < pagePool.length; i++) {
          if (!pagePool[i].inUse) {
            return i;
          }
        }
        
        if (isZooming) {
          return -1;
        }
        
        const visiblePages = getVisiblePageRange();
        
        for (let i = 0; i < pagePool.length; i++) {
          const slot = pagePool[i];
          const slotData = slotDataMap.get(i);
          
          if (slotData && slotData.pageNum && !visiblePages.includes(slotData.pageNum)) {
            console.log('Reclaiming slot', i, 'from page', slotData.pageNum);
            releaseSlot(i);
            return i;
          }
        }
        
        for (let i = 0; i < pagePool.length; i++) {
          const slot = pagePool[i];
          if (slot.pageNumber && !visiblePages.includes(slot.pageNumber)) {
            console.warn('Force reclaiming slot', i, 'from rendering page', slot.pageNumber);
            releaseSlot(i);
            return i;
          }
        }
        
        return -1;
      }

      function releaseSlot(slotIndex) {
        const slotData = slotDataMap.get(slotIndex);
        const slot = pagePool[slotIndex];
        
        if (slotData) {
          if (slotData.page) {
            try { slotData.page.cleanup(); } catch (e) {}
          }
          if (slotData.pdf) {
            try { slotData.pdf.destroy(); } catch (e) {}
          }
          
          const canvas = slotData.canvas;
          if (canvas) {
            const ctx = canvas.getContext('2d');
            if (ctx) {
              ctx.clearRect(0, 0, canvas.width, canvas.height);
            }
            canvas.width = 1;
            canvas.height = 1;
            canvas.remove();
          }

          if (slotData.placeholder && slot.element.parentNode === slotData.placeholder) {
            try {
              slotData.placeholder.removeChild(slot.element);
            } catch (e) {
              console.warn('Failed to remove slot from placeholder:', e);
            }
            const spinner = slotData.placeholder.querySelector('.loading-spinner');
            if (spinner) spinner.style.display = 'block';
          }

          pageSlotMap.delete(slotData.pageNum);
          slotDataMap.delete(slotIndex);
        }

        slot.element.innerHTML = '';
        slot.element.classList.add('hidden');
        
        if (slot.element.parentNode) {
          try {
            slot.element.parentNode.removeChild(slot.element);
          } catch (e) {
            console.warn('Failed to remove slot from DOM:', e);
          }
        }
        
        slot.inUse = false;
        slot.pageNumber = null;
      }

      function updateVisibleSlots() {
        const visiblePages = getVisiblePageRange();
        
        if (visiblePages.length > 0 && visiblePages[0] !== currentPage) {
          currentPage = visiblePages[0];
          window.parent.postMessage({ 
            type: 'pageChanged', 
            page: currentPage 
          }, '*');
        }

        for (const pageNum of visiblePages) {
          if (!pageSlotMap.has(pageNum)) {
            window.parent.postMessage({ 
              type: 'requestPage', 
              page: pageNum 
            }, '*');
          }
        }
      }

      async function renderPageInSlot(pageNum, pdfData) {
        if (pageSlotMap.has(pageNum)) {
          const existingSlotIndex = pageSlotMap.get(pageNum);
          const existingSlotData = slotDataMap.get(existingSlotIndex);
          
          if (existingSlotData && existingSlotData.canvas) {
            return;
          }
          
          if (!existingSlotData) {
            console.warn('Page', pageNum, 'stuck in pageSlotMap without data, clearing...');
            pageSlotMap.delete(pageNum);
          } else {
            return;
          }
        }

        const slotIndex = findAvailableSlot();
        
        if (slotIndex === -1) {
          console.log('No slots available, queueing page', pageNum);
          pendingPages.set(pageNum, pdfData);
          return;
        }
        
        const slot = pagePool[slotIndex];
        
        pageSlotMap.set(pageNum, slotIndex);
        slot.inUse = true;
        slot.pageNumber = pageNum;

        const placeholder = placeholders[pageNum - 1];
        if (!placeholder) {
          console.error('Placeholder not found for page', pageNum);
          pageSlotMap.delete(pageNum);
          slot.inUse = false;
          slot.pageNumber = null;
          return;
        }

        placeholder.appendChild(slot.element);
        slot.element.classList.remove('hidden');

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

          if (slot.pageNumber !== pageNum) {
            console.warn('Slot was reclaimed during render for page', pageNum);
            pdf.destroy();
            page.cleanup();
            canvas.remove();
            pendingPages.set(pageNum, pdfData);
            return;
          }

          const spinner = placeholder.querySelector('.loading-spinner');
          if (spinner) {
            spinner.style.display = 'none';
          } else {
            console.warn('Spinner not found for page', pageNum);
          }

          slot.element.innerHTML = '';
          slot.element.appendChild(canvas);

          const pageNumber = document.createElement('div');
          pageNumber.className = 'page-number';
          pageNumber.textContent = pageNum + ' / ' + totalPages;
          slot.element.appendChild(pageNumber);

          slotDataMap.set(slotIndex, {
            pageNum: pageNum,
            pdf: pdf,
            page: page,
            canvas: canvas,
            placeholder: placeholder
          });

          console.log('Successfully rendered page', pageNum);
          
          processPendingPages();

        } catch (error) {
          console.error('Error rendering page', pageNum, error);
          
          pageSlotMap.delete(pageNum);
          slot.element.innerHTML = '';
          slot.element.classList.add('hidden');
          
          if (slot.element.parentNode) {
            try {
              slot.element.parentNode.removeChild(slot.element);
            } catch (e) {}
          }
          
          slot.inUse = false;
          slot.pageNumber = null;
          
          const spinner = placeholder.querySelector('.loading-spinner');
          if (spinner) spinner.style.display = 'block';
        }
      }
      
      function processPendingPages() {
        if (pendingPages.size === 0) return;
        
        const visiblePages = getVisiblePageRange();
        
        for (const [pageNum, pdfData] of pendingPages.entries()) {
          if (visiblePages.includes(pageNum)) {
            pendingPages.delete(pageNum);
            renderPageInSlot(pageNum, pdfData);
            break;
          }
        }
      }

      function setZoom(newScale) {
        newScale = Math.max(0.1, Math.min(5.0, newScale));
        if (Math.abs(newScale - scale) < 0.01) return;

        const oldScrollRatio = container.scrollTop / container.scrollHeight;
        scale = newScale;
        
        isZooming = true;
        pendingPages.clear();

        calculateLayout();

        requestAnimationFrame(() => {
          container.scrollTop = container.scrollHeight * oldScrollRatio;
        });

        for (let i = 0; i < pagePool.length; i++) {
          releaseSlot(i);
        }

        placeholders.forEach(ph => {
          const spinner = ph.querySelector('.loading-spinner');
          if (spinner) spinner.style.display = 'block';
        });

        window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
        updateVisibleSlots();
        
        setTimeout(() => {
          isZooming = false;
          processPendingPages();
        }, 500);
      }

      function init() {
        container = document.getElementById('pdf-container');
        virtualScroller = document.getElementById('virtual-scroller');

        createPlaceholders();

        for (let i = 0; i < pagePoolSize; i++) {
          pagePool.push(createPageSlot(i));
        }

        let scrollTimeout;
        container.addEventListener('scroll', () => {
          clearTimeout(scrollTimeout);
          scrollTimeout = setTimeout(() => {
            updateVisibleSlots();
          }, 50);
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
        updateVisibleSlots();
      }

      window.addEventListener('message', async (event) => {
        const data = event.data;

        if (data.type === 'loadPage') {
          await renderPageInSlot(data.pageNumber, data.pageData);
        } else if (data.type === 'setZoom') {
          setZoom(data.scale);
        } else if (data.type === 'goToPage') {
          const placeholder = placeholders[data.page - 1];
          if (placeholder) {
            placeholder.scrollIntoView({ behavior: 'smooth', block: 'start' });
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

  void _prefetchAroundPage(int centerPage) {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;

      final radius = widget.config.prefetchRadius;
      for (int offset = -radius; offset <= radius; offset++) {
        final page = centerPage + offset;
        if (page >= 1 && page <= (_documentInfo?.totalPages ?? 0)) {
          _loadPage(page);
        }
      }
    });
  }

  Future<void> _loadPage(int pageNumber) async {
    // FIXED: Skip if already sent to viewer (prevent duplicate renders)
    if (_sentPages.contains(pageNumber)) {
      _debugLog('Page $pageNumber already sent, skipping');
      return;
    }

    // If page is in cache, send it immediately
    if (_pageCache.containsKey(pageNumber)) {
      _debugLog('Page $pageNumber found in cache, sending');
      _sentPages.add(pageNumber);
      _sendPageToViewer(pageNumber, _pageCache[pageNumber]!);
      return;
    }

    // If already loading, don't start another request
    if (_loadingPages.contains(pageNumber)) {
      _debugLog('Page $pageNumber already loading, skipping');
      return;
    }

    _loadingPages.add(pageNumber);

    try {
      final pageData = await _apiService.getPageAsPdf(widget.documentId, pageNumber)
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      _pageCache[pageNumber] = pageData;
      _loadingPages.remove(pageNumber);

      _cleanupDistantPages();

      // Mark as sent and send to viewer
      _sentPages.add(pageNumber);
      _sendPageToViewer(pageNumber, pageData);
    } catch (e) {
      _debugLog('Error loading page $pageNumber: $e');
      _loadingPages.remove(pageNumber);
    }
  }

  void _cleanupDistantPages() {
    if (_pageCache.length <= widget.config.pagePoolSize * 2) return;

    final keepRadius = widget.config.prefetchRadius + 2;
    final pagesToRemove = <int>[];

    for (final pageNum in _pageCache.keys) {
      if ((pageNum - _currentPage).abs() > keepRadius) {
        pagesToRemove.add(pageNum);
      }
    }

    for (final pageNum in pagesToRemove) {
      _pageCache.remove(pageNum);
      _sentPages.remove(pageNum);  // Also remove from sent tracker
    }

    if (pagesToRemove.isNotEmpty) {
      _debugLog('Cleaned ${pagesToRemove.length} pages from cache');
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

      _prefetchAroundPage(page);
    }
  }

  void _setZoom(double zoom) {
    final clampedZoom = zoom.clamp(0.1, 5.0);

    setState(() {
      _zoomLevel = clampedZoom;
    });

    if (_viewerInitialized) {
      // FIXED: Clear sent pages tracker when zooming (pages need re-render)
      _sentPages.clear();

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
                '${_pageCache.length} pages cached • ${_documentInfo!.formattedFileSize}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_out),
            onPressed: () => _setZoom(_zoomLevel - 0.3),
          ),
          Text('${(_zoomLevel * 100).toInt()}%'),
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
            onSubmitted: (value) {
              final page = int.tryParse(value);
              if (page != null) _goToPage(page);
            },
          ),
        ),
        Text(' / ${_documentInfo!.totalPages}'),
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
            const Icon(Icons.error, size: 48),
            Text(_error!),
            ElevatedButton(
              onPressed: _loadDocument,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // ignore: undefined_prefixed_name
    return HtmlElementView(viewType: _viewId);
  }

  @override
  void dispose() {
    _prefetchTimer?.cancel();
    _pageController.dispose();
    _pageFocusNode.dispose();
    _pageCache.clear();
    _sentPages.clear();
    super.dispose();
  }
}