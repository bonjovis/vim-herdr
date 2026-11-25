#!/usr/bin/env python3
"""Unified AI Agent CLI bridge for Vim (agy, claude, codex, and live Herdr panes)."""

import datetime
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import uuid


ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def parse_last_json(stdout: str):
    for line in reversed(stdout.splitlines()):
        s = line.strip()
        if not s.startswith("{"):
            continue
        try:
            return json.loads(s)
        except Exception:
            continue
    return None


def build_initial_prompt(req: dict) -> str:
    kind = (req.get("kind") or "symbol").strip()
    file_path = req.get("file") or ""
    line = req.get("line") or 1
    symbol = (req.get("symbol") or "").strip()
    code = (req.get("code") or "").strip()
    custom_q = (req.get("question") or "").strip()

    if kind == "qa":
        parts = [
            "请结合当前项目的真实代码检索确认（不要臆测），回答以下问题：",
            f"**问题**：{custom_q}",
        ]
        if file_path and file_path != "[No Name]":
            parts.append(f"（当前光标位于 `{file_path}:{line}`，仅供参考，请以全项目代码为准。）")
        if code:
            parts.append(f"用户同时附带了如下代码片段：\n```\n{code}\n```")
        parts.append(
            "请按以下结构用 Markdown 清晰作答：\n"
            "1. **核心总结**：先用简洁清晰的语言总结该功能/问题的整体实现逻辑、数据流或调用链路。\n"
            "2. **### 涉及的代码位置**：按执行顺序或模块分组，逐条列出所有关键代码文件与行号，格式严格使用：\n"
            "   - `相对路径/文件名:行号` — 该处代码承担的职责与关键符号名\n"
            "   （请确保每条路径和行号都基于项目真实代码核实，便于编辑器一键跳转。）\n"
            "3. 如需提供后续深入排查方向，可在末尾添加 `### 下一步建议` 并列出 2~4 条编号选项（`1. ...`、`2. ...`）。"
        )
        return "\n\n".join(parts)

    target_desc = f"`{symbol}`" if symbol else "选中的方法/代码"
    loc_desc = f"`{file_path}:{line}`" if file_path else "当前文件"

    parts = [
        f"请结合当前项目代码，深入分析 {loc_desc} 中的 {target_desc}。",
    ]
    if code:
        parts.append(f"相关代码片段如下：\n```\n{code}\n```")

    if custom_q:
        parts.append(f"具体问题：{custom_q}")
    else:
        parts.append(
            "请按以下 4 个部分清晰作答（使用 Markdown 格式，直接结合项目真实代码检索确认，不要臆测）：\n"
            "1. **具体作用**：该方法的核心职责、输入/输出与关键业务/技术逻辑。\n"
            "2. **使用方法**：参数含义、返回值、调用前置条件与常见使用示例。\n"
            "3. **在整个项目里的作用**：所属模块/架构层级，以及它在整个系统中的角色。\n"
            "4. **调用的代码层级关系**：用缩进树状图展示完整调用链（上游谁调用了它 -> 当前方法 -> 它内部调用了哪些核心下游方法/服务），并标注关键文件路径与行号。\n"
            "5. 如需向用户提供后续排查方向或确认选项，请在回答末尾添加 `### 下一步建议` 并列出 2~4 条编号选项（`1. ...`、`2. ...`）。"
        )
    return "\n\n".join(parts)


FIXED_SECTION_PREFIXES = (
    "具体作用",
    "使用方法",
    "在整个项目里的作用",
    "在项目中的作用",
    "调用的代码层级关系",
)


def _clean_option_text(text: str) -> str:
    s = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    s = s.replace("`", "").strip()
    return re.sub(r"\s+", " ", s)


def extract_options(answer: str, suggestions=None) -> list:
    """Extract up to 9 interactive follow-up options from AI response or structured suggestions."""
    opts = []
    if isinstance(suggestions, list):
        for s in suggestions:
            if isinstance(s, str) and s.strip():
                opts.append(_clean_option_text(s))
        if opts:
            return opts[:9]

    lines = answer.splitlines()
    if not lines:
        return []

    # Prefer items under a trailing suggestion/option heading if present
    start_idx = max(0, len(lines) - 35)
    heading_re = re.compile(r"^\s*#{1,6}\s*.*(下一步|建议|选项|可选|追问|接下来|options|next)", re.I)
    for i in range(len(lines) - 1, -1, -1):
        if heading_re.match(lines[i]):
            start_idx = i + 1
            break

    item_re = re.compile(r"^\s*(?:\d+[\.\)、]|[A-Da-d][\.\)、])\s+(.+)$")
    bullet_bold_re = re.compile(r"^\s*[-*]\s+(\*\*.+)$")
    in_code = False
    for raw in lines[:start_idx]:
        if raw.strip().startswith("```"):
            in_code = not in_code
    current = []
    for raw in lines[start_idx:]:
        stripped = raw.strip()
        if stripped.startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        if stripped.startswith("#") and current:
            break
        m = item_re.match(raw) or bullet_bold_re.match(raw)
        if m:
            txt = _clean_option_text(m.group(1))
            if txt and not any(txt.startswith(p) for p in FIXED_SECTION_PREFIXES):
                current.append(txt)
        elif not stripped and current:
            continue

    return current[:9]


