import Foundation

// MARK: - Multipart (meals §2.1: field `photos`, filename `photo{n}.jpg`, `image/jpeg`)

struct MultipartFile: Sendable { let fieldName: String; let filename: String; let mimeType: String; let data: Data }

/// `multipart/form-data` body builder (RFC 7578). Text fields come first, then files in order.
struct MultipartFormData: Sendable {
    let boundary: String
    init(boundary: String = "NutriLog-\(UUID().uuidString)") { self.boundary = boundary }
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    func body(files: [MultipartFile], fields: [String: String] = [:]) -> Data {
        var out = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            out.append("--\(boundary)\r\n")
            out.append("Content-Disposition: form-data; name=\"\(Self.quoted(name))\"\r\n\r\n")
            out.append(value)
            out.append("\r\n")
        }
        for file in files {
            out.append("--\(boundary)\r\n")
            out.append("Content-Disposition: form-data; name=\"\(Self.quoted(file.fieldName))\"; filename=\"\(Self.quoted(file.filename))\"\r\n")
            out.append("Content-Type: \(file.mimeType)\r\n\r\n")
            out.append(file.data)
            out.append("\r\n")
        }
        out.append("--\(boundary)--\r\n")
        return out
    }

    /// Escapes a header parameter value: `"` → `%22`, CR/LF → `%0D`/`%0A` (WHATWG form encoding).
    private static func quoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A")
    }
}

private extension Data {
    mutating func append(_ string: String) { append(Data(string.utf8)) }
}
