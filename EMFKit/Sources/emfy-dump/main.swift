import EMFParse
import Foundation

// emfy-dump — record-inventory CLI for EMF files. Permanent debugging tool:
// prints the header dimensions and a per-type record inventory for one file.
//
// Exit codes:
//   0 — the file parsed (diagnostics, if any, are REPORTED, never fatal;
//       log-and-skip is the failure philosophy)
//   1 — unreadable file, or no valid EMF header
//   2 — usage error

// MARK: - Formatting helpers

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func describe(_ error: EMFParseError) -> String {
    switch error {
    case .tooShort(let count):
        return "not an EMF file: \(count) bytes is below the 96-byte minimum "
            + "(88-byte header + 8-byte record header)"
    case .notHeaderRecord(let type):
        return "not an EMF file: first record type is \(type), expected 1 (EMR_HEADER)"
    case .badSignature(let found):
        return String(
            format: "not an EMF file: RecordSignature is 0x%08X, expected 0x464D4520 (\" EMF\")",
            found
        )
    case .invalidHeaderSize(let size):
        return "invalid EMF header: nSize \(size) must be >= 88, a multiple of 4, "
            + "and no larger than the file"
    }
}

func describe(_ diagnostic: EMFDiagnostic) -> String {
    switch diagnostic {
    case .sizeTooSmall(let offset, let size):
        return "record at offset \(offset): nSize \(size) is below the 8-byte minimum; walk stopped"
    case .sizeNotAligned(let offset, let size):
        return "record at offset \(offset): nSize \(size) is not a multiple of 4; walk stopped"
    case .sizeExceedsRemaining(let offset, let size, let remaining):
        return "record at offset \(offset): nSize \(size) exceeds the \(remaining) bytes remaining; walk stopped"
    case .truncatedRecordHeader(let offset, let remaining):
        return "record at offset \(offset): only \(remaining) bytes remain, too few for a record header; walk stopped"
    case .missingEOF:
        return "no EMR_EOF record before the end of the data"
    case .trailingBytesAfterEOF(let count):
        return "\(count) trailing bytes after EMR_EOF"
    case .recordCountMismatch(let headerSays, let walked):
        return "header Records field claims \(headerSays), walk found \(walked) (advisory field; the walk is authoritative)"
    case .byteCountMismatch(let headerSays, let walked):
        return "header Bytes field claims \(headerSays), walk covered \(walked) (advisory field; the walk is authoritative)"
    case .recordCountCapped(let limit):
        return "record-count cap of \(limit) reached; walk stopped, keeping every record parsed so far"
    }
}

// EMF+ diagnostics carry two offset domains: `recordOffset` is a file offset of
// the containing EMR_COMMENT_EMFPLUS; `streamOffset` is an offset into the
// reassembled EMF+ stream (a logical record can span several comments, so it has
// no single file offset). Both are stated explicitly below.
func describe(_ diagnostic: EMFPlusDiagnostic) -> String {
    switch diagnostic {
    case .commentDataSizeClamped(let recordOffset, let declaredDataSize, let keptStreamBytes):
        return "EMR_COMMENT_EMFPLUS at file offset \(recordOffset): DataSize \(declaredDataSize) "
            + "overruns the record; clamped to \(keptStreamBytes) stream bytes"
    case .recordSizeTooSmall(let streamOffset, let size):
        return "EMF+ record at reassembled-stream offset \(streamOffset): Size \(size) is below "
            + "the 12-byte header minimum; walk stopped"
    case .recordSizeNotAligned(let streamOffset, let size):
        return "EMF+ record at reassembled-stream offset \(streamOffset): Size \(size) is not a "
            + "multiple of 4; walk stopped"
    case .recordDataSizeExceedsSize(let streamOffset, let size, let dataSize):
        return "EMF+ record at reassembled-stream offset \(streamOffset): DataSize \(dataSize) "
            + "exceeds Size \(size) minus the 12-byte header; walk stopped"
    case .recordDataTruncated(let streamOffset, let declaredDataSize, let availableBytes):
        return "EMF+ record at reassembled-stream offset \(streamOffset): DataSize \(declaredDataSize) "
            + "runs past the \(availableBytes) stream bytes remaining; record dropped, walk stopped"
    case .trailingBytes(let count):
        return "\(count) trailing stream bytes after the last EMF+ record, too few for a 12-byte header"
    case .headerRecordMissing:
        return "EMF+ comments present but the stream does not open with an EmfPlusHeader (0x4001); "
            + "header left undecoded"
    case .headerUnexpectedSize(let size):
        return "EmfPlusHeader Size \(size) is not the required 0x1C; header decoded best-effort"
    case .headerUnexpectedDataSize(let dataSize):
        return "EmfPlusHeader DataSize \(dataSize) is not the required 0x10; header decoded best-effort"
    }
}

