import 'package:flutter/material.dart';
import 'dart:developer' as developer;

/// A QuickTime-style page scrubber with integrated navigation controls
class PageScrubber extends StatefulWidget {
  final int currentPage;
  final int totalPages;
  final Set<int> cachedPages;
  final Function(int) onPageChanged;
  final Function(int)? onPageSelected;
  final VoidCallback? onFirstPage;
  final VoidCallback? onPreviousPage;
  final VoidCallback? onNextPage;
  final VoidCallback? onLastPage;
  final VoidCallback? onPageSelectorTap;

  const PageScrubber({
    Key? key,
    required this.currentPage,
    required this.totalPages,
    required this.cachedPages,
    required this.onPageChanged,
    this.onPageSelected,
    this.onFirstPage,
    this.onPreviousPage,
    this.onNextPage,
    this.onLastPage,
    this.onPageSelectorTap,
  }) : super(key: key);

  @override
  State<PageScrubber> createState() => _PageScrubberState();
}

class _PageScrubberState extends State<PageScrubber> {
  bool _isDragging = false;
  int? _previewPage;

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 768;

    // More compact layout - removed page indicator from bottom
    final containerHeight = isMobile && isLandscape ? 48.0 : 60.0;
    final horizontalPadding = isMobile ? 8.0 : 16.0;

    return Container(
      height: containerHeight,
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: isMobile ? 6.0 : 8.0,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          // First page button
          _buildNavButton(
            icon: Icons.first_page,
            onPressed: widget.currentPage > 1 ? widget.onFirstPage : null,
            tooltip: 'First Page',
            isMobile: isMobile,
          ),

          // Previous page button
          _buildNavButton(
            icon: Icons.chevron_left,
            onPressed: widget.currentPage > 1 ? widget.onPreviousPage : null,
            tooltip: 'Previous Page',
            isMobile: isMobile,
          ),

          // Scrubber track (expandable) - with preview on drag only
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  clipBehavior: Clip.none, // Allow preview to overflow
                  children: [
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragStart: (details) {
                          setState(() => _isDragging = true);
                          _updatePageFromPosition(details.localPosition.dx, constraints.maxWidth);
                        },
                        onHorizontalDragUpdate: (details) {
                          if (!_isDragging) return;
                          _updatePageFromPosition(details.localPosition.dx, constraints.maxWidth);
                        },
                        onHorizontalDragEnd: (details) {
                          if (_previewPage != null && _previewPage != widget.currentPage) {
                            widget.onPageSelected?.call(_previewPage!);
                          }
                          if (mounted) {
                            setState(() {
                              _isDragging = false;
                              _previewPage = null;
                            });
                          }
                        },
                        onHorizontalDragCancel: () {
                          if (mounted) {
                            setState(() {
                              _isDragging = false;
                              _previewPage = null;
                            });
                          }
                        },
                        onTapUp: (details) {
                          _updatePageFromPosition(details.localPosition.dx, constraints.maxWidth);
                          if (_previewPage != null && _previewPage != widget.currentPage) {
                            widget.onPageSelected?.call(_previewPage!);
                          }
                          if (mounted) {
                            setState(() {
                              _previewPage = null;
                              _isDragging = false;
                            });
                          }
                        },
                        child: Stack(
                          children: [
                            // Background track
                            Positioned.fill(
                              child: Center(
                                child: _buildTrack(constraints, isMobile),
                              ),
                            ),

                            // Thumb indicator
                            _buildThumb(constraints, isMobile),
                          ],
                        ),
                      ),
                    ),

