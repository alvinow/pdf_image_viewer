// ═══════════════════════════════════════════════════════════════
// PUBSPEC.YAML - Add these dependencies
// ═══════════════════════════════════════════════════════════════
/*
name: pdf_viewer_app
description: Cross-platform PDF viewer with text selection

dependencies:
  flutter:
    sdk: flutter
  pdfx: ^2.6.0
  shared_preferences: ^2.2.0

dev_dependencies:
  flutter_test:
    sdk: flutter
*/

// ═══════════════════════════════════════════════════════════════
// 1. CONFIGURATION CLASSES
// File: lib/pdf_viewer/config/pdf_config.dart
// ═══════════════════════════════════════════════════════════════

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/widgets.dart';
import 'dart:html' as html;
import 'dart:ui' as ui;
import 'dart:convert';
import 'package:pdfx/pdfx.dart' as pdfx;

enum PdfRendererType { webCanvas, native, webView }

class PdfRendererConfig {
  final PdfRendererType? type;
  final double defaultScale;
  final bool enableTextSelection;
  final Color backgroundColor;

  const PdfRendererConfig({
    this.type,
    this.defaultScale = 1.5,
    this.enableTextSelection = true,
    this.backgroundColor = Colors.white,
  });

  factory PdfRendererConfig.auto() {
    if (kIsWeb) {
      return const PdfRendererConfig(type: PdfRendererType.webCanvas);
    } else if (Platform.isAndroid || Platform.isIOS) {
      return const PdfRendererConfig(type: PdfRendererType.native);
    }
    return const PdfRendererConfig(type: PdfRendererType.webView);
  }
}

enum PdfViewMode { continuous, singlePage, thumbnailGrid, thumbnailSidebar }

class PdfViewModeConfig {
  final PdfViewMode mode;
  final double gap;
  final EdgeInsets padding;

  const PdfViewModeConfig({
    this.mode = PdfViewMode.continuous,
    this.gap = 20.0,
    this.padding = const EdgeInsets.all(20),
  });
}

// ═══════════════════════════════════════════════════════════════
// 2. ABSTRACT RENDERER INTERFACE
// File: lib/pdf_viewer/renderer/pdf_canvas_renderer.dart
// ═══════════════════════════════════════════════════════════════



abstract class PdfCanvasRenderer {
  PdfRendererConfig get config;
  String get viewId;
  bool get isInitialized;
  bool get supportsTextSelection;

  Future<void> initialize();
  Future<void> renderPage({
    required Uint8List pdfData,
    double? scale,
    int? rotation,
  });
  Widget buildRendererWidget();
  void dispose();

  // Text selection
  void enableTextSelection();
  void disableTextSelection();
  String? getSelectedText();
  void clearSelection();

  // Events
  Stream<void> get onRenderComplete;
  Stream<String> get onRenderError;
  Stream<String> get onTextSelected;
}

// ═══════════════════════════════════════════════════════════════
// 3. WEB RENDERER (PDF.js)
// File: lib/pdf_viewer/renderer/web/pdf_js_renderer.dart
// ═══════════════════════════════════════════════════════════════



class PdfJsCanvasRenderer extends PdfCanvasRenderer {
  final PdfRendererConfig _config;
  final String _viewId = 'pdf-${DateTime.now().millisecondsSinceEpoch}';
  late html.IFrameElement _iframe;
  bool _isInit = false;

  final _completeController = StreamController<void>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _textController = StreamController<String>.broadcast();

  PdfJsCanvasRenderer(this._config);

  @override
  PdfRendererConfig get config => _config;
  @override
  String get viewId => _viewId;
  @override
  bool get isInitialized => _isInit;
  @override
  bool get supportsTextSelection => true;

  @override
  Future<void> initialize() async {
    _iframe = html.IFrameElement()
      ..style.border = 'none'
      ..style.width = '100%'
      ..style.height = '100%';

    // ignore: undefined_prefixed_name
    ui.platformViewRegistry.registerViewFactory(_viewId, (int id) => _iframe);

    html.window.onMessage.listen((event) {
      if (event.data is Map) {
        final data = event.data as Map;
        if (data['viewId'] == _viewId) {
          _handleMessage(data);
        }
      }
    });

    _iframe.srcdoc = _buildHtml();
    await _waitForReady();
    _isInit = true;
  }

