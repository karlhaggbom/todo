import Testing
import Foundation
@testable import Todo

/// ADF (Atlassian Document Format) parsing and rendering.
@Suite struct ADFTests {
    private func decode(_ json: String) throws -> ADFDocument {
        try JSONDecoder().decode(ADFDocument.self, from: Data(json.utf8))
    }

    @Test func plainTextJoinsParagraphNodesWithNewlines() throws {
        let doc = try decode("""
        {"type":"doc","version":1,"content":[
          {"type":"paragraph","content":[{"type":"text","text":"first line"}]},
          {"type":"paragraph","content":[{"type":"text","text":"second line"}]}
        ]}
        """)
        #expect(doc.plainText == "first line\nsecond line")
    }

    @Test func plainTextRendersMentionNodeAsAtDisplayName() throws {
        let doc = try decode("""
        {"type":"doc","version":1,"content":[
          {"type":"paragraph","content":[
            {"type":"text","text":"ping "},
            {"type":"mention","attrs":{"id":"abc123","text":"@Kalle Haggbom"}},
            {"type":"text","text":" please look"}
          ]}
        ]}
        """)
        #expect(doc.plainText == "ping @Kalle Haggbom please look")
    }

    @Test func plainTextToleratesMentionWithDisplayNameFallback() throws {
        // Some Jira payloads / older clients carry displayName instead of text.
        let doc = try decode("""
        {"type":"doc","version":1,"content":[
          {"type":"paragraph","content":[
            {"type":"mention","attrs":{"id":"abc123","displayName":"Kalle Haggbom"}}
          ]}
        ]}
        """)
        #expect(doc.plainText == "@Kalle Haggbom")
    }

    @Test func plainTextHardBreakRendersAsNewline() throws {
        let doc = try decode("""
        {"type":"doc","version":1,"content":[
          {"type":"paragraph","content":[
            {"type":"text","text":"a"},{"type":"hardBreak"},{"type":"text","text":"b"}
          ]}
        ]}
        """)
        #expect(doc.plainText == "a\nb")
    }

    @Test func paragraphsFromCreatesOneNodePerLine() {
        let doc = ADFDocument.paragraphs(from: "alpha\nbeta\ngamma")
        #expect(doc.content?.count == 3)
        #expect(doc.plainText == "alpha\nbeta\ngamma")
    }

    @Test func paragraphsFromEmptyTextProducesSingleEmptyParagraph() {
        let doc = ADFDocument.paragraphs(from: "")
        #expect(doc.content?.count == 1, "an empty comment still needs a valid paragraph node")
        #expect(doc.plainText == "")
    }

    @Test func adfDocumentCodableRoundTripPreservesContent() throws {
        let original = ADFDocument.paragraphs(from: "hello\nworld")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ADFDocument.self, from: data)
        #expect(decoded.plainText == "hello\nworld")
    }

    // MARK: ADFBuilder (comment construction with mentions)

    @Test func adfBuilderConvertsRegisteredAtNameIntoMentionNode() throws {
        let doc = ADFBuilder.comment(from: "hey @Kalle Haggbom can you review", mentions: ["Kalle Haggbom": "acc-7"])
        let paragraph = try #require(doc.content?.first)
        #expect(paragraph.type == "paragraph")
        let nodes = paragraph.content ?? []
        #expect(nodes.count == 3, "text + mention + text")
        #expect(nodes[0].text == "hey ")
        #expect(nodes[1].type == "mention")
        #expect(nodes[1].attrs?["id"]?.stringValue == "acc-7", "mention must carry the accountId")
        #expect(nodes[1].attrs?["text"]?.stringValue == "@Kalle Haggbom", "mention must carry Jira's documented text attr")
        #expect(nodes[2].text == " can you review")
    }

    @Test func adfBuilderLeavesUnregisteredAtNameAsLiteralText() {
        let doc = ADFBuilder.comment(from: "ping @Stranger", mentions: [:])
        let nodes = doc.content?.first?.content ?? []
        #expect(nodes.filter { $0.type == "mention" }.count == 0, "unknown @name must NOT become a mention node")
        #expect(doc.plainText == "ping @Stranger")
    }

    @Test func adfBuilderMentionAtEndOfTextIsConsumedWithoutTrailingJunk() {
        let doc = ADFBuilder.comment(from: "fyi @Kalle", mentions: ["Kalle": "acc-1"])
        let nodes = doc.content?.first?.content ?? []
        #expect(nodes.count == 2, "text + mention, nothing else")
        #expect(nodes[1].type == "mention")
        #expect(doc.plainText == "fyi @Kalle")
    }

    @Test func adfBuilderEmailAtSignInNotMentioned() {
        // "user@example.com" contains an @-segment; not in the mentions map,
        // so it must stay literal text.
        let doc = ADFBuilder.comment(from: "mail me at user@example.com", mentions: [:])
        #expect(doc.plainText == "mail me at user@example.com")
        #expect((doc.content?.first?.content ?? []).filter { $0.type == "mention" }.count == 0)
    }
}