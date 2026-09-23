import SwiftUI

/// Stand-in for `@State`, which cannot be used with Command Line Tools.
///
/// In the macOS 27 SDK `SwiftUI.State` is declared both as a struct and as an attached macro
/// (`#externalMacro(module: "SwiftUIMacros", type: "StateMacro")`). CLT ships no `SwiftUIMacros`
/// plugin and `-load-plugin-library` cannot help because the dylib does not exist, so writing
/// `@State` fails with "external macro implementation type ... could not be found" — the same failure
/// class as `#Preview`. A type alias refers to the struct, so the macro is never considered:
///
///     @UIState private var isPresented = false
///     ...
///     .popover(isPresented: $isPresented) { ... }
///
/// Prefer putting mutable state in an `@Observable` store; reach for `@UIState` only for state that is
/// genuinely private to one view. `@FocusState`, `@Binding`, `@Environment`, `@Bindable`,
/// `@AppStorage`, `@Namespace` and `@Observable` are unaffected and are used directly.
public typealias UIState<Value> = SwiftUI.State<Value>
