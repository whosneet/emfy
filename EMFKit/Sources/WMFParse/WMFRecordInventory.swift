import Foundation

extension WMFFile {
    /// Aggregates the walked records by `RecordFunction`: how many records of
    /// each function appear, and how many bytes they cover in total (the sum of
    /// their byte sizes, 6-byte record headers included). Entries are sorted by
    /// function value ascending.
    ///
    /// This is the inventory-level view for tooling such as `emfy-dump`; resolve
    /// display names separately via `WMFRecordType.name(for:)`.
    public func recordInventory() -> [(function: UInt16, count: Int, totalBytes: Int)] {
        var totals: [UInt16: (count: Int, totalBytes: Int)] = [:]
        for record in records {
            let current = totals[record.function] ?? (count: 0, totalBytes: 0)
            // Admitted record byte sizes are each bounded by the file length, so
            // the Int-domain sum cannot overflow.
            totals[record.function] = (
                count: current.count + 1,
                totalBytes: current.totalBytes + record.byteSize
            )
        }
        return totals
            .map { (function: $0.key, count: $0.value.count, totalBytes: $0.value.totalBytes) }
            .sorted { $0.function < $1.function }
    }
}
