import SwiftUI

/// The navigation stack a module's root screen sits in. A `<Module>Screen` uses it instead of a
/// bare `NavigationStack` (sheets keep their own `NavigationStack`):
///
///     ModuleNavigationStack(path: $path) {
///         List { ... }
///             .navigationTitle("Jobs")
///             .navigationDestination(for: JobsRoute.self) { JobsDestination(route: $0) }
///     }
///
/// On the Mac it is a `NavigationStack`; keeping one wrapper leaves a single place to change if
/// the shell ever hosts modules differently.
struct ModuleNavigationStack<Route: Hashable, Root: View>: View {
    private let path: Binding<[Route]>?
    private let root: Root

    /// A stack the screen drives through `path` (deep links push onto it).
    init(path: Binding<[Route]>, @ViewBuilder root: () -> Root) {
        self.path = path
        self.root = root()
    }

    var body: some View {
        if let path {
            NavigationStack(path: path) { root }
        } else {
            NavigationStack { root }
        }
    }
}

extension ModuleNavigationStack where Route == Never {
    /// A stack with no path of the screen's own (links push by destination or by value).
    init(@ViewBuilder root: () -> Root) {
        self.path = nil
        self.root = root()
    }
}
