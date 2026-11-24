import { spawn } from "node:child_process";

const SOURCE_LIMIT = 48_000;
const REQUEST_LIMIT = 64_000;
const RESPONSE_LIMIT = 64_000;
const KILL_GRACE_MS = 2_000;

const rejected = (error, recovery_required = false) => ({
  success: false, error, value: null, artifact_dir: null, recovery_required,
});

export function runProgram(program, { cwd, env = process.env, signal, spawnProcess = spawn, timeout = 310_000 }) {
  // Validate before serializing: even malformed non-string callers get a result,
  // rather than JSON.stringify throwing on a bigint or circular object.
  if (typeof program !== "string" || !program.length || Buffer.byteLength(program) > SOURCE_LIMIT)
    return Promise.resolve(rejected("Program/request exceeds adapter limits"));
  const request = JSON.stringify({program});
  if (Buffer.byteLength(request) > REQUEST_LIMIT)
    return Promise.resolve(rejected("Program/request exceeds adapter limits"));
  if (!cwd) return Promise.resolve(rejected("Operator must set FACTORIO_EYG_PROJECT"));
  if (signal?.aborted) return Promise.resolve(rejected("Cancelled before submission"));

  return new Promise((resolve) => {
    let child;
    let timer;
    let killTimer;
    let finished = false;
    let closed = false;
    const chunks = [];
    let bytes = 0;

    const finish = (result) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", stop);
      resolve(result);
    };
    const stop = () => {
      if (finished) return;
      // Schedule escalation first: a synchronous close must cancel it too.
      killTimer = setTimeout(() => {
        if (!closed) child.kill("SIGKILL");
      }, KILL_GRACE_MS);
      finish(rejected("Run interrupted; outcome uncertain. Inspect world and retained artifacts before mutations; never replay automatically", true));
      child.kill("SIGTERM");
    };

    try {
      child = spawnProcess("mix", ["factorio.adapter"], {cwd, env, shell: false, stdio: ["pipe", "pipe", "pipe"]});
    } catch {
      finish(rejected("Adapter could not start; no program effects dispatched"));
      return;
    }

    child.stdout.on("data", (data) => {
      if (finished) return;
      bytes += data.length;
      if (bytes > RESPONSE_LIMIT) stop();
      else chunks.push(Buffer.from(data));
    });
    // Drain but never expose raw process diagnostics or inherited credentials.
    child.stderr.on("data", () => {});
    child.stdin.on("error", stop);
    child.on("error", () => {
      if (!child.pid) finish(rejected("Adapter could not start; no program effects dispatched"));
      else stop();
    });
    child.on("close", (code) => {
      closed = true;
      clearTimeout(killTimer);
      if (finished) return;
      if (code !== 0) return finish(rejected("Adapter exited unsuccessfully; inspect state before retrying", true));
      try {
        const result = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (!result || typeof result.success !== "boolean" || typeof result.error !== "string" || typeof result.recovery_required !== "boolean") throw new Error();
        finish(result);
      } catch {
        finish(rejected("Invalid adapter response; inspect state and artifacts before retrying", true));
      }
    });

    timer = setTimeout(stop, timeout);
    signal?.addEventListener("abort", stop, {once: true});
    if (signal?.aborted) stop();
    if (!finished) {
      try {
        child.stdin.end(request);
      } catch {
        stop();
      }
    }
  });
}
