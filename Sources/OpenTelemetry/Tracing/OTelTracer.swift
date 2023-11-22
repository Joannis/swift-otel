//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift OTel open source project
//
// Copyright (c) 2023 Moritz Lang and the Swift OTel project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Logging
import ServiceLifecycle
import Tracing

/// An OpenTelemetry tracer implementing the Swift Distributed Tracing `Tracer` protocol.
///
/// [OpenTelemetry Specification: Tracer](https://github.com/open-telemetry/opentelemetry-specification/blob/v1.20.0/specification/trace/api.md#tracer)
public final class OTelTracer<
    IDGenerator: OTelIDGenerator,
    Sampler: OTelSampler,
    Propagator: OTelPropagator,
    Processor: OTelSpanProcessor
>: @unchecked Sendable {
    private var _idGenerator: IDGenerator
    private let idGeneratorLock = ReadWriteLock()

    private let sampler: Sampler
    private let propagator: Propagator
    private let processor: Processor
    private let logger = Logger(label: "OTelTracer")

    private let eventStream: AsyncStream<Event>
    private let eventStreamContinuation: AsyncStream<Event>.Continuation

    /// Create a new tracer.
    ///
    /// - Parameters:
    ///   - idGenerator: The generator used to create trace/span IDs.
    ///   - sampler: The sampler deciding whether to process/export spans.
    ///   - propagator: The propagator injecting/extracting span contexts.
    ///   - processor: The processor handling started/ended spans.
    public init(idGenerator: IDGenerator, sampler: Sampler, propagator: Propagator, processor: Processor) {
        _idGenerator = idGenerator
        self.sampler = sampler
        self.propagator = propagator
        self.processor = processor

        (eventStream, eventStreamContinuation) = AsyncStream.makeStream()
    }

    private enum Event {
        case spanStarted(_ span: OTelSpan, parentContext: ServiceContext)
        case spanEnded(_ span: OTelFinishedSpan)
        case forceFlushed
    }
}

extension OTelTracer: Service {
    public func run() async throws {
        try await withGracefulShutdownHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.processor.run()
                    self.logger.debug("Shut down.")
                }

                group.addTask {
                    for await event in self.eventStream {
                        switch event {
                        case .spanStarted(let span, let parentContext):
                            await self.processor.onStart(span, parentContext: parentContext)
                        case .spanEnded(let span):
                            await self.processor.onEnd(span)
                        case .forceFlushed:
                            try? await self.processor.forceFlush()
                        }
                    }

                    self.logger.debug("Shutting down.")
                }

                try await group.waitForAll()
            }
        } onGracefulShutdown: {
            self.eventStreamContinuation.finish()
        }
    }
}

extension OTelTracer: Tracer {
    public func startSpan(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> some TracerInstant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> OTelSpan {
        let parentContext = context()
        var childContext = parentContext

        let traceID: OTelTraceID
        let traceState: OTelTraceState?
        let spanID = idGeneratorLock.withWriterLock { _idGenerator.spanID() }

        if let parentSpanContext = parentContext.spanContext {
            traceID = parentSpanContext.traceID
            traceState = parentSpanContext.traceState
        } else {
            traceID = idGeneratorLock.withWriterLock { _idGenerator.traceID() }
            traceState = nil
        }

        let samplingResult = sampler.samplingResult(
            operationName: operationName,
            kind: kind,
            traceID: traceID,
            attributes: [:],
            links: [],
            parentContext: parentContext
        )
        let traceFlags: OTelTraceFlags = samplingResult.decision == .recordAndSample ? .sampled : []
        let spanContext = OTelSpanContext(
            traceID: traceID,
            spanID: spanID,
            parentSpanID: parentContext.spanContext?.spanID,
            traceFlags: traceFlags,
            traceState: traceState,
            isRemote: false
        )
        childContext.spanContext = spanContext

        let span: OTelSpan = {
            guard samplingResult.decision != .drop else {
                return .noOp(NoOpTracer.NoOpSpan(context: childContext))
            }

            return .recording(
                operationName: operationName,
                kind: kind,
                context: childContext,
                spanContext: spanContext,
                attributes: samplingResult.attributes,
                startTimeNanosecondsSinceEpoch: instant().nanosecondsSinceEpoch,
                onEnd: { [weak self] span in
                    self?.eventStreamContinuation.yield(.spanEnded(span))
                }
            )
        }()

        eventStreamContinuation.yield(.spanStarted(span, parentContext: parentContext))

        return span
    }

    public func forceFlush() {
        eventStreamContinuation.yield(.forceFlushed)
    }
}

extension OTelTracer: Instrument {
    public func inject<Carrier, Inject>(
        _ context: ServiceContext,
        into carrier: inout Carrier,
        using injector: Inject
    ) where Carrier == Inject.Carrier, Inject: Injector {
        guard let spanContext = context.spanContext else { return }
        propagator.inject(spanContext, into: &carrier, using: injector)
    }

    public func extract<Carrier, Extract>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    ) where Carrier == Extract.Carrier, Extract: Extractor {
        do {
            context.spanContext = try propagator.extractSpanContext(from: carrier, using: extractor)
        } catch {
            logger.debug("Failed to extract span context.", metadata: [
                "carrier": "\(carrier)",
                "error_type": "\(type(of: error))",
                "error_description": "\(error)",
            ])
        }
    }
}

extension OTelTracer: CustomStringConvertible {
    public var description: String { "OTelTracer" }
}
