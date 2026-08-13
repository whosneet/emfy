import Foundation

/// The type of graphics object created by an EmfPlusObject record, from the
/// [MS-EMFPLUS] §2.1.1.21 ObjectType enumeration. `unknown` preserves any value
/// outside the defined 0…9 range (ObjectType is a 7-bit field, so 10…127 are
/// possible on the wire) rather than discarding it — log-and-skip, not reject.
public enum EMFPlusObjectType: Sendable, Equatable {
    case invalid          // 0x00 ObjectTypeInvalid
    case brush            // 0x01 ObjectTypeBrush
    case pen              // 0x02 ObjectTypePen
    case path             // 0x03 ObjectTypePath
    case region           // 0x04 ObjectTypeRegion
    case image            // 0x05 ObjectTypeImage
    case font             // 0x06 ObjectTypeFont
    case stringFormat     // 0x07 ObjectTypeStringFormat
    case imageAttributes  // 0x08 ObjectTypeImageAttributes
    case customLineCap    // 0x09 ObjectTypeCustomLineCap
    case unknown(UInt8)

    public init(rawValue: UInt8) {
        switch rawValue {
        case 0x00: self = .invalid
        case 0x01: self = .brush
        case 0x02: self = .pen
        case 0x03: self = .path
        case 0x04: self = .region
        case 0x05: self = .image
        case 0x06: self = .font
        case 0x07: self = .stringFormat
        case 0x08: self = .imageAttributes
        case 0x09: self = .customLineCap
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: UInt8 {
        switch self {
        case .invalid: return 0x00
        case .brush: return 0x01
        case .pen: return 0x02
        case .path: return 0x03
        case .region: return 0x04
        case .image: return 0x05
        case .font: return 0x06
        case .stringFormat: return 0x07
        case .imageAttributes: return 0x08
        case .customLineCap: return 0x09
        case .unknown(let value): return value
        }
    }
}

/// One complete graphics object reassembled from the EMF+ stream: the table
/// index it is bound to, its type, and its full object payload with any
/// continuation framing removed.
///
/// `data` is the object definition exactly as [MS-EMFPLUS] §2.2.1 describes it
/// for the object type (e.g. an EmfPlusBrush for `.brush`) — the per-chunk
/// TotalObjectSize prefixes are stripped and multi-chunk objects are made
/// contiguous. For a single-chunk non-continued object `data` is a no-copy slice
/// over the assembled stream buffer, so it may carry a non-zero `startIndex`;
/// read it with a start-index-safe reader (as `decodedValue()` does) rather than
/// integer-subscripting from 0.
public struct EMFPlusObjectDefinition: Sendable, Equatable {
    /// The EMF+ Object Table index (§2.3.5.1 ObjectID). The spec requires 0…63;
    /// an out-of-range value is kept and flagged (`objectIDOutOfRange`).
    public let objectID: UInt8
    /// The object type (§2.1.1.21).
    public let objectType: EMFPlusObjectType
    /// The complete object payload, continuation framing removed.
    public let data: Data

    public init(objectID: UInt8, objectType: EMFPlusObjectType, data: Data) {
        self.objectID = objectID
        self.objectType = objectType
        self.data = data
    }
}

/// A non-fatal issue found while walking and reassembling EmfPlusObject records.
///
/// Mirrors `EMFPlusDiagnostic`'s log-and-skip voice (primer §8): the granularity
/// is the object — a bad object is dropped or clamped with a diagnostic, and the
/// walk over the remaining records continues.
public enum EMFPlusObjectDiagnostic: Sendable, Equatable {
    /// An EmfPlusObject's ObjectID exceeded the [MS-EMFPLUS] §2.3.5.1 limit of
    /// 63. The object is still produced; the id is kept verbatim.
    case objectIDOutOfRange(objectID: UInt8, objectType: EMFPlusObjectType)
    /// A record arrived that could not continue the pending continued sequence —
    /// a continuation-flagged record with a different ObjectID/ObjectType, or a
    /// non-continued record while the sequence was still incomplete. The pending
    /// sequence is dropped and the arriving record is processed as a fresh object.
    case continuationMismatch(
        pendingID: UInt8, pendingType: EMFPlusObjectType,
        arrivingID: UInt8, arrivingType: EMFPlusObjectType)
    /// A continued sequence accumulated more object bytes than its declared
    /// TotalObjectSize; the payload was clamped to TotalObjectSize.
    case continuationOverflow(objectID: UInt8, totalObjectSize: Int, accumulatedBytes: Int)
    /// A continued sequence never reached its TotalObjectSize before it was
    /// interrupted or the stream ended; it is dropped without a definition.
    case danglingContinuation(objectID: UInt8, totalObjectSize: Int, accumulatedBytes: Int)
    /// A continuation-flagged EmfPlusObject chunk held fewer than the 4 bytes
    /// needed for its TotalObjectSize prefix; the chunk is dropped.
    case chunkTooShort(dataSize: Int)
}

extension EMFPlusStream {
    /// EmfPlusObject record type id ([MS-EMFPLUS] §2.1.1.1 / §2.3.5.1).
    private static let objectRecordType: UInt16 = 0x4008
    /// EmfPlusObject Flags C (continues) bit ([MS-EMFPLUS] §2.3.5.1).
    private static let objectContinueFlag: UInt16 = 0x8000

    /// Walks the EMF+ record stream, selects EmfPlusObject (0x4008) records, and
    /// reassembles them into complete object definitions in stream order.
    ///
    /// SPEC-VS-WIRE DIVERGENCE ([MS-EMFPLUS] §2.3.5.1, v20240423). The current
    /// spec diagram draws `TotalObjectSize` as an optional record-header field
    /// between `Size` and `DataSize`, which would give continued records a
    /// 16-byte header. Every real EmfPlusObject record contradicts that: the
    /// header is the generic 12 bytes with `DataSize` at +8, and TotalObjectSize
    /// is instead the FIRST DWORD of the record-specific data — present in every
    /// chunk of a continued sequence (the opening chunk and each continuation),
    /// so the real object bytes a chunk contributes are `DataSize - 4`. This was
    /// arbitrated against every EmfPlusObject record in the local corpora
    /// (thousands of plain records plus the handful of genuinely continued ones,
    /// whose per-chunk `(DataSize - 4)` sums equal TotalObjectSize exactly). A
    /// non-continued (C clear) record carries no such prefix; its whole
    /// RecordData is the object payload.
    ///
    /// TERMINATION IS ACCOUNTING-DRIVEN. The spec says the C flag "is never set
    /// in the final record", but on the wire C stays set on the last observed
    /// chunk, so C is advisory (primer §8): a sequence completes once the
    /// accumulated `DataSize - 4` bytes reach TotalObjectSize, not when C clears.
    ///
    /// Never fails the walk: a malformed object is dropped or clamped with a
    /// diagnostic and the remaining records are still processed.
    public func objectDefinitions()
        -> (definitions: [EMFPlusObjectDefinition], diagnostics: [EMFPlusObjectDiagnostic]) {

        /// State for an in-progress continued object.
        struct Pending {
            let objectID: UInt8
            let objectType: EMFPlusObjectType
            let rawType: UInt8
            let totalObjectSize: Int
            var accumulated: Data
        }

        var definitions: [EMFPlusObjectDefinition] = []
        var diagnostics: [EMFPlusObjectDiagnostic] = []
        var pending: Pending?

        for record in records where record.type == Self.objectRecordType {
            let flags = record.flags
            let continues = (flags & Self.objectContinueFlag) != 0
            // Flags layout ([MS-EMFPLUS] §2.3.5.1): C is bit 15, ObjectType is the
            // next 7 bits (14…8), ObjectID is the low byte (7…0). Masks were
            // arbitrated against the corpus, not read off the diagram.
            let rawType = UInt8((flags >> 8) & 0x7F)
            let objectID = UInt8(flags & 0x00FF)
            let objectType = EMFPlusObjectType(rawValue: rawType)

            if objectID > 63 {
                diagnostics.append(.objectIDOutOfRange(objectID: objectID, objectType: objectType))
            }

            // Resolve any pending continued sequence before treating this record
            // as a fresh object.
            if let p = pending {
                let matchesPending = continues && objectID == p.objectID && rawType == p.rawType
                if matchesPending {
                    let chunk = ByteReader(record.data)
                    // Every continued chunk repeats the 4-byte TotalObjectSize
                    // prefix; strip it and accumulate the remaining DataSize-4.
                    guard chunk.count >= 4,
                          let objectBytes = chunk.data(at: 4, length: chunk.count - 4) else {
                        diagnostics.append(.chunkTooShort(dataSize: record.data.count))
                        diagnostics.append(.danglingContinuation(
                            objectID: p.objectID, totalObjectSize: p.totalObjectSize,
                            accumulatedBytes: p.accumulated.count))
                        pending = nil
                        continue
                    }
                    var accumulated = p.accumulated
                    accumulated.append(objectBytes)
                    if accumulated.count >= p.totalObjectSize {
                        if accumulated.count > p.totalObjectSize {
                            diagnostics.append(.continuationOverflow(
                                objectID: p.objectID, totalObjectSize: p.totalObjectSize,
                                accumulatedBytes: accumulated.count))
                        }
                        definitions.append(EMFPlusObjectDefinition(
                            objectID: p.objectID, objectType: p.objectType,
                            data: Data(accumulated.prefix(p.totalObjectSize))))
                        pending = nil
                    } else {
                        pending = Pending(
                            objectID: p.objectID, objectType: p.objectType, rawType: p.rawType,
                            totalObjectSize: p.totalObjectSize, accumulated: accumulated)
                    }
                    continue
                } else {
                    // The pending sequence can no longer complete: drop it and
                    // reprocess this record as a fresh object below.
                    diagnostics.append(.continuationMismatch(
                        pendingID: p.objectID, pendingType: p.objectType,
                        arrivingID: objectID, arrivingType: objectType))
                    pending = nil
                }
            }

            if continues {
                let chunk = ByteReader(record.data)
                guard chunk.count >= 4, let total32 = chunk.readUInt32(at: 0),
                      let objectBytes = chunk.data(at: 4, length: chunk.count - 4) else {
                    diagnostics.append(.chunkTooShort(dataSize: record.data.count))
                    continue
                }
                let total = Int(total32)
                if objectBytes.count >= total {
                    // Completes within this single chunk.
                    if objectBytes.count > total {
                        diagnostics.append(.continuationOverflow(
                            objectID: objectID, totalObjectSize: total,
                            accumulatedBytes: objectBytes.count))
                    }
                    definitions.append(EMFPlusObjectDefinition(
                        objectID: objectID, objectType: objectType,
                        data: Data(objectBytes.prefix(total))))
                } else {
                    pending = Pending(
                        objectID: objectID, objectType: objectType, rawType: rawType,
                        totalObjectSize: total, accumulated: Data(objectBytes))
                }
            } else {
                // Non-continued: the entire RecordData is the object payload; no
                // TotalObjectSize prefix is present. Kept as a no-copy slice.
                definitions.append(EMFPlusObjectDefinition(
                    objectID: objectID, objectType: objectType, data: record.data))
            }
        }

        if let p = pending {
            diagnostics.append(.danglingContinuation(
                objectID: p.objectID, totalObjectSize: p.totalObjectSize,
                accumulatedBytes: p.accumulated.count))
        }

        return (definitions, diagnostics)
    }
}
