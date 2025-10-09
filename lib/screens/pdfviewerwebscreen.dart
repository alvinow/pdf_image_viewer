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

/// perfect! Beta4

class PdfViewerConfig {
  final int prefetchRadius;
  final bool enableDebugLogging;
  final double pinchZoomSensitivityMobile;
  final double pinchZoomSensitivityDesktop;
  final int maxCacheSize;
  final bool enableTextSelection;
  final bool enableDarkMode;

  const PdfViewerConfig({
    this.prefetchRadius = 3,
    this.enableDebugLogging = false,
    this.pinchZoomSensitivityMobile = 0.005,    // ✅ Fixed: 0.005 untuk smooth mobile zoom
    this.pinchZoomSensitivityDesktop = 0.1,     // ✅ Fixed: 0.1 untuk desktop scroll zoom
    this.maxCacheSize = 20,
    this.enableTextSelection = true,
    this.enableDarkMode = false,
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
  bool _isDarkMode = false;

  late html.IFrameElement _iframeElement;
  final String _viewId = 'pdf-viewer-${DateTime.now().millisecondsSinceEpoch}';
  bool _viewerInitialized = false;

  final Map<int, Uint8List> _pageCache = {};
  final Set<int> _loadingPages = {};
  Timer? _prefetchTimer;

  final TextEditingController _pageController = TextEditingController();
  final FocusNode _pageFocusNode = FocusNode();

  bool get _isMobile {
    final data = MediaQuery.of(context);
    return data.size.shortestSide < 600;
  }

  bool get _isLandscape {
    return MediaQuery.of(context).orientation == Orientation.landscape;
  }

  bool get _shouldUseVerticalAppBar {
    return _isMobile && _isLandscape;
  }

  @override
  void initState() {
    super.initState();
    _apiService = PdfApiService(
      baseUrl: widget.apiBaseUrl ?? AppConfig.baseUrl,
    );
    _isDarkMode = widget.config.enableDarkMode;

    _initializePdfViewer();
    _loadDocument();
    _pageController.text = _currentPage.toString();
  }

  void _debugLog(String message) {
    if (widget.config.enableDebugLogging) {
      print('[PDF_VIEWER] $message');
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
              _loadAndSendPage(pageNum);
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

        case 'visiblePagesChanged':
          final pages = data['pages'] as List?;
          if (pages != null) {
            _debugLog('Visible pages: $pages');
          }
          break;

        case 'error':
          final errorMessage = data['message'];
          if (errorMessage != null) {
            _debugLog('Viewer error: $errorMessage');
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
    final totalPages = _documentInfo!.totalPages;
    final enableTextSelection = widget.config.enableTextSelection;

    final zoomSensitivityMobile = widget.config.pinchZoomSensitivityMobile;
    final zoomSensitivityDesktop = widget.config.pinchZoomSensitivityDesktop;

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
      transition: background-color 0.3s ease;
    }
    body.dark-mode {
      background: #1a1a1a;
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
      min-width: 100%;
    }
    .page-placeholder {
      background: white;
      box-shadow: 0 2px 8px rgba(0,0,0,0.3);
      display: flex;
      align-items: center;
      justify-content: center;
      position: relative;
      width: 100%;
      transition: filter 0.3s ease;
      margin: 0 auto;
    }
    body.dark-mode .page-placeholder {
      filter: invert(0.9) hue-rotate(180deg);
    }
    .page-content {
      position: relative;
      width: 100%;
      height: 100%;
    }
    canvas {
      display: block;
      background: white;
      width: 100%;
      height: 100%;
    }
    .textLayer {
      position: absolute;
      left: 0;
      top: 0;
      right: 0;
      bottom: 0;
      overflow: hidden;
      opacity: 0.2;
      line-height: 1.0;
    }
    .textLayer > span {
      color: transparent;
      position: absolute;
      white-space: pre;
      cursor: text;
      transform-origin: 0% 0%;
    }
    .textLayer ::selection {
      background: rgba(0, 100, 255, 0.3);
    }
    .textLayer ::-moz-selection {
      background: rgba(0, 100, 255, 0.3);
    }
    body.dark-mode .textLayer ::selection {
      background: rgba(255, 200, 0, 0.3);
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
    body.dark-mode .page-number {
      background: rgba(255,255,255,0.7);
      color: black;
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

      const isAndroid = /Android/i.test(navigator.userAgent);
      const isIOS = /iPhone|iPad|iPod/i.test(navigator.userAgent);
      const isMobile = isAndroid || isIOS;
      const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);

      const totalPages = ''' + totalPages.toString() + r''';
      const pageDimensions = ''' + pageDimensionsJsonString + r''';
      const enableTextSelection = ''' + enableTextSelection.toString() + r''';
      
      const zoomSensitivityMobile = ''' + zoomSensitivityMobile.toString() + r''';
      const zoomSensitivityDesktop = ''' + zoomSensitivityDesktop.toString() + r''';

      let container, virtualScroller;
      let scale = 1.0;
      let currentPage = 1;
      let currentRotation = 0;
      let isDarkMode = false;

      const placeholders = [];
      const renderingPages = new Set();
      const renderedPages = new Map();
      
      // ✅ Cache PDF data and parsed objects in JavaScript
      const pdfDataCache = new Map();
      const parsedPages = new Map();

      let initialPinchDistance = null;
      let initialScale = 1.0;
      let isZooming = false;

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

      function cleanupOffscreenPages() {
        const visiblePages = getVisiblePageRange();
        const visibleSet = new Set(visiblePages);

        placeholders.forEach((placeholder, idx) => {
          const pageNum = idx + 1;
          
          if (!visibleSet.has(pageNum) && !renderingPages.has(pageNum)) {
            const pageContent = placeholder.querySelector('.page-content');
            
            if (pageContent) {
              const canvas = pageContent.querySelector('canvas');
              
              if (canvas) {
                const ctx = canvas.getContext('2d');
                if (ctx) {
                  ctx.clearRect(0, 0, canvas.width, canvas.height);
                }
                canvas.width = 1;
                canvas.height = 1;
              }
              
              pageContent.remove();
              renderedPages.delete(pageNum);
            }

            if (parsedPages.has(pageNum)) {
              const { pdf, page } = parsedPages.get(pageNum);
              page.cleanup();
              pdf.destroy();
              parsedPages.delete(pageNum);
            }

            let spinner = placeholder.querySelector('.loading-spinner');
            if (!spinner) {
              spinner = document.createElement('div');
              spinner.className = 'loading-spinner';
              const spinnerIcon = document.createElement('div');
              spinnerIcon.className = 'spinner-icon';
              spinner.appendChild(spinnerIcon);
              placeholder.appendChild(spinner);
            } else {
              spinner.style.display = 'block';
            }
          }
        });
      }

      function updateVisiblePages() {
        const visiblePages = getVisiblePageRange();
        
        if (visiblePages.length > 0 && visiblePages[0] !== currentPage) {
          currentPage = visiblePages[0];
          window.parent.postMessage({ 
            type: 'pageChanged', 
            page: currentPage 
          }, '*');
        }

        window.parent.postMessage({
          type: 'visiblePagesChanged',
          pages: visiblePages
        }, '*');

        for (const pageNum of visiblePages) {
          const placeholder = placeholders[pageNum - 1];
          const hasContent = placeholder?.querySelector('.page-content');
          
          if (!hasContent && !renderingPages.has(pageNum)) {
            if (pdfDataCache.has(pageNum)) {
              const cachedData = pdfDataCache.get(pageNum);
              renderPage(pageNum, cachedData);
            } else {
              window.parent.postMessage({ 
                type: 'requestPage', 
                page: pageNum 
              }, '*');
            }
          }
        }

        cleanupOffscreenPages();
      }

      async function loadPdfPage(pageNum, pdfData) {
        if (parsedPages.has(pageNum)) {
          return parsedPages.get(pageNum);
        }

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

        const pdfObj = { pdf, page };
        parsedPages.set(pageNum, pdfObj);
        
        return pdfObj;
      }

      async function renderPage(pageNum, pdfData) {
        if (renderingPages.has(pageNum)) {
          return;
        }

        const placeholder = placeholders[pageNum - 1];
        if (!placeholder) {
          return;
        }

        const oldContent = placeholder.querySelector('.page-content');

        renderingPages.add(pageNum);

        try {
          const { page } = await loadPdfPage(pageNum, pdfData);

          const pageContent = document.createElement('div');
          pageContent.className = 'page-content';

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

          pageContent.appendChild(canvas);

          if (enableTextSelection === 'true') {
            const textLayerDiv = document.createElement('div');
            textLayerDiv.className = 'textLayer';
            textLayerDiv.style.width = canvas.style.width;
            textLayerDiv.style.height = canvas.style.height;

            const textContent = await page.getTextContent();
            
            pdfjsLib.renderTextLayer({
              textContentSource: textContent,
              container: textLayerDiv,
              viewport: viewport,
              textDivs: [],
            });

            pageContent.appendChild(textLayerDiv);
          }

          const pageNumber = document.createElement('div');
          pageNumber.className = 'page-number';
          pageNumber.textContent = pageNum + ' / ' + totalPages;
          pageContent.appendChild(pageNumber);

          const spinner = placeholder.querySelector('.loading-spinner');
          if (spinner) spinner.style.display = 'none';

          placeholder.appendChild(pageContent);

          if (oldContent) {
            oldContent.remove();
          }

          renderedPages.set(pageNum, { scale: scale, rotation: currentRotation });

        } catch (error) {
          console.error('Error rendering page ' + pageNum + ':', error);
          
          const errorDiv = document.createElement('div');
          errorDiv.style.cssText = 'color: #e74c3c; text-align: center; padding: 20px;';
          errorDiv.textContent = 'Error loading page ' + pageNum;
          
          if (oldContent) {
            oldContent.remove();
          }
          
          placeholder.appendChild(errorDiv);
          
        } finally {
          renderingPages.delete(pageNum);
        }
      }

      function setZoom(newScale) {
        newScale = Math.max(0.1, Math.min(5.0, newScale));
        if (Math.abs(newScale - scale) < 0.01) return;

        const oldScrollRatio = container.scrollTop / container.scrollHeight;
        const oldScale = scale;
        scale = newScale;

        calculateLayout();

        const pagesToRerender = [];
        const scaleChangePercent = Math.abs((newScale - oldScale) / oldScale);
        const shouldRerender = scaleChangePercent > 0.2;

        if (shouldRerender) {
          renderedPages.forEach((pageData, pageNum) => {
            if (Math.abs(pageData.scale - scale) / scale > 0.2) {
              pagesToRerender.push(pageNum);
            }
          });
        }

        requestAnimationFrame(() => {
          container.scrollTop = container.scrollHeight * oldScrollRatio;
          window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
          
          setTimeout(() => {
            if (!isZooming) {
              const visiblePages = getVisiblePageRange();
              
              visiblePages.forEach(pageNum => {
                if (shouldRerender && pagesToRerender.includes(pageNum) && pdfDataCache.has(pageNum)) {
                  const cachedData = pdfDataCache.get(pageNum);
                  renderPage(pageNum, cachedData);
                }
              });
            }
          }, 100);
        });
      }

      function setRotation(degrees) {
        degrees = degrees % 360;
        if (degrees < 0) degrees += 360;
        
        if (currentRotation === degrees) return;

        const oldScrollRatio = container.scrollTop / container.scrollHeight;
        currentRotation = degrees;

        calculateLayout();

        placeholders.forEach((placeholder, idx) => {
          const pageContent = placeholder.querySelector('.page-content');
          if (pageContent) pageContent.remove();

          const pageNum = idx + 1;
          renderedPages.delete(pageNum);

          let spinner = placeholder.querySelector('.loading-spinner');
          if (!spinner) {
            spinner = document.createElement('div');
            spinner.className = 'loading-spinner';
            const spinnerIcon = document.createElement('div');
            spinnerIcon.className = 'spinner-icon';
            spinner.appendChild(spinnerIcon);
            placeholder.appendChild(spinner);
          } else {
            spinner.style.display = 'block';
          }
        });

        requestAnimationFrame(() => {
          container.scrollTop = container.scrollHeight * oldScrollRatio;
          
          const visiblePages = getVisiblePageRange();
          visiblePages.forEach(pageNum => {
            if (pdfDataCache.has(pageNum)) {
              const cachedData = pdfDataCache.get(pageNum);
              renderPage(pageNum, cachedData);
            }
          });
        });
      }

      function setDarkMode(enabled) {
        isDarkMode = enabled;
        if (enabled) {
          document.body.classList.add('dark-mode');
        } else {
          document.body.classList.remove('dark-mode');
        }
      }

      function init() {
        container = document.getElementById('pdf-container');
        virtualScroller = document.getElementById('virtual-scroller');

        createPlaceholders();

        let scrollTimeout;
        container.addEventListener('scroll', () => {
          clearTimeout(scrollTimeout);
          scrollTimeout = setTimeout(() => {
            if (!isZooming) {
              updateVisiblePages();
            }
          }, 50);
        }, { passive: true });

        container.addEventListener('wheel', (e) => {
          if (e.ctrlKey || e.metaKey) {
            e.preventDefault();
            const delta = -Math.sign(e.deltaY);
            const newScale = scale + delta * parseFloat(zoomSensitivityDesktop);
            setZoom(newScale);
          }
        }, { passive: false });

        container.addEventListener('touchstart', (e) => {
          if (e.touches.length === 2) {
            isZooming = true;
            const touch1 = e.touches[0];
            const touch2 = e.touches[1];
            initialPinchDistance = Math.hypot(
              touch2.clientX - touch1.clientX,
              touch2.clientY - touch1.clientY
            );
            initialScale = scale;
          }
        }, { passive: true });

        container.addEventListener('touchmove', (e) => {
          if (e.touches.length === 2 && initialPinchDistance) {
            e.preventDefault();
            const touch1 = e.touches[0];
            const touch2 = e.touches[1];
            const currentDistance = Math.hypot(
              touch2.clientX - touch1.clientX,
              touch2.clientY - touch1.clientY
            );
            
            const distanceDelta = (currentDistance - initialPinchDistance) * parseFloat(zoomSensitivityMobile);
            const newScale = Math.max(0.1, Math.min(5.0, initialScale + distanceDelta));
            
            const oldScrollRatio = container.scrollTop / container.scrollHeight;
            scale = newScale;
            calculateLayout();
            requestAnimationFrame(() => {
              container.scrollTop = container.scrollHeight * oldScrollRatio;
            });
          }
        }, { passive: false });

        container.addEventListener('touchend', () => {
          if (isZooming) {
            isZooming = false;
            initialPinchDistance = null;
            window.parent.postMessage({ type: 'zoomChanged', zoom: scale }, '*');
            
            setTimeout(() => {
              const visiblePages = getVisiblePageRange();
              visiblePages.forEach(pageNum => {
                if (pdfDataCache.has(pageNum)) {
                  const pageData = renderedPages.get(pageNum);
                  if (!pageData || Math.abs(pageData.scale - scale) / scale > 0.2) {
                    const cachedData = pdfDataCache.get(pageNum);
                    renderPage(pageNum, cachedData);
                  }
                }
              });
            }, 200);
          }
        }, { passive: true });

        window.parent.postMessage({ type: 'viewerReady' }, '*');
        updateVisiblePages();
      }

      window.addEventListener('message', async (event) => {
        const data = event.data;

        if (data.type === 'renderPage') {
          pdfDataCache.set(data.pageNumber, data.pageData);
          await renderPage(data.pageNumber, data.pageData);
        } else if (data.type === 'setZoom') {
          setZoom(data.scale);
        } else if (data.type === 'goToPage') {
          const placeholder = placeholders[data.page - 1];
          if (placeholder) {
            placeholder.scrollIntoView({ behavior: 'smooth', block: 'start' });
          }
        } else if (data.type === 'setRotation') {
          setRotation(data.degrees);
        } else if (data.type === 'setDarkMode') {
          setDarkMode(data.enabled);
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

    _loadAndSendPage(1);
    if (_documentInfo!.totalPages > 1) {
      _loadAndSendPage(2);
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
          _loadAndSendPage(page);
        }
      }
    });
  }

  Future<void> _loadAndSendPage(int pageNumber) async {
    if (_pageCache.containsKey(pageNumber)) {
      _sendPageToViewer(pageNumber, _pageCache[pageNumber]!);
      return;
    }

    if (_loadingPages.contains(pageNumber)) {
      return;
    }

    _loadingPages.add(pageNumber);

    try {
      final pageData = await _apiService.getPageAsPdf(widget.documentId, pageNumber)
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      _pageCache[pageNumber] = pageData;
      _loadingPages.remove(pageNumber);

      _cleanupCache();

      _sendPageToViewer(pageNumber, pageData);
    } catch (e) {
      _debugLog('Error loading page $pageNumber: $e');
      _loadingPages.remove(pageNumber);
    }
  }

  void _cleanupCache() {
    if (_pageCache.length <= widget.config.maxCacheSize) return;

    final keepRadius = widget.config.prefetchRadius + 2;
    final pagesToRemove = <int>[];

    for (final pageNum in _pageCache.keys) {
      if ((pageNum - _currentPage).abs() > keepRadius) {
        pagesToRemove.add(pageNum);
      }
    }

    for (final pageNum in pagesToRemove) {
      _pageCache.remove(pageNum);
    }

    if (pagesToRemove.isNotEmpty) {
      _debugLog('Cleaned ${pagesToRemove.length} pages from cache');
    }
  }

  void _sendPageToViewer(int pageNumber, Uint8List pageData) {
    if (!_viewerInitialized) {
      _debugLog('Viewer not ready, skipping page $pageNumber');
      return;
    }

    final base64Data = base64Encode(pageData);
    _iframeElement.contentWindow?.postMessage({
      'type': 'renderPage',
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
      _iframeElement.contentWindow?.postMessage({
        'type': 'setZoom',
        'scale': clampedZoom,
      }, '*');
    }
  }

  void _rotateClockwise() {
    setState(() {
      _rotationDegrees = (_rotationDegrees + 90) % 360;
    });

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'setRotation',
        'degrees': _rotationDegrees,
      }, '*');
    }
  }

  void _rotateCounterClockwise() {
    setState(() {
      _rotationDegrees = (_rotationDegrees - 90) % 360;
      if (_rotationDegrees < 0) _rotationDegrees += 360;
    });

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'setRotation',
        'degrees': _rotationDegrees,
      }, '*');
    }
  }

  void _toggleDarkMode() {
    setState(() {
      _isDarkMode = !_isDarkMode;
    });

    if (_viewerInitialized) {
      _iframeElement.contentWindow?.postMessage({
        'type': 'setDarkMode',
        'enabled': _isDarkMode,
      }, '*');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_shouldUseVerticalAppBar) {
      return Scaffold(
        body: Row(
          children: [
            Expanded(child: _buildBody()),
            Container(
              width: 60,
              color: Colors.black26,
              child: _buildVerticalAppBar(),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        backgroundColor: Colors.black26,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_documentInfo?.title ?? widget.title),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(_isDarkMode ? Icons.light_mode : Icons.dark_mode),
            onPressed: _toggleDarkMode,
            tooltip: 'Toggle Dark Mode',
          ),
          IconButton(
            icon: const Icon(Icons.rotate_right),
            onPressed: _rotateClockwise,
            tooltip: 'Rotate Right',
          ),
          const VerticalDivider(),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(),
            icon: const Icon(Icons.zoom_out),
            onPressed: () => _setZoom(_zoomLevel - 0.3),
          ),
          Text('${(_zoomLevel * 100).toInt()}%'),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(),
            icon: const Icon(Icons.zoom_in),
            onPressed: () => _setZoom(_zoomLevel + 0.3),
          ),
          const VerticalDivider(),
          if (_documentInfo != null) _buildPageNav(),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildVerticalAppBar() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Back',
        ),
        const Divider(height: 1),
        IconButton(
          icon: Icon(_isDarkMode ? Icons.light_mode : Icons.dark_mode),
          onPressed: _toggleDarkMode,
          tooltip: 'Toggle Dark Mode',
        ),
        IconButton(
          icon: const Icon(Icons.rotate_right),
          onPressed: _rotateClockwise,
          tooltip: 'Rotate Right',
        ),
        /*const Divider(height: 1),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(),
          icon: const Icon(Icons.zoom_out),
          onPressed: () => _setZoom(_zoomLevel - 0.3),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '${(_zoomLevel * 100).toInt()}%',
            style: TextStyle(fontSize: 10),
          ),
        ),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(),
          icon: const Icon(Icons.zoom_in),
          onPressed: () => _setZoom(_zoomLevel + 0.3),
        ),*/
        const Divider(height: 1),
        if (_documentInfo != null) _buildVerticalPageNav(),
      ],
    );
  }

  Widget _buildVerticalPageNav() {
    return Column(
      children: [
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_up),
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(),
          onPressed: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
        ),
        SizedBox(
          width: 40,
          child: TextField(
            controller: _pageController,
            focusNode: _pageFocusNode,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            style: TextStyle(fontSize: 12),
            cursorHeight: 12,
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.white,
              contentPadding: EdgeInsets.zero,
              isDense: true,
              constraints: BoxConstraints(maxWidth: 40),
            ),
            onSubmitted: (value) {
              final page = int.tryParse(value);
              if (page != null) _goToPage(page);
            },
          ),
        ),
        SizedBox(height: 7),
        Text(
          '${_documentInfo!.totalPages}',
          style: TextStyle(fontSize: 12),
        ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(),
          onPressed: _currentPage < _documentInfo!.totalPages
              ? () => _goToPage(_currentPage + 1)
              : null,
        ),
      ],
    );
  }

  Widget _buildPageNav() {
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(),
          onPressed: _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
        ),
        SizedBox(
          width: 40,
          child: TextField(
            controller: _pageController,
            focusNode: _pageFocusNode,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            style: TextStyle(fontSize: 12),
            cursorHeight: 12,
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(4),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.white,
              contentPadding: EdgeInsets.zero,
              isDense: true,
              constraints: BoxConstraints(maxWidth: 40),
            ),
            onSubmitted: (value) {
              final page = int.tryParse(value);
              if (page != null) _goToPage(page);
            },
          ),
        ),
        SizedBox(width: 7),
        Text(
          '${_documentInfo!.totalPages}',
          style: TextStyle(fontSize: 12),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(),
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
            const SizedBox(height: 16),
            Text(_error!),
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
    _loadingPages.clear();
    super.dispose();
  }
}