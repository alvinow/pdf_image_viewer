import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/document_info.dart';
import 'package:pdf_image_viewer/appconfig.dart';

/// PDF API Service for Android platform
/// Handles all HTTP communication with the PDF backend
class PdfApiService {
  final String baseUrl;
  final http.Client? client;
  final Duration timeout;

  PdfApiService({
    this.baseUrl = AppConfig.baseUrl,
    this.client,
    this.timeout = const Duration(seconds: 30),
  });

  /// Get or create HTTP client
  http.Client get _client => client ?? http.Client();

  // ============================================================================
  // DOCUMENT INFO
  // ============================================================================

  /// Fetches document metadata
  /// Returns: Document information including page count, dimensions, etc.
  Future<DocumentInfo> getDocumentInfo(String documentId) async {
    try {
      final uri = Uri.parse('$baseUrl/pdf/$documentId/info');

      final response = await _client
          .get(
        uri,
        headers: {
          'Cache-Control': 'no-cache', // Always get fresh metadata
        },
      )
          .timeout(timeout);

      if (response.statusCode == 200) {
        return DocumentInfo.fromJson(jsonDecode(response.body));
      } else if (response.statusCode == 404) {
        throw DocumentNotFoundException('Document not found: $documentId');
      } else {
        throw PdfApiException(
          'Failed to load document info',
          statusCode: response.statusCode,
          body: response.body,
        );
      }
    } on http.ClientException catch (e) {
      throw PdfApiException('Network error: ${e.message}');
    } on TimeoutException {
      throw PdfApiException('Request timeout after ${timeout.inSeconds}s');
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching document info: $e');
    }
  }

  // ============================================================================
  // SINGLE PAGE
  // ============================================================================

