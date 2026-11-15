import { spawn } from "node:child_process";

export function runProgram(program, { cwd, env = process.env, signal, spawnProcess = spawn, timeout = 310_000 }) {
  const rejected = (error, recovery_required = false) => ({success: false, error, value: null, artifact_dir: null, recovery_required});
  const request = JSON.stringify({program});
  if (typeof program !== "string" || Buffer.byteLength(program) > 48_000 || !program.length || Buffer.byteLength(request) > 64_000)
    return Promise.resolve(rejected("Program/request exceeds adapter limits"));
  if (!cwd) return Promise.resolve(rejected("Operator must set FACTORIO_EYG_PROJECT"));
  if (signal?.aborted) return Promise.resolve(rejected("Cancelled before submission"));

  return new Promise((resolve) => {
    let child;
    const chunks = [];
    let bytes = 0;
    let stopped = false;
    let killTimer;
    const finish = (result) => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      resolve(result);
    };
    const stop = () => {
      if (stopped) return;
      stopped = true;
      child.kill("SIGTERM");
      killTimer = setTimeout(() => child.kill("SIGKILL"), 2000);
      finish(rejected("Run interrupted; outcome uncertain. Inspect world and retained artifacts before mutations; never replay automatically", true));
    };
    const abort = () => stop();
    const timer = setTimeout(stop, timeout);
    try {
      child = spawnProcess("mix", ["factorio.adapter"], {cwd, env, shell: false, stdio: ["pipe", "pipe", "pipe"]});
    } catch {
      finish(rejected("Adapter could not start"));
      return;
    }
    signal?.addEventListener("abort", abort, {once: true});
    if (signal?.aborted) stop();
    child.stdout.on("data", (data) => {
      bytes += data.length;
      if (bytes > 64_000) stop();
      else chunks.push(Buffer.from(data));
    });
    // Drain but never expose raw process diagnostics or inherited credentials.
    child.stderr.on("data", () => {});
    child.stdin.on("error", () => stop());
    child.on("error", () => finish(rejected("Adapter process failed; inspect state before retrying", true)));
    child.on("close", (code) => {
      clearTimeout(killTimer);
      if (stopped) return;
      if (code !== 0) return finish(rejected("Adapter exited unsuccessfully; inspect state before retrying", true));
      try {
        const result = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        if (typeof result.success !== "boolean" || typeof result.error !== "string" || typeof result.recovery_required !== "boolean") throw new Error();
        finish(result);
      } catch {
        finish(rejected("Invalid adapter response; inspect state and artifacts before retrying", true));
      }
    });
    if (!stopped) child.stdin.end(request);
  });
}
