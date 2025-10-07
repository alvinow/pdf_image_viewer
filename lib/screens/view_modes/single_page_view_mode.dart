// lib/pdf_viewer/view_modes/single_page_view_mode.dart

class SinglePageViewMode extends PdfViewMode {
  late PageController _pageController;
  int _currentPageIndex = 0;

  // For scrollbar seeking
  bool _isScrollbarDragging = false;
  int? _seekTargetPage;

  SinglePageViewMode({required super.controller});

  @override
  Future<void> onActivated() async {
    _currentPageIndex = controller.currentPage - 1;
    _pageController = PageController(initialPage: _currentPageIndex);
    _pageController.addListener(_onPageControllerChanged);
  }

  @override
  Widget buildLayout(BuildContext context) {
    final totalPages = controller.totalPages;

    return Stack(
      children: [
        // Main PageView
        Column(
          children: [
            Expanded(
              child: Scrollbar(
                controller: _pageController,
                thumbVisibility: true,
                trackVisibility: true,
                interactive: true,
                thickness: 12,
                radius: Radius.circular(6),
                child: NotificationListener<ScrollNotification>(
                  onNotification: _onScrollNotification,
                  child: PageView.builder(
                    controller: _pageController,
                    scrollDirection: Axis.vertical,
                    itemCount: totalPages,
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, index) {
                      return _buildPageItem(index + 1);
                    },
                  ),
                ),
              ),
            ),

            // Navigation bar at bottom
            _buildNavigationBar(context),
          ],
        ),

        // Page number overlay during scrollbar drag
        if (_isScrollbarDragging && _seekTargetPage != null)
          _buildSeekOverlay(_seekTargetPage!),
      ],
    );
  }

  Widget _buildPageItem(int pageNumber) {
    // Get canvas for this page
    final canvasId = controller.canvasManager.getCanvasForPage(pageNumber);

    return Container(
      color: Color(0xFF525659), // Match PDF background
      child: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: 1200,
            maxHeight: double.infinity,
          ),
          child: canvasId != null
              ? controller.canvasManager.getCanvasWidget(canvasId)
              : _buildLoadingPlaceholder(pageNumber),
        ),
      ),
    );
  }

  Widget _buildLoadingPlaceholder(int pageNumber) {
    // Calculate page dimensions
    final pageInfo = controller.documentInfo?.pages
        ?.firstWhere((p) => p.pageNumber == pageNumber);

    final width = pageInfo?.dimensions.width ?? 600.0;
    final height = pageInfo?.dimensions.height ?? 800.0;

    return Container(
      width: width * controller.zoomLevel,
      height: height * controller.zoomLevel,
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading page $pageNumber...',
                style: TextStyle(fontSize: 14, color: Colors.grey[600])),
          ],
        ),
      ),
    );
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification) {
      // Check if it's from scrollbar drag
      setState(() {
        _isScrollbarDragging = true;
      });
    } else if (notification is ScrollUpdateNotification) {
      // Update seek target page based on scroll position
      if (_isScrollbarDragging) {
        final progress = _pageController.page ?? _currentPageIndex.toDouble();
        final targetPage = (progress.round() + 1).clamp(1, controller.totalPages);

        if (_seekTargetPage != targetPage) {
          setState(() {
            _seekTargetPage = targetPage;
          });
        }
      }
    } else if (notification is ScrollEndNotification) {
      setState(() {
        _isScrollbarDragging = false;
        _seekTargetPage = null;
      });
    }

    return false;
  }

  Widget _buildSeekOverlay(int pageNumber) {
    return Positioned(
      top: MediaQuery.of(context).size.height * 0.4,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Page $pageNumber',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'of ${controller.totalPages}',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationBar(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 4,
            offset: Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: Icon(Icons.first_page),
            onPressed: currentPage > 1
                ? () => navigateToPage(1)
                : null,
          ),
          IconButton(
            icon: Icon(Icons.chevron_left),
            onPressed: currentPage > 1
                ? () => navigateToPage(currentPage - 1)
                : null,
          ),
          SizedBox(width: 8),

          // Page input
          SizedBox(
            width: 60,
            child: TextField(
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                    horizontal: 4, vertical: 8),
                isDense: true,
              ),
              controller: TextEditingController(text: '$currentPage'),
              onSubmitted: (value) {
                final page = int.tryParse(value);
                if (page != null && page >= 1 &&
                    page <= controller.totalPages) {
                  navigateToPage(page);
                }
              },
            ),
          ),

          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('/ ${controller.totalPages}',
                style: TextStyle(fontSize: 16)),
          ),

          SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.chevron_right),
            onPressed: currentPage < controller.totalPages
                ? () => navigateToPage(currentPage + 1)
                : null,
          ),
          IconButton(
            icon: Icon(Icons.last_page),
            onPressed: currentPage < controller.totalPages
                ? () => navigateToPage(controller.totalPages)
                : null,
          ),
        ],
      ),
    );
  }

  void _onPageControllerChanged() {
    if (!_pageController.hasClients) return;

    final page = _pageController.page?.round();
    if (page != null && page != _currentPageIndex) {
      _currentPageIndex = page;
      // Don't update here, let onPageChanged handle it
    }
  }

  void _onPageChanged(int index) {
    _currentPageIndex = index;
    controller.updateCurrentPage(index + 1);
  }

  @override
  List<int> getVisiblePages() {
    return [currentPage];
  }

  @override
  List<int> getPrefetchPages() {
    final pages = <int>[];

    // Prefetch previous and next
    if (currentPage > 1) {
      pages.add(currentPage - 1);
    }
    if (currentPage < controller.totalPages) {
      pages.add(currentPage + 1);
    }

    return pages;
  }

  @override
  Future<void> navigateToPage(int page, {bool animate = true}) async {
    if (page < 1 || page > controller.totalPages) return;

    final targetIndex = page - 1;

    if (animate) {
      await _pageController.animateToPage(
        targetIndex,
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _pageController.jumpToPage(targetIndex);
    }
  }

  @override
  int get currentPage => _currentPageIndex + 1;

  @override
  void onZoomChanged(double zoom) {
    // Trigger re-render of visible pages
    controller.requestRender(getVisiblePages());
  }

  @override
  void onRotationChanged(int degrees) {
    // Trigger re-render of visible pages
    controller.requestRender(getVisiblePages());
  }

  @override
  Future<void> onDeactivated() async {
    _pageController.removeListener(_onPageControllerChanged);
  }

  @override
  void dispose() {
    _pageController.dispose();
  }
}