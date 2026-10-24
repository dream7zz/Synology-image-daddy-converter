import Foundation

/// Multipart/form-data encoder for the one upload endpoint.
public struct MultipartFile {
    public let field: String
    public let filename: String
    public let mimeType: String
    public let data: Data
    public init(field: String, filename: String, mimeType: String = "image/jpeg", data: Data) {
        self.field = field
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct MultipartBody {
    public let boundary: String
    public let data: Data
    public let contentType: String

    public init(fields: [(String, String)], files: [MultipartFile], boundary: String? = nil) {
        let b = boundary ?? "----SIALite\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }

        for (name, value) in fields {
            append("--\(b)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        for f in files {
            append("--\(b)\r\n")
            append("Content-Disposition: form-data; name=\"\(f.field)\"; filename=\"\(f.filename)\"\r\n")
            append("Content-Type: \(f.mimeType)\r\n\r\n")
            body.append(f.data)
            append("\r\n")
        }
        append("--\(b)--\r\n")

        self.boundary = b
        self.data = body
        self.contentType = "multipart/form-data; boundary=\(b)"
    }
}

/// The recovered upload contract.
///
/// Reversed from the Synology Photos web client (`react_bundle.js`, fetched from
/// `/photo/webman/3rdparty/SynologyPhotos/react_bundle.js`), not guessed:
///
/// ```js
/// a = Yl("Upload.ConvertedFile", "upload", {}, version)
/// if (IsRelay) a.params._isRelay = true
/// formData = { _dataField: "film_h264", api, method, version, unit_id, ... }
/// ```
/// and the thumbnail variant builds:
/// ```js
/// s = { api, unit_id, thumb_xl, thumb_sm, thumb_m, film_h264, token }
/// ```
/// So the endpoint accepts three JPEG parts (`thumb_xl` 1280, `thumb_m` 320,
/// `thumb_sm` 240) and optionally a transcoded video part (`film_h264`).
/// We send only the JPEGs — no video transcode is required for a cover image.
public struct ConvertedFileUpload {
    public static let api = "SYNO.FotoTeam.Upload.ConvertedFile"
    public static let method = "upload"
    /// Recovered from the client's own version table, not from API.Info:
    ///   ConvertedFile: Object.freeze({list_convert_needed:3, set_broken:3, upload:3})
    /// API.Info advertises maxVersion 5, but the web client deliberately uses 3.
    public static let version = "3"

    public let unitID: Int
    public let token: String?
    public let parts: [MultipartFile]

    public init(unitID: Int, token: String?, xl: Data, m: Data, sm: Data) {
        self.unitID = unitID
        self.token = token
        let stem = "\(unitID)"
        self.parts = [
            MultipartFile(field: "thumb_xl", filename: "\(stem)_xl.jpg", data: xl),
            MultipartFile(field: "thumb_m", filename: "\(stem)_m.jpg", data: m),
            MultipartFile(field: "thumb_sm", filename: "\(stem)_sm.jpg", data: sm),
        ]
    }

    /// Fields the web client sends alongside the files.
    public func body(boundary: String? = nil) -> MultipartBody {
        var fields: [(String, String)] = [
            ("api", Self.api),
            ("method", Self.method),
            ("version", Self.version),
            ("unit_id", String(unitID)),
        ]
        // RB() adds the session token as a form field, not only as a header.
        if let token, !token.isEmpty { fields.append(("token", token)) }
        return MultipartBody(fields: fields, files: parts, boundary: boundary)
    }
}
