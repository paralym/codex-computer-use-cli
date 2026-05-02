import MCP
import CodexCUCore
import AppKit
import Foundation

// MARK: - Value helpers

extension Value {
    var intValue: Int? {
        switch self {
        case .int(let n): return n
        case .double(let n): return Int(n)
        default: return nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case .double(let n): return n
        case .int(let n): return Double(n)
        default: return nil
        }
    }
    var stringValue: String? {
        switch self {
        case .string(let s): return s
        default: return nil
        }
    }
}

func parseTarget(from args: [String: Value]?) -> ElementTarget? {
    if let idx = args?["index"]?.intValue { return .index(idx) }
    if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
        return .coordinates(x: x, y: y)
    }
    return nil
}

func toMCP(_ result: ToolResult) -> CallTool.Result {
    var content: [Tool.Content] = []
    for item in result.content {
        switch item {
        case .text(let text):
            content.append(.text(text: text, annotations: nil, _meta: nil))
        case .image(let base64, let mimeType):
            content.append(.image(data: base64, mimeType: mimeType, annotations: nil, _meta: nil))
        }
    }
    return .init(content: content, isError: result.isError)
}

func errText(_ msg: String) -> CallTool.Result {
    .init(content: [.text(text: msg, annotations: nil, _meta: nil)], isError: true)
}

// MARK: - Server setup

fputs("[MCP] codex-computer-use server starting\n", stderr)

let router = ToolRouter()

let server = Server(
    name: "codex-computer-use",
    version: "1.0.0",
    capabilities: .init(tools: .init(listChanged: false))
)

let tools: [Tool] = [
    Tool(name: "list_apps", description: "List all running applications", inputSchema: .object(["type": .string("object")])),
    Tool(name: "launch_app", description: "Launch an application by name", inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["app_name": .object(["type": .string("string")])]),
        "required": .array([.string("app_name")])
    ])),
    Tool(name: "activate_app", description: "Bring an application to the foreground", inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["app_name": .object(["type": .string("string")])]),
        "required": .array([.string("app_name")])
    ])),
    Tool(name: "get_app_state", description: "Capture screenshot + AX tree. Returns numbered element indices and a screenshot image. Always call before interacting with an app.", inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["app_name": .object(["type": .string("string")])]),
        "required": .array([.string("app_name")])
    ])),
    Tool(name: "click", description: "Click element by index or x,y coordinates. Single clicks use AX actions (zero activation). Double clicks use synthetic focus with visual masking.", inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "index": .object(["type": .string("integer"), "description": .string("Element index from AX tree")]),
            "x": .object(["type": .string("number"), "description": .string("X screen coordinate")]),
            "y": .object(["type": .string("number"), "description": .string("Y screen coordinate")]),
            "button": .object(["type": .string("string"), "enum": .array([.string("left"), .string("right")])]),
            "click_count": .object(["type": .string("integer")])
        ])
    ])),
    Tool(name: "type_text", description: "Type text into the focused element. Uses HID keyboard via synthetic focus. Call get_app_state first to set target app.", inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
        "required": .array([.string("text")])
    ])),
    Tool(name: "press_key", description: "Press a key combination (xdotool syntax). Examples: Return, super+c, ctrl+shift+a, Tab, Escape", inputSchema: .object([
        "type": .string("object"),
        "properties": .object(["key": .object(["type": .string("string")])]),
        "required": .array([.string("key")])
    ])),
    Tool(name: "scroll", description: "Scroll at an element or coordinates", inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "index": .object(["type": .string("integer")]),
            "x": .object(["type": .string("number")]),
            "y": .object(["type": .string("number")]),
            "direction": .object(["type": .string("string"), "enum": .array([.string("up"), .string("down"), .string("left"), .string("right")])]),
            "pages": .object(["type": .string("number")])
        ]),
        "required": .array([.string("direction")])
    ])),
    Tool(name: "drag", description: "Drag between two screen coordinates", inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "start_x": .object(["type": .string("number")]),
            "start_y": .object(["type": .string("number")]),
            "end_x": .object(["type": .string("number")]),
            "end_y": .object(["type": .string("number")])
        ]),
        "required": .array([.string("start_x"), .string("start_y"), .string("end_x"), .string("end_y")])
    ])),
    Tool(name: "set_value", description: "Set element value directly via AX API. Reliable for native text fields. Call get_app_state first.", inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "index": .object(["type": .string("integer")]),
            "value": .object(["type": .string("string")])
        ]),
        "required": .array([.string("index"), .string("value")])
    ])),
]

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: tools)
}

await server.withMethodHandler(CallTool.self) { params in
    let args = params.arguments
    fputs("[MCP] tools/call: \(params.name)\n", stderr)

    switch params.name {
    case "list_apps":
        return toMCP(await router.listApps())
    case "launch_app":
        guard let name = args?["app_name"]?.stringValue else { return errText("Missing app_name") }
        return toMCP(await router.launchApp(name: name))
    case "activate_app":
        guard let name = args?["app_name"]?.stringValue else { return errText("Missing app_name") }
        return toMCP(await router.activateApp(name: name))
    case "get_app_state":
        guard let name = args?["app_name"]?.stringValue else { return errText("Missing app_name") }
        return toMCP(await router.getAppState(appName: name))
    case "click":
        guard let t = parseTarget(from: args) else { return errText("Provide index or x+y") }
        let button = MouseButton(rawValue: args?["button"]?.stringValue ?? "left") ?? .left
        let count = args?["click_count"]?.intValue ?? 1
        return toMCP(await router.click(target: t, button: button, clickCount: count))
    case "type_text":
        guard let text = args?["text"]?.stringValue else { return errText("Missing text") }
        return toMCP(await router.typeText(text))
    case "press_key":
        guard let key = args?["key"]?.stringValue else { return errText("Missing key") }
        return toMCP(await router.pressKey(key))
    case "scroll":
        guard let dirStr = args?["direction"]?.stringValue,
              let dir = ScrollDirection(rawValue: dirStr) else { return errText("Missing direction") }
        let pages = args?["pages"]?.doubleValue ?? 1.0
        guard let t = parseTarget(from: args) else { return errText("Provide index or x+y") }
        return toMCP(await router.scroll(target: t, direction: dir, pages: pages))
    case "drag":
        guard let sx = args?["start_x"]?.doubleValue, let sy = args?["start_y"]?.doubleValue,
              let ex = args?["end_x"]?.doubleValue, let ey = args?["end_y"]?.doubleValue else {
            return errText("Missing coordinates")
        }
        return toMCP(await router.drag(startX: sx, startY: sy, endX: ex, endY: ey))
    case "set_value":
        guard let index = args?["index"]?.intValue, let value = args?["value"]?.stringValue else {
            return errText("Missing index or value")
        }
        return toMCP(await router.setValue(index: index, value: value))
    default:
        return errText("Unknown tool: \(params.name)")
    }
}

// MARK: - Start

let serverTask = Task {
    let transport = StdioTransport()
    try await server.start(transport: transport)
    fputs("[MCP] Server ready\n", stderr)
    await server.waitUntilCompleted()
}

// Keep main alive while server runs
while !serverTask.isCancelled {
    try? await Task.sleep(for: .seconds(1))
}
