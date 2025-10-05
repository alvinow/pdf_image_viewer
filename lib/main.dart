// lib/main.dart
import 'package:flutter/material.dart';
import 'package:pdf_image_viewer/appconfig.dart';
import 'package:pdf_image_viewer/screens/pdfviewerwebscreen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF Viewer Web',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const DocumentListScreen(),
    );
  }
}

class DocumentListScreen extends StatefulWidget {
  const DocumentListScreen({Key? key}) : super(key: key);

  @override
  State<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends State<DocumentListScreen> {
  final TextEditingController _urlController = TextEditingController(
    text: AppConfig.baseUrl,
  );
  final TextEditingController _docIdController = TextEditingController();

  final List<Map<String, String>> _recentDocuments = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.picture_as_pdf),
            SizedBox(width: 8),
            Text('PDF Viewer'),
          ],
        ),
        elevation: 2,
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 800),
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Open PDF Document',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _urlController,
                        decoration: const InputDecoration(
                          labelText: 'API Base URL',
                          hintText: AppConfig.baseUrl,
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.link),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _docIdController,
                        decoration: const InputDecoration(
                          labelText: 'Document ID',
                          hintText: 'my-document',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.description),
                        ),
                        onSubmitted: (_) => _openDocument(),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _openDocument,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Open Document'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.all(16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (_recentDocuments.isNotEmpty) ...[
                Text(
                  'Recent Documents',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView.builder(
                    itemCount: _recentDocuments.length,
                    itemBuilder: (context, index) {
                      final doc = _recentDocuments[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: const Icon(Icons.picture_as_pdf,
                            size: 40,
                            color: Colors.red,
                          ),
                          title: Text(doc['id']!),
                          subtitle: Text(doc['url']!),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openDocumentById(doc['id']!, doc['url']!),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _openDocument() {
    final url = _urlController.text.trim();
    final docId = _docIdController.text.trim();

    if (docId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a document ID')),
      );
      return;
    }

    _addToRecent(docId, url);
    _openDocumentById(docId, url);
  }

  void _openDocumentById(String docId, String url) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PdfViewerWebScreen(
          documentId: docId,
          apiBaseUrl: url,
          title: "<untitled>",
          config: PdfViewerConfig(
            enableDebugLogging: true,  // Shows cleanup logs in console
            maxConcurrentLoads: 2,
            enablePerformanceMonitoring: true,
            enableAutoRetry: true,
          ),
        ),
      ),
    ).then((_) {
      // Called when returning from PDF viewer
      print('📱 Returned from PDF viewer - memory should be cleaned up');
      print('💡 Check browser DevTools Console for cleanup logs');
      print('💡 Check browser DevTools Memory tab to verify memory release');
    });
  }

  void _addToRecent(String id, String url) {
    setState(() {
      _recentDocuments.removeWhere((doc) => doc['id'] == id);
      _recentDocuments.insert(0, {'id': id, 'url': url});
      if (_recentDocuments.length > 10) {
        _recentDocuments.removeLast();
      }
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _docIdController.dispose();
    super.dispose();
  }
}