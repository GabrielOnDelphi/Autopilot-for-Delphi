<!-- BEGIN Kai -->
# Instructions: RAD Studio IDE Integration (Kai)

Prefer the Kai MCP tools over native Read/Write/Edit so unsaved IDE buffers stay in sync.

- **Files**: `getEditorLines` (preferred), `getEditorContent`, `applyEdit` (preferred), `setEditorContent`. Do not read or write the disk yourself.
- **Project**: create on disk, then `addFileToProject`. Remove with `removeFileFromProject` (do not delete from disk unless asked). `getProjectInfo`, `openProject`.
- **Debug**: `runProject`, `stepOver`, `stepInto`, `terminateProcess`, `getCallStack`, `evaluateExpression`, `addBreakpoint`, `removeBreakpoint`, `listBreakpoints`.
<!-- END Kai -->