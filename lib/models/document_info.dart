import 'package:json_annotation/json_annotation.dart';

part 'document_info.g.dart';

@JsonSerializable()
class PageDimensions {
  final double width;
  final double height;
  final String unit; // 'pt', 'mm', 'in'

  PageDimensions({
    required this.width,
    required this.height,
    required this.unit,
  });

  factory PageDimensions.fromJson(Map<String, dynamic> json) =>
      _$PageDimensionsFromJson(json);
  Map<String, dynamic> toJson() => _$PageDimensionsToJson(this);

  String get formatted {
    return '${width.toStringAsFixed(2)} x ${height.toStringAsFixed(2)} $unit';
  }

  // Convert to other units
  PageDimensions toMillimeters() {
    if (unit == 'mm') return this;
    const ptToMm = 0.352778;
    const inToMm = 25.4;

    double w = width;
    double h = height;

    if (unit == 'pt') {
      w = width * ptToMm;
      h = height * ptToMm;
    } else if (unit == 'in') {
      w = width * inToMm;
      h = height * inToMm;
    }

    return PageDimensions(width: w, height: h, unit: 'mm');
  }

  PageDimensions toInches() {
    if (unit == 'in') return this;
    const ptToIn = 1 / 72;
    const mmToIn = 1 / 25.4;

    double w = width;
    double h = height;

    if (unit == 'pt') {
      w = width * ptToIn;
      h = height * ptToIn;
    } else if (unit == 'mm') {
      w = width * mmToIn;
      h = height * mmToIn;
    }

    return PageDimensions(width: w, height: h, unit: 'in');
  }
}

@JsonSerializable()
class PageBox {
  final double x;
  final double y;
  final double width;
  final double height;

  PageBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory PageBox.fromJson(Map<String, dynamic> json) =>
      _$PageBoxFromJson(json);
  Map<String, dynamic> toJson() => _$PageBoxToJson(this);
}

@JsonSerializable()
class PageBoxes {
  final PageBox mediaBox;
  final PageBox? cropBox;
  final PageBox? bleedBox;
  final PageBox? trimBox;
  final PageBox? artBox;

  PageBoxes({
    required this.mediaBox,
    this.cropBox,
    this.bleedBox,
    this.trimBox,
    this.artBox,
  });

  factory PageBoxes.fromJson(Map<String, dynamic> json) =>
      _$PageBoxesFromJson(json);
  Map<String, dynamic> toJson() => _$PageBoxesToJson(this);
}

@JsonSerializable()
class PageResources {
  final List<String>? fonts;
  final int? images;
  final int? annotations;
  final int? forms;

  PageResources({
    this.fonts,
    this.images,
    this.annotations,
    this.forms,
  });

  factory PageResources.fromJson(Map<String, dynamic> json) =>
      _$PageResourcesFromJson(json);
  Map<String, dynamic> toJson() => _$PageResourcesToJson(this);
}

@JsonSerializable()
class PageContent {
  final bool hasText;
  final bool hasImages;
  final bool hasVectorGraphics;
  final bool hasForms;
  final bool hasAnnotations;
  final bool hasTransparency;
  final int? textLength;

  PageContent({
    required this.hasText,
    required this.hasImages,
    required this.hasVectorGraphics,
    required this.hasForms,
    required this.hasAnnotations,
    required this.hasTransparency,
    this.textLength,
  });

  factory PageContent.fromJson(Map<String, dynamic> json) =>
      _$PageContentFromJson(json);
  Map<String, dynamic> toJson() => _$PageContentToJson(this);
}

@JsonSerializable()
class PageTransition {
  final String? style;
  final double? duration;
  final String? direction;

  PageTransition({
    this.style,
    this.duration,
    this.direction,
  });

  factory PageTransition.fromJson(Map<String, dynamic> json) =>
      _$PageTransitionFromJson(json);
  Map<String, dynamic> toJson() => _$PageTransitionToJson(this);
}

@JsonSerializable()
class PageMetadata {
  final String? label;
  final double? duration;
  final PageTransition? transition;
  final bool thumbnailExists;
  final bool isBlank;

  PageMetadata({
    this.label,
    this.duration,
    this.transition,
    required this.thumbnailExists,
    required this.isBlank,
  });

  factory PageMetadata.fromJson(Map<String, dynamic> json) =>
      _$PageMetadataFromJson(json);
  Map<String, dynamic> toJson() => _$PageMetadataToJson(this);
}

@JsonSerializable()
class PageColors {
  final String? colorSpace;
  final bool hasColor;
  final bool isGrayscale;

  PageColors({
    this.colorSpace,
    required this.hasColor,
    required this.isGrayscale,
  });

  factory PageColors.fromJson(Map<String, dynamic> json) =>
      _$PageColorsFromJson(json);
  Map<String, dynamic> toJson() => _$PageColorsToJson(this);
}

@JsonSerializable()
class PageDpi {
  final double x;
  final double y;

  PageDpi({required this.x, required this.y});

  factory PageDpi.fromJson(Map<String, dynamic> json) =>
      _$PageDpiFromJson(json);
  Map<String, dynamic> toJson() => _$PageDpiToJson(this);
}

@JsonSerializable()
class PageInfo {
  final int pageNumber;
  final PageDimensions dimensions;
  final String orientation; // 'portrait', 'landscape', 'square'
  final int rotation;
  final PageBoxes boxes;
  final PageContent content;
  final PageResources resources;
  final PageMetadata metadata;
  final PageColors colors;
  final double? userUnit;
  final PageDpi? dpi;
  final int? fileSize;
  final bool hasStructure;
  final bool hasAlternativeText;
  final bool? isProtected;
  final String? complexity; // 'simple', 'moderate', 'complex'
  final double? estimatedRenderTime;

