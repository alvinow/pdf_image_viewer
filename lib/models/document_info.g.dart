// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'document_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

PageDimensions _$PageDimensionsFromJson(Map<String, dynamic> json) =>
    PageDimensions(
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      unit: json['unit'] as String,
    );

Map<String, dynamic> _$PageDimensionsToJson(PageDimensions instance) =>
    <String, dynamic>{
      'width': instance.width,
      'height': instance.height,
      'unit': instance.unit,
    };

PageBox _$PageBoxFromJson(Map<String, dynamic> json) => PageBox(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
    );

Map<String, dynamic> _$PageBoxToJson(PageBox instance) => <String, dynamic>{
      'x': instance.x,
      'y': instance.y,
      'width': instance.width,
      'height': instance.height,
    };

PageBoxes _$PageBoxesFromJson(Map<String, dynamic> json) => PageBoxes(
      mediaBox: PageBox.fromJson(json['mediaBox'] as Map<String, dynamic>),
      cropBox: json['cropBox'] == null
          ? null
          : PageBox.fromJson(json['cropBox'] as Map<String, dynamic>),
      bleedBox: json['bleedBox'] == null
          ? null
          : PageBox.fromJson(json['bleedBox'] as Map<String, dynamic>),
      trimBox: json['trimBox'] == null
          ? null
          : PageBox.fromJson(json['trimBox'] as Map<String, dynamic>),
      artBox: json['artBox'] == null
          ? null
          : PageBox.fromJson(json['artBox'] as Map<String, dynamic>),
    );

Map<String, dynamic> _$PageBoxesToJson(PageBoxes instance) => <String, dynamic>{
      'mediaBox': instance.mediaBox,
      'cropBox': instance.cropBox,
      'bleedBox': instance.bleedBox,
      'trimBox': instance.trimBox,
      'artBox': instance.artBox,
    };

PageResources _$PageResourcesFromJson(Map<String, dynamic> json) =>
    PageResources(
      fonts:
          (json['fonts'] as List<dynamic>?)?.map((e) => e as String).toList(),
      images: (json['images'] as num?)?.toInt(),
      annotations: (json['annotations'] as num?)?.toInt(),
      forms: (json['forms'] as num?)?.toInt(),
    );

Map<String, dynamic> _$PageResourcesToJson(PageResources instance) =>
    <String, dynamic>{
      'fonts': instance.fonts,
      'images': instance.images,
      'annotations': instance.annotations,
      'forms': instance.forms,
    };

PageContent _$PageContentFromJson(Map<String, dynamic> json) => PageContent(
      hasText: json['hasText'] as bool,
      hasImages: json['hasImages'] as bool,
      hasVectorGraphics: json['hasVectorGraphics'] as bool,
      hasForms: json['hasForms'] as bool,
      hasAnnotations: json['hasAnnotations'] as bool,
      hasTransparency: json['hasTransparency'] as bool,
      textLength: (json['textLength'] as num?)?.toInt(),
    );

Map<String, dynamic> _$PageContentToJson(PageContent instance) =>
    <String, dynamic>{
      'hasText': instance.hasText,
      'hasImages': instance.hasImages,
      'hasVectorGraphics': instance.hasVectorGraphics,
      'hasForms': instance.hasForms,
      'hasAnnotations': instance.hasAnnotations,
      'hasTransparency': instance.hasTransparency,
      'textLength': instance.textLength,
    };

PageTransition _$PageTransitionFromJson(Map<String, dynamic> json) =>
    PageTransition(
      style: json['style'] as String?,
      duration: (json['duration'] as num?)?.toDouble(),
      direction: json['direction'] as String?,
    );

Map<String, dynamic> _$PageTransitionToJson(PageTransition instance) =>
    <String, dynamic>{
      'style': instance.style,
      'duration': instance.duration,
      'direction': instance.direction,
    };

PageMetadata _$PageMetadataFromJson(Map<String, dynamic> json) => PageMetadata(
      label: json['label'] as String?,
      duration: (json['duration'] as num?)?.toDouble(),
      transition: json['transition'] == null
          ? null
          : PageTransition.fromJson(json['transition'] as Map<String, dynamic>),
      thumbnailExists: json['thumbnailExists'] as bool,
      isBlank: json['isBlank'] as bool,
    );

Map<String, dynamic> _$PageMetadataToJson(PageMetadata instance) =>
    <String, dynamic>{
      'label': instance.label,
      'duration': instance.duration,
      'transition': instance.transition,
      'thumbnailExists': instance.thumbnailExists,
      'isBlank': instance.isBlank,
    };

PageColors _$PageColorsFromJson(Map<String, dynamic> json) => PageColors(
      colorSpace: json['colorSpace'] as String?,
      hasColor: json['hasColor'] as bool,
      isGrayscale: json['isGrayscale'] as bool,
    );

Map<String, dynamic> _$PageColorsToJson(PageColors instance) =>
    <String, dynamic>{
      'colorSpace': instance.colorSpace,
      'hasColor': instance.hasColor,
      'isGrayscale': instance.isGrayscale,
    };

PageDpi _$PageDpiFromJson(Map<String, dynamic> json) => PageDpi(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
    );

Map<String, dynamic> _$PageDpiToJson(PageDpi instance) => <String, dynamic>{
      'x': instance.x,
      'y': instance.y,
    };

