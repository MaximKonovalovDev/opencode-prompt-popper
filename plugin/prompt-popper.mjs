// Prompt Popper plugin — premade prompts as agent tools.
// Works in Opencode Desktop, TUI, and web: tools run model-side, unlike
// TUI-only prompt events. Lets the agent pull your premade prompts by name,
// e.g. "use the pp-fix prompt on these errors".
// The tray app + /pp-* slash commands cover the human side.

import { tool } from "@opencode-ai/plugin"
import { readFileSync, existsSync } from "node:fs"
import { join } from "node:path"
import { homedir } from "node:os"

function loadPrompts() {
  const file = join(homedir(), ".config", "opencode", "prompt-popper", "prompts.json")
  if (!existsSync(file)) throw new Error("prompts.json not found — run install-global first")
  const json = JSON.parse(readFileSync(file, "utf8"))
  return json.prompts ?? []
}

export const PromptPopperPlugin = async (_ctx) => {
  return {
    tool: {
      pp_list: tool({
        description: "List all Prompt Popper premade prompts (label, slash command, hotkey). Use pp_get to fetch the full text.",
        args: {
          query: tool.schema.string().optional().describe("Filter by label text, empty = all"),
        },
        async execute(args) {
          const q = (args.query ?? "").toLowerCase()
          return loadPrompts()
            .filter((p) => !q || p.label.toLowerCase().includes(q))
            .map((p, i) => ({ label: p.label, command: "/" + p.command, hotkey: i < 8 ? `Ctrl+Alt+${i + 1}` : "search", chars: p.text.length }))
        },
      }),
      pp_get: tool({
        description: "Get the full text of one Prompt Popper premade prompt by label or slash command (e.g. 'Fix errors' or 'pp-fix'). Apply it to the current task.",
        args: {
          name: tool.schema.string().describe("Prompt label or command name"),
        },
        async execute(args) {
          const want = args.name.toLowerCase().replace(/^\//, "")
          const found = loadPrompts().find(
            (p) => p.label.toLowerCase() === want || p.command.toLowerCase() === want
          )
          if (!found) throw new Error(`No prompt named '${args.name}'. Use pp_list to see names.`)
          return found.text
        },
      }),
    },
  }
}
