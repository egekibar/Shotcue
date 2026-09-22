import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Payload of a library drag: the ids of the dragged tasks, in the order they were shown.
/// One item carries the whole selection, so dropping on a sidebar project moves every selected task.
///
/// The content type is `.json` on purpose. A private `UTType(exportedAs: "com.shotcue.app.task")`
/// registers its identifier at runtime but reports `conforms(to: .data) == false` until the bundle
/// declares it in `UTExportedTypeDeclarations` (measured on this machine, 2026-09-22), and
/// `CodableRepresentation` needs a data-backed type. `.json` is system-declared and data-conforming, so
/// it works with no Info.plist change. The cost is cosmetic: dragging a foreign `.json` file over a
/// project row highlights it, and the drop is rejected because decoding fails.
/// If Plan 06 ever adds the declaration, swap the content type and nothing else changes.
///
/// `Transferable` comes from CoreTransferable, which SwiftUI re-exports; importing SwiftUI keeps this
/// module inside its allowed import list.
public struct TaskDragItem: Codable, Transferable, Hashable, Sendable {
    public let taskIDs: [UUID]

    nonisolated public init(taskIDs: [UUID]) {
        self.taskIDs = taskIDs
    }

    /// `nonisolated` is required: `transferRepresentation` is evaluated in a nonisolated context and
    /// this module is MainActor-by-default.
    nonisolated public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
