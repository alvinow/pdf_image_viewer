import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf_image_viewer/appconfig.dart';
import '../services/pdf_api_service.dart';
import '../models/document_info.dart';

/// Configuration class for PDF viewer behavior
class PdfViewerConfig {
  final int pagePoolSize;
  final int prefetchRadius;
  final bool enableDebugLogging;
  final double minZoom;
  final double maxZoom;
  final bool enableDiskCache;
  final int cacheSizeLimitMB;
  final Duration cacheExpiration;

  const PdfViewerConfig({
    this.pagePoolSize = 12,
    this.prefetchRadius = 3,
    this.enableDebugLogging = false,
    this.minZoom = 0.5,
    this.maxZoom = 5.0,
    this.enableDiskCache = true,
    this.cacheSizeLimitMB = 100,
    this.cacheExpiration = const Duration(days: 7),
  });
}

/// Main PDF Viewer Screen for Android with native rendering and text selection
class PdfViewerAndroidScreen extends StatefulWidget {
  final String documentId;
  final String? apiBaseUrl;
  final String title;
  final PdfViewerConfig config;

  const PdfViewerAndroidScreen({
    Key? key,
    required this.documentId,
    this.apiBaseUrl,
    required this.title,
    this.config = const PdfViewerConfig(),
  }) : super(key: key);

  @override
  State<PdfViewerAndroidScreen> createState() => _PdfViewerAndroidScreenState();
}

class _PdfViewerAndroidScreenState extends State<PdfViewerAndroidScreen> {
  late PdfApiService _apiService;
  DocumentInfo? _documentInfo;
  bool _isLoading = true;
  String? _error;

  // PDF document cache - stores PdfDocument for each page
  final Map<int, PdfDocument?> _pdfDocumentCache = {};
  final Map<int, PdfController?> _pdfControllerCache = {};
  final Map<int, Size> _pageSizes = {};
  final Set<int> _loadingPages = {};
  final Set<int> _loadedPages = {};

  // Disk cache directory
  Directory? _cacheDir;
  bool _cacheInitialized = false;

  // View state
  int _currentPage = 1;
  double _zoomLevel = 1.0;
  bool _textSelectionEnabled = false;

  // Controllers
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _pageController = TextEditingController();
  final FocusNode _pageFocusNode = FocusNode();
  Timer? _prefetchTimer;

  double _maxPageWidth = 0;
  bool _isMobile = true;

  @override
  void initState() {
    super.initState();
    _apiService = PdfApiService(
      baseUrl: widget.apiBaseUrl ?? AppConfig.baseUrl,
    );

    _scrollController.addListener(_onScroll);
    _initializeCache();
    _loadDocument();
    _pageController.text = _currentPage.toString();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final data = MediaQuery.of(context);
    _isMobile = data.size.shortestSide < 600;
  }

  void _debugLog(String message) {
    if (widget.config.enableDebugLogging) {
      print('[PDF_NATIVE] $message');
    }
  }

  // ============================================================================
  // DISK CACHE MANAGEMENT
  // ============================================================================