  void _handleMessage(Map data) {
    switch (data['type']) {
      case 'ready':
        break;
      case 'renderComplete':
        _completeController.add(null);
        break;
      case 'renderError':
        _errorController.add(data['error'] ?? 'Unknown error');
        break;
      case 'textSelected':
        if (data['text'] != null && data['text'].isNotEmpty) {
          _textController.add(data['text']);
        }
        break;
    }
  }

  Future<void> _waitForReady() async {
    final completer = Completer<void>();
    late StreamSubscription sub;
    sub = html.window.onMessage.listen((event) {
      if (event.data is Map) {
        final data = event.data as Map;
        if (data['viewId'] == _viewId && data['type'] == 'ready') {
          sub.cancel();
          completer.complete();
        }
      }
    });
    return completer.future.timeout(const Duration(seconds: 5));
  }

  @override
  Future<void> renderPage({
    required Uint8List pdfData,
    double? scale,
    int? rotation,
  }) async {
    _iframe.contentWindow?.postMessage({
      'viewId': _viewId,
      'type': 'renderPage',
      'pdfData': base64Encode(pdfData),
      'scale': scale ?? config.defaultScale,
      'rotation': rotation ?? 0,
      'enableTextLayer': config.enableTextSelection,
    }, '*');
  }

  @override
  Widget buildRendererWidget() {
    return HtmlElementView(viewType: _viewId);
  }

