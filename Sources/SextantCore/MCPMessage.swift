import Foundation

/// The JSON-RPC 2.0 error codes the MCP server answers with.
public enum JSONRPCErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
}

/// One line received by the MCP server, classified by the rules of JSON-RPC 2.0 as MCP revision
/// `MCPProtocol.revision` narrows them: a request id is a string or an integer and never null,
/// `params` is an object, and a batch (a JSON array) is not supported.
public enum MCPMessage {
    /// A request: it is answered, with a result or an error carrying `id`.
    case request(id: Any, method: String, params: [String: Any])
    /// A notification: it is never answered.
    case notification(method: String, params: [String: Any])
    /// A response from the client. The server sends no requests, so there is nothing to match it
    /// with, and a response is never answered.
    case response
    /// A line that is not a valid request. It is answered with this error; `id` is nil (sent as
    /// `null`) when the line has no id that could be read.
    case invalid(id: Any?, code: Int, message: String)

    public static func parse(_ line: String) -> MCPMessage {
        guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) else {
            return .invalid(id: nil, code: JSONRPCErrorCode.parseError, message: "Parse error: the line is not valid JSON")
        }
        if value is [Any] {
            return .invalid(id: nil, code: JSONRPCErrorCode.invalidRequest,
                            message: "Invalid Request: a batch (JSON array) is not supported in MCP \(MCPProtocol.revision); send one request per line")
        }
        guard let object = value as? [String: Any] else {
            return .invalid(id: nil, code: JSONRPCErrorCode.invalidRequest,
                            message: "Invalid Request: a request is a JSON object")
        }

        var id: Any?
        if let raw = object["id"] {
            guard let valid = validID(raw) else {
                return .invalid(id: nil, code: JSONRPCErrorCode.invalidRequest,
                                message: "Invalid Request: id must be a string or an integer, and not null")
            }
            id = valid
        }
        guard object["jsonrpc"] as? String == "2.0" else {
            return .invalid(id: id, code: JSONRPCErrorCode.invalidRequest,
                            message: "Invalid Request: jsonrpc must be \"2.0\"")
        }
        guard let rawMethod = object["method"] else {
            if id != nil, object["result"] != nil || object["error"] != nil { return .response }
            return .invalid(id: id, code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request: method is missing")
        }
        guard let method = rawMethod as? String else {
            return .invalid(id: id, code: JSONRPCErrorCode.invalidRequest, message: "Invalid Request: method must be a string")
        }
        let rawParams = object["params"]
        guard let id else {
            return .notification(method: method, params: rawParams as? [String: Any] ?? [:])
        }
        switch rawParams {
        case nil:
            return .request(id: id, method: method, params: [:])
        case let params as [String: Any]:
            return .request(id: id, method: method, params: params)
        case is [Any]:
            return .invalid(id: id, code: JSONRPCErrorCode.invalidParams,
                            message: "Invalid params: \(method) takes named params (an object), not an array")
        default:
            return .invalid(id: id, code: JSONRPCErrorCode.invalidRequest,
                            message: "Invalid Request: params must be an object")
        }
    }

    /// The id as given when it is a string or an integer; nil for null, a boolean, a fraction, or
    /// a structured value.
    static func validID(_ raw: Any) -> Any? {
        if raw is String { return raw }
        guard let number = raw as? NSNumber, !JSONValue.isBoolean(number),
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number
    }
}

/// What JSONSerialization produced, described in the words of JSON Schema.
enum JSONValue {
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Whether `value` is an instance of the JSON Schema type `type`.
    static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "string": return value is String
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "null": return value is NSNull
        case "boolean": return (value as? NSNumber).map(isBoolean) ?? false
        case "number":
            guard let number = value as? NSNumber, !isBoolean(number) else { return false }
            return number.doubleValue.isFinite
        case "integer":
            guard let number = value as? NSNumber, !isBoolean(number) else { return false }
            return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
        default: return false
        }
    }

    /// The JSON Schema type of `value`, for an error message.
    static func typeName(of value: Any) -> String {
        for type in ["null", "boolean", "integer", "number", "string", "array", "object"] where matches(value, type: type) {
            return type
        }
        return "unknown"
    }
}