  /// Fetches a single page as PDF bytes
  /// Returns: PDF data for the specified page
  Future<Uint8List> getPageAsPdf(String documentId, int pageNumber) async {
    if (pageNumber < 1) {
      throw ArgumentError('Page number must be greater than 0');
    }

    try {
      final uri = Uri.parse('$baseUrl/pdf/$documentId/page/$pageNumber');

      final response = await _client
          .get(uri)
          .timeout(timeout);

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;

        // Validate PDF content
        if (!_isPdfContent(bytes)) {
          throw PdfApiException('Response is not a valid PDF');
        }

        return bytes;
      } else if (response.statusCode == 404) {
        throw PageNotFoundException('Page $pageNumber not found');
      } else {
        throw PdfApiException(
          'Failed to load page $pageNumber',
          statusCode: response.statusCode,
          body: response.body,
        );
      }
    } on http.ClientException catch (e) {
      throw PdfApiException('Network error: ${e.message}');
    } on TimeoutException {
      throw PdfApiException('Request timeout after ${timeout.inSeconds}s');
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching page $pageNumber: $e');
    }
  }

  /// Fetches a single page as image bytes (PNG/JPEG)
  /// Returns: Image data for the specified page
  Future<Uint8List> getPageAsImage(
      String documentId,
      int pageNumber, {
        int? width,
        int? height,
        String format = 'png',
      }) async {
    if (pageNumber < 1) {
      throw ArgumentError('Page number must be greater than 0');
    }

    try {
      final queryParams = <String, String>{
        'format': 'image',
        if (width != null) 'width': width.toString(),
        if (height != null) 'height': height.toString(),
        if (format != 'png') 'type': format,
      };

      final uri = Uri.parse('$baseUrl/pdf/$documentId/page/$pageNumber')
          .replace(queryParameters: queryParams);

      final response = await _client
          .get(uri)
          .timeout(timeout);

      if (response.statusCode == 200) {
        return response.bodyBytes;
      } else if (response.statusCode == 404) {
        throw PageNotFoundException('Page $pageNumber not found');
      } else {
        throw PdfApiException(
          'Failed to load page image',
          statusCode: response.statusCode,
          body: response.body,
        );
      }
    } on http.ClientException catch (e) {
      throw PdfApiException('Network error: ${e.message}');
    } on TimeoutException {
      throw PdfApiException('Request timeout after ${timeout.inSeconds}s');
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching page image: $e');
    }
  }

  // ============================================================================
  // PAGE RANGE
  // ============================================================================

  /// Fetches a range of pages as a single merged PDF
  /// Returns: PDF data containing all pages in the range
  Future<Uint8List> getPageRange(
      String documentId,
      int start,
      int end,
      ) async {
    if (start < 1 || end < start) {
      throw ArgumentError('Invalid page range: start=$start, end=$end');
    }

    try {
      final uri = Uri.parse('$baseUrl/pdf/$documentId/pages')
          .replace(queryParameters: {
        'start': start.toString(),
        'end': end.toString(),
      });

      final response = await _client
          .get(uri)
          .timeout(timeout);

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;

        // Validate PDF content
        if (!_isPdfContent(bytes)) {
          throw PdfApiException('Response is not a valid PDF');
        }

        return bytes;
      } else if (response.statusCode == 404) {
        throw DocumentNotFoundException('Document not found: $documentId');
      } else {
        throw PdfApiException(
          'Failed to load page range $start-$end',
          statusCode: response.statusCode,
          body: response.body,
        );
      }
    } on http.ClientException catch (e) {
      throw PdfApiException('Network error: ${e.message}');
    } on TimeoutException {
      throw PdfApiException('Request timeout after ${timeout.inSeconds}s');
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching page range: $e');
    }
  }

  /// Fetches multiple pages as separate PDFs
  /// Returns: List of PDF data for each page
  Future<List<Uint8List>> getMultiplePages(
      String documentId,
      List<int> pageNumbers,
      ) async {
    if (pageNumbers.isEmpty) {
      throw ArgumentError('Page numbers list cannot be empty');
    }

    final results = <Uint8List>[];
    final errors = <int, dynamic>{};

    // Fetch pages in parallel
    final futures = pageNumbers.map((pageNumber) async {
      try {
        return await getPageAsPdf(documentId, pageNumber);
      } catch (e) {
        errors[pageNumber] = e;
        return null;
      }
    });

    final responses = await Future.wait(futures);

    for (var i = 0; i < responses.length; i++) {
      final response = responses[i];
      if (response != null) {
        results.add(response);
      }
    }

    if (errors.isNotEmpty) {
      throw MultiplePageException(
        'Failed to fetch ${errors.length} page(s)',
        failedPages: errors,
      );
    }

    return results;
  }

  // ============================================================================
  // FULL DOCUMENT
  // ============================================================================

  /// Fetches the complete document as a single PDF
  /// Returns: Full PDF document data
  Future<Uint8List> getFullDocument(String documentId) async {
    try {
      final uri = Uri.parse('$baseUrl/pdf/$documentId/full');

      final response = await _client
          .get(uri)
          .timeout(timeout);

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;

        // Validate PDF content
        if (!_isPdfContent(bytes)) {
          throw PdfApiException('Response is not a valid PDF');
        }

        return bytes;
      } else if (response.statusCode == 404) {
        throw DocumentNotFoundException('Document not found: $documentId');
      } else {
        throw PdfApiException(
          'Failed to load full document',
          statusCode: response.statusCode,
          body: response.body,
        );
      }
    } on http.ClientException catch (e) {
      throw PdfApiException('Network error: ${e.message}');
    } on TimeoutException {
      throw PdfApiException('Request timeout after ${timeout.inSeconds}s');
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching full document: $e');
    }
  }

  // ============================================================================
  // DOWNLOAD
  // ============================================================================

  /// Downloads a page with progress callback
  /// Returns: PDF data with progress updates
  Future<Uint8List> downloadPageWithProgress(
      String documentId,
      int pageNumber,
      void Function(int received, int total)? onProgress,
      ) async {
    if (pageNumber < 1) {
      throw ArgumentError('Page number must be greater than 0');
    }

    try {
      final uri = Uri.parse('$baseUrl/pdf/$documentId/page/$pageNumber');

      final request = http.Request('GET', uri);
      final streamedResponse = await _client.send(request).timeout(timeout);

      if (streamedResponse.statusCode == 200) {
        final contentLength = streamedResponse.contentLength ?? 0;
        final chunks = <int>[];
        int received = 0;

        await for (final chunk in streamedResponse.stream) {
          chunks.addAll(chunk);
          received += chunk.length;

          if (onProgress != null && contentLength > 0) {
            onProgress(received, contentLength);
          }
        }

        final bytes = Uint8List.fromList(chunks);

        // Validate PDF content
        if (!_isPdfContent(bytes)) {
          throw PdfApiException('Response is not a valid PDF');
        }

        return bytes;
      } else if (streamedResponse.statusCode == 404) {
        throw PageNotFoundException('Page $pageNumber not found');
      } else {
        throw PdfApiException(
          'Failed to download page $pageNumber',
          statusCode: streamedResponse.statusCode,
        );
      }
    } on http.ClientException catch (e) {
      throw PdfApiException('Network error: ${e.message}');
    } on TimeoutException {
      throw PdfApiException('Request timeout after ${timeout.inSeconds}s');
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error downloading page $pageNumber: $e');
    }
  }

  // ============================================================================
  // URL HELPERS
  // ============================================================================

  /// Gets URL for a single page as PDF
  String getPageAsPdfUrl(String documentId, int pageNumber) {
    return '$baseUrl/pdf/$documentId/page/$pageNumber';
  }

  /// Gets URL for page range
  String getPageRangeUrl(String documentId, int start, int end) {
    return '$baseUrl/pdf/$documentId/pages?start=$start&end=$end';
  }

  /// Gets URL for document info
  String getDocumentInfoUrl(String documentId) {
    return '$baseUrl/pdf/$documentId/info';
  }

  /// Gets URL for full document
  String getFullDocumentUrl(String documentId) {
    return '$baseUrl/pdf/$documentId/full';
  }

  // ============================================================================
  // VALIDATION
  // ============================================================================

  /// Validates if bytes start with PDF magic number (%PDF)
  bool _isPdfContent(Uint8List bytes) {
    if (bytes.length < 5) return false;
    return bytes[0] == 0x25 && // %
        bytes[1] == 0x50 && // P
        bytes[2] == 0x44 && // D
        bytes[3] == 0x46; // F
  }

  /// Checks if document exists
  Future<bool> documentExists(String documentId) async {
    try {
      await getDocumentInfo(documentId);
      return true;
    } on DocumentNotFoundException {
      return false;
    } catch (e) {
      rethrow;
    }
  }

  /// Checks if page exists
  Future<bool> pageExists(String documentId, int pageNumber) async {
    try {
      final info = await getDocumentInfo(documentId);
      return pageNumber >= 1 && pageNumber <= info.totalPages;
    } catch (e) {
      return false;
    }
  }

  // ============================================================================
  // LIFECYCLE
  // ============================================================================

  /// Disposes resources
  void dispose() {
    // Only close client if we created it
    if (client == null) {
      _client.close();
    }
  }
}

