// Context menus (Herdr's items). Opened as a popup with
// props { tab: "pane" | "tab" | "space" | "global", target }.
// ↑/↓ move, Enter runs, Esc closes. An item is [label, command, args];
// a command "worktree" opens the worktree dialog instead.

import { View, div, svg } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { run, props, closeOverlay, openOverlay, theme, keys, terminals, spaces, panes, exec } from "herdr";

// Where a space is now: its first terminal's live folder, else where it was made.
function place(s) {
  const tabs = new Set((s.tabs ?? []).map((c) => c.id));
  return panes().find((p) => tabs.has(p.tab) && p.cwd)?.cwd || s.folder;
}

// A space's checkout: "main" (a repo's own), "linked" (a worktree), or null.
async function checkout(folder, on) {
  const top = await exec("git", ["rev-parse", "--show-toplevel"], { cwd: folder, on });
  const common = await exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd: folder, on });
  if (top.code !== 0 || common.code !== 0) return null;
  return common.stdout.trim() === `${top.stdout.trim()}/.git` ? "main" : "linked";
}

function items(p, git) {
  p = p ?? {};
  const tg = p.target ?? {};
  switch (p.tab) {
    case "pane": {
      // A kept sub-agent can go back under its parent, still running.
      const all = terminals();
      const term = all.find((t) => t.address === tg.terminal);
      const parent = term?.parent && all.find((t) => t.address === term.parent);
      // Once they go to the program, Shift+right-click still opens this menu.
      const toProgram = term?.labels?.["herdr.right-click"] === "program";
      return [
        ["Copy", "terminal.copy", {}],
        ["Paste", "terminal.paste", {}],
        ["Open in Vim", "vim.open", { pane: tg.pane, terminal: tg.terminal }],
        ["Search in Vim", "vim.search", { pane: tg.pane, terminal: tg.terminal }],
        ["Split right", "pane.split", { direction: "right", pane: tg.pane }],
        ["Split down", "pane.split", { direction: "down", pane: tg.pane }],
        ["Zoom", "pane.zoom", { pane: tg.pane }],
        ...(term
          ? [
              toProgram
                ? ["Use Herdr right-click menu", "terminal.right_click", { terminal: term.address, to: "menu" }]
                : ["Send right-clicks to pane", "terminal.right_click", { terminal: term.address, to: "program" }],
            ]
          : []),
        ...(parent ? [[`Send back to ${parent.name || parent.address}`, "terminal.park", { terminal: term.address }]] : []),
        ["Close pane", "pane.close", { pane: tg.pane }],
      ];
    }
    case "tab":
      return [
        ["Rename", "tab.rename", { id: tg.id }],
        ["New tab", "tab.new", { space: tg.space }],
        ["Close", "tab.close", { id: tg.id }],
      ];
    case "space":
      return [
        ["Rename", "space.rename", { id: tg.id }],
        ...(git ? [["New worktree", "worktree", { space: tg.id, action: "new" }], ["Open worktree", "worktree", { space: tg.id, action: "open" }]] : []),
        ...(git === "linked" ? [["Remove worktree", "worktree", { space: tg.id, action: "remove" }]] : []),
        ["Close", "space.close", { id: tg.id }],
      ];
    default:
      return [
        ["New space", "space.new", {}],
        ["Keybinds", "app.help", {}],
        ["Theme: graphite", "app.theme", { name: "graphite" }],
        ["Theme: ink", "app.theme", { name: "ink" }],
        ["Theme: moss", "app.theme", { name: "moss" }],
        ["Theme: atom one dark", "app.theme", { name: "atom-one-dark" }],
      ];
  }
}

function menuIcon(command) {
  if (command === "terminal.copy") return "mods/my-menu/copy.svg";
  if (command === "terminal.paste") return "mods/my-menu/clipboard.svg";
  if (command === "vim.open") return "mods/my-menu/vim.svg";
  if (command === "vim.search") return "mods/workspace-chrome/search.svg";
  const name = command.endsWith(".close") ? "x" : command.endsWith(".rename") ? "square-pen" : command.endsWith(".new") ? "plus" : command === "worktree" ? "git-branch" : command === "app.help" ? "terminal" : command === "app.theme" ? "settings" : command === "pane.split" ? "panel-right" : command === "pane.zoom" ? "square" : "terminal";
  return `mods/workspace-chrome/${name}.svg`;
}

// The key bound to a command, for the hint on the right.
function shortcut(name, args) {
  // `pane.split:right` binds pane.split with { direction: "right" }.
  const value = args && Object.values(args)[0];
  const k = keys().find(
    (b) =>
      (b.section === "global" || b.section === "terminal") &&
      (b.action === name ||
        b.action === `${name}:${value}` ||
        (name === "vim.open" && b.action === "my-pane.open_vim") ||
        (name === "vim.search" && b.action === "my-pane.search_vim")),
  );
  return k ? k.keys : "";
}

