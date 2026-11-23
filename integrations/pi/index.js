// Static host imports must pass through Pi’s extension loader/aliases.
import { Text } from "@earendil-works/pi-tui";
import { install } from "./core.js";
import { runProgram } from "./runner.js";
import { createRenderers } from "./render.js";

export { install, programExamples } from "./core.js";

export default function (pi) {
  install(pi, runProgram, process.env, createRenderers(Text));
}
