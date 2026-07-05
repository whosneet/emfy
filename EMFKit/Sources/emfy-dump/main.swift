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
exit(0)
