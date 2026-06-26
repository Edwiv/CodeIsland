#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import sys
import time

VERSION = "0.4.2"
# Per-user socket path (#193): CodeIsland injects CODEISLAND_SOCKET_PATH via the hook
# command, but fall back to a uid-scoped path so multiple users on a shared host never
# collide on a single /tmp/codeisland.sock.
SOCKET_PATH = os.environ.get("CODEISLAND_SOCKET_PATH") or f"/tmp/codeisland-{os.getuid()}.sock"
REMOTE_HOST_ID = os.environ.get("CODEISLAND_REMOTE_HOST_ID", "")
REMOTE_HOST_NAME = os.environ.get("CODEISLAND_REMOTE_HOST_NAME", "")
SOURCE = os.environ.get("CODEISLAND_SOURCE", "")
TIMEOUT_SECONDS = 300


def _normalize_event(name):
    """Best-effort normalization matching CodeIslandCore.EventNormalizer."""
    if not isinstance(name, str):
        return ""
    # Cursor (camelCase)
    if name == "beforeSubmitPrompt":
        return "UserPromptSubmit"
    if name == "beforeShellExecution":
        return "PreToolUse"
    if name == "afterShellExecution":
        return "PostToolUse"
    if name == "beforeReadFile":
        return "PreToolUse"
    if name == "afterFileEdit":
        return "PostToolUse"
    if name == "beforeMCPExecution":
        return "PreToolUse"
    if name == "afterMCPExecution":
        return "PostToolUse"
    if name == "afterAgentThought":
        return "Notification"
    if name == "afterAgentResponse":
        return "AfterAgentResponse"
    if name == "stop":
        return "Stop"
    # Gemini
    if name == "BeforeTool":
        return "PermissionRequest"
    if name == "AfterTool":
        return "PostToolUse"
    if name == "BeforeAgent":
        return "SubagentStart"
    if name == "AfterAgent":
        return "SubagentStop"
    # GitHub Copilot CLI
    if name == "sessionStart":
        return "SessionStart"
    if name == "sessionEnd":
        return "SessionEnd"
    if name == "userPromptSubmitted":
        return "UserPromptSubmit"
    if name == "preToolUse":
        return "PreToolUse"
    if name == "postToolUse":
        return "PostToolUse"
    if name == "errorOccurred":
        return "Notification"
    # TraeCli (snake_case)
    if name == "session_start":
        return "SessionStart"
    if name == "session_end":
        return "SessionEnd"
    if name == "user_prompt_submit":
        return "UserPromptSubmit"
    if name == "pre_tool_use":
        return "PreToolUse"
    if name == "post_tool_use":
        return "PostToolUse"
    if name == "post_tool_use_failure":
        return "PostToolUseFailure"
    if name == "permission_request":
        return "PermissionRequest"
    if name == "subagent_start":
        return "SubagentStart"
    if name == "subagent_stop":
        return "SubagentStop"
    if name == "pre_compact":
        return "PreCompact"
    if name == "post_compact":
        return "PostCompact"
    if name == "notification":
        return "Notification"
    # Hermes (Nous Research) — snake_case, diverged from Claude/Gemini (#226).
    # `subagent_stop` is already handled above.
    if name == "pre_tool_call":
        return "PreToolUse"
    if name == "post_tool_call":
        return "PostToolUse"
    if name == "pre_llm_call":
        return "UserPromptSubmit"
    if name == "on_session_start":
        return "SessionStart"
    if name == "on_session_end":
        return "SessionEnd"
    if name == "on_session_reset":
        return "SessionEnd"
    return name