CODE_REF_WITH_LINE_RE = re.compile(
    r"(?:`|\b)([A-Za-z0-9_./-]+\.[A-Za-z0-9_+-]+)(?::|#L)(\d+)(?:-\d+|:\d+)?`?"
)
CODE_REF_FILE_ONLY_RE = re.compile(
    r"`([A-Za-z0-9_./-]+\.[A-Za-z0-9_+-]+)`"
)


def _resolve_existing_file(raw_path: str, cwd: str) -> str:
    p = raw_path.strip().lstrip("./")
    if not p or "://" in p:
        return ""
    if os.path.isabs(raw_path) and os.path.isfile(raw_path):
        try:
            rel = os.path.relpath(raw_path, cwd)
            if not rel.startswith(".."):
                return rel
        except ValueError:
            pass
        return raw_path
    cand = os.path.join(cwd, p)
    if os.path.isfile(cand):
        return p
    return ""


def _extract_ref_desc(raw_line: str, matched_span: str) -> str:
    s = raw_line.replace(matched_span, " ")
    s = re.sub(r"^\s*(?:[-*+]|\d+[\.\)、])\s*", "", s)
    s = re.sub(r"^[\s—–:\-：|]+", "", s)
    s = _clean_option_text(s)
    if len(s) > 100:
        s = s[:97] + "..."
    return s


def extract_code_refs(answer: str, cwd: str) -> list:
    """Extract existing project file:line references from an AI answer."""
    if not answer or not cwd:
        return []
    lines = answer.splitlines()
    heading_re = re.compile(r"^\s*#{1,6}\s*.*(涉及的代码|相关代码|代码位置|核心文件|关键文件|files|locations)", re.I)

    # First pass: collect from dedicated code-location section(s), then rest of answer
    priority_indices = []
    other_indices = []
    in_code = False
    in_ref_section = False
    for idx, raw in enumerate(lines):
        stripped = raw.strip()
        if stripped.startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        if stripped.startswith("#"):
            in_ref_section = bool(heading_re.match(raw))
            continue
        if in_ref_section:
            priority_indices.append((idx, True))
        else:
            other_indices.append((idx, False))

    refs = []
    seen = set()
    for idx, allow_file_only in priority_indices + other_indices:
        raw = lines[idx]
        matched_any = False
        for m in CODE_REF_WITH_LINE_RE.finditer(raw):
            rel = _resolve_existing_file(m.group(1), cwd)
            if not rel:
                continue
            lnum = max(1, int(m.group(2)))
            key = (rel, lnum)
            matched_any = True
            if key in seen:
                continue
            seen.add(key)
            refs.append({
                "file": rel,
                "line": lnum,
                "desc": _extract_ref_desc(raw, m.group(0)),
            })
        if not matched_any and allow_file_only:
            for m in CODE_REF_FILE_ONLY_RE.finditer(raw):
                rel = _resolve_existing_file(m.group(1), cwd)
                if not rel:
                    continue
                key = (rel, 1)
                if key in seen:
                    continue
                seen.add(key)
                refs.append({
                    "file": rel,
                    "line": 1,
                    "desc": _extract_ref_desc(raw, m.group(0)),
                })
        if len(refs) >= 50:
            break
    return refs


DEFAULT_TIMEOUT = 240


