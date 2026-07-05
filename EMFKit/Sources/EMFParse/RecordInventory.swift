import Foundation

extension EMFFile {
    /// Aggregates the walked records by type id: how many records of each
    /// type appear, and how many bytes they cover in total (the sum of their
    /// `nSize` values, 8-byte record headers included). The header record
    /// (`records[0]`) is counted like any other. Entries are sorted by type
    /// id ascending.
    ///
    /// This is the inventory-level view for tooling such as `emfy-dump`;
    /// resolve display names separately via `EMFRecordType.name(for:)`.
    public func recordInventory() -> [(type: UInt32, count: Int, totalBytes: Int)] {
        var totals: [UInt32: (count: Int, totalBytes: Int)] = [:]
        for record in records {
            let current = totals[record.type] ?? (count: 0, totalBytes: 0)
            // Admitted record sizes are each bounded by the file length, so
            // the Int-domain sum cannot overflow.
            totals[record.type] = (
                count: current.count + 1,
                totalBytes: current.totalBytes + Int(record.size)
            )
        }
        return totals
            .map { (type: $0.key, count: $0.value.count, totalBytes: $0.value.totalBytes) }
            .sorted { $0.type < $1.type }
    }
}