def _claude_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(home, ".claude", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _codebuddy_jsonl_path(session_id, cwd):
    if not session_id or not cwd:
        return None
    home = os.path.expanduser("~")
    project_dir = cwd.replace("/", "-").replace(".", "-")
    path = os.path.join(home, ".codebuddy", "projects", project_dir, f"{session_id}.jsonl")
    return path if os.path.exists(path) else None


def _codex_session_id_from_path(path):
    name = os.path.basename(path)
    if not name.endswith(".jsonl"):
        return None
    stem = name[:-len(".jsonl")]
    # Codex filenames are rollout-YYYY-MM-DDThh-mm-ss-<thread-id>.jsonl.
    # The thread id is UUID-shaped but not necessarily RFC-versioned.
    return stem[-36:] if len(stem) >= 36 else stem


def _extract_text(content):
    """A transcript message's content is either a plain string (user turns) or a list of
    typed blocks (Claude assistant turns); pull human-readable text out of either shape."""
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                t = block.get("text")
                if isinstance(t, str) and t.strip():
                    parts.append(t.strip())
        return "\n".join(parts).strip()
    return ""


def _is_noise_user_text(text):
    """Skip command / caveat wrappers and tool-result turns — they aren't real prompts."""
    if not text:
        return True
    s = text.lstrip()
    for prefix in ("<local-command", "<command-", "<bash-", "<user-", "Caveat:", "[Request interrupted"):
        if s.startswith(prefix):
            return True
    return False


def _is_interrupted_marker(text):
    return isinstance(text, str) and text.lstrip().startswith("[Request interrupted")


def _clip(text, limit):
    if not isinstance(text, str):
        return text
    text = text.strip()
    return text if len(text) <= limit else text[: max(0, limit - 1)] + "…"


def _scan_session_jsonl(path):
    if not path:
        return {}

    summary = None
    last_user = None
    last_assistant = None
    cwd = None
    model = None
    usage = None
    terminal_status = None

    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except Exception:
                    continue

                if cwd is None:
                    line_cwd = payload.get("cwd")
                    if isinstance(line_cwd, str) and line_cwd.strip():
                        cwd = line_cwd

                msg_type = payload.get("type")
                if msg_type == "summary" and not summary:
                    s = payload.get("summary") or payload.get("content")
                    if isinstance(s, str) and s.strip():
                        summary = s.strip()
                    continue

                # Claude nests the message under "message"; older/CodeBuddy formats put
                # role/content at the top level. Support both.
                msg = payload.get("message")
                if isinstance(msg, dict):
                    role = msg.get("role")
                    content = msg.get("content")
                else:
                    role = payload.get("role")
                    content = payload.get("content")

                # Capture the latest assistant model + token usage (Claude carries them on the
                # message dict). Done before the no-text early-continue below so a tool-only
                # assistant turn still refreshes the running context size, and so the remote
                # session card can show the model / context-window chips (#3).
                if role == "assistant":
                    msrc = msg if isinstance(msg, dict) else payload
                    m = msrc.get("model")
                    if isinstance(m, str) and m.strip():
                        model = m.strip()
                    u = msrc.get("usage")
                    if isinstance(u, dict):
                        usage = u

                text = _extract_text(content)
                if not text:
                    continue

                if role == "user":
                    if _is_interrupted_marker(text) or payload.get("interruptedMessageId"):
                        terminal_status = "interrupted"
                        continue
                    if payload.get("isMeta") is True or _is_noise_user_text(text):
                        continue
                    terminal_status = None
                    last_user = text
                elif role == "assistant":
                    terminal_status = None
                    last_assistant = text
    except Exception:
        return {}

    result = {
        # Title is the conversation's real summary only — NOT a first-prompt fallback. This
        # matches local sessions (SessionTitleStore reads only Claude's generated ai/custom
        # title), so a scanned session shows a "#title" only when one genuinely exists; the
        # first prompt is shown as the ">" chat row in every card either way.
        "session_title": _clip(summary, 120),
        "last_user_message": _clip(last_user, 500),
        "last_assistant_message": _clip(last_assistant, 500),
        "cwd": cwd,
    }
    if model:
        result["model"] = model
    if terminal_status:
        result["terminal_status"] = terminal_status
    # Flatten Claude's usage block to the top-level token names the Mac reducer reads
    # (extractMetadata: input_tokens / output_tokens / cache_read_tokens / cache_write_tokens).
    if isinstance(usage, dict):
        token_map = {
            "input_tokens": usage.get("input_tokens"),
            "output_tokens": usage.get("output_tokens"),
            "cache_read_tokens": usage.get("cache_read_input_tokens"),
            "cache_write_tokens": usage.get("cache_creation_input_tokens"),
        }
        for key, value in token_map.items():
            if isinstance(value, int):
                result[key] = value
    return result


def _scan_claude_jsonl(session_id, cwd):
    return _scan_session_jsonl(_claude_jsonl_path(session_id, cwd))


def _scan_codebuddy_jsonl(session_id, cwd):
    return _scan_session_jsonl(_codebuddy_jsonl_path(session_id, cwd))


def _scan_codex_jsonl(path):
    if not path:
        return {}

    cwd = None
    model = None
    last_user = None
    last_assistant = None
    terminal_status = None

    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    payload = json.loads(line)
                except Exception:
                    continue

                msg_type = payload.get("type")
                data = payload.get("payload")
                if not isinstance(data, dict):
                    data = {}

                if msg_type == "session_meta":
                    if cwd is None:
                        value = data.get("cwd")
                        if isinstance(value, str) and value.strip():
                            cwd = value.strip()
                    if model is None:
                        value = data.get("model") or data.get("model_provider")
                        if isinstance(value, str) and value.strip():
                            model = value.strip()
                    continue

                if msg_type == "turn_context":
                    if cwd is None:
                        value = data.get("cwd")
                        if isinstance(value, str) and value.strip():
                            cwd = value.strip()
                    if model is None:
                        value = data.get("model")
                        if isinstance(value, str) and value.strip():
                            model = value.strip()
                    continue

                if msg_type == "event_msg":
                    event_type = data.get("type")
                    if event_type == "task_started":
                        terminal_status = None
                    elif event_type == "user_message":
                        # A new turn may be appended before Codex records task_started. If the
                        # previous line left us at task_complete, don't carry that terminal state
                        # into the new active turn.
                        terminal_status = None
                    elif event_type == "task_complete":
                        terminal_status = "completed"
                    elif event_type == "turn_aborted":
                        terminal_status = "interrupted"
                    elif event_type == "turn_failed":
                        terminal_status = "failed"

                    message = data.get("message")
                    if isinstance(message, str) and message.strip():
                        if event_type == "user_message":
                            last_user = message.strip()
                        elif event_type == "agent_message":
                            last_assistant = message.strip()
                    continue

                if msg_type == "response_item":
                    response_type = data.get("type")
                    if response_type in ("function_call", "function_call_output", "reasoning"):
                        # Newer Codex JSONL can append tool/reasoning items after an early
                        # task_complete marker while the turn is still running. Treat any such
                        # post-terminal activity as live so discovery emits _discovered_status.
                        terminal_status = None
                    role = data.get("role")
                    content = data.get("content")
                    text = ""
                    if isinstance(content, list):
                        for item in content:
                            if not isinstance(item, dict):
                                continue
                            item_type = item.get("type")
                            value = item.get("text")
                            if not isinstance(value, str) or not value.strip():
                                continue
                            if role == "user" and item_type == "input_text" and last_user is None:
                                text = value.strip()
                                break
                            if role == "assistant" and item_type == "output_text":
                                text = value.strip()
                                break
                    if role == "user" and text and not text.lstrip().startswith("<"):
                        last_user = text
                    elif role == "assistant" and text:
                        last_assistant = text
    except Exception:
        return {}

    result = {
        "session_title": None,
        "last_user_message": _clip(last_user, 500),
        "last_assistant_message": _clip(last_assistant, 500),
        "cwd": cwd,
    }
    if model:
        result["model"] = model
    if terminal_status:
        result["terminal_status"] = terminal_status
    return result


def _scan_discovered_jsonl(source, path):
    if source == "codex":
        return _scan_codex_jsonl(path)
    return _scan_session_jsonl(path)


def _read_stdin_json():
    try:
        return json.load(sys.stdin)
    except Exception:
        return None


def _send_event(payload, expects_response):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(TIMEOUT_SECONDS)
    try:
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(payload).encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        if expects_response:
            response = sock.recv(65536)
            return response.decode("utf-8") if response else None
        return None
    except (OSError, socket.error):
        # Socket may not exist or server may have shut down — fail silently (#45)
        return None
    finally:
        try:
            sock.close()
        except Exception:
            pass


def _get_tty():
    pid = os.getppid()
    for _ in range(20):
        if pid <= 1:
            break
        try:
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "tty=,ppid="],
                capture_output=True,
                text=True,
                timeout=2,
            )
            parts = result.stdout.strip().split()
            if not parts:
                break
            tty = parts[0]
            if tty and tty not in {"??", "-"}:
                return tty if tty.startswith("/dev/") else f"/dev/{tty}"
            if len(parts) >= 2:
                pid = int(parts[1])
            else:
                break
        except Exception:
            break
    return None