// EMF+ object-envelope diagnostics ([MS-EMFPLUS] §2.3.5.1 reassembly). Same
// log-and-skip voice as the record-stream diagnostics above.
func describe(_ diagnostic: EMFPlusObjectDiagnostic) -> String {
    switch diagnostic {
    case .objectIDOutOfRange(let objectID, let objectType):
        return "EMF+ object ID \(objectID) (\(objectTypeName(objectType))) is outside the 0..63 range; kept"
    case .continuationMismatch(let pendingID, let pendingType, let arrivingID, let arrivingType):
        return "EMF+ continued object \(pendingID) (\(objectTypeName(pendingType))) interrupted by "
            + "object \(arrivingID) (\(objectTypeName(arrivingType))); pending dropped, restarted"
    case .continuationOverflow(let objectID, let totalObjectSize, let accumulatedBytes):
        return "EMF+ continued object \(objectID): \(accumulatedBytes) accumulated bytes exceed "
            + "TotalObjectSize \(totalObjectSize); clamped"
    case .danglingContinuation(let objectID, let totalObjectSize, let accumulatedBytes):
        return "EMF+ continued object \(objectID): only \(accumulatedBytes) of \(totalObjectSize) bytes "
            + "before the stream ended; dropped"
    case .chunkTooShort(let dataSize):
        return "EMF+ object chunk with \(dataSize) data bytes cannot hold its TotalObjectSize prefix; dropped"
    }
}

// Terse one-line reason for a failed typed object decode ([MS-EMFPLUS] §2.2.1).
func describe(_ failure: EMFPlusObjectDecodeFailure) -> String {
    switch failure {
    case .truncated(let field):
        return "truncated at \(field)"
    case .unknownBrushType(let raw):
        return String(format: "unknown brush type 0x%08X", raw)
    case .arrayCountExceedsBuffer(let field, let count, _):
        return "count \(count) exceeds buffer at \(field)"
    case .customCapSizeExceedsBuffer(let field, let size, _):
        return "custom-cap size \(size) exceeds buffer at \(field)"
    case .relativePathEncodingUnsupported:
        return "relative/RLE path encoding unsupported"
    case .unknownRegionNodeType(let raw):
        return String(format: "unknown region node type 0x%08X", raw)
    case .regionTreeTooDeep:
        return "region tree exceeds the depth cap"
    case .regionTooManyNodes:
        return "region tree exceeds the node cap"
    case .unknownImageType(let raw):
        return String(format: "unknown image type 0x%08X", raw)
    }
}

// Short name for an EMF+ object type ([MS-EMFPLUS] §2.1.1.21).
func objectTypeName(_ type: EMFPlusObjectType) -> String {
    switch type {
    case .invalid: return "invalid"
    case .brush: return "brush"
    case .pen: return "pen"
    case .path: return "path"
    case .region: return "region"
    case .image: return "image"
    case .font: return "font"
    case .stringFormat: return "stringFormat"
    case .imageAttributes: return "imageAttributes"
    case .customLineCap: return "customLineCap"
    case .unknown(let raw): return String(format: "unknown(0x%02X)", raw)
    }
}

func describe(_ variant: EMFHeaderVariant) -> String {
    switch variant {
    case .base: return "base (88-byte fixed part)"
    case .extension1: return "extension1 (100-byte fixed part)"
    case .extension2: return "extension2 (108-byte fixed part)"
    }
}

func leftPad(_ string: String, _ width: Int) -> String {
    string.count >= width
        ? string
        : String(repeating: " ", count: width - string.count) + string
}

func rightPad(_ string: String, _ width: Int) -> String {
    string.count >= width
        ? string
        : string + String(repeating: " ", count: width - string.count)
}

