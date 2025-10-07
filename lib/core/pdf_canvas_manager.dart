// lib/pdf_viewer/core/pdf_canvas_manager.dart

import 'package:flutter/material.dart';
import 'dart:typed_data';

/// Configuration for rendering a PDF page
class PdfRenderConfig {
  final double scale;
  final int rotation; // 0, 90, 180, 270

  const PdfRenderConfig({
    this.scale = 1.0,
    this.rotation = 0,
  });

  PdfRenderConfig copyWith({
    double? scale,
    int? rotation,
  }) {
    return PdfRenderConfig(
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
    );
  }
}

/// Information about a canvas
class CanvasInfo {
  final String canvasId;
  final int? currentPageNumber;
  final bool isAvailable;
  final DateTime? lastUsed;

  const CanvasInfo({
    required this.canvasId,
    this.currentPageNumber,
    required this.isAvailable,
    this.lastUsed,
  });
}

/// Abstract canvas manager - NO caching logic
/// Caching is handled by browser/platform
abstract class PdfCanvasManager {
  /// Initialize canvas pool with specified size
  Future<void> initialize(int poolSize);

  /// Allocate a canvas for a page number
  /// Returns canvasId or null if no slots available
  String? allocateCanvas(int pageNumber);

  /// Release a canvas and make it available for reuse
  Future<void> releaseCanvas(String canvasId);

  /// Reclaim a canvas from a distant page (for slot reuse)
  /// Returns canvasId of reclaimed canvas or null
  String? reclaimDistantCanvas(int currentPage, int targetPage);

  /// Render PDF page data to a specific canvas
  Future<void> renderPage({
    required String canvasId,
    required int pageNumber,
    required Uint8List pdfData,
    required PdfRenderConfig config,
  });

  /// Get the widget that displays this canvas
  Widget getCanvasWidget(String canvasId);

  /// Clear/reset a canvas
  Future<void> clearCanvas(String canvasId);

  /// Check if a page is currently rendered in any canvas
  bool isPageRendered(int pageNumber);

  /// Get which canvas is showing a specific page
  String? getCanvasForPage(int pageNumber);

  /// Get canvas information
  CanvasInfo? getCanvasInfo(String canvasId);

  /// Get current pool size
  int get currentPoolSize;

  /// Get list of all canvas IDs
  List<String> get allCanvasIds;

  /// Cleanup all resources
  Future<void> dispose();
}

/// Factory for creating platform-specific canvas managers
class PdfCanvasManagerFactory {
  static PdfCanvasManager create() {
    // Import will be conditional based on platform
    // For now, only web is implemented
    return PdfCanvasManagerWeb();
  }
}

// This will be imported conditionally
class PdfCanvasManagerWeb implements PdfCanvasManager {
  @override
  Future<void> initialize(int poolSize) async {
    throw UnimplementedError('Use actual web implementation');
  }

  @override
  String? allocateCanvas(int pageNumber) => null;

  @override
  Future<void> releaseCanvas(String canvasId) async {}

  @override
  String? reclaimDistantCanvas(int currentPage, int targetPage) => null;

  @override
  Future<void> renderPage({
    required String canvasId,
    required int pageNumber,
    required Uint8List pdfData,
    required PdfRenderConfig config,
  }) async {}

  @override
  Widget getCanvasWidget(String canvasId) => SizedBox.shrink();

  @override
  Future<void> clearCanvas(String canvasId) async {}

  @override
  bool isPageRendered(int pageNumber) => false;

  @override
  String? getCanvasForPage(int pageNumber) => null;

  @override
  CanvasInfo? getCanvasInfo(String canvasId) => null;

  @override
  int get currentPoolSize => 0;

  @override
  List<String> get allCanvasIds => [];

  @override
  Future<void> dispose() async {}
}