import Foundation
@main struct AssistantChecks {
    static func main() throws {
        let content = try HomeworkAIRequest.content(title: "Math", subject: "Algebra", instructions: "Solve x + 2 = 5", files: [])
        assert(content.count == 1 && content[0]["type"] as? String == "text")
        let answer = try HomeworkAIRequest.output(["status":"completed", "steps":[["type":"thought","content":[["type":"text","text":"hidden"]]], ["type":"model_output","content":[["type":"text","text":"x = 3"]]]]])
        assert(answer == "x = 3")
        for response: [String: Any] in [["status":"incomplete"], ["status":"requires_continuation"], ["status":"failed"], ["status":"completed","steps":[["type":"model_output","content":[["type":"refusal"]]]]], ["status":"completed","steps":[]]] {
            do { _ = try HomeworkAIRequest.output(response); fatalError("Invalid response accepted") } catch is AssistantError {}
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let txt = dir.appendingPathComponent("questions.txt")
        try "Question 1: 2+2?".write(to: txt, atomically: true, encoding: .utf8)
        let items = try HomeworkAIRequest.content(title:"Test",subject:"Math",instructions:"See file",files:[txt])
        assert(items.count == 2 && (items[1]["text"] as? String)?.contains("2+2") == true)
        for (ext, mime, type) in [("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "document"), ("pdf", "application/pdf", "document"), ("jpg", "image/jpeg", "image")] {
            let file = dir.appendingPathComponent("questions." + ext); try Data([1,2,3]).write(to: file)
            let parts = try HomeworkAIRequest.content(title:"T",subject:"S",instructions:"I",files:[file])
            let attachment = parts.last!
            assert(attachment["type"] as? String == type)
            assert(attachment["mime_type"] as? String == mime)
            assert(Data(base64Encoded: attachment["data"] as! String) == Data([1,2,3]))
        }
        for (name, data) in [("questions.zip", Data([1,2])), ("huge.pdf", Data(repeating:0, count:10_000_001))] {
            let bad = dir.appendingPathComponent(name); try data.write(to: bad)
            do { _ = try HomeworkAIRequest.content(title:"T",subject:"S",instructions:"I",files:[bad]); fatalError("Invalid file accepted") } catch is AssistantError {}
        }
        print("Passed: Gemini input encoding; DOCX, PDF and image payloads; final text only; incomplete/refusal rejection; file size and format limits.")
    }
}