def _discover_and_emit():
    """Connect-time discovery: scan known CLI session stores for recently-active sessions
    and replay a quiet SessionStart for each, so sessions that were already running before
    CodeIsland connected show up (not just newly-created ones). Marked `_discovered` so the
    Mac app registers them silently (no sound, no stealing the active selection)."""
    home = os.path.expanduser("~")
    stores = [
        ("claude", os.path.join(home, ".claude", "projects")),
        ("codebuddy", os.path.join(home, ".codebuddy", "projects")),
    ]
    max_age_seconds = 6 * 60 * 60   # only sessions touched within the last 6h
    max_sessions = 40               # cap the replay so a busy host can't flood the tunnel
    # A session whose transcript changed within this window is almost certainly mid-turn, so
    # tag the quiet SessionStart with a live status — otherwise a session that was already
    # running before we connected shows as idle (its UserPromptSubmit/PreToolUse fired before
    # connect and aren't replayed). Kept tight to limit a just-finished turn briefly reading as
    # active; the next real PostToolUse/Stop reconciles it.
    active_window_seconds = 90
    now = time.time()

    found = []  # (mtime, source, path, session_id)
    for source, base in stores:
        if not os.path.isdir(base):
            continue
        try:
            project_dirs = os.listdir(base)
        except OSError:
            continue
        for project_dir in project_dirs:
            pdir = os.path.join(base, project_dir)
            if not os.path.isdir(pdir):
                continue
            try:
                names = os.listdir(pdir)
            except OSError:
                continue
            for fname in names:
                if not fname.endswith(".jsonl"):
                    continue
                fpath = os.path.join(pdir, fname)
                try:
                    mtime = os.path.getmtime(fpath)
                except OSError:
                    continue
                if now - mtime > max_age_seconds:
                    continue
                found.append((mtime, source, fpath, fname[:-len(".jsonl")]))

    codex_base = os.path.join(home, ".codex", "sessions")
    if os.path.isdir(codex_base):
        try:
            for root, _, names in os.walk(codex_base):
                for fname in names:
                    if not fname.endswith(".jsonl"):
                        continue
                    fpath = os.path.join(root, fname)
                    try:
                        mtime = os.path.getmtime(fpath)
                    except OSError:
                        continue
                    if now - mtime > max_age_seconds:
                        continue
                    session_id = _codex_session_id_from_path(fpath)
                    if session_id:
                        found.append((mtime, "codex", fpath, session_id))
        except OSError:
            pass

    found.sort(key=lambda item: item[0], reverse=True)  # most recently active first
    for mtime, source, fpath, session_id in found[:max_sessions]:
        if not session_id:
            continue
        info = _scan_discovered_jsonl(source, fpath)
        cwd = info.get("cwd")
        if not cwd:
            continue
        payload = {
            "hook_event_name": "SessionStart",
            "session_id": session_id,
            "cwd": cwd,
            "_source": source,
            "_remote_host_id": REMOTE_HOST_ID,
            "_remote_host_name": REMOTE_HOST_NAME,
            "_discovered": True,
        }
        # Infer live status from transcript freshness so an already-running session shows as
        # active the moment we connect. The Mac reducer applies this only to brand-new
        # discovered sessions, never overriding a session it already tracks.
        if now - mtime <= active_window_seconds and not info.get("terminal_status"):
            payload["_discovered_status"] = "processing"
        for key in ("session_title", "last_user_message", "last_assistant_message",
                    "model", "terminal_status", "input_tokens", "output_tokens",
                    "cache_read_tokens", "cache_write_tokens"):
            value = info.get(key)
            if value:
                if key == "terminal_status":
                    payload["_discovered_terminal_status"] = value
                else:
                    payload[key] = value
        _send_event(payload, expects_response=False)
    return 0


