import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/document_info.dart';
import 'package:pdf_image_viewer/appconfig.dart';

// Conditional imports
import 'dart:html' as html;
import 'package:http/http.dart' as http;

class PdfApiService {
  final String baseUrl;
  final http.Client? client;
  final Duration timeout;

  // Store blob URLs for cleanup (web only)
  final Set<String> _blobUrls = {};

  PdfApiService({
    this.baseUrl = AppConfig.baseUrl,
    this.client,
    this.timeout = const Duration(seconds: 30),
  });

  http.Client get _client => client ?? http.Client();

  /// Fetches document metadata (not cached - always fresh)
  Future<DocumentInfo> getDocumentInfo(String documentId) async {
    try {
      if (kIsWeb) {
        return await _getDocumentInfoWeb(documentId);
      } else {
        return await _getDocumentInfoHttp(documentId);
      }
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching document info: $e');
    }
  }

  /// Web implementation using XMLHttpRequest
  Future<DocumentInfo> _getDocumentInfoWeb(String documentId) async {
    final url = '$baseUrl/pdf/$documentId/info';
    final completer = Completer<DocumentInfo>();

    try {
      final request = html.HttpRequest();
      request.open('GET', url);

      // Don't cache metadata
      request.setRequestHeader('Cache-Control', 'no-cache');

      request.onLoad.listen((_) {
        if (request.status == 200) {
          try {
            final text = request.responseText ?? '';
            final info = DocumentInfo.fromJson(jsonDecode(text));
            completer.complete(info);
          } catch (e) {
            completer.completeError(
              PdfApiException('Failed to parse document info: $e'),
            );
          }
        } else if (request.status == 404) {
          completer.completeError(
            DocumentNotFoundException('Document not found: $documentId'),
          );
        } else {
          completer.completeError(
            PdfApiException(
              'Failed to load document info',
              statusCode: request.status,
            ),
          );
        }
      });

      request.onError.listen((error) {
        completer.completeError(
          PdfApiException('Network error: $error'),
        );
      });

      request.onTimeout.listen((_) {
        completer.completeError(
          PdfApiException('Request timeout'),
        );
      });

      request.send();

      return completer.future.timeout(timeout);
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching document info: $e');
    }
  }

  /// HTTP implementation for non-web platforms
  Future<DocumentInfo> _getDocumentInfoHttp(String documentId) async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/pdf/$documentId/info'))
          .timeout(timeout);