PageInfo _$PageInfoFromJson(Map<String, dynamic> json) => PageInfo(
      pageNumber: (json['pageNumber'] as num).toInt(),
      dimensions:
          PageDimensions.fromJson(json['dimensions'] as Map<String, dynamic>),
      orientation: json['orientation'] as String,
      rotation: (json['rotation'] as num).toInt(),
      boxes: PageBoxes.fromJson(json['boxes'] as Map<String, dynamic>),
      content: PageContent.fromJson(json['content'] as Map<String, dynamic>),
      resources:
          PageResources.fromJson(json['resources'] as Map<String, dynamic>),
      metadata: PageMetadata.fromJson(json['metadata'] as Map<String, dynamic>),
      colors: PageColors.fromJson(json['colors'] as Map<String, dynamic>),
      userUnit: (json['userUnit'] as num?)?.toDouble(),
      dpi: json['dpi'] == null
          ? null
          : PageDpi.fromJson(json['dpi'] as Map<String, dynamic>),
      fileSize: (json['fileSize'] as num?)?.toInt(),
      hasStructure: json['hasStructure'] as bool,
      hasAlternativeText: json['hasAlternativeText'] as bool,
      isProtected: json['isProtected'] as bool?,
      complexity: json['complexity'] as String?,
      estimatedRenderTime: (json['estimatedRenderTime'] as num?)?.toDouble(),
    );

Map<String, dynamic> _$PageInfoToJson(PageInfo instance) => <String, dynamic>{
      'pageNumber': instance.pageNumber,
      'dimensions': instance.dimensions,
      'orientation': instance.orientation,
      'rotation': instance.rotation,
      'boxes': instance.boxes,
      'content': instance.content,
      'resources': instance.resources,
      'metadata': instance.metadata,
      'colors': instance.colors,
      'userUnit': instance.userUnit,
      'dpi': instance.dpi,
      'fileSize': instance.fileSize,
      'hasStructure': instance.hasStructure,
      'hasAlternativeText': instance.hasAlternativeText,
      'isProtected': instance.isProtected,
      'complexity': instance.complexity,
      'estimatedRenderTime': instance.estimatedRenderTime,
    };

DocumentInfo _$DocumentInfoFromJson(Map<String, dynamic> json) => DocumentInfo(
      documentId: json['documentId'] as String,
      totalPages: (json['totalPages'] as num).toInt(),
      title: json['title'] as String?,
      author: json['author'] as String?,
      subject: json['subject'] as String?,
      keywords: (json['keywords'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      creator: json['creator'] as String?,
      producer: json['producer'] as String?,
      creationDate: json['creationDate'] == null
          ? null
          : DateTime.parse(json['creationDate'] as String),
      modificationDate: json['modificationDate'] == null
          ? null
          : DateTime.parse(json['modificationDate'] as String),
      fileSize: (json['fileSize'] as num).toInt(),
      pdfVersion: json['pdfVersion'] as String?,
      pdfStandard: json['pdfStandard'] as String?,
      isEncrypted: json['isEncrypted'] as bool,
      isLinearized: json['isLinearized'] as bool,
      hasJavaScript: json['hasJavaScript'] as bool,
      hasEmbeddedFiles: json['hasEmbeddedFiles'] as bool,
      hasDigitalSignatures: json['hasDigitalSignatures'] as bool,
      pages: (json['pages'] as List<dynamic>?)
          ?.map((e) => PageInfo.fromJson(e as Map<String, dynamic>))
          .toList(),
      commonDimensions: json['commonDimensions'] == null
          ? null
          : PageDimensions.fromJson(
              json['commonDimensions'] as Map<String, dynamic>),
      hasVariablePageSizes: json['hasVariablePageSizes'] as bool,
      hasVariableOrientations: json['hasVariableOrientations'] as bool,
      totalImages: (json['totalImages'] as num?)?.toInt(),
      totalFonts: (json['totalFonts'] as num?)?.toInt(),
      totalAnnotations: (json['totalAnnotations'] as num?)?.toInt(),
      totalFormFields: (json['totalFormFields'] as num?)?.toInt(),
      isTagged: json['isTagged'] as bool,
      hasOutline: json['hasOutline'] as bool,
      language: json['language'] as String?,
    );

Map<String, dynamic> _$DocumentInfoToJson(DocumentInfo instance) =>
    <String, dynamic>{
      'documentId': instance.documentId,
      'totalPages': instance.totalPages,
      'title': instance.title,
      'author': instance.author,
      'subject': instance.subject,
      'keywords': instance.keywords,
      'creator': instance.creator,
      'producer': instance.producer,
      'creationDate': instance.creationDate?.toIso8601String(),
      'modificationDate': instance.modificationDate?.toIso8601String(),
      'fileSize': instance.fileSize,
      'pdfVersion': instance.pdfVersion,
      'pdfStandard': instance.pdfStandard,
      'isEncrypted': instance.isEncrypted,
      'isLinearized': instance.isLinearized,
      'hasJavaScript': instance.hasJavaScript,
      'hasEmbeddedFiles': instance.hasEmbeddedFiles,
      'hasDigitalSignatures': instance.hasDigitalSignatures,
      'pages': instance.pages,
      'commonDimensions': instance.commonDimensions,
      'hasVariablePageSizes': instance.hasVariablePageSizes,
      'hasVariableOrientations': instance.hasVariableOrientations,
      'totalImages': instance.totalImages,
      'totalFonts': instance.totalFonts,
      'totalAnnotations': instance.totalAnnotations,
      'totalFormFields': instance.totalFormFields,
      'isTagged': instance.isTagged,
      'hasOutline': instance.hasOutline,
      'language': instance.language,
    };