// MARK: - Arguments

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    printErr("usage: emfy-dump <file.emf>")
    exit(2)
}
let path = arguments[1]

// MARK: - Load and parse

let data: Data
do {
    data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
} catch {
    printErr("emfy-dump: cannot read '\(path)': \(error.localizedDescription)")
    exit(1)
}

let file: EMFFile
do {
    file = try EMFFile.parse(data)
} catch {
    printErr("emfy-dump: '\(path)': \(describe(error))")
    exit(1)
}

// MARK: - Header block

let header = file.header
print("file: \(URL(fileURLWithPath: path).lastPathComponent) (\(data.count) bytes)")
print("header:")
print("  variant:     \(describe(header.variant))")
print(String(format: "  version:     0x%08X", header.version))
// rclFrame is hundredths of a millimetre; subtract in the Int domain so
// hostile Int32 extremes cannot overflow.
let frameWidth = Double(Int(header.frame.right) - Int(header.frame.left)) / 100.0
let frameHeight = Double(Int(header.frame.bottom) - Int(header.frame.top)) / 100.0
print(String(format: "  frame:       %.2f x %.2f mm", frameWidth, frameHeight))
let bounds = header.bounds
print("  bounds:      (\(bounds.left), \(bounds.top)) - (\(bounds.right), \(bounds.bottom))")
print("  device:      \(header.device.cx) x \(header.device.cy) px, "
    + "\(header.millimeters.cx) x \(header.millimeters.cy) mm")
if let description = header.description {
    // The description is two NUL-terminated strings (application name,
    // picture name) per [MS-EMF] §2.2.9; shown separated by " | ".
    let parts = description.split(separator: "\u{0}").map(String.init)
    print("  description: \(parts.joined(separator: " | "))")
}

// MARK: - Counts

let walked = file.records.count
let claimed = Int(header.records)
let recordsPart = claimed == walked
    ? "records walked: \(walked)"
    : "records walked: \(walked) (header claims \(claimed))"
print("\(recordsPart), bytes walked: \(file.bytesWalked) of \(data.count)")
print("")

// MARK: - Inventory table

let rows: [(type: String, name: String, count: String, bytes: String)] =
    file.recordInventory().map { entry in
        (
            type: String(entry.type),
            name: EMFRecordType.name(for: entry.type) ?? "(unknown)",
            count: String(entry.count),
            bytes: String(entry.totalBytes)
        )
    }
let typeWidth = max("type".count, rows.map { $0.type.count }.max() ?? 0)
let nameWidth = max("name".count, rows.map { $0.name.count }.max() ?? 0)
let countWidth = max("count".count, rows.map { $0.count.count }.max() ?? 0)
let bytesWidth = max("total bytes".count, rows.map { $0.bytes.count }.max() ?? 0)
print(
    "\(leftPad("type", typeWidth))  \(rightPad("name", nameWidth))  "
    + "\(leftPad("count", countWidth))  \(leftPad("total bytes", bytesWidth))"
)
for row in rows {
    print(
        "\(leftPad(row.type, typeWidth))  \(rightPad(row.name, nameWidth))  "
        + "\(leftPad(row.count, countWidth))  \(leftPad(row.bytes, bytesWidth))"
    )
}
print("")

// MARK: - Diagnostics

if file.diagnostics.isEmpty {
    print("diagnostics: none")
} else {
    print("diagnostics:")
    for diagnostic in file.diagnostics {
        print("  - \(describe(diagnostic))")
    }
}

// MARK: - EMF+ block