function readClip(cx) {
  try {
    return (cx && cx.read_from_clipboard && cx.read_from_clipboard()) || "";
  } catch {
    return "";
  }
}

export default class Menu extends View {
  init(_props, cx) {
    this.at = 0;
    this.git = null;
    this.initialClip = readClip(cx);
    this.handle = cx.focus_handle();
    this.handle.focus();
    const p = props();
    const space = p?.tab === "space" && spaces().find((s) => s.id === p.target?.id);
    const folder = space && place(space);
    if (folder)
      cx.spawn(async (cx) => {
        this.git = await checkout(folder, space.machine).catch(() => null);
        cx.notify();
      });
  }

  openInVim(tg, overlay, cx, mode = "open") {
    const clipBefore = readClip(cx) || this.initialClip || "";
    if (tg.pane) run("pane.focus", { pane: tg.pane });
    run("terminal.copy", {});
    const launch = (clipAfter) => {
      const stateJson = JSON.stringify({
        mode,
        pane: tg.pane,
        terminal: tg.terminal,
        clipboard: clipAfter || "",
        clip_before: clipBefore,
        panes: panes(),
        terminals: terminals(),
        spaces: spaces(),
      });
      exec("sh", [
        "-c",
        'nohup python3 "${HERDR_APP_HOME:-$HOME/.config/herdr-app}/mods/my-menu/open_vim.py" "$1" >>/tmp/open_vim.log 2>&1 &',
        "vim-open",
        stateJson,
      ]);
      closeOverlay(overlay);
    };
    if (cx && cx.spawn) {
      cx.spawn(async (cx) => {
        await cx.sleep(40);
        launch(readClip(cx));
      });
    } else {
      launch("");
    }
  }

  choose(i, cx) {
    const it = items(props(), this.git)[i];
    if (!it) return;
    const tg = props()?.target ?? {};
    const overlay = props()?.overlay;
    if (it[1] === "vim.open") {
      this.openInVim(tg, overlay, cx, "open");
      return;
    }
    if (it[1] === "vim.search") {
      this.openInVim(tg, overlay, cx, "search");
      return;
    }
    closeOverlay(overlay);
    if (it[1] === "worktree") openOverlay({ mod: "worktree", kind: "dialog", ...(it[2].action === "open" ? { width: 560, height: 480 } : { width: 440, height: 260 }), props: it[2] });
    else {
      // Copy and paste act on the focused terminal, so focus the pane that was
      // right-clicked first (the menu itself holds the keyboard).
      if ((it[1] === "terminal.copy" || it[1] === "terminal.paste") && tg.pane) run("pane.focus", { pane: tg.pane });
      run(it[1], it[2]);
    }
  }

  render(cx) {
    const t = theme();
    const list = items(props(), this.git);
    return v_flex()
      .id("menu")
      .track_focus(this.handle)
      .w_full()
      .min_h(0)
      .p(5)
      .bg(t.popover)
      .text_size(12.8)
      .on_key_down((e, cx) => {
        if (e.key === "down") this.at = (this.at + 1) % list.length;
        else if (e.key === "up") this.at = (this.at + list.length - 1) % list.length;
        else if (e.key === "enter") this.choose(this.at, cx);
        else if (e.key === "escape") closeOverlay(props().overlay);
        else return;
        cx.notify();
      })
      .children(
        list.map((it, i) =>
          v_flex()
            .when(i > 0 && (it[1].endsWith(".close") || it[1] === "app.help" || (it[1] === "app.theme" && list[i - 1][1] !== "app.theme") || (it[1] === "pane.split" && (list[i - 1][1] === "terminal.paste" || list[i - 1][1] === "vim.open" || list[i - 1][1] === "vim.search"))), el => el.child(div().mx(7).my(4).h(1).bg(t.border)))
            .child(h_flex()
            .id(`mi-${i}`)
            .h(31)
            .px(8)
            .gap(9)
            .items_center()
            .justify_between()
            .rounded(7)
            .text_color(t.foreground)
            .when(i === this.at, (el) => el.bg(t.selected))
            .hover((s) => s.bg(t.hover))
            .on_click((_e, cx) => this.choose(i, cx))
            .child(svg(menuIcon(it[1])).size(14).flex_none().text_color(t.muted))
            .child(div().flex_1().child(it[0]))
            .child(div().text_size(11).text_color(t.dim).child(shortcut(it[1], it[2])))),
        ),
      );
  }
}
