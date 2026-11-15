import { runProgram } from "./runner.js";

export function install(pi, run = runProgram, env = process.env) {
  const only = () => pi.setActiveTools(["factorio_eyg"]);
  pi.registerTool({
    name: "factorio_eyg",
    label: "Factorio EYG",
    description: `Run typed EYG directly; no files or commands. Host grants only gameplay effects, never shell, filesystem, network, imports or achievement confirmation. Endpoint, actor and limits belong to the operator.
Use Result matching: match perform InspectBot({}) {Ok(s)->{{success:True({}),bot:s.bot}} Error(e)->{{success:False({}),error:e}}}.
Discover argument/result shapes using: match perform DescribeEffect({name:"Build"}) {Ok(s)->{{argument:s.argument_json,result:s.result_json}} Error(e)->{{error:e}}}.
Effects: DescribeEffect, Inspect, InspectBot, InspectEntity, InspectResources, InspectAction, InspectSimulation, InspectRecipe, InspectArea, InspectTransport, InspectWater, InspectTechnology, InspectMachine, Craft, WalkTo, Mine, Rotate, Build, Transfer, TransferQuality, Wait, Stop, Research, SetChestLimit, BuildUnderground, SetRecipe, ConnectPower, MineObject, HandCraft.
Positions are integer half tiles x2/y2; observations are thousandths x_milli/y_milli. Inspect before changing anything. Stop dependent work on error. After uncertain outcomes inspect bot/action/inventories; do not replay mutations. At most 100 effects, 300s/run, 48000 UTF-8 source bytes. Return plain records, not raw Result variants.`,
    parameters: {type: "object", properties: {program: {type: "string", minLength: 1, maxLength: 48000}}, required: ["program"], additionalProperties: false},
    executionMode: "sequential",
    async execute(_id, params, signal) {
      if (Object.keys(params).length !== 1 || typeof params.program !== "string") throw new Error("Only program is accepted");
      const result = await run(params.program, {cwd: env.FACTORIO_EYG_PROJECT, env, signal});
      return {content: [{type: "text", text: JSON.stringify(result)}], details: result, isError: !result.success};
    },
  });
  pi.on("session_start", only);
  pi.on("before_agent_start", () => {
    only();
    return {message: {customType: "factorio-gameplay", content: "Gameplay-only mode: use factorio_eyg exclusively. Missing capabilities require an operator/development session; do not bypass the effect boundary.", display: false}};
  });
  pi.on("tool_call", (event) => {
    if (event.toolName !== "factorio_eyg") return {block: true, reason: "Gameplay-only session permits only factorio_eyg"};
  });
}

export default install;