def _run_cli(cmd: list, cwd: str, timeout: int = DEFAULT_TIMEOUT):
    """Run an AI CLI subprocess with stdin closed and a bounded timeout."""
    return subprocess.run(
        cmd,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def run_agy(req: dict, prompt: str) -> dict:
    cwd = req.get("cwd") or os.getcwd()
    session_id = (req.get("session_id") or "").strip()
    cmd = ["agy", "--dangerously-skip-permissions", "--output-format", "json"]
    if session_id:
        cmd += ["--conversation", session_id]
    cmd += ["-p", prompt]

    try:
        proc = _run_cli(cmd, cwd)
    except subprocess.TimeoutExpired:
        return {"ok": False, "agent": "agy", "error": f"请求超时 ({DEFAULT_TIMEOUT}s)"}

    data = parse_last_json(proc.stdout)
    if not data:
        err = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        return {"ok": False, "agent": "agy", "error": err}

    answer = data.get("response") or data.get("result") or ""
    conv_id = data.get("conversation_id") or data.get("session_id") or session_id
    if proc.returncode != 0 and not answer:
        return {"ok": False, "agent": "agy", "error": data.get("error") or proc.stderr.strip()}

    return {
        "ok": True,
        "agent": "agy",
        "session_id": conv_id,
        "answer": answer.strip(),
    }


def run_claude(req: dict, prompt: str) -> dict:
    cwd = req.get("cwd") or os.getcwd()
    session_id = (req.get("session_id") or "").strip()
    cmd = ["claude", "--dangerously-skip-permissions", "-p", "--output-format", "json"]
    if session_id:
        cmd += ["--resume", session_id]
    cmd.append(prompt)

    try:
        proc = _run_cli(cmd, cwd)
    except subprocess.TimeoutExpired:
        return {"ok": False, "agent": "claude", "error": f"请求超时 ({DEFAULT_TIMEOUT}s)"}

    data = parse_last_json(proc.stdout)
    if not data:
        err = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        return {"ok": False, "agent": "claude", "error": err}

    if data.get("is_error"):
        return {"ok": False, "agent": "claude", "error": data.get("result") or "Claude error"}

    answer = data.get("result") or data.get("response") or ""
    sid = data.get("session_id") or session_id
    return {
        "ok": True,
        "agent": "claude",
        "session_id": sid,
        "answer": answer.strip(),
    }


def run_codex(req: dict, prompt: str) -> dict:
    cwd = req.get("cwd") or os.getcwd()
    session_id = (req.get("session_id") or "").strip()

    with tempfile.NamedTemporaryFile("r+", suffix=".md", delete=False) as tf:
        out_path = tf.name

    try:
        if session_id:
            cmd = [
                "codex",
                "exec",
                "resume",
                session_id,
                "--dangerously-bypass-approvals-and-sandbox",
                "--json",
                "--skip-git-repo-check",
                "-o",
                out_path,
                prompt,
            ]
        else:
            cmd = [
                "codex",
                "exec",
                "--dangerously-bypass-approvals-and-sandbox",
                "--json",
                "--skip-git-repo-check",
                "-C",
                cwd,
                "-o",
                out_path,
                prompt,
            ]

        try:
            proc = _run_cli(cmd, cwd)
        except subprocess.TimeoutExpired:
            return {"ok": False, "agent": "codex", "error": f"请求超时 ({DEFAULT_TIMEOUT}s)"}

        thread_id = session_id
        for line in proc.stdout.splitlines():
            s = line.strip()
            if not s.startswith("{"):
                continue
            try:
                ev = json.loads(s)
                if ev.get("type") == "thread.started" and ev.get("thread_id"):
                    thread_id = ev["thread_id"]
            except Exception:
                pass

        answer = ""
        if os.path.isfile(out_path):
            with open(out_path, "r", encoding="utf-8", errors="replace") as f:
                answer = f.read().strip()

        if proc.returncode != 0 and not answer:
            err = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
            return {"ok": False, "agent": "codex", "error": err}

        return {
            "ok": True,
            "agent": "codex",
            "session_id": thread_id,
            "answer": answer,
        }
    finally:
        try:
            os.unlink(out_path)
        except OSError:
            pass


def extract_terminal_reply(before_text: str, after_text: str, sent_line: str) -> str:
    after_lines = [strip_ansi(ln).rstrip() for ln in after_text.splitlines()]
    before_lines = [strip_ansi(ln).rstrip() for ln in before_text.splitlines()]

    # Try to locate the sent prompt near the bottom of after_lines
    marker = sent_line[:40].strip()
    start_idx = 0
    if marker:
        for i in range(len(after_lines) - 1, -1, -1):
            if marker in after_lines[i]:
                start_idx = i + 1
                break

    if start_idx == 0 and before_lines:
        anchor = ""
        for ln in reversed(before_lines):
            if ln.strip():
                anchor = ln.strip()
                break
        if anchor:
            for i in range(len(after_lines) - 1, -1, -1):
                if after_lines[i].strip() == anchor:
                    start_idx = i + 1
                    break

    reply_lines = after_lines[start_idx:]
    # Trim trailing empty lines and TUI bottom prompt chrome
    while reply_lines and (
        not reply_lines[-1].strip()
        or set(reply_lines[-1].strip()) <= set("─━╭╮╰╯│ ")
        or reply_lines[-1].strip().startswith((">", "❯", "›"))
    ):
        reply_lines.pop()

    return "\n".join(reply_lines).strip() or "(已在目标 Herdr Agent 窗口执行，请查看对应窗口输出)"


def run_herdr_window(req: dict, prompt: str, term_addr: str) -> dict:
    # Collapse newlines for safe single-turn TUI paste via hc send
    compact = re.sub(r"\s*\n+\s*", " | ", prompt).strip()

    before = subprocess.run(
        ["hc", "read", "--lines", "120", term_addr],
        capture_output=True,
        text=True,
    )
    send_proc = subprocess.run(
        ["hc", "send", term_addr, compact],
        capture_output=True,
        text=True,
    )
    if send_proc.returncode != 0:
        return {
            "ok": False,
            "agent": f"hc:{term_addr}",
            "error": (send_proc.stderr or send_proc.stdout).strip(),
        }

    subprocess.run(
        ["hc", "wait", "--timeout", "180", term_addr],
        capture_output=True,
        text=True,
    )
    after = subprocess.run(
        ["hc", "read", "--lines", "350", term_addr],
        capture_output=True,
        text=True,
    )
    answer = extract_terminal_reply(before.stdout, after.stdout, compact)
    return {
        "ok": True,
        "agent": f"hc:{term_addr}",
        "session_id": term_addr,
        "answer": answer,
    }


AGENT_NAMES = (
    "claude",
    "codex",
    "agy",
    "antigravity",
    "gemini",
    "opencode",
    "cursor",
    "copilot",
    "grok",
    "kimi",
)


def _herdr_tui_rpc(method: str, params=None, timeout: float = 1.5) -> dict:
    sock_path = os.environ.get("HERDR_SOCKET_PATH") or os.path.expanduser("~/.config/herdr/herdr.sock")
    if not os.path.exists(sock_path):
        return {}
    req = {"id": f"vim-ai-{int(time.time() * 1000)}", "method": method, "params": params or {}}
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
        resp = json.loads(line) if line else {}
        return resp.get("result") or {}
    except Exception:
        return {}


def _detect_agent_name(info: dict) -> str:
    fg = info.get("foreground") or {}
    fg_name = (fg.get("name") or "").lower()
    fg_argv = " ".join(fg.get("argv") or []).lower()
    status_app = ((info.get("status") or {}).get("app") or "").lower()
    agent_field = (info.get("agent") or "").lower()

    if status_app:
        return status_app
    if fg_name in AGENT_NAMES:
        return fg_name
    for k in AGENT_NAMES:
        if re.search(rf"(?:^|/|\s){re.escape(k)}(?:\s|$)", fg_argv):
            return k
    if agent_field and agent_field not in ("bash", "zsh", "fish", "sh"):
        for k in AGENT_NAMES:
            if k in agent_field:
                return k
    return ""


def list_herdr_agents(self_addr: str = "", cur_cwd: str = "") -> list:
    results = []
    norm_cur = os.path.normpath(cur_cwd) if cur_cwd else ""

    # 1. Check hc / herdr-app live terminals
    try:
        raw = subprocess.check_output(
            ["hc", "ls", "--json"], text=True, stderr=subprocess.DEVNULL, timeout=2.0
        )
        data = json.loads(raw)
        terms = data.get("terminals") or []
        unreachable = {
            m.get("name")
            for m in (data.get("machines") or [])
            if m.get("name") and m.get("state") != "connected"
        }
    except Exception:
        terms = []
        unreachable = set()

    my_space = ""
    my_tab = ""
    if self_addr:
        try:
            self_info = json.loads(
                subprocess.check_output(
                    ["hc", "get", "--json", self_addr],
                    text=True,
                    stderr=subprocess.DEVNULL,
                    timeout=1.5,
                )
            )
            self_labels = self_info.get("labels") or {}
            my_space = self_labels.get("herdr.space") or ""
            my_tab = self_labels.get("herdr.tab") or ""
        except Exception:
            pass

    for t in terms:
        if t.get("state") != "live":
            continue
        addr = t.get("address") or ""
        if not addr or addr == self_addr:
            continue
        if "/" in addr and addr.split("/", 1)[0] in unreachable:
            continue
        try:
            info = json.loads(
                subprocess.check_output(
                    ["hc", "get", "--json", addr],
                    text=True,
                    stderr=subprocess.DEVNULL,
                    timeout=1.5,
                )
            )
        except Exception:
            continue
        agent_label = _detect_agent_name(info)
        if not agent_label:
            continue
        labels = info.get("labels") or {}
        where = labels.get("where") or t.get("where") or ""
        cwd = (info.get("foreground") or {}).get("cwd") or info.get("cwd") or t.get("cwd") or ""
        norm_tcwd = os.path.normpath(cwd) if cwd else ""
        t_tab = labels.get("herdr.tab") or ""
        t_space = labels.get("herdr.space") or ""

        if my_tab and t_tab == my_tab:
            prio, scope_tag = 1, "★ 同分屏 Tab"
        elif my_space and t_space == my_space:
            prio, scope_tag = 2, "● 同工作区"
        elif norm_cur and norm_tcwd and (
            norm_cur == norm_tcwd
            or norm_cur.startswith(norm_tcwd + os.sep)
            or norm_tcwd.startswith(norm_cur + os.sep)
        ):
            prio, scope_tag = 3, "◆ 同项目目录"
        else:
            prio, scope_tag = 4, "其他窗口"

        results.append(
            {
                "id": f"hc:{addr}",
                "addr": addr,
                "label": f"[{addr}] {agent_label} ({where or os.path.basename(cwd)})",
                "scope": scope_tag,
                "priority": prio,
                "tab": t_tab,
                "space": t_space,
                "cwd": cwd,
            }
        )

    # 2. Check Herdr TUI panes if HERDR_PANE_ID is present and no hc match found
    self_pane = os.environ.get("HERDR_PANE_ID") or ""
    if self_pane:
        snap = (_herdr_tui_rpc("session.snapshot") or {}).get("snapshot") or {}
        panes = snap.get("panes") or []
        me = next((p for p in panes if p.get("pane_id") == self_pane), {})
        p_tab = me.get("tab_id") or ""
        p_ws = me.get("workspace_id") or ""
        for p in panes:
            pid = p.get("pane_id") or ""
            if not pid or pid == self_pane:
                continue
            ag = (p.get("agent") or "").lower()
            if not ag and not any(k in (p.get("label") or "").lower() for k in AGENT_NAMES):
                continue
            pcwd = p.get("foreground_cwd") or p.get("cwd") or ""
            if p_tab and p.get("tab_id") == p_tab:
                prio, scope_tag = 1, "★ 同分屏 Tab"
            elif p_ws and p.get("workspace_id") == p_ws:
                prio, scope_tag = 2, "● 同工作区"
            else:
                prio, scope_tag = 3, "Herdr TUI"
            results.append(
                {
                    "id": f"herdr:{pid}",
                    "addr": pid,
                    "label": f"[{pid}] {ag or p.get('label') or 'agent'} ({os.path.basename(pcwd)})",
                    "scope": scope_tag,
                    "priority": prio,
                    "cwd": pcwd,
                }
            )

    results.sort(key=lambda r: (r.get("priority", 9), r.get("id", "")))
    return results


def _read_sys_clip() -> bytes:
    for cmd in (
        ["wl-paste", "--no-newline"],
        ["xclip", "-selection", "clipboard", "-o"],
        ["xsel", "--clipboard", "--output"],
        ["pbpaste"],
    ):
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=0.5)
            if r.returncode == 0:
                return r.stdout
        except Exception:
            continue
    return b""


