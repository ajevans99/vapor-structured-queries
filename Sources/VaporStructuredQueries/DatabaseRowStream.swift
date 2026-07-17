import NIOConcurrencyHelpers

/// A single-pass, backpressured stream of database rows.
public struct DatabaseRowStream<Element: Sendable>: AsyncSequence, Sendable {
  private let source: any DatabaseRowStreamSource<Element>

  package init<Sequence: AsyncSequence & Sendable>(
    _ sequence: Sequence,
    onTermination: @escaping @Sendable () -> Void = {}
  ) where Sequence.Element == Element {
    self.source = ConcreteDatabaseRowStreamSource(
      sequence: sequence,
      termination: DatabaseRowStreamTermination(onTermination)
    )
  }

  package func cancel() {
    self.source.cancel()
  }

  /// An iterator over a row stream.
  public struct AsyncIterator: AsyncIteratorProtocol {
    private let iterator: DatabaseRowStreamIteratorOwner<Element>?
    private let alreadyConsumed: Bool

    fileprivate init(
      iterator: DatabaseRowStreamIteratorOwner<Element>?,
      alreadyConsumed: Bool = false
    ) {
      self.iterator = iterator
      self.alreadyConsumed = alreadyConsumed
    }

    /// Returns the next row.
    public mutating func next() async throws -> Element? {
      if self.alreadyConsumed {
        throw DatabaseRuntimeError.streamAlreadyConsumed
      }
      guard let iterator = self.iterator else {
        return nil
      }
      return try await iterator.next()
    }
  }

  /// Creates the stream's sole iterator.
  public func makeAsyncIterator() -> AsyncIterator {
    self.source.makeAsyncIterator()
  }
}

private protocol DatabaseRowStreamSource<Element>: Sendable {
  associatedtype Element: Sendable

  func makeAsyncIterator() -> DatabaseRowStream<Element>.AsyncIterator
  func cancel()
}

private final class ConcreteDatabaseRowStreamSource<Sequence>: DatabaseRowStreamSource, Sendable
where Sequence: AsyncSequence & Sendable, Sequence.Element: Sendable {
  private struct State: Sendable {
    var sequence: Sequence?
    weak var iterator: DatabaseRowStreamIteratorOwner<Sequence.Element>?
  }

  private let state: NIOLockedValueBox<State>
  private let termination: DatabaseRowStreamTermination

  init(sequence: Sequence, termination: DatabaseRowStreamTermination) {
    self.state = NIOLockedValueBox(State(sequence: sequence))
    self.termination = termination
  }

  func makeAsyncIterator() -> DatabaseRowStream<Sequence.Element>.AsyncIterator {
    self.state.withLockedValue { state in
      guard let sequence = state.sequence.take() else {
        return .init(iterator: nil, alreadyConsumed: true)
      }
      let iterator = DatabaseRowStreamIteratorOwner(
        sequence: sequence,
        termination: self.termination
      )
      state.iterator = iterator
      return .init(
        iterator: iterator
      )
    }
  }

  func cancel() {
    let iterator = self.state.withLockedValue { state in
      state.sequence = nil
      return state.iterator
    }
    iterator?.cancel()
    self.termination.finish()
  }
}

private final class DatabaseRowStreamIteratorOwner<Element: Sendable>: Sendable {
  private let broker: DatabaseRowStreamDemandBroker<Element>
  private let task: Task<Void, Never>
  private let termination: DatabaseRowStreamTermination

  init<Sequence: AsyncSequence & Sendable>(
    sequence: sending Sequence,
    termination: DatabaseRowStreamTermination
  ) where Sequence.Element == Element {
    let broker = DatabaseRowStreamDemandBroker<Element>()
    self.broker = broker
    self.termination = termination
    self.task = Task {
      defer { termination.finish() }
      guard await broker.waitForDemand() else {
        return
      }
      do {
        for try await element in sequence {
          broker.deliver(.success(element))
          guard await broker.waitForDemand() else {
            return
          }
        }
        broker.deliver(.success(nil))
      } catch {
        broker.deliver(.failure(error))
      }
    }
  }

