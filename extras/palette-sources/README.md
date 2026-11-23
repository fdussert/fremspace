# Palette sources

A palette source adds rows to Fremspace's palette: the agents of a tool, the windows of a
terminal multiplexer, a list of bookmarks. It is an executable file, in any language, that
Fremspace finds in

    ~/Library/Application Support/Fremspace/Palette Sources/

The five scripts here are sources ready to use, and examples to copy from.

## Installing one

Four of these scripts come with the app (all but `terminal-tabs`): in Fremspace's settings,
General → Palette lists them under "Ready-made sources", each with an **Add** button that copies
it into the folder. Then switch on **Palette sources** on the same page, and save.

For one of your own, or to do it by hand:

1. Copy the script into the folder above, or link it there (`ln -s`). "Open the sources folder",
   on the same page, makes the folder and shows it.
2. Keep it executable (`chmod +x`).
3. Switch on **Palette sources**, and save.

The scripts need `python3` (the one of the Xcode command line tools or of Homebrew will do) and
nothing else. A script whose tool is not installed, or not running, lists nothing.

## The protocol (version 1)

Fremspace calls a source in two ways.

**`<source> list`** prints the rows as JSON on its standard output and exits 0, within 3 seconds:

    {"items": [{"title": "…", "subtitle": "…", "arg": "…", "url": "…",
                "app": "<bundle identifier>", "tag": "…", "keywords": ["…"]}]}

Only `title` is required.

| Key        | What it is                                                                        |
|------------|-----------------------------------------------------------------------------------|
| `title`    | The row's name: what its owner types to find it.                                  |
| `subtitle` | A line shown under the title.                                                     |
| `tag`      | One short word of state shown at the right: "working", "done".                    |
| `keywords` | More words the row is found by.                                                   |
| `url`      | When the row is chosen, Fremspace opens this itself.                              |
| `arg`      | Without `url`, Fremspace runs `<source> run <arg>` when the row is chosen.        |
| `app`      | A bundle identifier: it gives the row its icon, and that application is brought to the front after the action. |

**`<source> run <arg>`** does what choosing the row means, within 10 seconds.

A source is given no input and no terminal, and this environment only: `HOME`, `USER`,
`LOGNAME`, `TMPDIR`, `LANG=en_US.UTF-8`, `FREMSPACE_PALETTE=1` and
`PATH=$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
`arg` is handed back as one argument, as it was printed: no shell reads it.

Fremspace keeps 200 rows and 1 MB of output at most, cuts titles at 200 characters and tags at
24, and leaves out a row whose `arg` is longer than 4096 characters. A source that fails, takes
too long or prints something else is left out: one that has nothing to show prints
`{"items": []}` and exits 0. The sources are asked together each time the palette opens, and the
rows of each appear as soon as it has answered; what it listed the time before is shown meanwhile.

Fremspace runs a file of the folder only when it is a regular file (or a link to one) that
belongs to you, that you may execute and that nobody else may write; the folder itself must be
yours alone to write. After `run` ends with status 0, the row's `app` is brought to the front;
with another status Fremspace beeps and leaves things as they are.

The smallest source lists addresses and has nothing to run:

```sh
#!/bin/sh
# Two bookmarks. Fremspace opens a row's "url" itself, so "run" is never called.
[ "$1" = list ] || { echo "usage: bookmarks list" >&2; exit 2; }
cat <<'JSON'
{"items": [
  {"title": "Team calendar", "subtitle": "calendar.example.com", "url": "https://calendar.example.com/"},
  {"title": "Billing dashboard", "url": "https://billing.example.com/", "keywords": ["invoices"]}
]}
JSON
```

## The scripts

| Script          | What it lists                                                        | What choosing a row does |
|-----------------|----------------------------------------------------------------------|--------------------------|
| `orca-agents`   | The agents open in Orca: their title, agent and workspace, and whether they are working or done. | Shows the agent's terminal tab in Orca (`orca terminal switch`), or opens its workspace when it has no live terminal (`orca worktree activate`), then brings Orca forward. |
| `herdr`         | The agents of herdr, then its tabs, with their state.                 | Focuses the agent's pane or the tab (`herdr agent focus`, `herdr tab focus`). |
| `tmux`          | Every window of every session of the default tmux server.             | Moves the most recently used client to the window (`switch-client`); when nobody is attached, makes it its session's current window (`select-window`). |
| `claude-code`   | The Claude Code sessions that were given a name, among the 40 most recently written. | Opens the default terminal in the session's folder on `claude --resume <session id>`. |
| `terminal-tabs` | The tabs of every Terminal window.                                    | Selects the tab, raises its window and brings Terminal forward. |

Things to know:

- `herdr` and `tmux` run inside a terminal and cannot tell which one, so Fremspace does not
  know what to bring forward. Write that terminal's bundle identifier in `TERMINAL_APP`, at the
  top of the script.
- `terminal-tabs` talks to Terminal through `osascript`, which macOS allows only to an
  application that declares it wants to control others. Fremspace does not declare that yet, so
  started by Fremspace this source lists nothing for now; run by hand from a terminal it works
  once macOS's question is answered. It does not start Terminal, nor `osascript` when Terminal is
  closed.
- `claude-code` reads only the start and the end of each transcript, which can weigh hundreds
  of megabytes. It writes a small `.command` file in the owner's temporary folder and opens it:
  the file removes itself as it starts. No Apple event is sent.
- `claude-code` reads `~/.claude`. Fremspace does not pass `CLAUDE_CONFIG_DIR` on: with
  another configuration folder, change `projects_dir` in the script.

## What was run, and what was not

These scripts were written in November 2026, on one Mac. Choosing a row changes what is on its
owner's screen, so **only one `run` was executed against a real tool** (`orca-agents`, once): the
others are written from the tool's own help, and were only checked up to the command they would
start.

| Script          | Run on a real machine                                                  | Not run |
|-----------------|------------------------------------------------------------------------|---------|
| `orca-agents`   | `list`, against a running Orca, and `run` once on an agent with a live terminal: `orca terminal switch` ended with status 0. | `orca worktree activate`, the way taken for an agent without a live terminal. |
| `herdr`         | `list` with herdr 0.9.5 installed and no server running: it lists nothing, as intended. | Everything else. The listing is written from `herdr api schema` and was checked against an invented snapshot of that shape; the focus commands come from `herdr --help`. |
| `tmux`          | Nothing: tmux was not installed.                                        | Everything. It is written from the tmux manual and was checked against a stand-in that prints invented lines. |
| `claude-code`   | `list`, against real transcripts, the largest of 160 MB.                | Opening the terminal. The `.command` file was written and checked with `sh -n`, never opened. |
| `terminal-tabs` | `list` with Terminal closed: it lists nothing. The two AppleScripts compile (`osacompile`). | Sending either script to Terminal. The parsing was checked against invented records. |

Every `list` answered in less than a second: 0.8 second for the slowest on its first run
(`orca-agents`, 26 rows), 0.3 second or less after that.
