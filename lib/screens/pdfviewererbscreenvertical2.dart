import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf_image_viewer/appconfig.dart';
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:typed_data';
import '../services/pdf_api_service.dart';
import '../models/document_info.dart';

class PdfViewerWebScreenVertical2 extends StatefulWidget {
  final String documentId;
  final String? apiBaseUrl;
  final String title;

  const PdfViewerWebScreenVertical2({
    Key? key,
    required this.documentId,
    this.apiBaseUrl,
    required this.title
  }) : super(key: key);

  @override
  State<PdfViewerWebScreenVertical2> createState() => _PdfViewerWebScreenVertical2State();
}

class _PdfViewerWebScreenVertical2State extends State<PdfViewerWebScreenVertical2> {
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

  // Page cache - only cache nearby pages
  final Map<int, Uint8List> _pageCache = {};
  final int _cacheWindowSize = 3; // Cache 3 pages before and after current

  @override
  void initState() {
    super.initState();
    _apiService = PdfApiService(
      baseUrl: widget.apiBaseUrl ?? AppConfig.baseUrl,
    );

    _initializePdfViewer();
    _loadDocument();
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

      print('Received message: $type'); // Debug log

      switch (type.toString()) {
        case 'pageInView':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null && pageNum != _currentPage) {
              setState(() {
                _currentPage = pageNum;
              });
              _preloadNearbyPages(pageNum);
            }
          }
          break;

        case 'viewerReady':
          print('Viewer ready, initializing pages'); // Debug log
          setState(() {
            _viewerInitialized = true;
          });
          // Load initial pages
          _loadInitialPages();
          break;

