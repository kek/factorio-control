import {test} from "node:test";
import assert from "node:assert/strict";
import {EventEmitter} from "node:events";
import {PassThrough} from "node:stream";
import {install, programExamples} from "./index.js";
import {runProgram} from "./runner.js";

function fakeSpawn(result, seen, hang = false) {
  return (exe, args, opts) => {
    seen.push({exe, args, opts});
    const child = new EventEmitter();
    child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
    child.kill = () => {queueMicrotask(() => child.emit("close", 143)); return true;};
    let request = "";
    child.stdin.on("data", (s) => request += s);
    child.stdin.on("finish", () => {
      seen[0].request = JSON.parse(request);
      if (!hang) queueMicrotask(() => {child.stdout.write(JSON.stringify(result)); child.emit("close", 0);});
    });
    return child;
  };
}

test("registers only EYG and blocks all alternate tools even when reenabled", async () => {
  const events = {}; const tools = []; const active = [];
  install({registerTool: t => tools.push(t), on: (n, f) => events[n] = f, setActiveTools: t => active.push(t)}, async () => ({success: true}), {FACTORIO_EYG_PROJECT: "/project"});
  assert.equal(tools.length, 1);
  for (const program of Object.values(programExamples))
    assert.ok(tools[0].description.includes(program), "advertise the typechecked examples verbatim");
  events.session_start(); events.before_agent_start();
  assert.deepEqual(active, [["factorio_eyg"], ["factorio_eyg"]]);
  for (const name of ["bash", "write", "read", "codemode", "mcp", "subagent", "unknown"])
    assert.equal(events.tool_call({toolName: name}).block, true);
  assert.equal(events.tool_call({toolName: "factorio_eyg"}), undefined);
  await assert.rejects(() => tools[0].execute("id", {program: "{}", effects: []}), /Only program/);
});

test("respawn is advertised only with the exact operator opt-in", () => {
  for (const setting of [undefined, "false", "1", "true"]) {
    let tool;
    install({registerTool: t => tool = t, on: () => {}, setActiveTools: () => {}}, async () => ({}), {FACTORIO_EYG_ALLOW_RESPAWN: setting});
    const effects = tool.description.split("Effects: ")[1].split("\n")[0];
    assert.equal(effects.includes("SpawnBot"), setting === "true");
    assert.ok(tool.description.includes(setting === "true" ? "SpawnBot is granted" : "SpawnBot is not granted"));
  }
});

test("fixed non-shell argv; source goes only to JSON stdin", async () => {
  const seen = [];
  const source = '"; touch /tmp/nope; $(whoami)"';
  const result = await runProgram(source, {cwd: "/project", env: {}, spawnProcess: fakeSpawn({success: true, error: "", recovery_required: false}, seen)});
  assert.equal(result.success, true);
  assert.equal(seen[0].exe, "mix");
  assert.deepEqual(seen[0].args, ["factorio.adapter"]);
  assert.equal(seen[0].opts.shell, false);
  assert.deepEqual(seen[0].request, {program: source});
});

test("rejects oversized request without spawning", async () => {
  const result = await runProgram("a".repeat(48001), {cwd: "/project", spawnProcess: () => assert.fail()});
  assert.equal(result.success, false);
  assert.equal(result.recovery_required, false);
});

test("timeout never retries and reports uncertainty", async () => {
  const seen = [];
  const result = await runProgram("{}", {cwd: "/project", timeout: 5, spawnProcess: fakeSpawn({}, seen, true)});
  assert.equal(result.recovery_required, true);
  assert.equal(seen.length, 1);
});

test("already aborted request never starts", async () => {
  const c = new AbortController(); c.abort();
  const result = await runProgram("{}", {cwd: "/project", signal: c.signal, spawnProcess: () => assert.fail()});
  assert.equal(result.recovery_required, false);
});
