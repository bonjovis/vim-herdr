#!/usr/bin/env python3
"""Unified AI Agent CLI bridge for Vim (agy, claude, codex, and live Herdr panes)."""

import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
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
    file_path = req.get("file") or ""
    line = req.get("line") or 1
    symbol = (req.get("symbol") or "").strip()
    code = (req.get("code") or "").strip()
    custom_q = (req.get("question") or "").strip()

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


def list_herdr_agents() -> list:
    try:
        raw = subprocess.check_output(["hc", "ls", "--json"], text=True, stderr=subprocess.DEVNULL)
        data = json.loads(raw)
        terms = data.get("terminals") or []
    except Exception:
        return []

    results = []
    for t in terms:
        if t.get("state") != "live":
            continue
        addr = t.get("address") or ""
        if not addr:
            continue
        try:
            info = json.loads(
                subprocess.check_output(["hc", "get", "--json", addr], text=True, stderr=subprocess.DEVNULL)
            )
        except Exception:
            continue
        fg_name = ((info.get("foreground") or {}).get("name") or "").lower()
        agent = (info.get("agent") or "").lower()
        if fg_name in ("claude", "codex", "agy") or any(
            k in agent for k in ("claude", "codex", "antigravity", "agy")
        ):
            where = (info.get("labels") or {}).get("where") or ""
            cwd = (info.get("foreground") or {}).get("cwd") or info.get("cwd") or ""
            label = fg_name or agent or "agent"
            results.append(
                {
                    "id": f"hc:{addr}",
                    "label": f"[{addr}] {label} ({where or os.path.basename(cwd)})",
                    "cwd": cwd,
                }
            )
    return results


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
    answer = (res.get("answer") or "").strip()
    opt_block = format_options_md(options)

    if record_id:
        for rec in records:
            if rec.get("id") == record_id:
                md_path = os.path.join(store_dir, rec.get("md_rel", ""))
                turn = int(rec.get("turns") or 0) + 1
                q = (req.get("question") or "").strip()
                append_md = f"\n\n---\n\n### 追问 #{turn}：{q}\n\n{answer}{opt_block}\n"
                if os.path.isfile(md_path):
                    with open(md_path, "a", encoding="utf-8") as f:
                        f.write(append_md)
                rec["updated_at"] = now_str
                rec["turns"] = turn
                rec["options"] = options
                if res.get("session_id"):
                    rec["session_id"] = res["session_id"]
                save_index(cwd, records)
                return (record_id, md_path)

    file_rel = (req.get("file") or "[No Name]").strip()
    line = int(req.get("line") or 1)
    symbol = (req.get("symbol") or "AI").strip() or "AI"
    agent = res.get("agent") or req.get("agent") or "agy"
    ts_slug = now_dt.strftime("%Y%m%d_%H%M%S")
    short_uid = uuid.uuid4().hex[:4]
    record_id = f"{ts_slug}_{_safe_slug(agent, 20)}_{short_uid}"
    md_rel = os.path.join(
        "history",
        f"{_safe_slug(file_rel, 70)}__{_safe_slug(symbol, 40)}__{record_id}.md",
    )
    md_path = os.path.join(store_dir, md_rel)

    header_md = (
        f"# AI 代码分析：`{symbol}`\n"
        f"- **Agent**: `{agent}`  |  **位置**: `{file_rel}:{line}`  |  **时间**: `{now_str}`\n"
        f"- **快捷键**: `1`~`9` 直选快捷项  |  `o` 弹窗单选/多选  |  `a`/`<Space>ar` 自由追问  |  `R` 重新诊断  |  `Enter`/`gf` 跳转文件或选项  |  `q` 关闭 Tab\n\n"
        f"---\n\n"
        f"### 1. 作用 / 用法 / 项目角色 / 调用层级分析\n\n"
        f"{answer}{opt_block}\n"
    )
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(header_md)

    new_rec = {
        "id": record_id,
        "created_at": now_str,
        "updated_at": now_str,
        "file": file_rel,
        "line": line,
        "symbol": symbol,
        "agent": agent,
        "session_id": res.get("session_id") or "",
        "options": options,
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
        print(json.dumps(list_herdr_agents(), ensure_ascii=False))
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
        try:
            rec_id, md_path = persist_diagnosis(req, res)
            res["record_id"] = rec_id
            res["md_path"] = md_path
        except Exception:
            pass

    print(json.dumps(res, ensure_ascii=False))


if __name__ == "__main__":
    main()
