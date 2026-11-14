// CcinnPsql — a native StarRocks client for macOS.
// `CcinnPsql mcp …` runs the headless MCP server instead of the app.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "mcp" {
    MCPCommand.run(arguments: Array(arguments.dropFirst()))
} else {
    CcinnPsqlApp.main()
}