  deinit {
    self.cancel()
    self.termination.finish()
  }

  func next() async throws -> Element? {
    try await self.broker.next()
  }

  func cancel() {
    self.broker.cancel()
    self.task.cancel()
  }
}

private final class DatabaseRowStreamDemandBroker<Element: Sendable>: Sendable {
  private struct State: Sendable {
    var consumer: CheckedContinuation<Element?, any Error>?
    var producer: CheckedContinuation<Bool, Never>?
    var demandPending = false
    var terminal: Result<Element?, any Error>?
  }

  private let state = NIOLockedValueBox(State())

  func next() async throws -> Element? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let action = self.state.withLockedValue { state -> BrokerAction in
          if let terminal = state.terminal {
            return .resumeConsumer(continuation, terminal)
          }
          precondition(
            state.consumer == nil,
            "Database row streams do not support concurrent next() calls"
          )
          state.consumer = continuation
          if let producer = state.producer.take() {
            return .resumeProducer(producer)
          }
          state.demandPending = true
          return .none
        }
        action.run()
      }
    } onCancel: {
      self.cancel()
    }
  }

  func waitForDemand() async -> Bool {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let action = self.state.withLockedValue { state -> BrokerAction in
          if state.terminal != nil {
            return .resumeProducerWithValue(continuation, false)
          }
          if state.demandPending {
            state.demandPending = false
            return .resumeProducerWithValue(continuation, true)
          }
          state.producer = continuation
          return .none
        }
        action.run()
      }
    } onCancel: {
      self.cancel()
    }
  }

  func deliver(_ result: Result<Element?, any Error>) {
    let action = self.state.withLockedValue { state -> BrokerAction in
      guard state.terminal == nil else {
        return .none
      }
      if case .success(nil) = result {
        state.terminal = result
      } else if case .failure = result {
        state.terminal = result
      }
      guard let consumer = state.consumer.take() else {
        preconditionFailure("A database row was produced without consumer demand")
      }
      return .resumeConsumer(consumer, result)
    }
    action.run()
  }

  func cancel() {
    let actions = self.state.withLockedValue { state -> [BrokerAction] in
      guard state.terminal == nil else {
        return []
      }
      let cancellation: Result<Element?, any Error> = .failure(CancellationError())
      state.terminal = cancellation
      var actions: [BrokerAction] = []
      if let consumer = state.consumer.take() {
        actions.append(.resumeConsumer(consumer, cancellation))
      }
      if let producer = state.producer.take() {
        actions.append(.resumeProducerWithValue(producer, false))
      }
      return actions
    }
    for action in actions {
      action.run()
    }
  }

  private enum BrokerAction {
    case none
    case resumeConsumer(
      CheckedContinuation<Element?, any Error>,
      Result<Element?, any Error>
    )
    case resumeProducer(CheckedContinuation<Bool, Never>)
    case resumeProducerWithValue(CheckedContinuation<Bool, Never>, Bool)

    func run() {
      switch self {
      case .none:
        break
      case .resumeConsumer(let continuation, let result):
        continuation.resume(with: result)
      case .resumeProducer(let continuation):
        continuation.resume(returning: true)
      case .resumeProducerWithValue(let continuation, let value):
        continuation.resume(returning: value)
      }
    }
  }
}

private final class DatabaseRowStreamTermination: Sendable {
  private struct State: Sendable {
    var operation: (@Sendable () -> Void)?
  }

  private let state: NIOLockedValueBox<State>

  init(_ operation: @escaping @Sendable () -> Void) {
    self.state = NIOLockedValueBox(State(operation: operation))
  }

  deinit {
    self.finish()
  }

  func finish() {
    let operation = self.state.withLockedValue { $0.operation.take() }
    operation?()
  }
}

extension Optional {
  fileprivate mutating func take() -> Wrapped? {
    defer { self = nil }
    return self
  }
}
