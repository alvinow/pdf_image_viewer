// lib/pdf_viewer/core/pdf_view_mode.dart

import 'package:flutter/material.dart';

enum PdfViewModeType {
  continuousScroll,
  singlePage,
  thumbnailGrid,      // Future
  thumbnailSidebar,   // Future
}

/// Abstract base for view modes
abstract class PdfViewMode {
  final PdfViewerController controller;

  PdfViewMode({required this.controller});

  /// Build the view mode layout
  Widget buildLayout(BuildContext context);

  /// Get currently visible pages (for rendering)
  List<int> getVisiblePages();

  /// Get pages to prefetch
  List<int> getPrefetchPages();

  /// Navigate to specific page
  Future<void> navigateToPage(int page, {bool animate = true});

  /// Handle zoom change
  void onZoomChanged(double zoom);

  /// Handle rotation change
  void onRotationChanged(int degrees);

  /// Get current page
  int get currentPage;

  /// Called when view mode becomes active
  Future<void> onActivated();

  /// Called when view mode becomes inactive
  Future<void> onDeactivated();

  /// Dispose resources
  void dispose();
}

/// Controller interface for view modes to communicate with parent
abstract class PdfViewerController {
  // Document info
  DocumentInfo ? get documentInfo;
  int get totalPages;

  // State
  double get zoomLevel;
  int get rotationDegrees;
  PdfViewerConfig get config;

  // Canvas manager
  PdfCanvasManager get canvasManager;

  // Callbacks
  void updateCurrentPage(int page);
  void updateZoomLevel(double zoom);

  // Data loading
  Future<Uint8List> loadPageData(int pageNumber);

  // Request re-render
  void requestRender(List<int> pageNumbers);
}