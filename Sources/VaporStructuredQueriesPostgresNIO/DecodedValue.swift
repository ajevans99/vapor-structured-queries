import StructuredQueries

// Only decoded output crosses the async sequence boundary, not the query representation.
struct DecodedValue<Value: QueryRepresentable>: QueryRepresentable, Sendable
where Value.QueryOutput: Sendable {
  let queryOutput: Value.QueryOutput

  init(queryOutput: Value.QueryOutput) {
    self.queryOutput = queryOutput
  }

  init(decoder: inout some QueryDecoder) throws {
    self.queryOutput = try Value(decoder: &decoder).queryOutput
  }
}