      if (response.statusCode == 200) {
        return DocumentInfo.fromJson(jsonDecode(response.body));
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
    }
  }

  /// Fetches a single page as PDF (browser cached via ETag and Cache-Control)
  Future<Uint8List> getPageAsPdf(String documentId, int pageNumber) async {
    if (pageNumber < 1) {
      throw ArgumentError('Page number must be greater than 0');
    }

    try {
      if (kIsWeb) {
        return await _getPageAsPdfWeb(documentId, pageNumber);
      } else {
        return await _getPageAsPdfHttp(documentId, pageNumber);
      }
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching page $pageNumber: $e');
    }
  }

  /// Web implementation using XMLHttpRequest with browser caching
  Future<Uint8List> _getPageAsPdfWeb(String documentId, int pageNumber) async {
    final url = '$baseUrl/pdf/$documentId/page/$pageNumber';
    final completer = Completer<Uint8List>();

    try {
      final request = html.HttpRequest();
      request.open('GET', url);
      request.responseType = 'arraybuffer';

      // Let browser handle caching - don't set Cache-Control header
      // Browser will automatically use ETag and Cache-Control from server

      request.onLoad.listen((_) {
        if (request.status == 200 || request.status == 304) {
          if (request.status == 304) {
            print('Page $pageNumber served from browser cache (304)');
          }

          try {
            final buffer = request.response as ByteBuffer;
            final bytes = buffer.asUint8List();

            if (!_isPdfContent(bytes)) {
              completer.completeError(
                PdfApiException('Response is not a valid PDF'),
              );
              return;
            }

            completer.complete(bytes);
          } catch (e) {
            completer.completeError(
              PdfApiException('Failed to process response: $e'),
            );
          }
        } else if (request.status == 404) {
          completer.completeError(
            PageNotFoundException('Page $pageNumber not found'),
          );
        } else {
          completer.completeError(
            PdfApiException(
              'Failed to load page',
              statusCode: request.status,
            ),
          );
        }
      });

      request.onError.listen((error) {
        completer.completeError(
          PdfApiException('Network error: $error'),
        );
      });

      request.onTimeout.listen((_) {
        completer.completeError(
          PdfApiException('Request timeout'),
        );
      });

      request.send();

      return completer.future.timeout(timeout);
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching page: $e');
    }
  }

  /// HTTP implementation for non-web platforms
  Future<Uint8List> _getPageAsPdfHttp(String documentId, int pageNumber) async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/pdf/$documentId/page/$pageNumber'))
          .timeout(timeout);

      if (response.statusCode == 200) {
        if (!_isPdfContent(response.bodyBytes)) {
          throw PdfApiException('Response is not a valid PDF');
        }
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
    }
  }

  /// Fetches a range of pages as a single PDF (browser cached)
  Future<Uint8List> getPageRange(
      String documentId,
      int start,
      int end,
      ) async {
    if (start < 1 || end < start) {
      throw ArgumentError('Invalid page range: start=$start, end=$end');
    }

    try {
      if (kIsWeb) {
        return await _getPageRangeWeb(documentId, start, end);
      } else {
        return await _getPageRangeHttp(documentId, start, end);
      }
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching page range: $e');
    }
  }

  /// Web implementation for page range using XMLHttpRequest
  Future<Uint8List> _getPageRangeWeb(
      String documentId,
      int start,
      int end,
      ) async {
    final url = '$baseUrl/pdf/$documentId/pages?start=$start&end=$end';
    final completer = Completer<Uint8List>();

    try {
      final request = html.HttpRequest();
      request.open('GET', url);
      request.responseType = 'arraybuffer';

      request.onLoad.listen((_) {
        if (request.status == 200 || request.status == 304) {
          try {
            final buffer = request.response as ByteBuffer;
            final bytes = buffer.asUint8List();

            if (!_isPdfContent(bytes)) {
              completer.completeError(
                PdfApiException('Response is not a valid PDF'),
              );
              return;
            }

            completer.complete(bytes);
          } catch (e) {
            completer.completeError(
              PdfApiException('Failed to process response: $e'),
            );
          }
        } else if (request.status == 404) {
          completer.completeError(
            DocumentNotFoundException('Document not found: $documentId'),
          );
        } else {
          completer.completeError(
            PdfApiException(
              'Failed to load page range',
              statusCode: request.status,
            ),
          );
        }
      });

      request.onError.listen((error) {
        completer.completeError(
          PdfApiException('Network error: $error'),
        );
      });

      request.send();

      return completer.future.timeout(timeout);
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching page range: $e');
    }
  }

  /// HTTP implementation for page range
  Future<Uint8List> _getPageRangeHttp(
      String documentId,
      int start,
      int end,
      ) async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/pdf/$documentId/pages?start=$start&end=$end'))
          .timeout(timeout);

      if (response.statusCode == 200) {
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
    }
  }

  /// Fetches a single page as image bytes (PNG/JPEG)
  Future<Uint8List> getPageAsImage(String documentId, int pageNumber) async {
    if (pageNumber < 1) {
      throw ArgumentError('Page number must be greater than 0');
    }

    final url = '$baseUrl/pdf/$documentId/page/$pageNumber?format=image';

    try {
      if (kIsWeb) {
        return await _getImageWeb(url, pageNumber);
      } else {
        return await _getImageHttp(url, pageNumber);
      }
    } catch (e) {
      if (e is PdfApiException) rethrow;
      throw PdfApiException('Error fetching page image: $e');
    }
  }

  Future<Uint8List> _getImageWeb(String url, int pageNumber) async {
    final completer = Completer<Uint8List>();

    final request = html.HttpRequest();
    request.open('GET', url);
    request.responseType = 'arraybuffer';

    request.onLoad.listen((_) {
      if (request.status == 200) {
        final buffer = request.response as ByteBuffer;
        completer.complete(buffer.asUint8List());
      } else if (request.status == 404) {
        completer.completeError(
          PageNotFoundException('Page $pageNumber not found'),
        );
      } else {
        completer.completeError(
          PdfApiException(
            'Failed to load page image',
            statusCode: request.status,
          ),
        );
      }
    });

    request.onError.listen((error) {
      completer.completeError(PdfApiException('Network error: $error'));
    });

    request.send();

    return completer.future.timeout(timeout);
  }

  Future<Uint8List> _getImageHttp(String url, int pageNumber) async {
    final response = await _client.get(Uri.parse(url)).timeout(timeout);

    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else if (response.statusCode == 404) {
      throw PageNotFoundException('Page $pageNumber not found');
    } else {
      throw PdfApiException(
        'Failed to load page image',
        statusCode: response.statusCode,
      );
    }
  }

  /// Gets URL for page range
  String getPageRangeUrl(String documentId, int start, int end) {
    return '$baseUrl/pdf/$documentId/pages?start=$start&end=$end';
  }

  /// Gets URL for single page as PDF
  String getPageAsPdfUrl(String documentId, int pageNumber) {
    return '$baseUrl/pdf/$documentId/page/$pageNumber';
  }

  /// Gets URL for a specific page
  String getPageUrl(String documentId, int pageNumber) {
    return '$baseUrl/pdf/$documentId/page/$pageNumber';
  }

  /// Creates a blob URL from PDF bytes (Web only)
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

  /// Fetches page range optimized for viewer
  Future<dynamic> getPageRangeForViewer(
      String documentId,
      int start,
      int end,
      ) async {
    if (kIsWeb) {
      return getPageRangeUrl(documentId, start, end);
    } else {
      return await getPageRange(documentId, start, end);
    }
  }

  /// Validates if bytes start with PDF magic number
  bool _isPdfContent(Uint8List bytes) {
    if (bytes.length < 4) return false;
    return bytes[0] == 0x25 && // %
        bytes[1] == 0x50 && // P
        bytes[2] == 0x44 && // D
        bytes[3] == 0x46; // F
  }

  /// Cleans up blob URLs
  void revokeBlobUrls() {
    if (!kIsWeb) return;

    for (final url in _blobUrls) {
      html.Url.revokeObjectUrl(url);
    }
    _blobUrls.clear();
  }

  /// Disposes resources
  void dispose() {
    revokeBlobUrls();
    if (client == null) {
      _client.close();
    }
  }
}

// Custom exceptions
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