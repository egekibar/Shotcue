import Testing

@testable import ShotcueCore

@Suite("UnifiedDiffParser")
struct UnifiedDiffParserTests {
    @Test func modifiedFileNumbersEveryLineOnBothSides() throws {
        let text = """
            diff --git a/Sources/App.swift b/Sources/App.swift
            index 1111111..2222222 100644
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -10,4 +10,5 @@ struct App {
                 let a = 1
            -    let b = 2
            +    let b = 3
            +    let c = 4
                 return a
            """
        let document = UnifiedDiffParser.parse(text)
        #expect(document.files.count == 1)
        let file = try #require(document.files.first)
        #expect(file.path == "Sources/App.swift")
        #expect(file.fileName == "App.swift")
        #expect(file.directory == "Sources")
        #expect(file.status == .modified)
        #expect(file.additions == 2 && file.deletions == 1)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.header == "@@ -10,4 +10,5 @@ struct App {")
        #expect(
            hunk.lines == [
                DiffLine(kind: .context, text: "    let a = 1", oldNumber: 10, newNumber: 10),
                DiffLine(kind: .removed, text: "    let b = 2", oldNumber: 11, newNumber: nil),
                DiffLine(kind: .added, text: "    let b = 3", oldNumber: nil, newNumber: 11),
                DiffLine(kind: .added, text: "    let c = 4", oldNumber: nil, newNumber: 12),
                DiffLine(kind: .context, text: "    return a", oldNumber: 12, newNumber: 13),
            ])
        #expect(document.additions == 2 && document.deletions == 1)
        #expect(document.isTruncated == false)
    }

    @Test func addedDeletedAndRenamedFiles() throws {
        let text = """
            diff --git a/new.txt b/new.txt
            new file mode 100644
            index 0000000..ce01362
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1 @@
            +hello
            diff --git a/old.txt b/old.txt
            deleted file mode 100644
            index ce01362..0000000
            --- a/old.txt
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -bye
            -now
            diff --git a/a b.txt b/c d.txt
            similarity index 100%
            rename from a b.txt
            rename to c d.txt
            """
        let files = UnifiedDiffParser.parse(text).files
        #expect(files.map(\.path) == ["new.txt", "old.txt", "c d.txt"])
        #expect(files.map(\.status) == [.added, .deleted, .renamed])
        #expect(files[0].hunks[0].lines == [DiffLine(kind: .added, text: "hello", oldNumber: nil, newNumber: 1)])
        #expect(files[1].deletions == 2)
        #expect(files[1].hunks[0].lines.last == DiffLine(kind: .removed, text: "now", oldNumber: 2, newNumber: nil))
        #expect(files[2].oldPath == "a b.txt")
        #expect(files[2].hunks.isEmpty)
    }

    @Test func binaryFilesAndNamesWithSpacesWithoutHunks() {
        let text = """
            diff --git a/img/logo 2.png b/img/logo 2.png
            new file mode 100644
            index 0000000..e69de29
            Binary files /dev/null and b/img/logo 2.png differ
            diff --git a/empty.txt b/empty.txt
            new file mode 100644
            """
        let files = UnifiedDiffParser.parse(text).files
        #expect(files.map(\.path) == ["img/logo 2.png", "empty.txt"])
        #expect(files[0].isBinary && files[0].status == .added)
        #expect(files[1].isBinary == false && files[1].hunks.isEmpty)
    }

    @Test func pathsComeFromTheMarkerLinesWithTheirTrailingTabAndQuotingRemoved() {
        let text =
            "diff --git \"a/say \\\"hi\\\".md\" \"b/say \\\"hi\\\".md\"\n"
            + "--- \"a/say \\\"hi\\\".md\"\n+++ \"b/say \\\"hi\\\".md\"\n@@ -1 +1 @@\n-a\n+b\n"
            + "diff --git a/x y.txt b/x y.txt\n--- a/x y.txt\t\n+++ b/x y.txt\t\n@@ -1 +1 @@\n-a\n+b\n"
        let files = UnifiedDiffParser.parse(text).files
        #expect(files.map(\.path) == ["say \"hi\".md", "x y.txt"])
    }

    @Test func noNewlineMarkerIsKeptWithoutANumber() throws {
        let text = """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1,2 @@
            -first
            \\ No newline at end of file
            +first
            +second
            """
        let lines = try #require(UnifiedDiffParser.parse(text).files.first?.hunks.first?.lines)
        #expect(
            lines[1] == DiffLine(kind: .noNewline, text: "\\ No newline at end of file", oldNumber: nil, newNumber: nil)
        )
        #expect(lines.last == DiffLine(kind: .added, text: "second", oldNumber: nil, newNumber: 2))
    }

    @Test func aHunkLineStartingLikeAHeaderIsStillContent() throws {
        // `--- x` removed from a Markdown file must not start a new file header while the hunk expects lines.
        let text = """
            diff --git a/doc.md b/doc.md
            --- a/doc.md
            +++ b/doc.md
            @@ -1,2 +1,1 @@
            --- x
             keep
            """
        let file = try #require(UnifiedDiffParser.parse(text).files.first)
        #expect(file.hunks[0].lines.first == DiffLine(kind: .removed, text: "-- x", oldNumber: 1, newNumber: nil))
        #expect(file.deletions == 1)
    }

    @Test func truncationMarkerIsDetected() {
        let text =
            "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,3 +1,3 @@\n-x\n" + DiffText.truncationNotice(maxBytes: 9)
        let document = UnifiedDiffParser.parse(text)
        #expect(document.isTruncated)
        #expect(document.files.first?.hunks.first?.lines.count == 1)
    }

    @Test func emptyTextHasNoFiles() {
        #expect(UnifiedDiffParser.parse("").files.isEmpty)
        #expect(UnifiedDiffParser.parse("\n").isTruncated == false)
    }

    @Test func aFilesPatchTextRoundTripsItsHunks() throws {
        let text = """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,2 +1,2 @@
             keep
            -old
            \\ No newline at end of file
            +new
            """
        let file = try #require(UnifiedDiffParser.parse(text).files.first)
        #expect(
            file.patchText == "--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n keep\n-old\n\\ No newline at end of file\n+new")
        let added = DiffFile(id: 0, path: "n.txt", status: .added)
        #expect(added.patchText == "--- /dev/null\n+++ b/n.txt")
    }
}
