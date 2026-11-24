import {test} from "node:test";
import assert from "node:assert/strict";
import {EventEmitter} from "node:events";
import {PassThrough} from "node:stream";
import {runProgram} from "./runner.js";

const success = {success: true, error: "", recovery_required: false};

function processFixture() {
  const child = new EventEmitter();
  child.pid = 123;
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  const kills = [];
  child.kill = signal => {
    kills.push(signal);
    // Also exercise close during kill(), not only a later event-loop turn.
    child.emit("close", 143);
    return true;
  };
  return {child, kills, spawnProcess: () => child};
}

test("invalid input is rejected before serialization or process creation", async () => {
  const circular = {}; circular.self = circular;
  for (const program of [1n, circular, null, undefined, "", "a".repeat(48001), "\0".repeat(12000)]) {
    const result = await runProgram(program, {cwd: "/project", spawnProcess: () => assert.fail()});
    assert.equal(result.success, false);
    assert.equal(result.recovery_required, false);
  }
});

test("synchronous and asynchronous spawn failures do not imply dispatch", async () => {
  const options = {cwd: "/project"};
  const sync = await runProgram("{}", {...options, spawnProcess: () => {throw new Error("secret");}});
  const fixture = processFixture();
  delete fixture.child.pid;
  const pending = runProgram("{}", {...options, spawnProcess: fixture.spawnProcess});
  fixture.child.emit("error", new Error("secret"));
  fixture.child.emit("close", -2);
  const async = await pending;
  for (const result of [sync, async]) {
    assert.equal(result.success, false);
    assert.equal(result.recovery_required, false);
    assert.ok(!result.error.includes("secret"));
  }
});

test("late stream errors and cancellation cannot kill a completed run", async () => {
  const fixture = processFixture();
  const controller = new AbortController();
  const pending = runProgram("{}", {cwd: "/project", signal: controller.signal, spawnProcess: fixture.spawnProcess});
  fixture.child.stdout.write(JSON.stringify(success));
  fixture.child.emit("close", 0);
  assert.deepEqual(await pending, success);
  fixture.child.stdin.emit("error", new Error("late EPIPE"));
  fixture.child.emit("error", new Error("late error"));
  fixture.child.stdout.write(Buffer.alloc(64001));
  controller.abort();
  assert.deepEqual(fixture.kills, []);
});

test("stdin submission errors are normalized and terminate once without replay", async () => {
  const fixture = processFixture();
  let submissions = 0;
  fixture.child.stdin.end = () => {submissions++; throw new Error("secret");};
  const result = await runProgram("{}", {cwd: "/project", spawnProcess: fixture.spawnProcess});
  assert.equal(result.recovery_required, true);
  assert.equal(submissions, 1);
  assert.deepEqual(fixture.kills, ["SIGTERM"]);
  assert.ok(!result.error.includes("secret"));
});

test("output overflow cancels exactly once and ignores subsequent process errors", async () => {
  const fixture = processFixture();
  const pending = runProgram("{}", {cwd: "/project", spawnProcess: fixture.spawnProcess});
  fixture.child.stdout.write(Buffer.alloc(64001));
  fixture.child.stdin.emit("error", new Error("EPIPE"));
  fixture.child.emit("error", new Error("error"));
  assert.equal((await pending).recovery_required, true);
  assert.deepEqual(fixture.kills, ["SIGTERM"]);
});

test("cancellation escalates only while the child remains open", {timeout: 5000}, async () => {
  const fixture = processFixture();
  const controller = new AbortController();
  let confirmEscalation;
  const escalated = new Promise(resolve => {confirmEscalation = resolve;});
  fixture.child.kill = signal => {
    fixture.kills.push(signal);
    if (signal === "SIGKILL") {
      fixture.child.emit("close", 137);
      confirmEscalation();
    }
    return true;
  };
  const pending = runProgram("{}", {cwd: "/project", signal: controller.signal, spawnProcess: fixture.spawnProcess});
  controller.abort();
  assert.equal((await pending).recovery_required, true);
  assert.deepEqual(fixture.kills, ["SIGTERM"]);
  await escalated;
  assert.deepEqual(fixture.kills, ["SIGTERM", "SIGKILL"]);
});

test("nonzero exits and malformed responses preserve uncertainty", async () => {
  for (const [code, response] of [[1, ""], [0, "null"], [0, "{}"], [0, "not JSON"]]) {
    const fixture = processFixture();
    const pending = runProgram("{}", {cwd: "/project", spawnProcess: fixture.spawnProcess});
    fixture.child.stdout.write(response);
    fixture.child.emit("close", code);
    const result = await pending;
    assert.equal(result.success, false);
    assert.equal(result.recovery_required, true);
    assert.deepEqual(fixture.kills, []);
  }
});
