import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:pdf_image_viewer/appconfig.dart';
import 'dart:convert';
import '../models/document_info.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// Add this import for web
import 'dart:html' as html show Blob, Url;

class PdfApiService {
  final String baseUrl;
  final http.Client? client;
  final Duration timeout;

  // Store blob URLs for cleanup
  final Set<String> _blobUrls = {};

  PdfApiService({
    this.baseUrl = AppConfig.baseUrl,
    this.client,
    this.timeout = const Duration(seconds: 30),
  });

  http.Client get _client => client ?? http.Client();

  /// Fetches document metadata and information
  Future<DocumentInfo> getDocumentInfo(String documentId) async {
    try {
      final response = await _client
          .get(
        Uri.parse('$baseUrl/pdf/$documentId/info'),
      )
          .timeout(timeout);

      if (response.statusCode == 200) {
        Map<String,dynamic> bodyDebug= json.decode(response.body);
        return DocumentInfo.fromJson(json.decode(response.body));
      } else if (response.statusCode == 404) {
        throw DocumentNotFoundException('Document not found: $documentId');
      } else {
        throw PdfApiException(
          'Failed to load document info',
          statusCode: response.statusCode,
        );
      }
    } on http.ClientException catch (e) {
      throw PdfApiException('Network error: ${e.message}');
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching document info: $e');
    }
  }

  /// Fetches a single page as image bytes (PNG/JPEG)
  Future<Uint8List> getPageAsImage(String documentId, int pageNumber) async {
    if (pageNumber < 1) {
      throw ArgumentError('Page number must be greater than 0');
    }

    try {
      final response = await _client
          .get(
        Uri.parse('$baseUrl/pdf/$documentId/page/$pageNumber'),
      )
          .timeout(timeout);

      if (response.statusCode == 200) {
        return response.bodyBytes;
      } else if (response.statusCode == 404) {
        throw PageNotFoundException('Page $pageNumber not found');
      } else {
        throw PdfApiException(
          'Failed to load page',
          statusCode: response.statusCode,
        );
      }
    } on http.ClientException catch (e) {
      throw PdfApiException('Network error: ${e.message}');
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching page: $e');
    }
  }

  /// Fetches a single page as PDF bytes
  Future<Uint8List> getPageAsPdf(String documentId, int pageNumber) async {
    return getPageRange(documentId, pageNumber, pageNumber);
  }

  /// Fetches a range of pages as a single PDF
  Future<Uint8List> getPageRange(
      String documentId,
      int start,
      int end,
      ) async {
    if (start < 1 || end < start) {
      throw ArgumentError('Invalid page range: start=$start, end=$end');
    }

    try {
      final response = await _client
          .get(
        Uri.parse('$baseUrl/pdf/$documentId/pages?start=$start&end=$end'),
      )
          .timeout(timeout);

      if (response.statusCode == 200) {
        // Validate it's actually a PDF
        if (!_isPdfContent(response.bodyBytes)) {
          throw PdfApiException('Response is not a valid PDF');
        }
        return response.bodyBytes;
      } else if (response.statusCode == 404) {
        throw DocumentNotFoundException('Document not found: $documentId');
      } else {
        throw PdfApiException(
          'Failed to load page range',
          statusCode: response.statusCode,
        );
      }
    } on http.ClientException catch (e) {
      throw PdfApiException('Network error: ${e.message}');
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching page range: $e');
    }
  }

  /// NEW: Gets URL for page range - works better with SfPdfViewer.network on web
  String getPageRangeUrl(String documentId, int start, int end) {
    return '$baseUrl/pdf/$documentId/pages?start=$start&end=$end';
  }

  /// NEW: Gets URL for single page as PDF
  String getPageAsPdfUrl(String documentId, int pageNumber) {
    return getPageRangeUrl(documentId, pageNumber, pageNumber);
  }

  /// NEW: Creates a blob URL from PDF bytes (Web only)
  /// This is the recommended way to display PDFs with Syncfusion on web
  String? createBlobUrl(Uint8List pdfBytes) {
    if (!kIsWeb) return null;

    try {
      final blob = html.Blob([pdfBytes], 'application/pdf');
      final url = html.Url.createObjectUrlFromBlob(blob);
      _blobUrls.add(url);
      return url;
    } catch (e) {
      throw PdfApiException('Failed to create blob URL: $e');
    }
  }

  /// NEW: Fetches page range and returns blob URL for web, bytes for other platforms
  Future<dynamic> getPageRangeForViewer(
      String documentId,
      int start,
      int end,
      ) async {
    if (kIsWeb) {
      // For web, use network URL directly (most reliable)
      return getPageRangeUrl(documentId, start, end);
    } else {
      // For mobile/desktop, use memory
      return await getPageRange(documentId, start, end);
    }
  }

  /// Returns the URL for a specific page image
  String getPageUrl(String documentId, int pageNumber) {
    return '$baseUrl/pdf/$documentId/page/$pageNumber';
  }

  /// Validates if bytes start with PDF magic number
  bool _isPdfContent(Uint8List bytes) {
    if (bytes.length < 4) return false;
    // Check for PDF magic number: %PDF
    return bytes[0] == 0x25 && // %
        bytes[1] == 0x50 && // P
        bytes[2] == 0x44 && // D
        bytes[3] == 0x46;   // F
  }

  /// Cleans up blob URLs
  void revokeBlobUrls() {
    if (!kIsWeb) return;

    for (final url in _blobUrls) {
      html.Url.revokeObjectUrl(url);
    }
    _blobUrls.clear();
  }

  /// Disposes the HTTP client and cleans up resources
  void dispose() {
    revokeBlobUrls();
    if (client == null) {
      _client.close();
    }
  }
}

// Custom exceptions remain the same
class PdfApiException implements Exception {
  final String message;
  final int? statusCode;

  PdfApiException(this.message, {this.statusCode});

  @override
  String toString() => statusCode != null
      ? 'PdfApiException: $message (Status: $statusCode)'
      : 'PdfApiException: $message';
}

class DocumentNotFoundException extends PdfApiException {
  DocumentNotFoundException(String message) : super(message, statusCode: 404);
}

class PageNotFoundException extends PdfApiException {
  PageNotFoundException(String message) : super(message, statusCode: 404);
}