// ============================================================================
// EXCEPTIONS
// ============================================================================

/// Base exception for PDF API errors
class PdfApiException implements Exception {
  final String message;
  final int? statusCode;
  final String? body;

  PdfApiException(
      this.message, {
        this.statusCode,
        this.body,
      });

  @override
  String toString() {
    final buffer = StringBuffer('PdfApiException: $message');
    if (statusCode != null) {
      buffer.write(' (Status: $statusCode)');
    }
    if (body != null && body!.isNotEmpty) {
      buffer.write('\nResponse: ${body!.substring(0, body!.length > 100 ? 100 : body!.length)}');
    }
    return buffer.toString();
  }
}

/// Exception thrown when document is not found
class DocumentNotFoundException extends PdfApiException {
  DocumentNotFoundException(String message)
      : super(message, statusCode: 404);
}

/// Exception thrown when page is not found
class PageNotFoundException extends PdfApiException {
  PageNotFoundException(String message)
      : super(message, statusCode: 404);
}

/// Exception thrown when multiple pages fail to load
class MultiplePageException extends PdfApiException {
  final Map<int, dynamic> failedPages;

  MultiplePageException(
      String message, {
        required this.failedPages,
      }) : super(message);

  @override
  String toString() {
    final buffer = StringBuffer(super.toString());
    buffer.write('\nFailed pages: ${failedPages.keys.join(", ")}');
    return buffer.toString();
  }
}

/// Exception thrown on network timeout
class TimeoutException extends PdfApiException {
  TimeoutException(String message) : super(message);
}