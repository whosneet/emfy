import Foundation

// MARK: - Image model (shell)

/// The fixed header of a bitmap image, [MS-EMFPLUS] §2.2.2.2 EmfPlusBitmap. The
/// pixel/compressed payload is kept raw for a later increment.
public struct EMFPlusImageBitmapHeader: Sendable, Equatable {
    public let width: Int32
    public let height: Int32
    public let stride: Int32
    public let pixelFormat: UInt32
    /// §2.1.1.2 BitmapDataType: 0 = pixel data, 1 = compressed (PNG/JPEG/…).
    public let bitmapDataType: UInt32

    public init(width: Int32, height: Int32, stride: Int32, pixelFormat: UInt32, bitmapDataType: UInt32) {
        self.width = width
        self.height = height
        self.stride = stride
        self.pixelFormat = pixelFormat
        self.bitmapDataType = bitmapDataType
    }
}

/// The fixed header of a metafile image, [MS-EMFPLUS] §2.2.2.27 EmfPlusMetafile.
/// The embedded metafile bytes are kept raw for a later increment.
public struct EMFPlusImageMetafileHeader: Sendable, Equatable {
    /// §2.1.1.20 MetafileDataType.
    public let metafileType: UInt32
    public let metafileDataSize: UInt32

    public init(metafileType: UInt32, metafileDataSize: UInt32) {
        self.metafileType = metafileType
        self.metafileDataSize = metafileDataSize
    }
}

/// A decoded image SHELL, [MS-EMFPLUS] §2.2.1.4 EmfPlusImage: the typed header is
/// decoded so a consumer knows the dimensions/format and where the pixel or
/// metafile bytes are, but those bytes are NOT interpreted in this increment.
public struct EMFPlusImage: Sendable, Equatable {
    public let version: UInt32
    public let content: Content

    public init(version: UInt32, content: Content) {
        self.version = version
        self.content = content
    }

    public enum Content: Sendable, Equatable {
        /// §2.1.1.15 ImageDataTypeBitmap: bitmap header + raw BitmapData.
        case bitmap(EMFPlusImageBitmapHeader, data: Data)
        /// §2.1.1.15 ImageDataTypeMetafile: metafile header + raw MetafileData.
        case metafile(EMFPlusImageMetafileHeader, data: Data)
    }
}

/// A decoded image-attributes object, [MS-EMFPLUS] §2.2.1.5 EmfPlusImageAttributes.
/// The two Reserved fields are read past and dropped.
public struct EMFPlusImageAttributes: Sendable, Equatable {
    public let version: UInt32
    /// §2.1.1.33 WrapMode, raw.
    public let wrapMode: UInt32
    public let clampColor: EMFPlusARGB
    public let objectClamp: Int32

    public init(version: UInt32, wrapMode: UInt32, clampColor: EMFPlusARGB, objectClamp: Int32) {
        self.version = version
        self.wrapMode = wrapMode
        self.clampColor = clampColor
        self.objectClamp = objectClamp
    }
}

// MARK: - Image decode (shell)

/// Decodes an EmfPlusImage SHELL ([MS-EMFPLUS] §2.2.1.4): Version, Type
/// (§2.1.1.15 ImageDataType), then the fixed header for a bitmap (§2.2.2.2) or
/// metafile (§2.2.2.27) followed by the remaining bytes captured raw. An unknown
/// or `ImageDataTypeUnknown` type fails typed (no size guessing).
func decodeImage(_ cursor: inout ByteCursor)
    -> Result<EMFPlusImage, EMFPlusObjectDecodeFailure> {
    guard let version = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusImage.Version"))
    }
    guard let type = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusImage.Type"))
    }

    switch type {
    case 0x0000_0001:   // ImageDataTypeBitmap
        guard let width = cursor.readInt32() else { return .failure(.truncated(field: "EmfPlusBitmap.Width")) }
        guard let height = cursor.readInt32() else { return .failure(.truncated(field: "EmfPlusBitmap.Height")) }
        guard let stride = cursor.readInt32() else { return .failure(.truncated(field: "EmfPlusBitmap.Stride")) }
        guard let pixelFormat = cursor.readUInt32() else { return .failure(.truncated(field: "EmfPlusBitmap.PixelFormat")) }
        guard let bitmapType = cursor.readUInt32() else { return .failure(.truncated(field: "EmfPlusBitmap.Type")) }
        let header = EMFPlusImageBitmapHeader(
            width: width, height: height, stride: stride,
            pixelFormat: pixelFormat, bitmapDataType: bitmapType)
        let raw = cursor.readBytes(cursor.remaining) ?? Data()
        return .success(EMFPlusImage(version: version, content: .bitmap(header, data: raw)))

    case 0x0000_0002:   // ImageDataTypeMetafile
        guard let metafileType = cursor.readUInt32() else { return .failure(.truncated(field: "EmfPlusMetafile.Type")) }
        guard let metafileDataSize = cursor.readUInt32() else { return .failure(.truncated(field: "EmfPlusMetafile.MetafileDataSize")) }
        let header = EMFPlusImageMetafileHeader(metafileType: metafileType, metafileDataSize: metafileDataSize)
        let raw = cursor.readBytes(cursor.remaining) ?? Data()
        return .success(EMFPlusImage(version: version, content: .metafile(header, data: raw)))

    default:            // ImageDataTypeUnknown (0) or any undefined value
        return .failure(.unknownImageType(raw: type))
    }
}

/// Decodes an EmfPlusImageAttributes ([MS-EMFPLUS] §2.2.1.5): Version,
/// Reserved1 (ignored), WrapMode, ClampColor (ARGB), ObjectClamp, Reserved2
/// (ignored).
func decodeImageAttributes(_ cursor: inout ByteCursor)
    -> Result<EMFPlusImageAttributes, EMFPlusObjectDecodeFailure> {
    guard let version = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusImageAttributes.Version"))
    }
    guard cursor.readUInt32() != nil else {   // Reserved1
        return .failure(.truncated(field: "EmfPlusImageAttributes.Reserved1"))
    }
    guard let wrapMode = cursor.readUInt32() else {
        return .failure(.truncated(field: "EmfPlusImageAttributes.WrapMode"))
    }
    guard let clampColor = cursor.readARGB() else {
        return .failure(.truncated(field: "EmfPlusImageAttributes.ClampColor"))
    }
    guard let objectClamp = cursor.readInt32() else {
        return .failure(.truncated(field: "EmfPlusImageAttributes.ObjectClamp"))
    }
    guard cursor.readUInt32() != nil else {   // Reserved2
        return .failure(.truncated(field: "EmfPlusImageAttributes.Reserved2"))
    }
    return .success(EMFPlusImageAttributes(
        version: version, wrapMode: wrapMode, clampColor: clampColor, objectClamp: objectClamp))
}
