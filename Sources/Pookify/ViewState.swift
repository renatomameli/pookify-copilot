import Combine

/// View-local state container used instead of SwiftUI's `@State`.
///
/// Command Line Tools 27 expand `@State` as a macro but do not ship the SwiftUI macro plugin, so
/// `@State` cannot compile without a full Xcode installation. `@StateObject` with this box has
/// the same ownership semantics and builds with both toolchains.
final class ViewState<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
