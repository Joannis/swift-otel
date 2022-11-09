//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift OpenTelemetry open source project
//
// Copyright (c) 2021 Moritz Lang and the Swift OpenTelemetry project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

extension OTel {
    /// A log processor that simply forwards all *sampled* spans to a given exporter.
    public struct SimpleMetricsProcessor: OTelMetricsProcessor {
        private let exporter: OTelMetricsExporter
        
        /// Initialize a new no-op processor.
        ///
        /// - Parameter eventLoopGroup: The event loop group on which to shut down.
        public init(exporter: OTelMetricsExporter) {
            self.exporter = exporter
        }
        
        public func processMetric(_ metric: OTel.RecordedMetric) {
            _ = exporter.exportMetrics([metric])
        }
        
        public func shutdownGracefully() -> EventLoopFuture<Void> {
            exporter.shutdownGracefully()
        }
    }
}