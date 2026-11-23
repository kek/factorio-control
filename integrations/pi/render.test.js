import {test} from "node:test";
import assert from "node:assert/strict";
import {createRenderers} from "./render.js";
import {install} from "./core.js";

class Text { constructor(text) { this.text = text; } }
const theme = {fg: (_color, text) => text};
const renderers = createRenderers(Text);
const context = {keyHint: (_key, label) => `ctrl+o ${label}`};
const result = {details: {success: true, error: "", value: {schema: "huge schema"}, artifact_dir: "tmp/run", recovery_required: false}, content: [{type: "text", text: "FULL RESULT"}]};

test("call hides EYG by default and expands without changing source", () => {
  const args = {purpose: "Inspect science inputs", program: "perform InspectBot({})"};
  const small = renderers.renderCall(args, theme, {}).text;
  assert.ok(small.includes(args.purpose));
  assert.ok(!small.includes(args.program));
  assert.ok(renderers.renderCall(args, theme, {expanded: true}).text.includes(args.program));
  assert.ok(renderers.renderCall({program: "{}"}, theme, {}).text.includes("Run typed Factorio program"));
});

test("compact result retains artifact link and expansion hint, not raw JSON", () => {
  const small = renderers.renderResult(result, {}, theme, context).text;
  assert.ok(small.includes("Evaluation completed"));
  assert.ok(small.includes("tmp/run"));
  assert.ok(small.includes("ctrl+o"));
  assert.ok(!small.includes("FULL RESULT"));
  assert.ok(renderers.renderResult(result, {expanded: true}, theme, context).text.includes("FULL RESULT"));
});

test("errors, recovery and nested failures stay visible when collapsed", () => {
  const failed = {...result, isError: true, details: {...result.details, success: false, error: "timeout", recovery_required: true}};
  const small = renderers.renderResult(failed, {}, theme, context).text;
  assert.ok(small.includes("timeout"));
  assert.ok(small.includes("RECOVERY REQUIRED"));
  const nested = {...result, details: {...result.details, value: {bot: {success: false, error: "no_character"}}}};
  assert.ok(renderers.renderResult(nested, {}, theme, context).text.includes("nested operation failed"));
  assert.ok(renderers.renderResult(result, {isPartial: true}, theme, context).text.includes("Running"));
  assert.ok(renderers.renderResult({content: []}, {}, theme, context).text.includes("failed"));
});

test("purpose is presentation only and never reaches executor", async () => {
  let tool, seen;
  install({registerTool: t => tool = t, on: () => {}, setActiveTools: () => {}}, async (...args) => {seen = args; return result.details;}, {}, renderers);
  assert.equal(tool.renderCall, renderers.renderCall);
  assert.equal(tool.renderResult, renderers.renderResult);
  await tool.execute("id", {purpose: "Inspect inputs", program: "{}"});
  assert.equal(seen[0], "{}");
  assert.ok(!("purpose" in seen[1]));
  for (const purpose of ["", " ", "x".repeat(121), 42])
    await assert.rejects(() => tool.execute("id", {purpose, program: "{}"}), /purpose/);
});

test("intent labels cannot inject terminal escape sequences or lines", () => {
  const text = renderers.renderCall({purpose: "Inspect\n\x1b[2Jinputs"}, theme, {}).text;
  assert.ok(!text.includes("\x1b"));
  assert.ok(!text.includes("\n"));
});
