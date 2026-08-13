import Foundation

extension EMFPlusStream {
    /// Aggregates the walked EMF+ records by type id: how many records of each
    /// type appear, and how many bytes they cover in total. The EmfPlusHeader
    /// record (`records[0]`, when present) is counted like any other. Entries are
    /// sorted by type id ascending.
    ///
    /// `totalBytes` sums each record's on-stream footprint — the 12-byte record
    /// header plus its `data.count` — rather than its declared `Size`. On a clean
    /// stream this keeps the inventory total equal to `bytesConsumed`: a final
    /// record whose declared alignment padding is cut off by the assembled-stream
    /// boundary still contributes only the bytes actually present, so the two
    /// figures agree. Using `declaredSize` would over-count in that case and break
    /// the agreement, which is a phase-1 gate property.
    ///
    /// This is the inventory-level view for tooling such as `emfy-dump`; resolve
    /// display names separately via `EMFPlusRecordType.displayName(for:)`.
    public func recordInventory() -> [(type: UInt16, count: Int, totalBytes: Int)] {
        var totals: [UInt16: (count: Int, totalBytes: Int)] = [:]
        for record in records {
            let current = totals[record.type] ?? (count: 0, totalBytes: 0)
            // Each record's data was bounded by the assembled stream (itself at
            // most the file size), so the Int-domain sum cannot overflow.
            totals[record.type] = (
                count: current.count + 1,
                totalBytes: current.totalBytes + 12 + record.data.count
            )
        }
        return totals
            .map { (type: $0.key, count: $0.value.count, totalBytes: $0.value.totalBytes) }
            .sorted { $0.type < $1.type }
    }
}
