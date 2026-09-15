import Foundation
import StructuredQueries
import Testing
import VaporStructuredQueries

@Table("vsq_adapter_records")
private struct AdapterRecord: Equatable, Sendable {
  let id: Int64
  var title: String
  var note: String?
  var isComplete: Bool
}

func verifyTypedQueryFlow(on database: any Database) async throws {
  try await #sql(
    """
    CREATE TABLE "vsq_adapter_records" (
      "id" BIGINT PRIMARY KEY,
      "title" TEXT NOT NULL,
      "note" TEXT,
      "isComplete" BOOLEAN NOT NULL
    )
    """,
    as: Void.self
  ).execute(on: database)

  try await withTestTableCleanup(named: "vsq_adapter_records", on: database) {
    try await AdapterRecord.insert {
      AdapterRecord.Draft(id: 1, title: "First 'bound' title", note: nil, isComplete: false)
      AdapterRecord.Draft(id: 2, title: "Second", note: "A note", isComplete: true)
    }.execute(on: database)

    let rows = try await AdapterRecord.order(by: \.id).all(on: database)
    #expect(
      rows == [
        AdapterRecord(id: 1, title: "First 'bound' title", note: nil, isComplete: false),
        AdapterRecord(id: 2, title: "Second", note: "A note", isComplete: true),
      ]
    )

    let titles = try await AdapterRecord.where(\.isComplete).select(\.title).all(on: database)
    #expect(titles == ["Second"])

    try await AdapterRecord.where { $0.id.eq(Int64(1)) }.update {
      $0.title = #bind("Updated")
      $0.note = #bind("No longer null")
      $0.isComplete = #bind(true)
    }.execute(on: database)

    let updated = try await AdapterRecord.where { $0.id.eq(Int64(1)) }.first(on: database)
    #expect(
      updated == AdapterRecord(id: 1, title: "Updated", note: "No longer null", isComplete: true)
    )

    try await AdapterRecord.where { $0.id.eq(Int64(2)) }.delete().execute(on: database)
    let missing = try await AdapterRecord.where { $0.id.eq(Int64(2)) }.first(on: database)
    #expect(missing == nil)

    let insertedRows = try await AdapterRecord.insert {
      AdapterRecord.Draft(id: 3, title: "Returning", note: nil, isComplete: false)
    }
    .returning(\.self)
    .all(on: database)
    #expect(
      insertedRows == [AdapterRecord(id: 3, title: "Returning", note: nil, isComplete: false)]
    )

    let null = try await #sql("SELECT NULL", as: String?.self).all(on: database)
    #expect(null == [nil])

    let identifier = UUID(uuid: (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15))
    let decodedIdentifier = try await #sql("SELECT \(bind: identifier)", as: UUID.self)
      .first(on: database)
    #expect(decodedIdentifier == identifier)

    let date = Date(timeIntervalSince1970: 1_700_000_000.125)
    let decodedDate = try await #sql("SELECT \(bind: date)", as: Date.self).first(on: database)
    #expect(decodedDate == date)

    let bytes: [UInt8] = [0, 1, 127, 128, 255]
    let decodedBytes = try await #sql("SELECT \(bind: bytes)", as: [UInt8].self).first(on: database)
    #expect(decodedBytes == bytes)

    let represented = #sql("SELECT \(bind: "represented")", as: TitleRepresentation.self)
    #expect(try await represented.all(on: database) == ["represented"])
    #expect(try await represented.first(on: database) == "represented")

    await #expect(throws: QueryDecodingError.self) {
      try await #sql("SELECT NULL", as: Int.self).all(on: database)
    }

    await #expect(throws: (any Error).self) {
      try await #sql(
        "SELECT vsq_adapter_records.missing_column FROM \"vsq_adapter_records\"",
        as: Int.self
      )
      .all(on: database)
    }
  }
}

private final class TitleRepresentation: QueryRepresentable {
  let queryOutput: String

  init(queryOutput: String) {
    self.queryOutput = queryOutput
  }

  init(decoder: inout some QueryDecoder) throws {
    self.queryOutput = try String(decoder: &decoder)
  }
}

func withTestTableCleanup(
  named tableName: String,
  on database: any Database,
  operation: () async throws -> Void
) async throws {
  do {
    try await operation()
  } catch {
    do {
      try await #sql("DROP TABLE \(quote: tableName)", as: Void.self).execute(on: database)
    } catch {
      Issue.record(error, "Could not clean up typed-query test table")
    }
    throw error
  }

  try await #sql("DROP TABLE \(quote: tableName)", as: Void.self).execute(on: database)
}