def _write_sys_clip(data: bytes) -> bool:
    for cmd in (
        ["wl-copy"],
        ["xclip", "-selection", "clipboard", "-in"],
        ["xsel", "--clipboard", "--input"],
        ["pbcopy"],
    ):
        try:
            p = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            p.communicate(input=data, timeout=0.6)
            if p.returncode == 0:
                return True
        except Exception:
            continue
    return False


def send_ref_to_agent(target_id: str, full_file: str, start_line: int, end_line: int, agent_cwd: str = "") -> dict:
    path_str = full_file
    if agent_cwd and os.path.isabs(full_file):
        try:
            rel = os.path.relpath(full_file, agent_cwd)
            if not rel.startswith(".."):
                path_str = rel
        except ValueError:
            pass

    s_ln = max(1, int(start_line))
    e_ln = max(s_ln, int(end_line))
    loc = f"@{path_str}:{s_ln}-{e_ln}" if e_ln > s_ln else f"@{path_str}:{s_ln}"
    payload = loc + " "

    if target_id.startswith("herdr:"):
        pid = target_id.split(":", 1)[1]
        _herdr_tui_rpc("pane.focus", {"pane_id": pid})
        _herdr_tui_rpc("pane.send_input", {"pane_id": pid, "text": payload})
        return {"ok": True, "ref": loc, "target": target_id, "pasted": True}

    addr = target_id.split(":", 1)[1] if ":" in target_id else target_id
    saved_clip = _read_sys_clip()
    wrote_clip = _write_sys_clip(payload.encode("utf-8"))

    pasted = False
    if wrote_clip:
        try:
            r_focus = subprocess.run(
                ["herdr-app", "do", "pane.focus", json.dumps({"terminal": addr})],
                capture_output=True,
                text=True,
                timeout=1.5,
            )
            if r_focus.returncode != 0 or '"error"' in (r_focus.stdout or ""):
                subprocess.run(
                    ["herdr-app", "do", "agent.focus", json.dumps({"terminal": addr})],
                    capture_output=True,
                    text=True,
                    timeout=1.5,
                )
            time.sleep(0.04)
            r_paste = subprocess.run(
                ["herdr-app", "do", "terminal.paste", "{}"],
                capture_output=True,
                text=True,
                timeout=1.5,
            )
            if r_paste.returncode == 0 and '"error"' not in (r_paste.stdout or ""):
                pasted = True
                time.sleep(0.10)
                _write_sys_clip(saved_clip)
        except Exception:
            pass

    return {"ok": True, "ref": loc, "target": target_id, "pasted": pasted}