// Appended after the GDI diagnostics. A pure-GDI file — no EMF+ records, no EMF+
// diagnostics, and no decoded header — prints nothing here, so its output stays
// byte-identical to a build without EMF+ support (primer §8, log-and-skip: EMF+
// issues are diagnostics, never exit-code changes).
let plus = file.emfPlusStream()
if !plus.records.isEmpty || !plus.diagnostics.isEmpty || plus.header != nil {
    print("")
    print("emf+:")
    if let plusHeader = plus.header {
        let mode = plusHeader.isDual ? "dual" : "EMF+ only"
        let device = plusHeader.isVideoDisplay ? "video display" : "printer"
        let versionHex = String(format: "0x%08X", plusHeader.version)
        print("  version:     \(versionHex) (\(mode), \(device), "
            + "\(plusHeader.logicalDpiX) x \(plusHeader.logicalDpiY) dpi)")
    } else {
        print("  version:     (no EmfPlusHeader record)")
    }
    let plusAccounting = "  records walked: \(plus.records.count), "
        + "stream bytes: \(plus.bytesConsumed) of \(plus.assembledByteCount)"
    print(plus.leftoverByteCount != 0
        ? plusAccounting + " (\(plus.leftoverByteCount) unwalked)"
        : plusAccounting)
    print("")

    // Inventory table — same padding discipline as the GDI table above.
    let plusRows: [(type: String, name: String, count: String, bytes: String)] =
        plus.recordInventory().map { entry in
            (
                type: String(format: "0x%04X", entry.type),
                name: EMFPlusRecordType.displayName(for: entry.type),
                count: String(entry.count),
                bytes: String(entry.totalBytes)
            )
        }
    let plusTypeWidth = max("type".count, plusRows.map { $0.type.count }.max() ?? 0)
    let plusNameWidth = max("name".count, plusRows.map { $0.name.count }.max() ?? 0)
    let plusCountWidth = max("count".count, plusRows.map { $0.count.count }.max() ?? 0)
    let plusBytesWidth = max("total bytes".count, plusRows.map { $0.bytes.count }.max() ?? 0)
    print(
        "\(leftPad("type", plusTypeWidth))  \(rightPad("name", plusNameWidth))  "
        + "\(leftPad("count", plusCountWidth))  \(leftPad("total bytes", plusBytesWidth))"
    )
    for row in plusRows {
        print(
            "\(leftPad(row.type, plusTypeWidth))  \(rightPad(row.name, plusNameWidth))  "
            + "\(leftPad(row.count, plusCountWidth))  \(leftPad(row.bytes, plusBytesWidth))"
        )
    }
    print("")

    // Object breakdown — printed only when at least one EmfPlusObject was
    // reassembled, so a shell EMF+ file (no objects) prints nothing here and its
    // output is unchanged.
    let objects = plus.objectDefinitions()
    if !objects.definitions.isEmpty {
        print("  emf+ objects: \(objects.definitions.count) definitions")
        var tallies: [(type: EMFPlusObjectType, count: Int, decoded: Int)] = []
        var malformedLines: [String] = []
        for definition in objects.definitions {
            let value = definition.decodedValue()
            let decoded: Bool
            switch value {
            case .undecoded, .malformed: decoded = false
            default: decoded = true
            }
            if let index = tallies.firstIndex(where: { $0.type == definition.objectType }) {
                tallies[index].count += 1
                if decoded { tallies[index].decoded += 1 }
            } else {
                tallies.append((definition.objectType, 1, decoded ? 1 : 0))
            }
            if case .malformed(let type, let reason) = value {
                malformedLines.append("    malformed: \(objectTypeName(type)) — \(describe(reason))")
            }
        }
        tallies.sort { $0.type.rawValue < $1.type.rawValue }
        let objRows = tallies.map {
            (name: objectTypeName($0.type), count: String($0.count), decoded: String($0.decoded))
        }
        let onWidth = max("type".count, objRows.map { $0.name.count }.max() ?? 0)
        let ocWidth = max("count".count, objRows.map { $0.count.count }.max() ?? 0)
        let odWidth = max("decoded".count, objRows.map { $0.decoded.count }.max() ?? 0)
        print("    \(rightPad("type", onWidth))  \(leftPad("count", ocWidth))  \(leftPad("decoded", odWidth))")
        for row in objRows {
            print("    \(rightPad(row.name, onWidth))  \(leftPad(row.count, ocWidth))  \(leftPad(row.decoded, odWidth))")
        }
        for line in malformedLines { print(line) }
        print("")
    }

    // Diagnostics — stream-walk issues and object-envelope issues share the
    // block; both empty prints the same single `none` line as before.
    if plus.diagnostics.isEmpty && objects.diagnostics.isEmpty {
        print("emf+ diagnostics: none")
    } else {
        print("emf+ diagnostics:")
        for diagnostic in plus.diagnostics {
            print("  - \(describe(diagnostic))")
        }
        for diagnostic in objects.diagnostics {
            print("  - \(describe(diagnostic))")
        }
    }
}
exit(0)