def main():
    if "--version" in sys.argv:
        print(VERSION)
        return 0
    if "--discover" in sys.argv:
        return _discover_and_emit()

    data = _read_stdin_json()
    if not data:
        return 1

    event_name = data.get("hook_event_name") or data.get("event")
    session_id = data.get("session_id")
    cwd = data.get("cwd") or os.getcwd()
    if not event_name or not session_id:
        return 1

    normalized_event = _normalize_event(event_name)

    payload = dict(data)
    payload["hook_event_name"] = event_name
    payload["session_id"] = session_id
    payload["cwd"] = cwd
    payload["_source"] = payload.get("_source") or SOURCE
    payload["_remote_host_id"] = payload.get("_remote_host_id") or REMOTE_HOST_ID
    payload["_remote_host_name"] = payload.get("_remote_host_name") or REMOTE_HOST_NAME
    payload["_tty"] = payload.get("_tty") or _get_tty()

    if SOURCE == "claude":
        extras = _scan_claude_jsonl(session_id, cwd)
        for key, value in extras.items():
            if value and not payload.get(key):
                payload[key] = value
        if normalized_event == "UserPromptSubmit" and not payload.get("prompt"):
            prompt = extras.get("last_user_message")
            if prompt:
                payload["prompt"] = prompt

    if SOURCE == "codebuddy":
        extras = _scan_codebuddy_jsonl(session_id, cwd)
        for key, value in extras.items():
            if value and not payload.get(key):
                payload[key] = value
        if normalized_event == "UserPromptSubmit" and not payload.get("prompt"):
            prompt = extras.get("last_user_message")
            if prompt:
                payload["prompt"] = prompt

    # Blocking events: permission prompts + question prompts
    expects_response = normalized_event == "PermissionRequest" or (
        normalized_event == "Notification" and payload.get("question")
    )
    response = _send_event(payload, expects_response)
    if response:
        if SOURCE == "google-antigravity" or SOURCE == "gemini":
            try:
                res_obj = json.loads(response)
                behavior = res_obj.get("hookSpecificOutput", {}).get("decision", {}).get("behavior")
                if behavior in ("allow", "always"):
                    print(json.dumps({"decision": "allow"}))
                else:
                    print(json.dumps({"decision": "deny"}))
            except Exception:
                if '"behavior":"allow"' in response or '"behavior":"always"' in response:
                    print(json.dumps({"decision": "allow"}))
                elif '"behavior":"deny"' in response:
                    print(json.dumps({"decision": "deny"}))
                else:
                    print(response)
        else:
            print(response)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