  PageInfo({
    required this.pageNumber,
    required this.dimensions,
    required this.orientation,
    required this.rotation,
    required this.boxes,
    required this.content,
    required this.resources,
    required this.metadata,
    required this.colors,
    this.userUnit,
    this.dpi,
    this.fileSize,
    required this.hasStructure,
    required this.hasAlternativeText,
    this.isProtected,
    this.complexity,
    this.estimatedRenderTime,
  });

  factory PageInfo.fromJson(Map<String, dynamic> json) =>
      _$PageInfoFromJson(json);
  Map<String, dynamic> toJson() => _$PageInfoToJson(this);

  bool get isPortrait => orientation == 'portrait';
  bool get isLandscape => orientation == 'landscape';
  bool get isSquare => orientation == 'square';
  bool get isRotated => rotation != 0;
  bool get isEmpty => metadata.isBlank;
}

@JsonSerializable()
class DocumentInfo {
  final String documentId;
  final int totalPages;

  // Basic metadata
  final String? title;
  final String? author;
  final String? subject;
  final List<String>? keywords;
  final String? creator;
  final String? producer;
  final DateTime? creationDate;
  final DateTime? modificationDate;

  // File information
  final int fileSize;

  // PDF properties
  final String? pdfVersion;
  final String? pdfStandard;
  final bool isEncrypted;
  final bool isLinearized;
  final bool hasJavaScript;
  final bool hasEmbeddedFiles;
  final bool hasDigitalSignatures;

  // Page information
  final List<PageInfo>? pages;
  final PageDimensions? commonDimensions;
  final bool hasVariablePageSizes;
  final bool hasVariableOrientations;

  // Document statistics
  final int? totalImages;
  final int? totalFonts;
  final int? totalAnnotations;
  final int? totalFormFields;

  // Accessibility
  final bool isTagged;
  final bool hasOutline;
  final String? language;

  DocumentInfo({
    required this.documentId,
    required this.totalPages,
    this.title,
    this.author,
    this.subject,
    this.keywords,
    this.creator,
    this.producer,
    this.creationDate,
    this.modificationDate,
    required this.fileSize,
    this.pdfVersion,
    this.pdfStandard,
    required this.isEncrypted,
    required this.isLinearized,
    required this.hasJavaScript,
    required this.hasEmbeddedFiles,
    required this.hasDigitalSignatures,
    this.pages,
    this.commonDimensions,
    required this.hasVariablePageSizes,
    required this.hasVariableOrientations,
    this.totalImages,
    this.totalFonts,
    this.totalAnnotations,
    this.totalFormFields,
    required this.isTagged,
    required this.hasOutline,
    this.language,
  });

  factory DocumentInfo.fromJson(Map<String, dynamic> json) =>
      _$DocumentInfoFromJson(json);
  Map<String, dynamic> toJson() => _$DocumentInfoToJson(this);

  // Computed properties
  String get formattedFileSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String get pdfVersionDisplay => pdfVersion ?? 'Unknown';

  bool get hasMetadata =>
      title != null ||
          author != null ||
          subject != null ||
          keywords != null;

  bool get hasAdvancedFeatures =>
      hasJavaScript ||
          hasEmbeddedFiles ||
          hasDigitalSignatures ||
          isEncrypted;

  int get blankPageCount =>
      pages?.where((p) => p.metadata.isBlank).length ?? 0;

  int get colorPageCount =>
      pages?.where((p) => p.colors.hasColor).length ?? 0;

  int get grayscalePageCount =>
      pages?.where((p) => p.colors.isGrayscale).length ?? 0;

  int get portraitPageCount =>
      pages?.where((p) => p.isPortrait).length ?? 0;

  int get landscapePageCount =>
      pages?.where((p) => p.isLandscape).length ?? 0;

  String get orientationSummary {
    if (!hasVariableOrientations) {
      return pages?.first.orientation ?? 'unknown';
    }
    return 'Mixed ($portraitPageCount portrait, $landscapePageCount landscape)';
  }

  String get pageSizeSummary {
    if (commonDimensions != null) {
      return commonDimensions!.formatted;
    }
    if (hasVariablePageSizes) {
      return 'Variable sizes';
    }
    return 'Unknown';
  }

  // Get page by number
  PageInfo? getPage(int pageNumber) {
    if (pages == null || pageNumber < 1 || pageNumber > totalPages) {
      return null;
    }
    return pages!.firstWhere(
          (p) => p.pageNumber == pageNumber,
      orElse: () => pages![pageNumber - 1],
    );
  }

  // Get pages by orientation
  List<PageInfo> getPagesByOrientation(String orientation) {
    return pages?.where((p) => p.orientation == orientation).toList() ?? [];
  }

  // Get pages with specific content
  List<PageInfo> getPagesWithImages() {
    return pages?.where((p) => p.content.hasImages).toList() ?? [];
  }

  List<PageInfo> getPagesWithForms() {
    return pages?.where((p) => p.content.hasForms).toList() ?? [];
  }

  List<PageInfo> getPagesWithAnnotations() {
    return pages?.where((p) => p.content.hasAnnotations).toList() ?? [];
  }

  List<PageInfo> getBlankPages() {
    return pages?.where((p) => p.metadata.isBlank).toList() ?? [];
  }
}