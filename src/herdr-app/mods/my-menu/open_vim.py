#!/usr/bin/env python3
import fcntl
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
from urllib.parse import unquote

LOCAL_BIN = os.path.expanduser("~/.local/bin")
if LOCAL_BIN not in os.environ.get("PATH", "").split(os.pathsep):
    os.environ["PATH"] = LOCAL_BIN + os.pathsep + os.environ.get("PATH", "")

LAST_CLIP_FILE = "/tmp/herdr-vim-last-clip.json"
LOCK_FILE = "/tmp/herdr-open-vim.lock"


def log(msg):
    try:
        with open("/tmp/open_vim.log", "a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    except Exception:
        pass


def run_cmd(argv, cwd=None, timeout=4):
    try:
        r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except Exception:
        return 1, ""


def herdr_socket_path():
    return os.environ.get("HERDR_SOCKET_PATH") or os.path.expanduser("~/.config/herdr/herdr.sock")


def herdr_rpc(method, params=None, timeout=2.0):
    sock_path = herdr_socket_path()
    req = {
        "id": f"vim-{int(time.time() * 1000)}",
        "method": method,
        "params": params or {},
    }
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(sock_path)
            s.sendall((json.dumps(req) + "\n").encode("utf-8"))
            buf = b""
            while b"\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        line = buf.splitlines()[0].decode("utf-8", errors="replace") if buf else ""
        if not line:
            return {}
        resp = json.loads(line)
        if resp.get("error"):
            log(f"herdr_rpc error ({method}): {resp['error']}")
            return {}
        return resp.get("result") or {}
    except Exception as e:
        log(f"herdr_rpc exception ({method}): {e}")
        return {}


def read_clip_cmd(cmds):
    for cmd in cmds:
        code, out = run_cmd(cmd, timeout=0.4)
        if code == 0 and out.strip():
            return out
    return ""


def read_system_clipboard():
    return read_clip_cmd(
        [
            ["wl-paste", "--no-newline"],
            ["xclip", "-o", "-selection", "clipboard"],
            ["xsel", "-ob"],
        ]
    )


def read_primary_selection():
    return read_clip_cmd(
        [
            ["wl-paste", "--primary", "--no-newline"],
            ["xclip", "-o", "-selection", "primary"],
            ["xsel", "-op"],
        ]
    )


def load_last_clip():
    try:
        with open(LAST_CLIP_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_last_clip(data):
    try:
        with open(LAST_CLIP_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
    except Exception:
        pass


def notify_err(msg):
    log(f"ERROR: {msg}")
    run_cmd(["notify-send", "-a", "Herdr", "Open in Vim", msg])


STRIP_CHARS = " \t\r\n\"'`([<«“‘（【《〈「『）]》〉」』”’,;:。，；！!？?、…"
BOX_RE = re.compile(r"[│┃┆┊╎▏▎▍▌▋▊▉█╭╮╯╰├┤┬┴┼─━]+")
BULLET_RE = re.compile(r"^\s*[●•◦▪▸▹►▻*>-]+\s*")
CJK_RE = re.compile(r"[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]")


def clean_token(tok):
    s = (tok or "").strip()
    if not s:
        return "", None
    m_url = re.search(r"file://([^\s)\x22'`>]+)", s, re.I)
    if m_url:
        s = unquote(m_url.group(1))
    else:
        m_md = re.search(r"\[[^\]]*\]\(([^)]+)\)", s)
        if m_md:
            s = m_md.group(1).strip()
    m_tool = re.match(r"^(?:Read|Update|Write|Edit|Create|Delete|View|Patch)\s*\((.+)\)$", s, re.I)
    if m_tool:
        s = m_tool.group(1).strip()
    s = s.strip(STRIP_CHARS)
    line = None
    m_cn = re.match(r"^(.*?)[\s`'\"*]*第\s*(\d+)\s*(?:[-~～]\s*\d+\s*)?行.*$", s)
    if m_cn and m_cn.group(1):
        s, line = m_cn.group(1).strip(STRIP_CHARS), int(m_cn.group(2))
    m_hash = re.match(r"^(.*?)#L(\d+)(?:-L?\d+)?$", s, re.I)
    if m_hash and m_hash.group(1):
        s, line = m_hash.group(1), int(m_hash.group(2))
    else:
        m_col = re.match(r"^(.*?):(\d+)(?::\d+|-\d+)?$", s)
        if m_col and m_col.group(1):
            s, line = m_col.group(1), int(m_col.group(2))
        else:
            m_par = re.match(r"^(.*?)\((\d+)(?:,\s*\d+)?\)$", s)
            if m_par and m_par.group(1):
                s, line = m_par.group(1), int(m_par.group(2))
    s = s.strip(STRIP_CHARS)
    return s, line


TOKEN_PATTERNS = [
    re.compile(r"file://([^\s)\x22'`>]+)", re.I),
    re.compile(
        r"([~./]*[A-Za-z0-9_.$~/-]*[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+[\s`'\"*]*第\s*\d+\s*(?:[-~～]\s*\d+\s*)?行)"
    ),
    re.compile(
        r"(?<![A-Za-z0-9_.$~/-])([~./]*[A-Za-z0-9_.$~/-]*[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+(?::\d+(?::\d+|-\d+)?)?(?:#L\d+(?:-L?\d+)?)?)"
    ),
    re.compile(r"(?<![A-Za-z0-9_.$~/-])([~./]*[A-Za-z0-9_.$~-]+(?:/[A-Za-z0-9_.$~-]+)+(?::\d+)?)"),
    re.compile(r"\b([A-Za-z_][A-Za-z0-9_-]{2,}:\d+(?:-\d+)?)\b"),
    re.compile(
        r"\b((?:Makefile|Dockerfile|Containerfile|Justfile|Vagrantfile|Gemfile|Rakefile|Procfile|CMakeLists\.txt|BUILD|WORKSPACE)(?::\d+)?)\b"
    ),
]


def extract_candidates(raw):
    text = (raw or "").strip()
    if not text:
        return []
    lines = []
    for l in text.splitlines():
        l = BOX_RE.sub(" ", l)
        l = BULLET_RE.sub("", l).strip()
        if l:
            lines.append(l)
    if not lines:
        return []

    seen = set()
    cands = []

    def add(f, ln):
        if not f or len(f) > 512:
            return
        if f in (".", "..", "/"):
            return
        # Handle "aggregate.go/query.go" (two filenames with extensions separated by slash)
        if "/" in f and not f.startswith("/"):
            parts = f.split("/")
            if len(parts) == 2 and "." in parts[0] and "." in parts[1]:
                for p in parts:
                    add(p, ln)
        if ln is not None and (f, None) in seen:
            seen.discard((f, None))
            seen.add((f, ln))
            for idx, (cf, cln) in enumerate(cands):
                if cf == f and cln is None:
                    cands[idx] = (f, ln)
                    return
        if ln is None and any(cf == f and cln is not None for cf, cln in seen):
            return
        key = (f, ln)
        if key not in seen:
            seen.add(key)
            cands.append((f, ln))

    joined = "".join(lines)
    if len(lines) > 1 and not CJK_RE.search(joined) and " " not in joined and "\t" not in joined:
        f, ln = clean_token(joined)
        if not CJK_RE.search(f):
            add(f, ln)

    first_tok = lines[0].split()[0] if lines[0].split() else ""
    if first_tok and not CJK_RE.search(first_tok):
        f, ln = clean_token(first_tok)
        if not CJK_RE.search(f):
            add(f, ln)

    full_text = "\n".join(lines)
    for pat in TOKEN_PATTERNS:
        for m in pat.finditer(full_text):
            tok = m.group(0)
            f, ln = clean_token(tok)
            if f and not CJK_RE.search(f):
                add(f, ln)

    return cands


def git_toplevel(path):
    if not path or not os.path.isdir(path):
        return ""
    code, out = run_cmd(["git", "-C", path, "rev-parse", "--show-toplevel"])
    return out.strip() if code == 0 else ""


def resolve_direct(cands, roots, primary_cwd):
    for f, ln in cands:
        p = os.path.expanduser(f)
        tries = [p] if os.path.isabs(p) else []
        for r in roots:
            tries.append(os.path.join(r, p))
            if p.startswith("a/") or p.startswith("b/"):
                tries.append(os.path.join(r, p[2:]))
        for t in tries:
            if os.path.isfile(t):
                real = os.path.realpath(t)
                froot = git_toplevel(os.path.dirname(real)) or (roots[0] if roots else primary_cwd)
                return real, froot, ln
    return None


def resolve_search(cands, roots, primary_cwd, include_ignored=False):
    res = resolve_direct(cands, roots, primary_cwd)
    if res:
        return res
    flags_list = ([], ["--no-ignore"]) if include_ignored else ([],)
    for ignore_flag in flags_list:
        file_list = []
        seen_files = set()
        for r in roots:
            if not os.path.isdir(r):
                continue
            cmd = (
                ["rg", "--files", "--hidden"]
                + ignore_flag
                + [
                    "-g",
                    "!.git",
                    "-g",
                    "!node_modules",
                    "-g",
                    "!vendor",
                    "-g",
                    "!target",
                    "-g",
                    "!dist",
                    "-g",
                    "!.venv",
                    "-g",
                    "!venv",
                    "-g",
                    "!__pycache__",
                    "-g",
                    "!storage",
                    "-g",
                    "!runtime",
                    r,
                ]
            )
            code, out = run_cmd(cmd)
            if code == 0 or out:
                for line in out.splitlines():
                    if line and line not in seen_files:
                        seen_files.add(line)
                        file_list.append(line)
        if not file_list:
            continue
        for f, ln in cands:
            clean = f.lstrip("./")
            if not clean:
                continue
            suffix = "/" + clean
            suffix_low = suffix.lower()
            clean_low = clean.lower()
            no_ext = "." not in os.path.basename(clean) and len(clean) >= 3
            matches = []
            for path in file_list:
                if path == clean or path.endswith(suffix):
                    in_cwd = 0 if (primary_cwd and path.startswith(primary_cwd.rstrip("/") + "/")) else 1
                    try:
                        mt = os.path.getmtime(path)
                    except OSError:
                        mt = 0
                    matches.append((0, in_cwd, -mt, len(path), path))
                else:
                    plow = path.lower()
                    if plow == clean_low or plow.endswith(suffix_low):
                        in_cwd = 0 if (primary_cwd and path.startswith(primary_cwd.rstrip("/") + "/")) else 1
                        try:
                            mt = os.path.getmtime(path)
                        except OSError:
                            mt = 0
                        matches.append((1, in_cwd, -mt, len(path), path))
                    elif no_ext:
                        stem = os.path.splitext(os.path.basename(path))[0]
                        if stem == clean or stem.lower() == clean_low:
                            prio = 2 if stem == clean else 3
                            in_cwd = 0 if (primary_cwd and path.startswith(primary_cwd.rstrip("/") + "/")) else 1
                            try:
                                mt = os.path.getmtime(path)
                            except OSError:
                                mt = 0
                            matches.append((prio, in_cwd, -mt, len(path), path))
            if matches:
                matches.sort()
                best = os.path.realpath(matches[0][4])
                if os.path.isfile(best):
                    froot = git_toplevel(os.path.dirname(best)) or (roots[0] if roots else primary_cwd)
                    return best, froot, ln
    return None


def resolve_from_screen(raw, cands, term_addr, roots, primary_cwd, screen_reader=None):
    screen = ""
    if screen_reader is not None:
        screen = screen_reader() or ""
    elif term_addr:
        code, out = run_cmd(["hc", "read", term_addr], timeout=1.5)
        if code == 0:
            screen = out
    if not screen:
        return None
    screen_cands = []
    for f, ln in cands:
        base = os.path.basename(f)
        if base:
            matches = list(
                re.finditer(
                    r"([~./A-Za-z0-9_$-]+(?:/[A-Za-z0-9_.$~-]+)+/" + re.escape(base) + r")(?::(\d+))?",
                    screen,
                )
            )
            for m in reversed(matches):
                sf = m.group(1)
                sln = ln or (int(m.group(2)) if m.group(2) else None)
                screen_cands.append((sf, sln))
    raw_clean = raw.strip().splitlines()[0].strip()
    if raw_clean:
        for sline in reversed(screen.splitlines()):
            if raw_clean in sline:
                screen_cands.extend(extract_candidates(sline))
    if not screen_cands:
        return None
    return resolve_direct(screen_cands, roots, primary_cwd) or resolve_search(screen_cands, roots, primary_cwd)


def resolve_any(raw, cands, term_addr, roots, extra_roots, primary_cwd, screen_reader=None):
    if not raw or not raw.strip():
        return None
    res = resolve_direct(cands, roots, primary_cwd) if cands else None
    if not res and cands:
        res = resolve_search(cands, roots, primary_cwd, include_ignored=False)
    if not res:
        res = resolve_from_screen(raw, cands, term_addr, roots, primary_cwd, screen_reader=screen_reader)
    if not res and cands and extra_roots:
        res = resolve_search(cands, extra_roots, primary_cwd, include_ignored=False)
    if not res and cands:
        res = resolve_search(cands, roots, primary_cwd, include_ignored=True)
    if not res and cands:
        for f, ln in cands:
            if "/" in f:
                for r in roots:
                    d = os.path.realpath(os.path.join(r, f.lstrip("/")))
                    if os.path.isdir(d):
                        res = (d, git_toplevel(d) or r, ln)
                        break
                if res:
                    break
    return res


def get_term_info(addr, fallback=None):
    if addr:
        code, out = run_cmd(["hc", "get", "--json", addr], timeout=1.5)
        if code == 0 and out.strip():
            try:
                return json.loads(out)
            except Exception:
                pass
    return fallback or {}


def collect_raw_sources(state):
    clip_before = (state.get("clip_before") or "").strip()
    clip_after = (state.get("clipboard") or "").strip()
    if not clip_after:
        time.sleep(0.04)
    sys_clip = read_system_clipboard().strip()
    primary_clip = read_primary_selection().strip()
    effective_after = clip_after or sys_clip

    last = load_last_clip()
    last_before = (last.get("last_before") or "").strip()
    last_after = (last.get("last_after") or "").strip()
    last_primary = (last.get("last_primary") or "").strip()
    last_used = (last.get("last_used") or "").strip()

    ordered = []

    def push(val, tag):
        if val and val not in ordered:
            ordered.append(val)
            log(f"source[{tag}]: {val[:120]!r}")

    # 1. If terminal.copy produced a brand-new selection (different from clip_before and last_after)
    if effective_after and effective_after != clip_before and effective_after != last_after:
        push(effective_after, "new_after")

    # 2. If clip_before changed since last run (e.g. TUI app like Antigravity copied on mouse-up,
    #    even if terminal.copy then overwrote clipboard with a stale Vt selection)
    if clip_before and clip_before != last_used and clip_before != last_before:
        push(clip_before, "new_before")

    # 3. If primary selection changed since last run
    if primary_clip and primary_clip != last_primary and primary_clip != last_used:
        push(primary_clip, "new_primary")

    # 4. Standard fallback order
    push(effective_after, "after")
    push(sys_clip, "sys_clip")
    push(clip_before, "before")
    push(primary_clip, "primary")

    return ordered, {
        "last_before": clip_before,
        "last_after": effective_after,
        "last_primary": primary_clip,
    }


def collect_raw_sources_herdr(ctx):
    clicked_url = (ctx.get("clicked_url") or "").strip()
    selected_text = (ctx.get("selected_text") or "").strip()
    sys_clip = read_system_clipboard().strip()
    primary_clip = read_primary_selection().strip()

    last = load_last_clip()
    last_after = (last.get("last_after") or "").strip()
    last_primary = (last.get("last_primary") or "").strip()
    last_used = (last.get("last_used") or "").strip()

    ordered = []

    def push(val, tag):
        if val and val not in ordered:
            ordered.append(val)
            log(f"herdr_source[{tag}]: {val[:120]!r}")

    push(clicked_url, "clicked_url")
    push(selected_text, "selected_text")

    if sys_clip and sys_clip != last_after and sys_clip != last_used:
        push(sys_clip, "new_sys_clip")
    if primary_clip and primary_clip != last_primary and primary_clip != last_used:
        push(primary_clip, "new_primary")

    push(sys_clip, "sys_clip")
    push(primary_clip, "primary")

    return ordered, {
        "last_before": sys_clip,
        "last_after": sys_clip,
        "last_primary": primary_clip,
    }


def vim_escape(s):
    return re.sub(r"[ \t\n*?[{\x60$\\%#'\"|!<]", lambda m: "\\" + m.group(0), s)


def run_herdr_mode(mode, ctx):
    snap = (herdr_rpc("session.snapshot") or {}).get("snapshot") or {}
    all_panes = snap.get("panes") or []
    all_workspaces = snap.get("workspaces") or []
    all_layouts = snap.get("layouts") or []

    tg_pane = ctx.get("focused_pane_id") or snap.get("focused_pane_id") or os.environ.get("HERDR_PANE_ID") or ""
    clicked_pane = next((p for p in all_panes if p.get("pane_id") == tg_pane), None)
    if not clicked_pane and all_panes:
        clicked_pane = next((p for p in all_panes if p.get("focused")), all_panes[0])
        tg_pane = clicked_pane.get("pane_id") or ""

    clicked_tab = (
        (clicked_pane or {}).get("tab_id")
        or ctx.get("tab_id")
        or snap.get("focused_tab_id")
        or os.environ.get("HERDR_TAB_ID")
        or ""
    )
    clicked_ws = (
        (clicked_pane or {}).get("workspace_id")
        or ctx.get("workspace_id")
        or snap.get("focused_workspace_id")
        or os.environ.get("HERDR_WORKSPACE_ID")
        or ""
    )
    owner_ws = next((w for w in all_workspaces if w.get("workspace_id") == clicked_ws), None)

    log(f"--- open_vim (herdr) start: mode={mode} pane={tg_pane} tab={clicked_tab} ws={clicked_ws} ---")

    raw_sources, clip_meta = collect_raw_sources_herdr(ctx)
    if not raw_sources:
        notify_err("Please select a filename first")
        return

    fg_cwd = (clicked_pane or {}).get("foreground_cwd") or ""
    pane_cwd = (clicked_pane or {}).get("cwd") or ctx.get("focused_pane_cwd") or ""
    ws_cwd = (owner_ws or {}).get("cwd") or ctx.get("workspace_cwd") or ""
    primary_cwd = fg_cwd or pane_cwd or ws_cwd or os.getcwd()

    roots = []
    live_cwds = [fg_cwd, pane_cwd]
    for c in (live_cwds if any(live_cwds) else [ws_cwd]):
        if c and os.path.isdir(c) and c not in roots:
            roots.append(c)
        gt = git_toplevel(c)
        if gt and gt not in roots:
            roots.append(gt)

    extra_roots = []
    for cfg_dir in ("~/.config/herdr", "~/.config/herdr-app"):
        p_cfg = os.path.expanduser(cfg_dir)
        if os.path.isdir(p_cfg) and p_cfg not in roots and p_cfg not in extra_roots:
            extra_roots.append(p_cfg)
    for p in all_panes:
        for pc in (p.get("foreground_cwd"), p.get("cwd")):
            if pc and os.path.isdir(pc) and pc not in roots and pc not in extra_roots:
                extra_roots.append(pc)
    if ws_cwd and os.path.isdir(ws_cwd) and ws_cwd not in roots and ws_cwd not in extra_roots:
        extra_roots.append(ws_cwd)

    log(f"herdr primary_cwd={primary_cwd} roots={roots}")

    proc_cache = {}

    def procs_for_pane(p):
        pid = p.get("pane_id")
        if not pid:
            return []
        if pid not in proc_cache:
            res = herdr_rpc("pane.process_info", {"pane_id": pid})
            proc_cache[pid] = (res.get("process_info") or {}).get("foreground_processes") or []
        return proc_cache[pid]

    def is_vim(p):
        for proc in procs_for_pane(p):
            name = (proc.get("name") or "").lower()
            argv = proc.get("argv") or []
            arg0 = os.path.basename(argv[0]).lower() if argv else ""
            if name in ("vim", "nvim") or arg0 in ("vim", "nvim"):
                return True
        label = p.get("label") or ""
        return label.startswith("Vim · ")

    def is_idle_shell(p):
        if is_vim(p) or p.get("agent"):
            return False
        procs = procs_for_pane(p)
        if not procs or len(procs) > 1:
            return False
        fg = (procs[0].get("name") or "").lower()
        return fg in ("bash", "zsh", "fish", "sh", "dash", "ksh", "nu", "pwsh", "powershell")

    same_tab_panes = [
        p for p in all_panes if clicked_tab and p.get("tab_id") == clicked_tab and p.get("pane_id") != tg_pane
    ]
    other_tab_panes = [
        p
        for p in all_panes
        if clicked_ws
        and p.get("workspace_id") == clicked_ws
        and p.get("tab_id") != clicked_tab
        and p.get("pane_id") != tg_pane
    ]

    tab_layout = next((l for l in all_layouts if l.get("tab_id") == clicked_tab), None)
    is_zoomed = bool(tab_layout and tab_layout.get("zoomed"))

    if mode == "search":
        raw_q = raw_sources[0]
        clean_lines = [
            re.sub(r"^[│┃┆┊╭╮╯╰─━\s]+|[│┃┆┊╭╮╯╰─━\s]+$", "", ln).strip()
            for ln in raw_q.splitlines()
        ]
        clean_lines = [ln for ln in clean_lines if ln]
        query = clean_lines[0] if clean_lines else raw_q.strip()
        if not query:
            notify_err("No text selected for search")
            return
        clip_meta["last_used"] = raw_q
        save_last_clip(clip_meta)

        search_dir = (
            primary_cwd
            if (primary_cwd and os.path.isdir(primary_cwd))
            else (roots[0] if roots else os.path.expanduser("~"))
        )
        search_file = "/tmp/herdr-vim-search.json"
        try:
            with open(search_file, "w", encoding="utf-8") as f:
                json.dump({"dir": search_dir, "query": query}, f)
        except Exception as e:
            log(f"failed writing {search_file}: {e}")

        log(f"herdr search mode: dir={search_dir} query={query!r}")

        vim_pane = clicked_pane if (clicked_pane and is_vim(clicked_pane)) else None
        switch_tab_id = None
        if not vim_pane:
            vim_pane = next((p for p in same_tab_panes if is_vim(p)), None)
        if not vim_pane:
            vim_pane = next((p for p in other_tab_panes if is_vim(p)), None)
            if vim_pane:
                switch_tab_id = vim_pane.get("tab_id")
        shell_pane = next((p for p in same_tab_panes if is_idle_shell(p)), None) if not vim_pane else None

        if is_zoomed and (not vim_pane or vim_pane.get("pane_id") != tg_pane) and not switch_tab_id:
            herdr_rpc("pane.zoom", {"pane_id": tg_pane, "mode": "off"})

        if vim_pane:
            vpid = vim_pane["pane_id"]
            log(f"herdr search reusing vim_pane={vpid} switch_tab={switch_tab_id}")
            if switch_tab_id:
                herdr_rpc("tab.focus", {"tab_id": switch_tab_id})
            herdr_rpc("pane.focus", {"pane_id": vpid})
            ex_cmd = "silent! source ~/.vimrc|silent! call HerdrCleanMainWin()|call timer_start(20,{->HerdrSearchFromFile('/tmp/herdr-vim-search.json')})|visual"
            herdr_rpc("pane.send_keys", {"pane_id": vpid, "keys": ["ctrl+\\", "ctrl+n", "g", "shift+q"]})
            herdr_rpc("pane.send_input", {"pane_id": vpid, "text": ex_cmd, "keys": ["enter"]})
        elif shell_pane:
            spid = shell_pane["pane_id"]
            log(f"herdr search reusing shell_pane={spid}")
            herdr_rpc("pane.focus", {"pane_id": spid})
            vim_cmd = f"cd {shlex.quote(search_dir)} && vim -c \"call timer_start(50, {{-> HerdrSearchFromFile('/tmp/herdr-vim-search.json')}})\""
            herdr_rpc("pane.send_input", {"pane_id": spid, "text": vim_cmd, "keys": ["enter"]})
        else:
            log(f"herdr search splitting new vim pane right of {tg_pane}")
            split_res = herdr_rpc(
                "pane.split",
                {"target_pane_id": tg_pane, "direction": "right", "cwd": search_dir, "focus": True},
            )
            new_pid = (split_res.get("pane") or {}).get("pane_id")
            if new_pid:
                time.sleep(0.08)
                vim_cmd = "vim -c \"call timer_start(50, {-> HerdrSearchFromFile('/tmp/herdr-vim-search.json')})\""
                herdr_rpc("pane.send_input", {"pane_id": new_pid, "text": vim_cmd, "keys": ["enter"]})
        return

    screen_cache = {}

    def read_herdr_screen():
        if not tg_pane:
            return ""
        if "text" not in screen_cache:
            r = herdr_rpc("pane.read", {"pane_id": tg_pane, "source": "visible"})
            screen_cache["text"] = (r.get("read") or {}).get("text") or ""
        return screen_cache["text"]

    res = None
    chosen_raw = ""
    first_cands = []
    for raw in raw_sources:
        cands = extract_candidates(raw)
        if not first_cands and cands:
            first_cands = cands
        log(f"herdr trying raw={raw[:80]!r} -> cands={cands[:5]}")
        res = resolve_any(raw, cands, None, roots, extra_roots, primary_cwd, screen_reader=read_herdr_screen)
        if res:
            chosen_raw = raw
            break

    if not res:
        label = first_cands[0][0] if first_cands else raw_sources[0].strip().splitlines()[0][:40]
        notify_err(f"File not found: {label}")
        return

    clip_meta["last_used"] = chosen_raw
    save_last_clip(clip_meta)

    file_path, proj_root, line = res
    log(f"herdr resolved: file={file_path} root={proj_root} line={line}")

    # 1. Existing Vim pane in the same Tab
    vim_pane = next((p for p in same_tab_panes if is_vim(p)), None)
    switch_tab_id = None

    # 2. Existing Vim pane in another Tab of the same Workspace
    if not vim_pane:
        vim_pane = next((p for p in other_tab_panes if is_vim(p)), None)
        if vim_pane:
            switch_tab_id = vim_pane.get("tab_id")

    # 3. If current pane itself is Vim
    if not vim_pane and clicked_pane and is_vim(clicked_pane):
        vim_pane = clicked_pane

    # 4. Idle shell pane in the same Tab
    shell_pane = next((p for p in same_tab_panes if is_idle_shell(p)), None) if not vim_pane else None

    if is_zoomed and (not vim_pane or vim_pane.get("pane_id") != tg_pane) and not switch_tab_id:
        herdr_rpc("pane.zoom", {"pane_id": tg_pane, "mode": "off"})

    pane_label = f"Vim · {file_path}"

    if vim_pane:
        vpid = vim_pane["pane_id"]
        log(f"herdr reusing vim_pane={vpid} switch_tab={switch_tab_id}")
        if switch_tab_id:
            herdr_rpc("tab.focus", {"tab_id": switch_tab_id})
        herdr_rpc("pane.focus", {"pane_id": vpid})
        herdr_rpc("pane.rename", {"pane_id": vpid, "label": pane_label})
        cd_part = f"silent! cd {vim_escape(proj_root)}|" if proj_root else ""
        cursor_part = f"|call cursor({line},1)|execute 'normal! zz'" if line else ""
        edit_part = f"silent! edit {vim_escape(file_path)}{cursor_part}|set title|let &titlestring=expand('%:p')"
        ex_cmd = f"silent! call HerdrCleanMainWin()|if &bt!=''||&ft=~#'^\\(fern\\|tagbar\\|qf\\)$'|wincmd p|endif|set hidden|{cd_part}{edit_part}|visual"
        herdr_rpc("pane.send_keys", {"pane_id": vpid, "keys": ["ctrl+\\", "ctrl+n", "g", "shift+q"]})
        herdr_rpc("pane.send_input", {"pane_id": vpid, "text": ex_cmd, "keys": ["enter"]})
    elif shell_pane:
        spid = shell_pane["pane_id"]
        log(f"herdr reusing shell_pane={spid}")
        herdr_rpc("pane.focus", {"pane_id": spid})
        herdr_rpc("pane.rename", {"pane_id": spid, "label": pane_label})
        cd_cmd = f"cd {shlex.quote(proj_root)} && " if proj_root else ""
        line_arg = f"+{line} " if line else ""
        vim_cmd = f"{cd_cmd}vim {line_arg}{shlex.quote(file_path)}"
        herdr_rpc("pane.send_input", {"pane_id": spid, "text": vim_cmd, "keys": ["enter"]})
    else:
        log(f"herdr splitting new vim pane right of {tg_pane}")
        split_cwd = proj_root if (proj_root and os.path.isdir(proj_root)) else os.path.dirname(file_path)
        split_res = herdr_rpc(
            "pane.split",
            {"target_pane_id": tg_pane, "direction": "right", "cwd": split_cwd, "focus": True},
        )
        new_pid = (split_res.get("pane") or {}).get("pane_id")
        if new_pid:
            herdr_rpc("pane.rename", {"pane_id": new_pid, "label": pane_label})
            time.sleep(0.08)
            line_arg = f"+{line} " if line else ""
            vim_cmd = f"vim {line_arg}{shlex.quote(file_path)}"
            herdr_rpc("pane.send_input", {"pane_id": new_pid, "text": vim_cmd, "keys": ["enter"]})


def main():
    lock_fp = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return

    # Check if invoked in herdr (TUI) mode via --herdr [open|search] or HERDR_PLUGIN_CONTEXT_JSON
    if len(sys.argv) >= 2 and sys.argv[1] == "--herdr":
        mode = sys.argv[2] if len(sys.argv) >= 3 else "open"
        ctx_raw = os.environ.get("HERDR_PLUGIN_CONTEXT_JSON") or ""
        try:
            ctx = json.loads(ctx_raw) if ctx_raw else {}
        except Exception:
            ctx = {}
        run_herdr_mode(mode, ctx)
        return

    if len(sys.argv) < 2:
        if os.environ.get("HERDR_PLUGIN_CONTEXT_JSON") or os.environ.get("HERDR_ENV"):
            action_id = os.environ.get("HERDR_PLUGIN_ACTION_ID") or ""
            mode = "search" if action_id.endswith("search") else "open"
            ctx_raw = os.environ.get("HERDR_PLUGIN_CONTEXT_JSON") or ""
            try:
                ctx = json.loads(ctx_raw) if ctx_raw else {}
            except Exception:
                ctx = {}
            run_herdr_mode(mode, ctx)
        return

    state = json.loads(sys.argv[1])
    tg_pane = state.get("pane")
    tg_term = state.get("terminal")
    log(f"--- open_vim start: pane={tg_pane} term={tg_term} ---")

    raw_sources, clip_meta = collect_raw_sources(state)
    if not raw_sources:
        notify_err("Please select a filename first")
        return

    all_panes = state.get("panes") or []
    all_terms = state.get("terminals") or []
    all_spaces = state.get("spaces") or []

    clicked_pane = next((p for p in all_panes if p.get("pane") == tg_pane), None)
    term_addr = tg_term or (clicked_pane.get("terminal") if clicked_pane else "")
    clicked_term_summary = next((t for t in all_terms if t.get("address") == term_addr), None)
    clicked_term = get_term_info(term_addr, clicked_term_summary)

    clicked_tab = (clicked_pane or {}).get("tab") or ""
    owner_space = next(
        (s for s in all_spaces if any(t.get("id") == clicked_tab for t in (s.get("tabs") or []))),
        None,
    ) or next((s for s in all_spaces if s.get("active")), None)

    fg_cwd = (clicked_term.get("foreground") or {}).get("cwd") or ""
    pane_cwd = (clicked_pane or {}).get("cwd") or ""
    term_cwd = clicked_term.get("cwd") or ""
    space_cwd = (owner_space or {}).get("folder") or ""
    primary_cwd = fg_cwd or pane_cwd or term_cwd or space_cwd or os.getcwd()

    roots = []
    live_cwds = [fg_cwd, pane_cwd, term_cwd]
    for c in (live_cwds if any(live_cwds) else [space_cwd]):
        if c and os.path.isdir(c) and c not in roots:
            roots.append(c)
        gt = git_toplevel(c)
        if gt and gt not in roots:
            roots.append(gt)

    extra_roots = []
    herdr_cfg = os.path.expanduser("~/.config/herdr-app")
    if os.path.isdir(herdr_cfg) and herdr_cfg not in roots:
        extra_roots.append(herdr_cfg)
    for t in all_terms:
        tc = (t.get("foreground") or {}).get("cwd") or t.get("cwd") or ""
        if tc and os.path.isdir(tc) and tc not in roots and tc not in extra_roots:
            extra_roots.append(tc)
    if space_cwd and os.path.isdir(space_cwd) and space_cwd not in roots and space_cwd not in extra_roots:
        extra_roots.append(space_cwd)

    log(f"primary_cwd={primary_cwd} roots={roots}")

    mode = state.get("mode") or "open"
    term_cache = {}

    def term_for_pane(p):
        addr = p.get("terminal")
        if not addr:
            return {}
        if addr not in term_cache:
            summary = next((x for x in all_terms if x.get("address") == addr), None)
            term_cache[addr] = get_term_info(addr, summary)
        return term_cache[addr]

    def is_vim(p):
        prog = p.get("program") or {}
        k = (prog.get("key") or "").lower()
        n = (prog.get("name") or "").lower()
        t = term_for_pane(p)
        fg = ((t.get("foreground") or {}).get("name") or t.get("agent") or "").lower()
        return k in ("vim", "nvim") or n in ("vim", "neovim") or fg in ("vim", "nvim")

    def is_idle_shell(p):
        if is_vim(p) or p.get("status"):
            return False
        t = term_for_pane(p)
        fg = ((t.get("foreground") or {}).get("name") or "").lower()
        if fg and fg not in ("bash", "zsh", "fish", "sh", "dash", "ksh", "nu", "pwsh", "powershell"):
            return False
        return bool((p.get("program") or {}).get("shell"))

    same_tab_panes = [
        p
        for p in all_panes
        if clicked_tab and p.get("tab") == clicked_tab and p.get("pane") != tg_pane and p.get("terminal")
    ]
    space_tab_ids = [t.get("id") for t in ((owner_space or {}).get("tabs") or []) if t.get("id")]
    other_tab_panes = [
        p
        for p in all_panes
        if p.get("tab") in space_tab_ids
        and p.get("tab") != clicked_tab
        and p.get("pane") != tg_pane
        and p.get("terminal")
    ]

    if mode == "search":
        raw_q = raw_sources[0]
        clean_lines = [
            re.sub(r"^[│┃┆┊╭╮╯╰─━\s]+|[│┃┆┊╭╮╯╰─━\s]+$", "", ln).strip()
            for ln in raw_q.splitlines()
        ]
        clean_lines = [ln for ln in clean_lines if ln]
        query = clean_lines[0] if clean_lines else raw_q.strip()
        if not query:
            notify_err("No text selected for search")
            return
        clip_meta["last_used"] = raw_q
        save_last_clip(clip_meta)

        search_dir = (
            primary_cwd
            if (primary_cwd and os.path.isdir(primary_cwd))
            else (roots[0] if roots else os.path.expanduser("~"))
        )
        search_file = "/tmp/herdr-vim-search.json"
        try:
            with open(search_file, "w") as f:
                json.dump({"dir": search_dir, "query": query}, f)
        except Exception as e:
            log(f"failed writing {search_file}: {e}")

        log(f"search mode: dir={search_dir} query={query!r}")

        vim_pane = clicked_pane if (clicked_pane and is_vim(clicked_pane)) else None
        switch_tab_id = None
        if not vim_pane:
            vim_pane = next((p for p in same_tab_panes if is_vim(p)), None)
        if not vim_pane:
            vim_pane = next((p for p in other_tab_panes if is_vim(p)), None)
            if vim_pane:
                switch_tab_id = vim_pane.get("tab")
        shell_pane = next((p for p in same_tab_panes if is_idle_shell(p)), None) if not vim_pane else None

        if clicked_pane and clicked_pane.get("zoomed") and (not vim_pane or vim_pane.get("pane") != tg_pane) and not switch_tab_id:
            run_cmd(["herdr-app", "do", "pane.zoom", json.dumps({"pane": tg_pane})])

        if vim_pane:
            log(f"search reusing vim_pane={vim_pane.get('pane')} term={vim_pane.get('terminal')} switch_tab={switch_tab_id}")
            if switch_tab_id:
                run_cmd(["herdr-app", "do", "tab.select", json.dumps({"id": switch_tab_id})])
            run_cmd(["herdr-app", "do", "pane.focus", json.dumps({"pane": vim_pane["pane"]})])
            ex_cmd = "silent! source ~/.vimrc|silent! call HerdrCleanMainWin()|call timer_start(20,{->HerdrSearchFromFile('/tmp/herdr-vim-search.json')})|visual"
            run_cmd(["hc", "keys", vim_pane["terminal"], "ctrl+\\", "ctrl+n", "g", "shift+q"])
            run_cmd(["hc", "send", "--force", vim_pane["terminal"], ex_cmd])
        elif shell_pane:
            log(f"search reusing shell_pane={shell_pane.get('pane')} term={shell_pane.get('terminal')}")
            run_cmd(["herdr-app", "do", "pane.focus", json.dumps({"pane": shell_pane["pane"]})])
            vim_cmd = f"cd {shlex.quote(search_dir)} && vim -c \"call timer_start(50, {{-> HerdrSearchFromFile('/tmp/herdr-vim-search.json')}})\""
            run_cmd(["hc", "send", "--force", shell_pane["terminal"], vim_cmd])
        else:
            log(f"search splitting new vim pane right of {tg_pane}")
            argv = [
                "vim",
                "-c",
                f"cd {vim_escape(search_dir)}",
                "-c",
                "call timer_start(50, {-> HerdrSearchFromFile('/tmp/herdr-vim-search.json')})",
            ]
            run_cmd(["herdr-app", "do", "pane.split", json.dumps({"direction": "right", "pane": tg_pane, "argv": argv})])
        return

    res = None
    chosen_raw = ""
    first_cands = []
    for raw in raw_sources:
        cands = extract_candidates(raw)
        if not first_cands and cands:
            first_cands = cands
        log(f"trying raw={raw[:80]!r} -> cands={cands[:5]}")
        res = resolve_any(raw, cands, term_addr, roots, extra_roots, primary_cwd)
        if res:
            chosen_raw = raw
            break

    if not res:
        label = first_cands[0][0] if first_cands else raw_sources[0].strip().splitlines()[0][:40]
        notify_err(f"File not found: {label}")
        return

    clip_meta["last_used"] = chosen_raw
    save_last_clip(clip_meta)

    file_path, proj_root, line = res
    log(f"resolved: file={file_path} root={proj_root} line={line}")

    # 1. Existing Vim pane in the same Tab
    vim_pane = next((p for p in same_tab_panes if is_vim(p)), None)
    switch_tab_id = None

    # 2. Existing Vim pane in another Tab of the same Space
    if not vim_pane:
        vim_pane = next((p for p in other_tab_panes if is_vim(p)), None)
        if vim_pane:
            switch_tab_id = vim_pane.get("tab")

    # 3. Idle shell pane in the same Tab
    shell_pane = next((p for p in same_tab_panes if is_idle_shell(p)), None) if not vim_pane else None

    if clicked_pane and clicked_pane.get("zoomed") and not switch_tab_id:
        run_cmd(["herdr-app", "do", "pane.zoom", json.dumps({"pane": tg_pane})])

    if vim_pane:
        log(f"reusing vim_pane={vim_pane.get('pane')} term={vim_pane.get('terminal')} switch_tab={switch_tab_id}")
        if switch_tab_id:
            run_cmd(["herdr-app", "do", "tab.select", json.dumps({"id": switch_tab_id})])
        run_cmd(["herdr-app", "do", "pane.focus", json.dumps({"pane": vim_pane["pane"]})])
        cd_part = f"silent! cd {vim_escape(proj_root)}|" if proj_root else ""
        cursor_part = f"|call cursor({line},1)|execute 'normal! zz'" if line else ""
        edit_part = f"silent! edit {vim_escape(file_path)}{cursor_part}|set title|let &titlestring=expand('%:p')"
        ex_cmd = f"silent! call HerdrCleanMainWin()|if &bt!=''||&ft=~#'^\\(fern\\|tagbar\\|qf\\)$'|wincmd p|endif|set hidden|{cd_part}{edit_part}|visual"
        run_cmd(["hc", "keys", vim_pane["terminal"], "ctrl+\\", "ctrl+n", "g", "shift+q"])
        run_cmd(["hc", "send", "--force", vim_pane["terminal"], ex_cmd])
    elif shell_pane:
        log(f"reusing shell_pane={shell_pane.get('pane')} term={shell_pane.get('terminal')}")
        run_cmd(["herdr-app", "do", "pane.focus", json.dumps({"pane": shell_pane["pane"]})])
        cd_cmd = f"cd {shlex.quote(proj_root)} && " if proj_root else ""
        line_arg = f"+{line} " if line else ""
        vim_cmd = f"{cd_cmd}vim {line_arg}{shlex.quote(file_path)}"
        run_cmd(["hc", "send", "--force", shell_pane["terminal"], vim_cmd])
    else:
        log(f"splitting new vim pane right of {tg_pane}")
        argv = ["vim"]
        if proj_root:
            argv += ["-c", f"cd {vim_escape(proj_root)}"]
        if line:
            argv.append(f"+{line}")
        argv += ["-c", "set title | let &titlestring=expand('%:p')", file_path]
        run_cmd(["herdr-app", "do", "pane.split", json.dumps({"direction": "right", "pane": tg_pane, "argv": argv})])


if __name__ == "__main__":
    main()