  String _buildHtml() {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <script src="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.min.mjs" type="module"></script>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { width: 100%; height: 100%; overflow: hidden; background: white; }
    #container { position: relative; width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; }
    canvas { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
    .textLayer { position: absolute; left: 0; top: 0; right: 0; bottom: 0; opacity: 0; line-height: 1; z-index: 10; }
    .textLayer > div { color: transparent; position: absolute; white-space: pre; cursor: text; }
    .textLayer ::selection { background: rgba(0,123,255,0.3); }
  </style>
</head>
<body>
  <div id="container"></div>
  <script type="module">
    const pdfjsLib = await import('https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.min.mjs');
    pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/4.9.155/pdf.worker.min.mjs';
    pdfjsLib.GlobalWorkerOptions.verbosity = pdfjsLib.VerbosityLevel.ERRORS;
    
    const container = document.getElementById('container');
    const pixelRatio = Math.min(window.devicePixelRatio || 1, 2);
    let canvas = null, textLayer = null;
    
    window.parent.postMessage({ viewId: '$_viewId', type: 'ready' }, '*');
    
    window.addEventListener('message', async (e) => {
      const d = e.data;
      if (!d || d.viewId !== '$_viewId' || d.type !== 'renderPage') return;
      
      try {
        if (canvas) canvas.remove();
        if (textLayer) textLayer.remove();
        
        const bin = atob(d.pdfData);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        
        const pdf = await pdfjsLib.getDocument({ data: bytes, useSystemFonts: true }).promise;
        const page = await pdf.getPage(1);
        
        canvas = document.createElement('canvas');
        const ctx = canvas.getContext('2d', { alpha: false });
        const vp = page.getViewport({ scale: d.scale, rotation: d.rotation });
        
        canvas.width = vp.width * pixelRatio;
        canvas.height = vp.height * pixelRatio;
        canvas.style.width = vp.width + 'px';
        canvas.style.height = vp.height + 'px';
        ctx.scale(pixelRatio, pixelRatio);
        
        await page.render({ canvasContext: ctx, viewport: vp, background: 'white' }).promise;
        container.appendChild(canvas);
        
        if (d.enableTextLayer) {
          const txt = await page.getTextContent();
          textLayer = document.createElement('div');
          textLayer.className = 'textLayer';
          await pdfjsLib.renderTextLayer({ textContent: txt, container: textLayer, viewport: vp, textDivs: [] }).promise;
          container.appendChild(textLayer);
        }
        
        page.cleanup();
        pdf.destroy();
        window.parent.postMessage({ viewId: '$_viewId', type: 'renderComplete' }, '*');
      } catch (err) {
        window.parent.postMessage({ viewId: '$_viewId', type: 'renderError', error: err.message }, '*');
      }
    });
    
    document.addEventListener('selectionchange', () => {
      const txt = window.getSelection()?.toString() || '';
      if (txt) window.parent.postMessage({ viewId: '$_viewId', type: 'textSelected', text: txt }, '*');
    });
  </script>
</body>
</html>''';
  }

  @override
  void enableTextSelection() {}
  @override
  void disableTextSelection() {}
  @override
  String? getSelectedText() => null;
  @override
  void clearSelection() {
    _iframe.contentWindow?.postMessage({'viewId': _viewId, 'type': 'clearSelection'}, '*');
  }

  @override
  Stream<void> get onRenderComplete => _completeController.stream;
  @override
  Stream<String> get onRenderError => _errorController.stream;
  @override
  Stream<String> get onTextSelected => _textController.stream;

  @override
  void dispose() {
    _completeController.close();
    _errorController.close();
    _textController.close();
  }
}

// ═══════════════════════════════════════════════════════════════
// 4. MOBILE RENDERER (pdfx)
// File: lib/pdf_viewer/renderer/mobile/pdf_native_renderer.dart
// ═══════════════════════════════════════════════════════════════



class PdfNativeCanvasRenderer extends PdfCanvasRenderer {
  final PdfRendererConfig _config;
  final String _viewId = 'pdf-native-${DateTime.now().millisecondsSinceEpoch}';
  bool _isInit = false;

  pdfx.PdfDocument? _doc;
  pdfx.PdfPage? _page;
  pdfx.PdfPageImage? _image;

  final _completeController = StreamController<void>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _textController = StreamController<String>.broadcast();

  PdfNativeCanvasRenderer(this._config);

  @override
  PdfRendererConfig get config => _config;
  @override
  String get viewId => _viewId;
  @override
  bool get isInitialized => _isInit;
  @override
  bool get supportsTextSelection => true;

  @override
  Future<void> initialize() async {
    _isInit = true;
  }

  @override
  Future<void> renderPage({
    required Uint8List pdfData,
    double? scale,
    int? rotation,
  }) async {
    try {
      _doc = await pdfx.PdfDocument.openData(pdfData);
      _page = await _doc!.getPage(1);

      final w = (_page!.width * (scale ?? config.defaultScale)).toInt();
      final h = (_page!.height * (scale ?? config.defaultScale)).toInt();

      _image = await _page!.render(
        width: w.toDouble(),
        height: h.toDouble(),
        format: pdfx.PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );

      _completeController.add(null);
    } catch (e) {
      _errorController.add(e.toString());
    }
  }

  @override
  Widget buildRendererWidget() {
    if (_image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Image.memory(_image!.bytes, fit: BoxFit.contain);
  }

  @override
  void enableTextSelection() {}
  @override
  void disableTextSelection() {}
  @override
  String? getSelectedText() => null;
  @override
  void clearSelection() {}

  @override
  Stream<void> get onRenderComplete => _completeController.stream;
  @override
  Stream<String> get onRenderError => _errorController.stream;
  @override
  Stream<String> get onTextSelected => _textController.stream;

  @override
  void dispose() {
    _page?.close();
    _doc?.close();
    _completeController.close();
    _errorController.close();
    _textController.close();
  }
}

// ═══════════════════════════════════════════════════════════════
// 5. RENDERER FACTORY
// File: lib/pdf_viewer/renderer/pdf_renderer_factory.dart
// ═══════════════════════════════════════════════════════════════

class PdfRendererFactory {
  static PdfCanvasRenderer create(PdfRendererConfig config) {
    final type = config.type ?? _autoDetect();

    switch (type) {
      case PdfRendererType.webCanvas:
        if (!kIsWeb) throw UnsupportedError('webCanvas only on web');
        return PdfJsCanvasRenderer(config);

      case PdfRendererType.native:
        if (kIsWeb) throw UnsupportedError('native not on web');
        return PdfNativeCanvasRenderer(config);

      case PdfRendererType.webView:
        throw UnimplementedError('WebView renderer not implemented');
    }
  }

  static PdfRendererType _autoDetect() {
    if (kIsWeb) return PdfRendererType.webCanvas;
    if (Platform.isAndroid || Platform.isIOS) return PdfRendererType.native;
    return PdfRendererType.webView;
  }
}

// ═══════════════════════════════════════════════════════════════
// 6. PDF PAGE WIDGET
// File: lib/pdf_viewer/widgets/pdf_page_widget.dart
// ═══════════════════════════════════════════════════════════════

class PdfPageWidget extends StatefulWidget {
  final int pageNumber;
  final int totalPages;
  final double width;
  final double height;
  final double scale;
  final Future<Uint8List> Function() loadPageData;

  const PdfPageWidget({
    Key? key,
    required this.pageNumber,
    required this.totalPages,
    required this.width,
    required this.height,
    required this.scale,
    required this.loadPageData,
  }) : super(key: key);

  @override
  State<PdfPageWidget> createState() => _PdfPageWidgetState();
}

class _PdfPageWidgetState extends State<PdfPageWidget> {
  PdfCanvasRenderer? _renderer;
  bool _isLoading = false;
  bool _isRendered = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAndRender();
  }

  Future<void> _loadAndRender() async {
    if (_isLoading || _isRendered) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final data = await widget.loadPageData();
      if (!mounted) return;

      _renderer = PdfRendererFactory.create(PdfRendererConfig.auto());
      await _renderer!.initialize();
      if (!mounted) return;

      await _renderer!.renderPage(pdfData: data, scale: widget.scale);

      setState(() {
        _isLoading = false;
        _isRendered = true;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        children: [
          if (_isRendered && _renderer != null)
            _renderer!.buildRendererWidget(),

          if (_isLoading)
            const Center(child: CircularProgressIndicator()),

          if (_error != null)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error, color: Colors.red),
                  const SizedBox(height: 8),
                  Text('Error: $_error'),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _isRendered = false;
                        _error = null;
                      });
                      _loadAndRender();
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),

          Positioned(
            bottom: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${widget.pageNumber} / ${widget.totalPages}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _renderer?.dispose();
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════
// 7. PDF VIEWER CONTROLLER
// File: lib/pdf_viewer/controller/pdf_viewer_controller.dart
// ═══════════════════════════════════════════════════════════════

class PdfViewerController extends ChangeNotifier {
  final Map<int, Uint8List> _cache = {};
  final Set<int> _loading = {};
  final Set<int> _sent = {};
  final Future<Uint8List> Function(int page) fetchPage;

  PdfViewerController({required this.fetchPage});

  Future<Uint8List> loadPage(int page) async {
    if (_sent.contains(page)) {
      return _cache[page]!;
    }

    if (_cache.containsKey(page)) {
      _sent.add(page);
      return _cache[page]!;
    }

    if (_loading.contains(page)) {
      while (_loading.contains(page)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return _cache[page]!;
    }

    _loading.add(page);
    try {
      final data = await fetchPage(page);
      _cache[page] = data;
      _sent.add(page);
      return data;
    } finally {
      _loading.remove(page);
    }
  }

  void clearCache() {
    _cache.clear();
    _sent.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _cache.clear();
    _sent.clear();
    _loading.clear();
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════
// 8. PDF VIEWER SCREEN
// File: lib/pdf_viewer/screens/pdf_viewer_screen.dart
// ═══════════════════════════════════════════════════════════════

class PdfViewerScreen extends StatefulWidget {
  final String documentId;
  final List<Map<String, dynamic>> pages;
  final int totalPages;
  final Future<Uint8List> Function(String docId, int page) fetchPageData;
  final String title;

  const PdfViewerScreen({
    Key? key,
    required this.documentId,
    required this.pages,
    required this.totalPages,
    required this.fetchPageData,
    this.title = 'PDF Viewer',
  }) : super(key: key);

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  late PdfViewerController _controller;
  double _scale = 1.5;
  PdfViewMode _viewMode = PdfViewMode.continuous;

  @override
  void initState() {
    super.initState();
    _controller = PdfViewerController(
      fetchPage: (page) => widget.fetchPageData(widget.documentId, page),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          // Zoom out
          IconButton(
            icon: const Icon(Icons.zoom_out),
            onPressed: () {
              setState(() {
                _scale = (_scale - 0.3).clamp(0.5, 3.0);
                _controller.clearCache();
              });
            },
          ),

          // Zoom level
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text('${(_scale * 100).toInt()}%'),
            ),
          ),

          // Zoom in
          IconButton(
            icon: const Icon(Icons.zoom_in),
            onPressed: () {
              setState(() {
                _scale = (_scale + 0.3).clamp(0.5, 3.0);
                _controller.clearCache();
              });
            },
          ),

          // View mode selector
          PopupMenuButton<PdfViewMode>(
            icon: const Icon(Icons.view_module),
            onSelected: (mode) {
              setState(() => _viewMode = mode);
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: PdfViewMode.continuous,
                child: Row(
                  children: [
                    Icon(Icons.view_stream),
                    SizedBox(width: 8),
                    Text('Continuous'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: PdfViewMode.singlePage,
                child: Row(
                  children: [
                    Icon(Icons.view_agenda),
                    SizedBox(width: 8),
                    Text('Single Page'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_viewMode) {
      case PdfViewMode.continuous:
        return _buildContinuousView();
      case PdfViewMode.singlePage:
        return _buildSinglePageView();
      default:
        return _buildContinuousView();
    }
  }

  Widget _buildContinuousView() {
    return Container(
      color: const Color(0xFF525659),
      child: ListView.builder(
        padding: const EdgeInsets.all(20),
        itemCount: widget.pages.length,
        itemBuilder: (context, index) {
          final pageInfo = widget.pages[index];
          final pageNumber = pageInfo['pageNumber'] as int;

          double width = (pageInfo['width'] as num).toDouble();
          double height = (pageInfo['height'] as num).toDouble();

          final unit = pageInfo['unit'] as String?;
          if (unit == 'mm') {
            width *= 2.83465;
            height *= 2.83465;
          } else if (unit == 'in') {
            width *= 72;
            height *= 72;
          }

          width *= _scale;
          height *= _scale;

          return Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: PdfPageWidget(
              key: ValueKey('page-$pageNumber-$_scale'),
              pageNumber: pageNumber,
              totalPages: widget.totalPages,
              width: width,
              height: height,
              scale: _scale,
              loadPageData: () => _controller.loadPage(pageNumber),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSinglePageView() {
    return Container(
      color: const Color(0xFF525659),
      child: PageView.builder(
        itemCount: widget.pages.length,
        itemBuilder: (context, index) {
          final pageInfo = widget.pages[index];
          final pageNumber = pageInfo['pageNumber'] as int;

          double width = (pageInfo['width'] as num).toDouble();
          double height = (pageInfo['height'] as num).toDouble();

          final unit = pageInfo['unit'] as String?;
          if (unit == 'mm') {
            width *= 2.83465;
            height *= 2.83465;
          } else if (unit == 'in') {
            width *= 72;
            height *= 72;
          }

          width *= _scale;
          height *= _scale;

          return Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: PdfPageWidget(
                key: ValueKey('page-$pageNumber-$_scale'),
                pageNumber: pageNumber,
                totalPages: widget.totalPages,
                width: width,
                height: height,
                scale: _scale,
                loadPageData: () => _controller.loadPage(pageNumber),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

// ═══════════════════════════════════════════════════════════════
// 9. EXAMPLE USAGE
// File: lib/main.dart
// ═══════════════════════════════════════════════════════════════

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF Viewer',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const PdfViewerExample(),
    );
  }
}

class PdfViewerExample extends StatelessWidget {
  const PdfViewerExample({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Example document info
    final pages = List.generate(10, (i) => {
      'pageNumber': i + 1,
      'width': 595.0,  // A4 width in points
      'height': 842.0, // A4 height in points
      'unit': 'pt',
    });

    return PdfViewerScreen(
      documentId: 'example-doc',
      pages: pages,
      totalPages: 10,
      title: 'Example PDF',
      fetchPageData: (docId, page) async {
        // TODO: Replace with your actual API call
        // Example: return await PdfApiService.getPage(docId, page);

        // For demo, return empty PDF page
        await Future.delayed(const Duration(seconds: 1));
        throw UnimplementedError('Implement your PDF API service here');
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// INTEGRATION WITH YOUR EXISTING API
// ═══════════════════════════════════════════════════════════════

/*
To integrate with your existing PdfApiService:

1. In PdfViewerScreen, replace fetchPageData:

   PdfViewerScreen(
     documentId: widget.documentId,
     pages: documentInfo.pages,
     totalPages: documentInfo.totalPages,
     title: documentInfo.title,
     fetchPageData: (docId, page) async {
       return await _apiService.getPageAsPdf(docId, page);
     },
   )

2. Load document info first:

   class PdfViewerWrapper extends StatefulWidget {
     final String documentId;

     @override
     State<PdfViewerWrapper> createState() => _PdfViewerWrapperState();
   }

   class _PdfViewerWrapperState extends State<PdfViewerWrapper> {
     DocumentInfo? _docInfo;
     bool _loading = true;

     @override
     void initState() {
       super.initState();
       _loadDocInfo();
     }

     Future<void> _loadDocInfo() async {
       final info = await PdfApiService().getDocumentInfo(widget.documentId);
       setState(() {
         _docInfo = info;
         _loading = false;
       });
     }

     @override
     Widget build(BuildContext context) {
       if (_loading) return Scaffold(body: Center(child: CircularProgressIndicator()));

       return PdfViewerScreen(
         documentId: widget.documentId,
         pages: _docInfo!.pages,
         totalPages: _docInfo!.totalPages,
         title: _docInfo!.title,
         fetchPageData: (docId, page) => PdfApiService().getPageAsPdf(docId, page),
       );
     }
   }
*/