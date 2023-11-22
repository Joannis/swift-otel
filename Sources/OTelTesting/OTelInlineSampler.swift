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

import OpenTelemetry
import Tracing

public struct OTelInlineSampler: OTelSampler {
    private let onSamplingResult: (
        _ operationName: String,
        _ kind: SpanKind,
        _ traceID: OTelTraceID,
        _ attributes: SpanAttributes,
        _ links: [SpanLink],
        _ parentContext: ServiceContext
    ) -> OTelSamplingResult

    public init(
        onSamplingResult: @escaping (
            _ operationName: String,
            _ spanKind: SpanKind,
            _ traceID: OTelTraceID,
            _ attributes: SpanAttributes,
            _ links: [SpanLink],
            _ parentContext: ServiceContext
        ) -> OTelSamplingResult
    ) {
        self.onSamplingResult = onSamplingResult
    }

    public func samplingResult(
        operationName: String,
        kind: SpanKind,
        traceID: OTelTraceID,
        attributes: SpanAttributes,
        links: [SpanLink],
        parentContext: ServiceContext
    ) -> OTelSamplingResult {
        onSamplingResult(operationName, kind, traceID, attributes, links, parentContext)
    }
}