def list_projects(recent_file: str = "", cur_cwd: str = "") -> list:
    markers = (".git", "go.mod", "pom.xml", "build.gradle", "build.gradle.kts", "package.json", "composer.json")
    seen = set()
    items = []

    home_name = os.path.basename(os.path.expanduser("~"))
    skip_parents = {home_name, "work", "projects", "code", "src"}

    def add_proj(path: str, is_recent: bool):
        p = os.path.normpath(os.path.expanduser(path.strip()))
        if not p or p in seen or not os.path.isdir(p):
            return
        seen.add(p)
        name = os.path.basename(p) or p
        parent = os.path.basename(os.path.dirname(p))
        short_name = f"{parent}/{name}" if parent and parent not in skip_parents else name
        tag = "\x1b[33m★ 最近\x1b[0m" if is_recent else "\x1b[36m◆ 项目\x1b[0m"
        cur_mark = " \x1b[32m(当前)\x1b[0m" if cur_cwd and os.path.normpath(cur_cwd) == p else ""
        disp = f"{tag}  \x1b[1m{short_name:<32}\x1b[0m {p}{cur_mark}"
        items.append(f"{p}\t{disp}")

    if recent_file and os.path.isfile(recent_file):
        try:
            with open(recent_file, "r", encoding="utf-8", errors="replace") as f:
                for ln in f:
                    if ln.strip():
                        add_proj(ln, True)
        except OSError:
            pass

    for base in ("~/work", "~/projects", "~/code", "~/src"):
        b = os.path.expanduser(base)
        if not os.path.isdir(b):
            continue
        try:
            lvl1 = sorted(os.scandir(b), key=lambda e: e.name.lower())
        except OSError:
            continue
        for d1 in lvl1:
            if not d1.is_dir() or d1.name.startswith("."):
                continue
            if any(os.path.exists(os.path.join(d1.path, m)) for m in markers):
                add_proj(d1.path, False)
                continue
            try:
                lvl2 = sorted(os.scandir(d1.path), key=lambda e: e.name.lower())
            except OSError:
                continue
            for d2 in lvl2:
                if not d2.is_dir() or d2.name.startswith("."):
                    continue
                if any(os.path.exists(os.path.join(d2.path, m)) for m in markers):
                    add_proj(d2.path, False)

    return items


