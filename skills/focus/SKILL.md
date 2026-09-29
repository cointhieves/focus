---
name: focus
description: Use when the user mentions Focus, their Focus list or queue, or asks to jot down, remember, or be reminded of something ("add X to focus", "remind me to X by 5pm", "put that on my list", "what's on my focus", "mark it done", "skip that"). Focus is a macOS menubar queue driven by the `focus` CLI.
---

# Focus

Focus is a menubar app on the user's Mac that keeps a queue of things waiting on
them: tasks (with or without a deadline) they add, plus their in-progress Jira sprint tickets
that need a response. Focus orders the queue itself (oldest-untouched first,
urgent items popped to the front). You change it through the `focus` CLI, and the
panel picks up changes within about a second.

Run `focus help` for the current commands. It is the source of truth; do not rely
on a remembered syntax.

## What you would otherwise get wrong

- **Ids come from `focus list --json`.** Never guess an id or reuse one from
  earlier in the conversation; the queue changes underneath you. Match the item
  by title, and ask if more than one could be meant.
- **Deadlines go in the text or `--by`.** "take out the trash by 5pm" and
  "stretch in 30 minutes" set a due time; so does `--by "Friday 3pm"`. Only a
  time after the word "by", or "in N minutes/hours", counts. If the user gave a
  time, confirm from the command output that a due time was set. If it wasn't,
  retry with `--by` rather than leaving a timed task untimed.
- **`done` is for tasks; `dismiss` is for Jira and Slack items.**
  `done` deletes the item. `dismiss` hides a Jira/Slack item until something new
  happens on it. The CLI refuses `done` on a Jira item. A Jira item listed as
  `removed` has left the user's sprint; `dismiss` clears it for good.
- **"Remind me about this later" / "push it down for a bit" is `snooze`.** It moves
  the item to the bottom and brings it back after N business hours (or sooner if
  someone replies). `unsnooze` brings it back now.
- **Jira items come from Jira.** Do not `add` a ticket to track it; Focus shows
  the user's sprint tickets automatically. To make one go away, the user
  comments on it or closes it in Jira.
- **Add the user's words, lightly tidied.** Keep it short enough to read in a
  narrow panel. Don't expand a task into a plan.

## If `focus` is not found

Focus is not installed on this machine, or `~/.local/bin` is not on PATH. Say so
and stop. Do not create files or substitute another tool.

## Done means

Run `focus list` after any change and confirm the result: the new item is
present (with its due time if one was asked for), or the done/dismissed item is
gone. Report what changed in one line.