        case 'requestPage':
          final page = data['page'];
          if (page != null) {
            final pageNum = page is int ? page : int.tryParse(page.toString());
            if (pageNum != null) {
              print('Page $pageNum requested'); // Debug log
              _loadAndSendPage(pageNum);
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

    // Set loading to false immediately so UI shows iframe
    setState(() {
      _isLoading = false;
    });

    final htmlContent = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5, user-scalable=yes">
  <title>${this.widget.title.toString()}</title>
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
      min-height: 400px;
      display: flex;
      align-items: center;
      justify-content: center;
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

@media (max-width: 768px) {
  .page-indicator {
    right: 20px;
    padding: 10px 14px;
  }
  
  .page-indicator .current {
    font-size: 20px;
  }
}
    @media (max-width: 768px) {
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
    
    // Initialize placeholder containers
    function init() {
      console.log('Initializing viewer with', totalPages, 'pages');
      
      for (let i = 1; i <= totalPages; i++) {
        const pageContainer = document.createElement('div');
        pageContainer.className = 'page-container loading';
        pageContainer.id = 'page-' + i;
        pageContainer.style.width = '100%';
        
        const spinner = document.createElement('div');
        spinner.className = 'loading-spinner';
        spinner.textContent = 'Loading page ' + i + '...';
        pageContainer.appendChild(spinner);
        
        const pageNumber = document.createElement('div');
        pageNumber.className = 'page-number';
        pageNumber.textContent = i + ' / ' + totalPages;
        pageContainer.appendChild(pageNumber);
        
        pagesWrapper.appendChild(pageContainer);
        pageElements.set(i, { container: pageContainer, canvas: null, pdf: null, rendered: false });
      }
      
      setupScrollListener();
      setupZoomControls();
      setupKeyboardControls();
      
      console.log('Sending viewerReady message');
      window.parent.postMessage({ type: 'viewerReady' }, '*');
      
      // Fallback: if no response in 2 seconds, request first pages directly
      setTimeout(() => {
        if (pageData.size === 0) {
          console.log('No pages loaded, requesting manually');
          for (let i = 1; i <= Math.min(3, totalPages); i++) {
            if (!loadingPages.has(i)) {
              loadingPages.add(i);
              window.parent.postMessage({ type: 'requestPage', page: i }, '*');
            }
          }
        }
      }, 2000);
    }
    
    function setupScrollListener() {
  let scrollTimeout;
  let lastVisiblePages = new Set();
  const pageIndicator = document.getElementById('page-indicator');
  const pageIndicatorCurrent = pageIndicator.querySelector('.current');
  const pageIndicatorTotal = pageIndicator.querySelector('.total');
  
  // Update total pages
  pageIndicatorTotal.textContent = 'of ' + totalPages;
  
  // Show page indicator on scroll
  let indicatorTimeout;
  container.addEventListener('scroll', () => {
    pageIndicator.classList.add('visible');
    
    clearTimeout(indicatorTimeout);
    indicatorTimeout = setTimeout(() => {
      pageIndicator.classList.remove('visible');
    }, 1500);
  });
  
  const observer = new IntersectionObserver((entries) => {
    const visiblePages = new Set();
    
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        const pageNum = parseInt(entry.target.id.split('-')[1]);
        visiblePages.add(pageNum);
        
        // Request page if not loaded
        if (!pageData.has(pageNum) && !loadingPages.has(pageNum)) {
          loadingPages.add(pageNum);
          window.parent.postMessage({ type: 'requestPage', page: pageNum }, '*');
        }
      }
    });
    
    if (visiblePages.size > 0) {
      const minPage = Math.min(...visiblePages);
      if (minPage !== currentPage) {
        currentPage = minPage;
        pageIndicatorCurrent.textContent = currentPage;
        window.parent.postMessage({ type: 'pageInView', page: currentPage }, '*');
      }
    }
    
    lastVisiblePages = visiblePages;
  }, {
    root: container,
    rootMargin: '400px 0px',
    threshold: 0.01
  });
  
  pageElements.forEach((data, pageNum) => {
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
        
        // Create canvas
        const canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d');
        
        // Calculate size
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
        
        // Render
        await page.render({
          canvasContext: ctx,
          viewport: viewport,
          background: 'rgba(255, 255, 255, 1)',
        }).promise;
        
        // Update container
        pageInfo.container.innerHTML = '';
        pageInfo.container.appendChild(canvas);
        
        const pageNumber = document.createElement('div');
        pageNumber.className = 'page-number';
        pageNumber.textContent = pageNum + ' / ' + totalPages;
        pageInfo.container.appendChild(pageNumber);
        
        pageInfo.container.classList.remove('loading');
        pageInfo.container.style.width = 'auto';
        
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
      
      console.log('Zooming from', oldScale, 'to', newScale);
      
      // Re-render all loaded pages
      const renderPromises = [];
      for (const [pageNum, data] of pageData) {
        renderPromises.push(rerenderPage(pageNum));
      }
      
      await Promise.all(renderPromises);
      
      // Restore scroll position proportionally
      if (container.scrollHeight > 0) {
        container.scrollTop = scrollRatio * container.scrollHeight;
        const scaleRatio = newScale / oldScale;
        container.scrollLeft = oldScrollLeft * scaleRatio;
      }
      
      window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
    }
    
    function scrollToPage(pageNum) {
      console.log('Scrolling to page:', pageNum);
      const pageContainer = document.getElementById('page-' + pageNum);
      if (pageContainer) {
        const containerRect = container.getBoundingClientRect();
        const pageRect = pageContainer.getBoundingClientRect();
        const scrollOffset = pageRect.top - containerRect.top + container.scrollTop - 20;
        
        container.scrollTo({
          top: scrollOffset,
          behavior: 'smooth'
        });
        
        // Update current page immediately
        currentPage = pageNum;
        window.parent.postMessage({ type: 'pageInView', page: pageNum }, '*');
        
        // Load the page if not already loaded
        if (!pageData.has(pageNum) && !loadingPages.has(pageNum)) {
          loadingPages.add(pageNum);
          window.parent.postMessage({ type: 'requestPage', page: pageNum }, '*');
        }
      }
    }
    
    function setupKeyboardControls() {
      document.addEventListener('keydown', async (e) => {
        // Prevent default for navigation keys to avoid page scrolling
        const navKeys = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'PageUp', 'PageDown', 'Home', 'End'];

        switch(e.key) {
          case 'ArrowDown':
          case 'PageDown':
            // Scroll down by viewport height
            e.preventDefault();
            container.scrollBy({
              top: container.clientHeight * 0.9,
              behavior: 'smooth'
            });
            break;

          case 'ArrowUp':
          case 'PageUp':
            // Scroll up by viewport height
            e.preventDefault();
            container.scrollBy({
              top: -container.clientHeight * 0.9,
              behavior: 'smooth'
            });
            break;

          case 'ArrowRight':
            // Next page
            e.preventDefault();
            if (currentPage < totalPages) {
              scrollToPage(currentPage + 1);
            }
            break;

          case 'ArrowLeft':
            // Previous page
            e.preventDefault();
            if (currentPage > 1) {
              scrollToPage(currentPage - 1);
            }
            break;

          case 'Home':
            // Go to first page
            e.preventDefault();
            scrollToPage(1);
            break;

          case 'End':
            // Go to last page
            e.preventDefault();
            scrollToPage(totalPages);
            break;

          case '+':
          case '=':
            // Zoom in
            if (e.ctrlKey || e.metaKey) {
              e.preventDefault();
              const newScale = Math.min(3.0, scale + 0.25);
              await setZoom(newScale);
            }
            break;

          case '-':
          case '_':
            // Zoom out
            if (e.ctrlKey || e.metaKey) {
              e.preventDefault();
              const newScale = Math.max(0.5, scale - 0.25);
              await setZoom(newScale);
            }
            break;

          case '0':
            // Reset zoom
            if (e.ctrlKey || e.metaKey) {
              e.preventDefault();
              await setZoom(1.0);
            }
            break;

          case 'g':
          case 'G':
            // Go to page (send message to Flutter to show dialog)
            if (e.ctrlKey || e.metaKey) {
              e.preventDefault();
              window.parent.postMessage({ type: 'showPageDialog' }, '*');
            }
            break;
        }
      });

      console.log('Keyboard controls enabled');
    }
    
    function setupZoomControls() {
      // Mouse wheel zoom
      container.addEventListener('wheel', async (e) => {
        if (e.ctrlKey || e.metaKey) {
          e.preventDefault();
          const delta = -Math.sign(e.deltaY);
          const newScale = Math.max(0.5, Math.min(3.0, scale + delta * 0.1));
          if (newScale !== scale) {
            await setZoom(newScale);
          }
        }
      }, { passive: false });
      
      // Touch pinch zoom
      let isPinching = false;
      let initialPinchDistance = 0;
      let initialScale = scale;
      let lastPinchTime = 0;
      let pinchCenter = { x: 0, y: 0 };
      
      container.addEventListener('touchstart', (e) => {
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
          
          // Calculate pinch center
          pinchCenter = {
            x: (touch1.clientX + touch2.clientX) / 2,
            y: (touch1.clientY + touch2.clientY) / 2
          };
        }
      }, { passive: false });
      
      container.addEventListener('touchmove', async (e) => {
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
            const oldScrollTop = container.scrollTop;
            const oldScrollLeft = container.scrollLeft;
            
            await setZoom(newScale);
            
            // Try to maintain focus on pinch center
            const scaleRatio = newScale / scale;
            container.scrollTop = oldScrollTop * scaleRatio;
            container.scrollLeft = oldScrollLeft * scaleRatio;
          }
        }
      }, { passive: false });
      
      container.addEventListener('touchend', (e) => {
        if (e.touches.length < 2) {
          isPinching = false;
        }
      });
      
      container.addEventListener('touchcancel', () => {
        isPinching = false;
      });
      
      // Double-tap to zoom
      let lastTap = 0;
      let doubleTapTimeout;
      
      container.addEventListener('touchend', async (e) => {
        if (e.touches.length === 0 && e.changedTouches.length === 1) {
          const now = Date.now();
          const timeSince = now - lastTap;
          
          clearTimeout(doubleTapTimeout);
          
          if (timeSince < 300 && timeSince > 0) {
            // Double tap detected
            e.preventDefault();
            
            if (scale === 1.0) {
              await setZoom(2.0);
            } else {
              await setZoom(1.0);
            }
            
            lastTap = 0;
          } else {
            lastTap = now;
            doubleTapTimeout = setTimeout(() => {
              lastTap = 0;
            }, 300);
          }
        }
      });
    }
    
    // Message handling
    window.addEventListener('message', async (event) => {
      const data = event.data;
      
      if (data.type === 'loadPage') {
        await renderPage(data.pageNumber, data.pageData);
      } else if (data.type === 'setZoom') {
        await setZoom(data.scale);
      } else if (data.type === 'goToPage') {
        scrollToPage(data.page);
      }
    });
    
    window.addEventListener('orientationchange', async () => {
      setTimeout(async () => {
        for (const pageNum of pageData.keys()) {
          await rerenderPage(pageNum);
        }
      }, 100);
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

    // Load first 3 pages initially
    for (int i = 1; i <= 3 && i <= _documentInfo!.totalPages; i++) {
      _loadAndSendPage(i);
    }
  }

  Future<void> _loadAndSendPage(int pageNumber) async {
    if (_pageCache.containsKey(pageNumber)) {
      print('Page $pageNumber already cached, sending to viewer');
      _sendPageToViewer(pageNumber);
      return;
    }

    try {
      print('Loading page $pageNumber from API...');
      final pageData = await _apiService.getPageAsPdf(widget.documentId, pageNumber);
      _pageCache[pageNumber] = pageData;
      _loadedPages.add(pageNumber);
      print('Page $pageNumber loaded, sending to viewer');
      _sendPageToViewer(pageNumber);

      if (mounted) {
        setState(() {});
      }

      // Cleanup old pages if cache is too large
      _cleanupCache(pageNumber);
    } catch (e) {
      print('Error loading page $pageNumber: $e');
    }
  }

  void _sendPageToViewer(int pageNumber) {
    if (!_viewerInitialized) return;

    final pageData = _pageCache[pageNumber];
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

    // Preload pages within cache window
    for (int i = currentPage - _cacheWindowSize; i <= currentPage + _cacheWindowSize; i++) {
      if (i >= 1 && i <= _documentInfo!.totalPages && !_pageCache.containsKey(i)) {
        _loadAndSendPage(i);
      }
    }
  }

  void _cleanupCache(int currentPage) {
    if (_pageCache.length <= _cacheWindowSize * 3) return;

    // Remove pages far from current page
    final keysToRemove = <int>[];
    for (final pageNum in _pageCache.keys) {
      if ((pageNum - currentPage).abs() > _cacheWindowSize * 2) {
        keysToRemove.add(pageNum);
      }
    }

    for (final key in keysToRemove) {
      _pageCache.remove(key);
      _loadedPages.remove(key);
    }
  }

  void _goToPage(int page) {
    if (_documentInfo == null) {
      print('ERROR: Cannot go to page - documentInfo is null');
      return;
    }
    if (page < 1 || page > _documentInfo!.totalPages) {
      print('ERROR: Invalid page number: $page (total: ${_documentInfo!.totalPages})');
      return;
    }

    HapticFeedback.selectionClick();

    print('Going to page: $page (viewerInitialized: $_viewerInitialized)');

    if (_viewerInitialized) {
      try {
        _iframeElement.contentWindow?.postMessage({
          'type': 'goToPage',
          'page': page,
        }, '*');

        setState(() {
          _currentPage = page;
        });

        // Preload nearby pages
        _preloadNearbyPages(page);

        print('Successfully sent goToPage message for page $page');
      } catch (e) {
        print('ERROR posting message to iframe: $e');
      }
    } else {
      print('WARNING: Viewer not initialized yet, cannot navigate to page $page');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File is still loading. Please wait...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _setZoom(double zoom) {
    final clampedZoom = zoom.clamp(0.5, 3.0);

    print('Setting zoom to: $clampedZoom');

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
      //floatingActionButton: _documentInfo != null && isMobile ? _buildFloatingActions() : null,
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, bool isMobile) {
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _documentInfo?.title ?? this.widget.title,
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
        /*if (isMobile)
          PopupMenuButton(
            icon: const Icon(Icons.more_vert),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'zoom_out',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.zoom_out),
                  title: const Text('Zoom Out'),
                  trailing: Text('${(_zoomLevel * 100).toInt()}%'),
                ),
              ),
              PopupMenuItem(
                value: 'zoom_in',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.zoom_in),
                  title: const Text('Zoom In'),
                ),
              ),
              PopupMenuItem(
                value: 'reset_zoom',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.refresh),
                  title: const Text('Reset Zoom'),
                ),
              ),
            ],
            onSelected: (value) {
              switch (value) {
                case 'zoom_out':
                  _zoomOut();
                  break;
                case 'zoom_in':
                  _zoomIn();
                  break;
                case 'reset_zoom':
                  _resetZoom();
                  break;
              }
            },
          ),*/

      ],
    );
  }

  void _showPageSelector() {
    if (_documentInfo == null) return;

    // Disable iframe pointer events when dialog opens
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
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Please enter a valid page number (1-${_documentInfo!.totalPages})'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
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
                          '${_loadedPages.length} pages loaded in memory',
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
      // Re-enable pointer events immediately
      _setIframePointerEvents(true);

      // If a page was selected, navigate to it
      if (selectedPage != null && mounted) {
        print('Navigating to page: $selectedPage');
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

  Widget _buildFloatingActions() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.small(
          heroTag: 'zoom_in',
          onPressed: _zoomIn,
          tooltip: 'Zoom In',
          child: const Icon(Icons.add),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'zoom_out',
          onPressed: _zoomOut,
          tooltip: 'Zoom Out',
          child: const Icon(Icons.remove),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'go_to_page',
          onPressed: _showPageSelector,
          tooltip: 'Go to Page',
          child: const Icon(Icons.search),
        ),
      ],
    );
  }






  void _setIframePointerEvents(bool enabled) {
    _iframeElement.style.pointerEvents = enabled ? 'auto' : 'none';
  }

  @override
  void dispose() {
    _pageCache.clear();
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


