// Presentation only: the full source/result stay in Pi's transcript and artifacts.
const plain = (value, limit = 180) => String(value ?? "").replace(/[\x00-\x1f\x7f-\x9f]/g, " ").slice(0, limit);

function nestedFailure(value, depth = 0) {
  if (!value || typeof value !== "object" || depth > 12) return "";
  if (typeof value.error === "string" && value.error.length > 0) return value.error;
  if (value.success === false) return "Program reported failure";
  for (const child of Object.values(value)) {
    const error = nestedFailure(child, depth + 1);
    if (error) return error;
  }
  return "";
}

export function createRenderers(Text) {
  return {
    renderCall(args, theme, context) {
      const title = plain(args.purpose || "Run typed Factorio program", 120);
      let text = theme.fg("toolTitle", "Factorio · ") + title;
      if (context?.expanded) text += "\n" + (args.program || "");
      else text += theme.fg("dim", " · EYG collapsed");
      return new Text(text, 0, 0);
    },
    renderResult(result, {expanded, isPartial}, theme, context) {
      if (isPartial) return new Text(theme.fg("muted", "Running…"), 0, 0);
      const data = result.details;
      const warning = nestedFailure(data?.value);
      let status = !data || result.isError || data.success !== true ? "Evaluation failed" : "Evaluation completed";
      if (warning) status += " · nested operation failed";
      if (data?.recovery_required) status += " · RECOVERY REQUIRED — inspect before mutations";
      const color = !data || result.isError || data.success !== true ? "error" : warning ? "warning" : "muted";
      let text = theme.fg(color, status);
      if (data?.error) text += "\n" + plain(data.error, 300);
      else if (warning) text += "\n" + plain(warning, 300);
      if (data?.artifact_dir) text += "\n" + theme.fg("dim", "Artifacts: " + plain(data.artifact_dir, 300));
      if (expanded) {
        text += "\n" + (result.content || []).filter(c => c.type === "text").map(c => c.text).join("\n");
      } else {
        const hint = context?.keyHint?.("app.tools.expand", "to expand EYG/result");
        if (hint) text += "\n" + theme.fg("dim", hint);
      }
      return new Text(text, 0, 0);
    },
  };
}
