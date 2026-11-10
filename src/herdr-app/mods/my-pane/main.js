// A pane's header, for layouts that frame their panes:
//   { "tab": "active", "pane": { "header": { "content": { "mod": "my-pane" } } } }
// Shows the program's icon (the app's program table), the agent's name or
// the terminal's title, the folder, and the agent's status; buttons split, zoom and close
// this pane. Props from the app: { pane, terminal }. Click: focus the pane.

import { View, div, svg, image } from "gpui-kit";
import { h_flex } from "gpui-base";
import { panes, props, run, theme, home, focused, terminals, spaces, exec, nextCommand } from "herdr";

function readClip(cx) {
  try {
    return (cx && cx.read_from_clipboard && cx.read_from_clipboard()) || "";
  } catch {
    return "";
  }
}

function icon(p, size, color) {
  if (!p?.icon) return null;
  return p.tint ? svg(p.icon).size(size).flex_none().text_color(color) : image(p.icon).w(size).h(size).flex_none();
}

function folder(cwd) {
  if (!cwd) return "";
  const h = home();
  return cwd === h ? "~" : cwd.startsWith(h + "/") ? "~" + cwd.slice(h.length) : cwd;
}

export default class Pane extends View {
  init(_props, cx) {
    this.hovered = false;
    cx.spawn(async (cx) => {
      for (;;) {
        const c = await nextCommand();
        if (c === "open_vim") {
          this.openInVim(cx, "open");
        } else if (c === "search_vim") {
          this.openInVim(cx, "search");
        }
      }
    });
  }

  openInVim(cx, mode = "open") {
    const me = this.me();
    const f = focused();
    const activePane =
      (f?.pane && panes().find((p) => p.pane === f.pane)) ||
      panes().find((p) => p.focused) ||
      me;
    if (!me || !activePane || me.pane !== activePane.pane) return;

    const clipBefore = readClip(cx);
    if (activePane.pane) run("pane.focus", { pane: activePane.pane });
    run("terminal.copy", {});
    cx.spawn(async (cx) => {
      await cx.sleep(40);
      const clipAfter = readClip(cx);
      const stateJson = JSON.stringify({
        mode,
        pane: activePane.pane,
        terminal: activePane.terminal || f?.terminal,
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
    });
  }

  me() {
    return panes().find((p) => p.pane === props()?.pane);
  }

  button(t, id, icon, command, args) {
    return div()
      .id(id)
      .p(3)
      .rounded(4)
      .text_color(t.dim)
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => {
        cx.stop_propagation();
        run(command, args);
      })
      .child(svg(`mods/my-pane/${icon}.svg`).size(14));
  }

  render(cx) {
    const t = theme();
    const p = this.me();
    if (!p) return div();
    const isVim = p.program?.key === "vim" || p.program?.key === "nvim";
    const vimFile = isVim && p.title && (p.title.startsWith("/") || p.title.startsWith("~")) ? p.title : "";
    const name = vimFile
      ? p.program?.name || "Vim"
      : ((p.program?.agent || p.program?.shell) && p.program.name) || p.title || p.program?.name || "shell";
    const sub = vimFile || folder(p.cwd);
    const pic = icon(p.program, 14, t.dim);
    const st = p.status;
    const pane = p.pane;
    return h_flex()
      .id(`pane-head-${pane}`)
      .size_full()
      .px(10)
      .gap(8)
      .items_center()
      .bg(t.background)
      .border_b(1)
      .border_color(t.border)
      .text_size(12)
      .on_hover((hovered, cx) => { this.hovered = hovered; cx.notify(); })
      .on_click(() => run("pane.focus", { pane }))
      .when(Boolean(pic), (el) => el.child(pic))
      .child(div().flex_none().truncate().max_w(260).font_medium().text_color(t.foreground).child(name))
      .child(div().flex_1().truncate().text_color(vimFile ? t.foreground : t.dim).child(sub))
      .when(st === "working", el => el.child(svg("mods/workspace-chrome/spinner.svg").size(12).flex_none().text_color(t.working).spin(900)))
      .when(st === "blocked", el => el.child(div().flex_none().px(6).h(18).flex().items_center().rounded(5).bg(t.blocked + "26").text_size(10.5).font_semibold().text_color(t.blocked).child("Needs you")))
      .when(st === "done", el => el.child(div().size(7).flex_none().rounded(4).bg(t.done)))
      .when(this.hovered, el => el
        .child(this.button(t, `ph-r-${pane}`, "split-right", "pane.split", { direction: "right", pane }))
        .child(this.button(t, `ph-d-${pane}`, "split-down", "pane.split", { direction: "down", pane }))
        .child(this.button(t, `ph-z-${pane}`, p.zoomed ? "unzoom" : "zoom", "pane.zoom", { pane }))
        .child(this.button(t, `ph-x-${pane}`, "close", "pane.close", { pane })));
  }
}
