# mcp-shim (P1.7)

A ~100-line Node MCP server that exposes `profile`, `fill`, `read_values`, and `eval` as
tools by shelling out to the `scribeski` CLI. Dev only, never shipped. It must not
reimplement the Safari transport; that lives in `Sources/FormDriver` alone.
