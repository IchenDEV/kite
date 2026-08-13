import Testing
@testable import Kite

@Suite("Add task options")
struct AddTaskOptionsTests {
    @Test("Selected container files are serialized in aria2 index order")
    func selectedFiles() {
        var options = AddTaskOptions(directory: "/tmp/downloads")
        options.selectedFileIndices = [4, 1, 3]

        #expect(options.aria2Options["select-file"] == .string("1,3,4"))
    }

    @Test("An empty file selection is never sent as an aria2 option")
    func emptySelection() {
        var options = AddTaskOptions(directory: "/tmp/downloads")
        options.selectedFileIndices = []

        #expect(options.aria2Options["select-file"] == nil)
    }
}
