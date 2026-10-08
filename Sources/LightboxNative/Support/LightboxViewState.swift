import SwiftUI

// The macOS 27 SDK resolves @State to a macro whose SwiftUIMacros plug-in
// is absent from Command Line Tools 27. Keep the existing property-wrapper
// semantics (including _state initialization and $state bindings) on all
// supported systems, without requiring a full Xcode installation.
typealias LightboxViewState<Value> = SwiftUI.State<Value>
