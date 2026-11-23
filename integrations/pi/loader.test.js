import {test} from "node:test";
import assert from "node:assert/strict";
import {resolve} from "node:path";
import {pathToFileURL} from "node:url";

// Opt-in uses the actual installed Pi loader and its host-owned TUI dependency.
// No model call, game connection, credentials or local pi-tui install is needed.
test("real Pi loader activates compact renderers without checkout dependencies", {skip: !process.env.PI_EXTENSION_LOADER}, async () => {
  const {loadExtensions} = await import(pathToFileURL(resolve(process.env.PI_EXTENSION_LOADER)).href);
  const cwd = resolve(import.meta.dirname, "../..");
  const loaded = await loadExtensions([resolve(cwd, "integrations/pi/index.js")], cwd);
  assert.deepEqual(loaded.errors, []);
  assert.equal(loaded.extensions.length, 1);
  assert.deepEqual([...loaded.extensions[0].tools.keys()], ["factorio_eyg"]);
  const tool = loaded.extensions[0].tools.get("factorio_eyg").definition;
  const theme = {fg: (_color, value) => value};
  const args = {purpose: "Inspect science inputs", program: "perform InspectBot({})"};
  const call = tool.renderCall(args, theme, {expanded: false});
  assert.ok(!call.render(80).join("\n").includes(args.program));
  assert.ok(tool.renderCall(args, theme, {expanded: true}).render(80).join("\n").includes(args.program));
  const result = {details: {success: true, error: "", value: {}, artifact_dir: "tmp/run", recovery_required: false}, content: [{type: "text", text: "FULL RESULT"}]};
  const context = {keyHint: () => "ctrl+o to expand"};
  const small = tool.renderResult(result, {}, theme, context);
  assert.ok(!small.render(80).join("\n").includes("FULL RESULT"));
  assert.ok(small.render(24).every(line => line.length <= 24));
  assert.ok(tool.renderResult(result, {expanded: true}, theme, context).render(80).join("\n").includes("FULL RESULT"));
});