STORE_DIR_NAME = ".vim-ai"


def ensure_store_dir(cwd: str) -> str:
    store_dir = os.path.join(cwd, STORE_DIR_NAME)
    hist_dir = os.path.join(store_dir, "history")
    os.makedirs(hist_dir, exist_ok=True)

    gi_path = os.path.join(store_dir, ".gitignore")
    if not os.path.isfile(gi_path):
        with open(gi_path, "w", encoding="utf-8") as f:
            f.write("*\n")

    git_exclude = os.path.join(cwd, ".git", "info", "exclude")
    if os.path.isfile(git_exclude) and os.access(git_exclude, os.W_OK):
        try:
            with open(git_exclude, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
            if f"{STORE_DIR_NAME}/" not in content and STORE_DIR_NAME not in content.splitlines():
                with open(git_exclude, "a", encoding="utf-8") as f:
                    if content and not content.endswith("\n"):
                        f.write("\n")
                    f.write(f"{STORE_DIR_NAME}/\n")
        except OSError:
            pass
    return store_dir


def load_index(cwd: str) -> list:
    idx_path = os.path.join(cwd, STORE_DIR_NAME, "index.json")
    if not os.path.isfile(idx_path):
        return []
    try:
        with open(idx_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def save_index(cwd: str, records: list):
    store_dir = ensure_store_dir(cwd)
    idx_path = os.path.join(store_dir, "index.json")
    tmp_path = idx_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(records, f, ensure_ascii=False, indent=2)
    os.replace(tmp_path, idx_path)


def format_code_refs_md(code_refs: list) -> str:
    if not code_refs:
        return ""
    lines = [
        "",
        f"> 📂 **涉及的代码位置（共 {len(code_refs)} 处）**（按 `f` 弹出 FZF 预览并跳转，或光标移到任意代码行按 `Enter` 打开）：",
    ]
    for i, ref in enumerate(code_refs, 1):
        desc = f" — {ref['desc']}" if ref.get("desc") else ""
        lines.append(f"> `[C{i}]` `{ref['file']}:{ref['line']}`{desc}")
    return "\n".join(lines)


def format_options_md(options: list) -> str:
    if not options:
        return ""
    lines = [
        "",
        f"> 💡 **快捷选项**（按数字键 `1`~`{len(options)}` 直接追问，按 `o` 弹窗单选/多选，或光标移到选项行按 `Enter`）：",
    ]
    for i, opt in enumerate(options, 1):
        lines.append(f"> `[{i}]` {opt}")
    return "\n".join(lines)


def _safe_slug(s: str, max_len: int = 80) -> str:
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", s.strip("/"))
    return (slug[:max_len] or "item").strip("_") or "item"


def _merge_code_refs(old_refs: list, new_refs: list) -> list:
    merged = []
    seen = set()
    for ref in (old_refs or []) + (new_refs or []):
        if not isinstance(ref, dict) or not ref.get("file"):
            continue
        key = (ref["file"], int(ref.get("line") or 1))
        if key in seen:
            continue
        seen.add(key)
        merged.append({
            "file": ref["file"],
            "line": int(ref.get("line") or 1),
            "desc": ref.get("desc") or "",
        })
    return merged[:80]


def persist_diagnosis(req: dict, res: dict) -> tuple:
    cwd = req.get("cwd") or os.getcwd()
    if not os.path.isdir(cwd):
        return ("", "")

    store_dir = ensure_store_dir(cwd)
    records = load_index(cwd)
    now_dt = datetime.datetime.now()
    now_str = now_dt.strftime("%Y-%m-%d %H:%M:%S")

    record_id = (req.get("record_id") or "").strip()
    options = res.get("options") or []
    code_refs = res.get("code_refs") or []
    answer = (res.get("answer") or "").strip()
    refs_block = format_code_refs_md(code_refs)
    opt_block = format_options_md(options)

    if record_id:
        for rec in records:
            if rec.get("id") == record_id:
                md_path = os.path.join(store_dir, rec.get("md_rel", ""))
                turn = int(rec.get("turns") or 0) + 1
                q = (req.get("question") or "").strip()
                append_md = f"\n\n---\n\n### 追问 #{turn}：{q}\n\n{answer}{refs_block}{opt_block}\n"
                if os.path.isfile(md_path):
                    with open(md_path, "a", encoding="utf-8") as f:
                        f.write(append_md)
                rec["updated_at"] = now_str
                rec["turns"] = turn
                rec["options"] = options
                rec["code_refs"] = _merge_code_refs(rec.get("code_refs") or [], code_refs)
                if res.get("session_id"):
                    rec["session_id"] = res["session_id"]
                save_index(cwd, records)
                return (record_id, md_path)

    kind = (req.get("kind") or "symbol").strip()
    file_rel = (req.get("file") or "[No Name]").strip()
    line = int(req.get("line") or 1)
    question = (req.get("question") or "").strip()
    symbol = (req.get("symbol") or "AI").strip() or "AI"
    if kind == "qa" and question:
        symbol = question[:40]
        file_rel = "[项目问答]"
    agent = res.get("agent") or req.get("agent") or "agy"
    ts_slug = now_dt.strftime("%Y%m%d_%H%M%S")
    short_uid = uuid.uuid4().hex[:4]
    record_id = f"{ts_slug}_{_safe_slug(agent, 20)}_{short_uid}"
    md_rel = os.path.join(
        "history",
        f"{_safe_slug(file_rel, 70)}__{_safe_slug(symbol, 40)}__{record_id}.md",
    )
    md_path = os.path.join(store_dir, md_rel)

    if kind == "qa":
        title_line = f"# AI 项目问答：{question or symbol}\n"
        meta_line = f"- **Agent**: `{agent}`  |  **项目**: `{cwd}`  |  **时间**: `{now_str}`\n"
        sec_heading = "### 总结与涉及代码\n\n"
    else:
        title_line = f"# AI 代码分析：`{symbol}`\n"
        meta_line = f"- **Agent**: `{agent}`  |  **位置**: `{file_rel}:{line}`  |  **时间**: `{now_str}`\n"
        sec_heading = "### 1. 作用 / 用法 / 项目角色 / 调用层级分析\n\n"

    header_md = (
        f"{title_line}"
        f"{meta_line}"
        f"- **快捷键**: `f` 选择并跳转代码位置  |  `1`~`9` 直选快捷项  |  `o` 弹窗单选/多选  |  `a`/`<Space>ar` 自由追问  |  `R` 重新提问  |  `Enter`/`gf` 跳转文件或选项  |  `q` 关闭 Tab\n\n"
        f"---\n\n"
        f"{sec_heading}"
        f"{answer}{refs_block}{opt_block}\n"
    )
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(header_md)

    new_rec = {
        "id": record_id,
        "kind": kind,
        "question": question,
        "created_at": now_str,
        "updated_at": now_str,
        "file": file_rel,
        "line": line,
        "symbol": symbol,
        "agent": agent,
        "session_id": res.get("session_id") or "",
        "options": options,
        "code_refs": code_refs,
        "turns": 0,
        "md_rel": md_rel,
    }
    records.insert(0, new_rec)
    save_index(cwd, records)
    return (record_id, md_path)


def query_history(cwd: str, file_rel: str = "", symbol: str = "") -> list:
    store_dir = os.path.join(cwd, STORE_DIR_NAME)
    records = load_index(cwd)
    out = []
    norm_file = file_rel.strip("/")
    for rec in records:
        md_path = os.path.join(store_dir, rec.get("md_rel", ""))
        if not os.path.isfile(md_path):
            continue
        if norm_file and rec.get("file", "").strip("/") != norm_file:
            continue
        if symbol and rec.get("symbol", "") != symbol:
            continue
        item = dict(rec)
        item["md_path"] = md_path
        out.append(item)
    return out


def get_record(cwd: str, record_id: str) -> dict:
    for item in query_history(cwd):
        if item.get("id") == record_id:
            return {"ok": True, "record": item}
    return {"ok": False, "error": f"Record not found: {record_id}"}


def build_fallback_followup_prompt(req: dict) -> str:
    cwd = req.get("cwd") or os.getcwd()
    record_id = (req.get("record_id") or "").strip()
    q = (req.get("question") or "").strip()
    file_rel = req.get("file") or ""
    line = req.get("line") or 1
    symbol = req.get("symbol") or ""

    hist_md = ""
    if record_id:
        rec_res = get_record(cwd, record_id)
        if rec_res.get("ok"):
            md_path = rec_res["record"].get("md_path") or ""
            if os.path.isfile(md_path):
                try:
                    with open(md_path, "r", encoding="utf-8", errors="replace") as f:
                        hist_md = f.read().strip()
                except OSError:
                    pass

    if hist_md:
        if len(hist_md) > 6000:
            hist_md = "...(前略)...\n" + hist_md[-6000:]
        return (
            f"以下是此前对项目中 `{file_rel}:{line}` 的 `{symbol}` 所做的历史诊断记录：\n\n"
            f"{hist_md}\n\n---\n"
            f"请结合当前项目代码与上述上下文，回答追问：{q}"
        )
    return build_initial_prompt(req)


def _dispatch_agent(agent: str, req: dict, prompt: str) -> dict:
    if agent == "agy":
        return run_agy(req, prompt)
    if agent == "claude":
        return run_claude(req, prompt)
    if agent == "codex":
        return run_codex(req, prompt)
    if agent.startswith("hc:"):
        return run_herdr_window(req, prompt, agent[3:])
    return {"ok": False, "agent": agent, "error": f"Unknown agent: {agent}"}


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--list-windows":
        self_addr = sys.argv[2] if len(sys.argv) >= 3 else (os.environ.get("HC_TERMINAL_ID") or "")
        cur_cwd = sys.argv[3] if len(sys.argv) >= 4 else ""
        print(json.dumps(list_herdr_agents(self_addr, cur_cwd), ensure_ascii=False))
        return

    if len(sys.argv) >= 6 and sys.argv[1] == "--send-ref":
        res = send_ref_to_agent(
            sys.argv[2],
            sys.argv[3],
            int(sys.argv[4]),
            int(sys.argv[5]),
            sys.argv[6] if len(sys.argv) >= 7 else "",
        )
        print(json.dumps(res, ensure_ascii=False))
        return

    if len(sys.argv) >= 2 and sys.argv[1] == "--list-projects":
        recent_file = sys.argv[2] if len(sys.argv) >= 3 else ""
        cur_cwd = sys.argv[3] if len(sys.argv) >= 4 else ""
        for ln in list_projects(recent_file, cur_cwd):
            print(ln)
        return

    if len(sys.argv) >= 3 and sys.argv[1] == "--query-history":
        cwd = sys.argv[2]
        file_rel = sys.argv[3] if len(sys.argv) >= 4 else ""
        symbol = sys.argv[4] if len(sys.argv) >= 5 else ""
        print(json.dumps(query_history(cwd, file_rel, symbol), ensure_ascii=False))
        return

    if len(sys.argv) >= 4 and sys.argv[1] == "--get-record":
        print(json.dumps(get_record(sys.argv[2], sys.argv[3]), ensure_ascii=False))
        return

    if len(sys.argv) < 2:
        print(json.dumps({"ok": False, "error": "missing request json path"}, ensure_ascii=False))
        return

    req_path = sys.argv[1]
    with open(req_path, "r", encoding="utf-8") as f:
        req = json.load(f)

    agent = (req.get("agent") or "agy").strip()
    has_session = bool((req.get("session_id") or "").strip())
    has_record = bool((req.get("record_id") or "").strip())
    has_question = bool((req.get("question") or "").strip())

    if has_question and has_session:
        res = _dispatch_agent(agent, req, req["question"].strip())
        # Fallback if the cached CLI session expired or was cleaned up locally
        if not res.get("ok") and not agent.startswith("hc:"):
            fallback_req = dict(req)
            fallback_req["session_id"] = ""
            res = _dispatch_agent(agent, fallback_req, build_fallback_followup_prompt(req))
    elif has_question and has_record:
        res = _dispatch_agent(agent, req, build_fallback_followup_prompt(req))
    else:
        res = _dispatch_agent(agent, req, build_initial_prompt(req))

    if res.get("ok"):
        res["options"] = extract_options(res.get("answer") or "", res.get("suggestions"))
        res["code_refs"] = extract_code_refs(res.get("answer") or "", req.get("cwd") or os.getcwd())
        try:
            rec_id, md_path = persist_diagnosis(req, res)
            res["record_id"] = rec_id
            res["md_path"] = md_path
        except Exception:
            pass

    print(json.dumps(res, ensure_ascii=False))


if __name__ == "__main__":
    main()
