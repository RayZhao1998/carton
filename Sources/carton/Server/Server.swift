// Copyright 2020 Carton contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CartonHelpers
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif
import SwiftToolchain
import TSCBasic
import Vapor

/// This `Hashable` conformance is required to handle simulatenous connections with `Set<WebSocket>`
extension WebSocket: Hashable {
  public static func == (lhs: WebSocket, rhs: WebSocket) -> Bool {
    lhs === rhs
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

final class Server {
  private var connections = Set<WebSocket>()
  private var subscriptions = [AnyCancellable]()
  private let watcher: Watcher
  private var builder: ProcessRunner?
  private let app: Application

  init(
    builderArguments: [String],
    pathsToWatch: [AbsolutePath],
    mainWasmPath: AbsolutePath,
    customIndexContent: String?,
    package: SwiftToolchain.Package,
    verbose: Bool,
    _ terminal: InteractiveWriter,
    port: Int
  ) throws {
    watcher = try Watcher(pathsToWatch)

    var env = Environment(name: verbose ? "development" : "production", arguments: ["vapor"])
    try LoggingSystem.bootstrap(from: &env)
    app = Application(env)
    app.configure(
      port: port,
      mainWasmPath: mainWasmPath,
      customIndexContent: customIndexContent,
      package: package,
      onWebSocketOpen: { [weak self] in
        self?.connections.insert($0)
      },
      onWebSocketClose: { [weak self] in
        self?.connections.remove($0)
      }
    )

    watcher.publisher
      .flatMap(maxPublishers: .max(1)) { changes -> AnyPublisher<String, Never> in
        if !verbose {
          terminal.homeAndClear()
        }
        terminal.write("\nThese paths have changed, rebuilding...\n", inColor: .yellow)
        for change in changes.map(\.pathString) {
          terminal.write("- \(change)\n", inColor: .cyan)
        }
        return ProcessRunner(builderArguments, terminal)
          .publisher
          .handleEvents(receiveCompletion: { [weak self] in
            guard case .finished = $0 else { return }

            terminal.write("\nBuild completed successfully\n", inColor: .green, bold: false)
            terminal.logLookup("The app is currently hosted at ", "http://127.0.0.1:\(port)/")
            self?.connections.forEach { $0.send("reload") }
          })
          .catch { _ in Empty().eraseToAnyPublisher() }
          .eraseToAnyPublisher()
      }
      .sink(receiveValue: { _ in })
      .store(in: &subscriptions)
  }

  /// Blocking function that starts the HTTP server
  func run() throws {
    defer { app.shutdown() }
    try app.run()
    for conn in connections {
      try conn.close().wait()
    }
  }
}
