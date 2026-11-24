// seance extension for Pi.
//
// Reports Pi's lifecycle to Emacs through bin/seance-hook, using the
// same events as Claude Code hooks.  Does nothing outside a terminal that
// seance tagged with SEANCE_ID.  See README.md.

import { spawn, spawnSync } from "node:child_process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function hookPath(): string {
  if (process.env.SEANCE_HOOK) return process.env.SEANCE_HOOK;
  // Follow a symlink in ~/.pi/agent/extensions back to the checkout.
  const here = realpathSync(fileURLToPath(import.meta.url));
  return join(dirname(here), "..", "bin", "seance-hook");
}

export default function (pi: ExtensionAPI) {
  if (!process.env.SEANCE_ID) return;
  const hook = hookPath();
  let running = false;
  // One hook at a time, so events reach Emacs in order.
  let queue = Promise.resolve();

  // Pi's process ID tells this agent apart from agents it runs itself,
  // which inherit the terminal's SEANCE_ID.
  function input(event: Record<string, unknown>): string {
    return JSON.stringify({ ...event, pid: process.pid });
  }

  function report(event: Record<string, unknown>) {
    queue = queue.then(
      () =>
        new Promise<void>((resolve) => {
          const child = spawn(hook, [], { stdio: ["pipe", "ignore", "ignore"] });
          child.on("error", () => resolve());
          child.on("close", () => resolve());
          child.stdin.on("error", () => {});
          child.stdin.end(input(event));
        }),
    );
  }

  type Model = { id: string; name: string };

  // The model and how much of the context window is used.  Pi reports
  // null tokens when it doesn't know, such as straight after a compaction.
  function reportInfo(
    ctx: {
      model: Model | undefined;
      getContextUsage(): { tokens: number | null; percent: number | null } | undefined;
    },
    model: Model | undefined = ctx.model,
  ) {
    const usage = ctx.getContextUsage();
    report({
      hook_event_name: "Info",
      model_name: model?.name || model?.id || null,
      context_tokens: usage?.tokens ?? null,
      context_percent: usage?.percent ?? null,
    });
  }

  pi.on("session_start", (_event, ctx) => {
    running = false;
    report({ hook_event_name: "SessionStart", cwd: ctx.cwd });
    reportInfo(ctx);
  });

  pi.on("turn_end", (_event, ctx) => {
    reportInfo(ctx);
  });

  pi.on("model_select", (event, ctx) => {
    reportInfo(ctx, event.model);
  });

  pi.on("agent_start", (_event, ctx) => {
    running = true;
    report({ hook_event_name: "UserPromptSubmit", cwd: ctx.cwd });
  });

  // A dialog from an extension, such as a confirmation before a tool runs.
  pi.on("ui_prompt_start", (event, ctx) => {
    report({
      hook_event_name: "Notification",
      notification_type: "ui_prompt",
      message: event.title ?? `Waiting on ${event.kind}`,
      cwd: ctx.cwd,
    });
  });

  pi.on("ui_prompt_end", (_event, ctx) => {
    report({ hook_event_name: running ? "UserPromptSubmit" : "Interrupt", cwd: ctx.cwd });
  });

  // Unlike agent_end, Pi will not carry on by itself after agent_settled.
  pi.on("agent_settled", (event, ctx) => {
    running = false;
    report({ hook_event_name: event.aborted ? "Interrupt" : "Stop", cwd: ctx.cwd });
    reportInfo(ctx);
  });

  // Other reasons replace the session, and session_start follows.  Pi
  // exits straight after a quit, so report it before returning.
  pi.on("session_shutdown", (event, ctx) => {
    if (event.reason !== "quit") return;
    spawnSync(hook, [], {
      input: input({ hook_event_name: "SessionEnd", cwd: ctx.cwd }),
      stdio: ["pipe", "ignore", "ignore"],
      timeout: 6000,
    });
  });
}