  /// Initialize disk cache directory
  Future<void> _initializeCache() async {
    if (!widget.config.enableDiskCache) return;

    try {
      final tempDir = await getTemporaryDirectory();
      _cacheDir = Directory('${tempDir.path}/pdf_cache/${widget.documentId}');

      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
        _debugLog('Created cache directory: ${_cacheDir!.path}');
      }

      _cacheInitialized = true;

      // Clean up expired cache on startup
      _cleanupExpiredCache();

    } catch (e) {
      _debugLog('Failed to initialize cache: $e');
      _cacheInitialized = false;
    }
  }

  /// Clean up expired cache files based on cacheExpiration duration
  Future<void> _cleanupExpiredCache() async {
    if (_cacheDir == null || !await _cacheDir!.exists()) return;

    try {
      final now = DateTime.now();
      final files = await _cacheDir!.list().toList();
      int deletedCount = 0;

      for (final file in files) {
        if (file is File) {
          final stat = await file.stat();
          final age = now.difference(stat.modified);

          if (age > widget.config.cacheExpiration) {
            await file.delete();
            deletedCount++;
          }
        }
      }

      if (deletedCount > 0) {
        _debugLog('Cleaned up $deletedCount expired cache files');
      }

      // Check total cache size
      await _enforceCacheSizeLimit();

    } catch (e) {
      _debugLog('Error cleaning up cache: $e');
    }
  }

  /// Enforce cache size limit by deleting oldest files
  Future<void> _enforceCacheSizeLimit() async {
    if (_cacheDir == null || !await _cacheDir!.exists()) return;

    try {
      final files = await _cacheDir!.list().toList();
      int totalSize = 0;
      final fileStats = <MapEntry<File, int>>[];

      for (final file in files) {
        if (file is File) {
          final size = await file.length();
          totalSize += size;
          fileStats.add(MapEntry(file, size));
        }
      }

      final limitBytes = widget.config.cacheSizeLimitMB * 1024 * 1024;

      if (totalSize > limitBytes) {
        _debugLog('Cache size ($totalSize bytes) exceeds limit ($limitBytes bytes)');

        // Sort by modification time (oldest first)
        fileStats.sort((a, b) {
          final aTime = a.key.statSync().modified;
          final bTime = b.key.statSync().modified;
          return aTime.compareTo(bTime);
        });

        // Delete oldest files until under limit
        int deletedSize = 0;
        int deletedCount = 0;

        for (final entry in fileStats) {
          if (totalSize - deletedSize <= limitBytes) break;

          await entry.key.delete();
          deletedSize += entry.value;
          deletedCount++;
        }

        _debugLog('Deleted $deletedCount files (${deletedSize ~/ 1024} KB) to enforce cache limit');
      }

    } catch (e) {
      _debugLog('Error enforcing cache size limit: $e');
    }
  }

  /// Get cache file name for a specific page
  String _getCacheFileName(int pageNumber) {
    return 'page_$pageNumber.pdf';
  }

  /// Get cache file for a specific page
  File? _getCacheFile(int pageNumber) {
    if (_cacheDir == null) return null;
    return File('${_cacheDir!.path}/${_getCacheFileName(pageNumber)}');
  }

  /// Load page data from disk cache
  Future<Uint8List?> _loadFromDiskCache(int pageNumber) async {
    if (!widget.config.enableDiskCache || !_cacheInitialized) {
      return null;
    }

    try {
      final cacheFile = _getCacheFile(pageNumber);
      if (cacheFile == null || !await cacheFile.exists()) {
        return null;
      }

      final data = await cacheFile.readAsBytes();
      _debugLog('Loaded page $pageNumber from disk cache (${data.length} bytes)');
      return data;

    } catch (e) {
      _debugLog('Error reading from disk cache for page $pageNumber: $e');
      return null;
    }
  }

  /// Save page data to disk cache
  Future<void> _saveToDiskCache(int pageNumber, Uint8List data) async {
    if (!widget.config.enableDiskCache || !_cacheInitialized) {
      return;
    }

    try {
      final cacheFile = _getCacheFile(pageNumber);
      if (cacheFile == null) return;

      await cacheFile.writeAsBytes(data);
      _debugLog('Saved page $pageNumber to disk cache (${data.length} bytes)');

    } catch (e) {
      _debugLog('Error saving to disk cache for page $pageNumber: $e');
    }
  }

  /// Clear all disk cache
  Future<void> clearDiskCache() async {
    if (_cacheDir == null || !await _cacheDir!.exists()) return;

    try {
      await _cacheDir!.delete(recursive: true);
      await _cacheDir!.create(recursive: true);
      _debugLog('Cleared all disk cache');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cache cleared successfully')),
        );
      }
    } catch (e) {
      _debugLog('Error clearing cache: $e');
    }
  }

  /// Get cache size information as formatted string
  Future<String> getCacheSizeInfo() async {
    if (_cacheDir == null || !await _cacheDir!.exists()) {
      return '0 MB';
    }

    try {
      final files = await _cacheDir!.list().toList();
      int totalSize = 0;

      for (final file in files) {
        if (file is File) {
          totalSize += await file.length();
        }
      }

      final sizeMB = totalSize / (1024 * 1024);
      return '${sizeMB.toStringAsFixed(2)} MB';

    } catch (e) {
      return 'Error';
    }
  }

  // ============================================================================
  // SCROLLING AND NAVIGATION
  // ============================================================================

  /// Handle scroll events with debouncing
  void _onScroll() {
    _prefetchTimer?.cancel();
    _prefetchTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      _updateCurrentPage();
      _prefetchAroundPage(_currentPage);
    });
  }

  /// Update current page based on scroll position
  void _updateCurrentPage() {
    if (_documentInfo == null || _pageSizes.isEmpty) return;

    final scrollOffset = _scrollController.offset;
    final viewportHeight = _scrollController.position.viewportDimension;
    final viewportCenter = scrollOffset + (viewportHeight / 2);

    double accumulatedHeight = 0;
    final gap = _isMobile ? 10.0 : 20.0;

    for (int i = 1; i <= _documentInfo!.totalPages; i++) {
      final pageSize = _pageSizes[i];
      if (pageSize == null) continue;

      final pageHeight = pageSize.height * _zoomLevel;
      final pageCenter = accumulatedHeight + (pageHeight / 2);

      if (viewportCenter < pageCenter + pageHeight) {
        if (_currentPage != i) {
          setState(() {
            _currentPage = i;
            _pageController.text = i.toString();
          });
        }
        break;
      }

      accumulatedHeight += pageHeight + gap;
    }
  }

  /// Navigate to a specific page
  void _goToPage(int page) {
    if (_documentInfo == null || page < 1 || page > _documentInfo!.totalPages) {
      return;
    }

    HapticFeedback.selectionClick();

    // Calculate scroll position for the target page
    double targetOffset = 0;
    final gap = _isMobile ? 10.0 : 20.0;

    for (int i = 1; i < page; i++) {
      final pageSize = _pageSizes[i];
      if (pageSize != null) {
        targetOffset += (pageSize.height * _zoomLevel) + gap;
      }
    }

    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );

    setState(() {
      _currentPage = page;
      _pageController.text = page.toString();
    });

    _prefetchAroundPage(page);
  }

  // ============================================================================
  // DOCUMENT LOADING
  // ============================================================================

  /// Load document information from API
  Future<void> _loadDocument() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final info = await _apiService
          .getDocumentInfo(widget.documentId)
          .timeout(const Duration(seconds: 30));

      if (!mounted) return;

      setState(() {
        _documentInfo = info;
      });

      _calculatePageDimensions();

      setState(() {
        _isLoading = false;
      });

      _loadInitialPages();

    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Calculate page dimensions from document info
  void _calculatePageDimensions() {
    if (_documentInfo == null) return;

    for (final pageInfo in _documentInfo!.pages ?? []) {
      final dimensions = pageInfo.dimensions;
      double widthPt = dimensions.width;
      double heightPt = dimensions.height;

      // Convert to points (PDF standard unit)
      if (dimensions.unit == 'mm') {
        widthPt *= 2.83465;
        heightPt *= 2.83465;
      } else if (dimensions.unit == 'in') {
        widthPt *= 72;
        heightPt *= 72;
      }

      _pageSizes[pageInfo.pageNumber] = Size(widthPt, heightPt);

      if (widthPt > _maxPageWidth) {
        _maxPageWidth = widthPt;
      }
    }

    _debugLog('Calculated dimensions for ${_pageSizes.length} pages');
  }

  /// Load initial pages when document first loads
  Future<void> _loadInitialPages() async {
    if (_documentInfo == null) return;

    _loadPage(1);
    if (_documentInfo!.totalPages > 1) {
      _loadPage(2);
    }
    if (_documentInfo!.totalPages > 2) {
      _loadPage(3);
    }
  }

  /// Prefetch pages around a center page
  void _prefetchAroundPage(int centerPage) {
    final radius = widget.config.prefetchRadius;
    for (int offset = -radius; offset <= radius; offset++) {
      final page = centerPage + offset;
      if (page >= 1 && page <= (_documentInfo?.totalPages ?? 0)) {
        _loadPage(page);
      }
    }
  }

  // ============================================================================
  // PAGE LOADING
  // ============================================================================

  /// Load a specific page from cache or API
  Future<void> _loadPage(int pageNumber) async {
    if (_documentInfo == null) return;

    // Skip if already loaded or currently loading
    if (_loadedPages.contains(pageNumber) || _loadingPages.contains(pageNumber)) {
      return;
    }

    _loadingPages.add(pageNumber);
    _debugLog('Loading page $pageNumber');

    try {
      Uint8List? pdfData;

      // Try to load from disk cache first
      if (widget.config.enableDiskCache) {
        pdfData = await _loadFromDiskCache(pageNumber);

        if (pdfData != null) {
          _debugLog('Page $pageNumber loaded from cache');
        }
      }

      // If not in cache, fetch from API
      if (pdfData == null) {
        _debugLog('Page $pageNumber not in cache, fetching from API');
        pdfData = await _apiService
            .getPageAsPdf(widget.documentId, pageNumber)
            .timeout(const Duration(seconds: 30));

        // Save to disk cache for future use
        if (widget.config.enableDiskCache) {
          await _saveToDiskCache(pageNumber, pdfData);
        }
      }

      if (!mounted) return;

      // Create PDF document and controller from the page data
      final pdfDocument = await PdfDocument.openData(pdfData);
      final controller = PdfController(
        document: PdfDocument.openData(pdfData),
      );

      setState(() {
        _pdfDocumentCache[pageNumber] = pdfDocument;
        _pdfControllerCache[pageNumber] = controller;
        _loadedPages.add(pageNumber);
      });

      _loadingPages.remove(pageNumber);
      _cleanupDistantPages();

      _debugLog('Successfully loaded PDF page $pageNumber');

    } catch (e) {
      _debugLog('Error loading page $pageNumber: $e');
      _loadingPages.remove(pageNumber);

      if (mounted) {
        setState(() {
          _pdfDocumentCache[pageNumber] = null;
        });
      }
    }
  }

  /// Clean up pages that are far from current view
  void _cleanupDistantPages() {
    if (_pdfDocumentCache.length <= widget.config.pagePoolSize * 2) return;

    final keepRadius = widget.config.prefetchRadius + 2;
    final pagesToRemove = <int>[];

    for (final pageNum in _pdfDocumentCache.keys) {
      if ((pageNum - _currentPage).abs() > keepRadius) {
        pagesToRemove.add(pageNum);
      }
    }

    if (pagesToRemove.isNotEmpty) {
      for (final pageNum in pagesToRemove) {
        // Dispose controllers and close documents
        _pdfControllerCache[pageNum]?.dispose();
        _pdfDocumentCache[pageNum]?.close();
        _pdfControllerCache.remove(pageNum);
        _pdfDocumentCache.remove(pageNum);
        _loadedPages.remove(pageNum);
      }

      _debugLog('Cleaned ${pagesToRemove.length} pages from cache');
    }
  }

  // ============================================================================
  // ZOOM AND TEXT SELECTION
  // ============================================================================

  /// Set zoom level
  void _setZoom(double zoom) {
    final clampedZoom = zoom.clamp(widget.config.minZoom, widget.config.maxZoom);

    if ((clampedZoom - _zoomLevel).abs() < 0.01) return;

    setState(() {
      _zoomLevel = clampedZoom;
    });
  }

  /// Toggle text selection mode
  void _toggleTextSelection() {
    setState(() {
      _textSelectionEnabled = !_textSelectionEnabled;
    });

    HapticFeedback.selectionClick();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _textSelectionEnabled
              ? 'Text selection mode: Long press on text to select'
              : 'Text selection mode disabled',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ============================================================================
  // UI BUILDING
  // ============================================================================

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
                '${_loadedPages.length} pages loaded • ${_documentInfo!.formattedFileSize}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          // Cache menu
          if (widget.config.enableDiskCache)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) async {
                if (value == 'clear_cache') {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Clear Cache'),
                      content: const Text('Are you sure you want to clear the disk cache?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true) {
                    await clearDiskCache();
                  }
                } else if (value == 'cache_info') {
                  final cacheSize = await getCacheSizeInfo();
                  if (mounted) {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Cache Information'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Disk cache size: $cacheSize'),
                            Text('Loaded pages: ${_loadedPages.length}'),
                            Text('Cache location: ${_cacheDir?.path ?? "Not initialized"}'),
                            const SizedBox(height: 8),
                            Text('Cache limit: ${widget.config.cacheSizeLimitMB} MB'),
                            Text('Expiration: ${widget.config.cacheExpiration.inDays} days'),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    );
                  }
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'cache_info',
                  child: Row(
                    children: [
                      Icon(Icons.info_outline),
                      SizedBox(width: 8),
                      Text('Cache Info'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'clear_cache',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline),
                      SizedBox(width: 8),
                      Text('Clear Cache'),
                    ],
                  ),
                ),
              ],
            ),

          // Text selection toggle
          // Note: Text selection in pdfx works through native gestures (long press)
          // The toggle button serves as a visual reminder to users
          IconButton(
            icon: Icon(
              _textSelectionEnabled ? Icons.text_fields : Icons.text_fields_outlined,
              color: _textSelectionEnabled ? Colors.blue : null,
            ),
            tooltip: _textSelectionEnabled
                ? 'Text selection active: Long press to select'
                : 'Enable text selection reminder',
            onPressed: _toggleTextSelection,
          ),

          // Zoom controls
          IconButton(
            icon: const Icon(Icons.zoom_out),
            onPressed: () => _setZoom(_zoomLevel - 0.3),
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
            onPressed: () => _setZoom(_zoomLevel + 0.3),
          ),

          // Page navigation
          if (_documentInfo != null) _buildPageNav(),
        ],
      ),
      body: _buildBody(),
    );
  }

  /// Build page navigation widget
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
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: InputBorder.none,
            ),
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

  /// Build main body content
  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Error loading PDF',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
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
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading PDF document...'),
          ],
        ),
      );
    }

    if (_documentInfo == null) {
      return const Center(child: Text('No document loaded'));
    }

    return Container(
      color: const Color(0xFF525659),
      child: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.all(_isMobile ? 10 : 20),
        itemCount: _documentInfo!.totalPages,
        itemBuilder: (context, index) {
          final pageNumber = index + 1;
          return _buildPageItem(pageNumber);
        },
      ),
    );
  }

  /// Build individual page item
  Widget _buildPageItem(int pageNumber) {
    final pageSize = _pageSizes[pageNumber];
    if (pageSize == null) {
      return Container(
        height: 400,
        margin: EdgeInsets.only(bottom: _isMobile ? 10 : 20),
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
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width - (_isMobile ? 20 : 40);
    final scale = screenWidth / _maxPageWidth;
    final baseScale = _isMobile ? 1.2 : 1.5;
    final finalScale = scale * baseScale * _zoomLevel;

    final displayWidth = pageSize.width * finalScale;
    final displayHeight = pageSize.height * finalScale;

    final pdfController = _pdfControllerCache[pageNumber];
    final isLoading = _loadingPages.contains(pageNumber);

    return Container(
      width: displayWidth,
      height: displayHeight,
      margin: EdgeInsets.only(bottom: _isMobile ? 10 : 20),
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
        fit: StackFit.expand,
        children: [
          // PDF View Widget
          if (pdfController != null)
            PdfView(
              controller: pdfController,
              scrollDirection: Axis.vertical,
              physics: const NeverScrollableScrollPhysics(),
              pageSnapping: false,
              onDocumentLoaded: (document) {
                _debugLog('PDF page $pageNumber document loaded');
              },
              onPageChanged: (page) {
                _debugLog('PDF page $pageNumber changed to internal page $page');
              },
              builders: PdfViewBuilders<DefaultBuilderOptions>(
                options: const DefaultBuilderOptions(),
                documentLoaderBuilder: (_) => const Center(
                  child: CircularProgressIndicator(),
                ),
                pageLoaderBuilder: (_) => const Center(
                  child: CircularProgressIndicator(),
                ),
                errorBuilder: (_, error) => Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 32),
                      const SizedBox(height: 8),
                      Text('Error: $error', style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            )

          // Loading state
          else if (isLoading)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    'Loading page $pageNumber...',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            )

          // Placeholder state
          else
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.picture_as_pdf, size: 48, color: Colors.black26),
                  const SizedBox(height: 8),
                  Text(
                    'Page $pageNumber',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ),

          // Page number overlay
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
                '$pageNumber / ${_documentInfo!.totalPages}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================================
  // LIFECYCLE
  // ============================================================================

  @override
  void dispose() {
    _prefetchTimer?.cancel();
    _scrollController.dispose();
    _pageController.dispose();
    _pageFocusNode.dispose();

    // Clean up all PDF controllers and documents
    for (final controller in _pdfControllerCache.values) {
      controller?.dispose();
    }
    for (final document in _pdfDocumentCache.values) {
      document?.close();
    }

    _pdfControllerCache.clear();
    _pdfDocumentCache.clear();
    _loadedPages.clear();
    _loadingPages.clear();

    super.dispose();
  }
}