                    // Preview indicator when dragging (outside GestureDetector)
                    if (_isDragging && _previewPage != null)
                      _buildDragPreview(constraints, isMobile),
                  ],
                );
              },
            ),
          ),

          // Next page button
          _buildNavButton(
            icon: Icons.chevron_right,
            onPressed: widget.currentPage < widget.totalPages ? widget.onNextPage : null,
            tooltip: 'Next Page',
            isMobile: isMobile,
          ),

          // Last page button
          _buildNavButton(
            icon: Icons.last_page,
            onPressed: widget.currentPage < widget.totalPages ? widget.onLastPage : null,
            tooltip: 'Last Page',
            isMobile: isMobile,
          ),
        ],
      ),
    );
  }

  Widget _buildNavButton({
    required IconData icon,
    required VoidCallback? onPressed,
    required String tooltip,
    required bool isMobile,
  }) {
    return IconButton(
      icon: Icon(icon, size: isMobile ? 20 : 24),
      onPressed: onPressed,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints(
        minWidth: isMobile ? 36 : 44,
        minHeight: isMobile ? 36 : 44,
      ),
    );
  }

  Widget _buildCurrentPageIndicator(bool isMobile) {
    return InkWell(
      onTap: widget.onPageSelectorTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 10 : 12,
          vertical: isMobile ? 4 : 6,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.7),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description,
              size: isMobile ? 14 : 16,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
            SizedBox(width: isMobile ? 4 : 6),
            Text(
              '${widget.currentPage} / ${widget.totalPages}',
              style: TextStyle(
                fontSize: isMobile ? 12 : 14,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDragPreview(BoxConstraints constraints, bool isMobile) {
    if (_previewPage == null) return const SizedBox.shrink();

    final progress = widget.totalPages > 1
        ? ((_previewPage! - 1) / (widget.totalPages - 1)).clamp(0.0, 1.0)
        : 0.0;

    final thumbSize = 24.0;
    final maxPosition = constraints.maxWidth - thumbSize;
    final thumbPosition = (progress * maxPosition).clamp(0.0, maxPosition);

    // Calculate preview box width to prevent overflow
    final previewWidth = isMobile ? 70.0 : 80.0;
    final previewOffset = (thumbPosition + thumbSize / 2 - previewWidth / 2)
        .clamp(0.0, constraints.maxWidth - previewWidth);

    return Positioned(
      left: previewOffset,
      bottom: isMobile ? 42.0 : 50.0, // Position above the scrubber
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: 1.0,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 10 : 12,
              vertical: isMobile ? 6 : 8,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      widget.cachedPages.contains(_previewPage)
                          ? Icons.description
                          : Icons.insert_drive_file_outlined,
                      size: isMobile ? 16 : 18,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                    SizedBox(width: isMobile ? 4 : 6),
                    Text(
                      'Hal $_previewPage',
                      style: TextStyle(
                        fontSize: isMobile ? 13 : 15,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 2),
                Text(
                  'dari ${widget.totalPages}',
                  style: TextStyle(
                    fontSize: isMobile ? 10 : 11,
                    color: Theme.of(context).colorScheme.onPrimaryContainer.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrack(BoxConstraints constraints, bool isMobile) {
    return Container(
      height: isMobile ? 6 : 8,
      margin: EdgeInsets.symmetric(vertical: isMobile ? 4 : 8),
      child: CustomPaint(
        size: Size(constraints.maxWidth, isMobile ? 6 : 8),
        painter: _ScrubberTrackPainter(
          currentPage: widget.currentPage,
          totalPages: widget.totalPages,
          cachedPages: widget.cachedPages,
          primaryColor: Theme.of(context).colorScheme.primary,
          cachedColor: Theme.of(context).colorScheme.primaryContainer,
          backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
          isMobile: isMobile,
        ),
      ),
    );
  }

  Widget _buildThumb(BoxConstraints constraints, bool isMobile) {
    try {
      if (widget.totalPages <= 0) {
        return const SizedBox.shrink();
      }

      final displayPage = (_isDragging && _previewPage != null)
          ? _previewPage!
          : widget.currentPage;

      final progress = widget.totalPages > 1
          ? ((displayPage - 1) / (widget.totalPages - 1)).clamp(0.0, 1.0)
          : 0.0;

      final thumbSize = _isDragging
          ? (isMobile ? 24.0 : 28.0)
          : (isMobile ? 20.0 : 24.0);
      final maxPosition = constraints.maxWidth - thumbSize;
      final thumbPosition = (progress * maxPosition).clamp(0.0, maxPosition);

      return Positioned(
        left: thumbPosition,
        top: 0,
        bottom: 0,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: thumbSize,
            height: thumbSize,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.4),
                  blurRadius: _isDragging ? (isMobile ? 8 : 12) : (isMobile ? 6 : 8),
                  spreadRadius: _isDragging ? (isMobile ? 1 : 2) : 1,
                ),
              ],
            ),
            child: Icon(
              Icons.drag_indicator,
              size: isMobile ? 14 : 16,
              color: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
        ),
      );
    } catch (e, stack) {
      developer.log('Error in _buildThumb: $e\n$stack');
      return const SizedBox.shrink();
    }
  }

  void _updatePageFromPosition(double dx, double trackWidth) {
    try {
      if (trackWidth <= 0 || widget.totalPages <= 0) {
        return;
      }

      final clampedDx = dx.clamp(0.0, trackWidth);
      final progress = (clampedDx / trackWidth).clamp(0.0, 1.0);

      final page = widget.totalPages > 1
          ? ((progress * (widget.totalPages - 1)) + 1).round().clamp(1, widget.totalPages)
          : 1;

      if (_previewPage != page) {
        if (mounted) {
          setState(() => _previewPage = page);
        }

        try {
          widget.onPageChanged(page);
        } catch (e, stack) {
          developer.log('Error in onPageChanged callback: $e\n$stack');
        }
      }
    } catch (e, stack) {
      developer.log('Error in _updatePageFromPosition: $e\n$stack');
    }
  }
}

class _ScrubberTrackPainter extends CustomPainter {
  final int currentPage;
  final int totalPages;
  final Set<int> cachedPages;
  final Color primaryColor;
  final Color cachedColor;
  final Color backgroundColor;
  final bool isMobile;

  _ScrubberTrackPainter({
    required this.currentPage,
    required this.totalPages,
    required this.cachedPages,
    required this.primaryColor,
    required this.cachedColor,
    required this.backgroundColor,
    this.isMobile = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    try {
      if (size.width <= 0 || size.height <= 0) return;

      final paint = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = isMobile ? 6 : 8;

      // Draw background track
      paint.color = backgroundColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height),
          Radius.circular(isMobile ? 3 : 4),
        ),
        paint,
      );

      // Draw cached pages indicators
      if (totalPages > 1) {
        final segmentWidth = size.width / totalPages;

        for (int page in cachedPages) {
          if (page >= 1 && page <= totalPages) {
            final x = ((page - 1) * segmentWidth).clamp(0.0, size.width);
            paint.color = cachedColor.withOpacity(0.6);
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(x, 0, segmentWidth.clamp(0.0, size.width - x), size.height),
                Radius.circular(isMobile ? 3 : 4),
              ),
              paint,
            );
          }
        }
      }

      // Draw progress (viewed pages) up to current page
      if (totalPages > 1 && currentPage >= 1 && currentPage <= totalPages) {
        final progress = ((currentPage - 1) / (totalPages - 1)).clamp(0.0, 1.0);
        final progressWidth = (size.width * progress).clamp(0.0, size.width);
        paint.color = primaryColor;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, progressWidth, size.height),
            Radius.circular(isMobile ? 3 : 4),
          ),
          paint,
        );
      }

      // Draw current page indicator (highlighted segment)
      if (totalPages > 1 && currentPage >= 1 && currentPage <= totalPages) {
        final segmentWidth = size.width / totalPages;
        final x = ((currentPage - 1) * segmentWidth).clamp(0.0, size.width);

        // Draw glowing effect for current page
        if (!isMobile || segmentWidth > 10) {
          paint.color = primaryColor.withOpacity(0.3);
          paint.strokeWidth = isMobile ? 10 : 12;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x, -2, segmentWidth.clamp(0.0, size.width - x), size.height + 4),
              Radius.circular(isMobile ? 5 : 6),
            ),
            paint,
          );
        }

        // Draw solid current page segment
        paint.color = primaryColor;
        paint.strokeWidth = isMobile ? 6 : 8;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, 0, segmentWidth.clamp(0.0, size.width - x), size.height),
            Radius.circular(isMobile ? 3 : 4),
          ),
          paint,
        );
      }

      // Draw page markers for small documents
      final showMarkers = isMobile ? totalPages <= 20 : totalPages <= 50;
      if (totalPages > 1 && showMarkers) {
        final markerPaint = Paint()
          ..color = backgroundColor.withOpacity(0.5)
          ..strokeWidth = 1;

        for (int i = 0; i < totalPages; i++) {
          final x = ((i / (totalPages - 1)) * size.width).clamp(0.0, size.width);
          canvas.drawLine(
            Offset(x, 0),
            Offset(x, size.height),
            markerPaint,
          );
        }
      }
    } catch (e) {
      developer.log('Error in _ScrubberTrackPainter.paint: $e');
    }
  }

  @override
  bool shouldRepaint(_ScrubberTrackPainter oldDelegate) {
    return oldDelegate.currentPage != currentPage ||
        oldDelegate.totalPages != totalPages ||
        oldDelegate.cachedPages != cachedPages ||
        oldDelegate.isMobile != isMobile;
  }
}