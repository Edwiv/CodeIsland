#!/usr/bin/env python3
"""
CodeIsland ⇄ Lark (Feishu) bridge sidecar.

Owns ALL Feishu protocol work so the Swift app never needs a Feishu SDK:
  • sends interactive approval/question cards to the user's phone,
  • receives button taps via a WebSocket long connection (card.action.trigger),
  • updates ("recalls") a card when the request is resolved on the desktop.

Transport with the app is newline-delimited JSON over stdin/stdout:

  app → sidecar:
    {"type":"config","appId":..,"appSecret":..,"target":{"type":"dm|group","value":..},"i18n":{..}}
    {"type":"push","reqId":..,"askType":"approval|question","agent":..,"project":..,"sessionShort":..,"payload":{..}}
    {"type":"resolve","reqId":..,"by":"desktop"}
    {"type":"test"}

  sidecar → app:
    {"type":"ready","botName":..}
    {"type":"error","code":"missing_dep|auth|send","message":..}
    {"type":"pushed","reqId":..,"messageId":..}
    {"type":"decision","reqId":..,"actionId":..,"formValue":{..}}

Requires: pip3 install lark-oapi
"""
import json
import os
import sys
import threading
import time
import urllib.request

OUT_LOCK = threading.Lock()
STATE_LOCK = threading.Lock()

FEISHU_BASE = "https://open.feishu.cn"
LOG_PATH = os.environ.get("CODEISLAND_LARK_LOG") or ("/tmp/codeisland-lark-%d.log" % os.getuid())


def flog(msg):
    """Append a timestamped line to a debug log file (best-effort)."""
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))
    except Exception:
        pass


def emit(obj):
    """Write one JSON object to stdout as a single line (thread-safe)."""
    line = json.dumps(obj, ensure_ascii=False)
    with OUT_LOCK:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()
    flog("→ " + line)


def log_err(msg):
    sys.stderr.write(str(msg) + "\n")
    sys.stderr.flush()


# lark-oapi is the one hard dependency. Fail loudly-but-cleanly if it's missing.
try:
    import lark_oapi as lark
    from lark_oapi.api.im.v1 import (
        CreateMessageRequest, CreateMessageRequestBody,
        PatchMessageRequest, PatchMessageRequestBody,
    )
except Exception:  # ImportError or partial install
    emit({"type": "error", "code": "missing_dep",
          "message": "lark-oapi not installed. Run: pip3 install lark-oapi"})
    sys.exit(0)

# The response type used to update a card inline from a card-action callback (so Feishu doesn't
# roll back the optimistic UI). Optional — fall back to REST patch if unavailable.
try:
    from lark_oapi.event.callback.model.p2_card_action_trigger import P2CardActionTriggerResponse
except Exception:
    P2CardActionTriggerResponse = None


# ── Shared state (guarded by STATE_LOCK) ─────────────────────────────────────
client = None                  # lark.Client
target = {"type": "dm", "value": ""}
i18n = {}
req_to_msg = {}                # reqId -> {"message_id":.., "title":..}
msg_to_req = {}                # message_id -> reqId (reverse, for form submits where value is empty)


def t(key, default):
    return i18n.get(key, default)


# ── Card building (Feishu card schema 2.0) ───────────────────────────────────

def _md(content):
    return {"tag": "markdown", "content": content}


def _btn(text, btype, action_id, req_id, form_submit=False):
    b = {
        "tag": "button",
        "text": {"tag": "plain_text", "content": text},
        "type": btype,
        "name": "btn_%s" % action_id,
        "value": {"reqId": req_id, "actionId": action_id},
    }
    if form_submit:
        b["form_action_type"] = "submit"
    return b


def _button_row(buttons):
    return {
        "tag": "column_set",
        "flex_mode": "flow",
        "horizontal_spacing": "8px",
        "columns": [{"tag": "column", "width": "auto", "elements": [b]} for b in buttons],
    }


def _wrap(title, elements, template="orange"):
    return {
        "schema": "2.0",
        "config": {"update_multi": True},
        "header": {"title": {"tag": "plain_text", "content": title}, "template": template},
        "body": {"elements": elements},
    }


def _clip(text, limit):
    text = str(text or "")
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _header_lines(msg):
    lines = ["🤖 %s: %s" % (t("agent", "Agent"), msg.get("agent", "Agent"))]
    project = msg.get("project") or ""
    if project:
        lines.append("📁 %s: %s" % (t("project", "Project"), project))
    short = msg.get("sessionShort") or ""
    if short:
        lines.append("🆔 `%s`" % short)
    return lines


def build_approval_card(msg):
    req_id = msg["reqId"]
    payload = msg.get("payload", {})
    elements = [_md("\n".join(_header_lines(msg))), {"tag": "hr"}]
    elements.append(_md("**%s**: `%s`" % (t("permission", "Permission"), payload.get("tool", "?"))))
    command = payload.get("command")
    summary = payload.get("summary")
    if command:
        elements.append(_md("```\n%s\n```" % _clip(command, 500)))
    elif summary:
        elements.append(_md(_clip(summary, 500)))
    buttons = [_btn(t("allow_once", "Allow once"), "primary", "allowOnce", req_id)]
    if payload.get("allowAlways"):
        buttons.append(_btn(t("allow_always", "Always allow"), "default", "allowAlways", req_id))
    buttons.append(_btn(t("deny", "Deny"), "danger", "deny", req_id))
    elements.append(_button_row(buttons))
    elements.append(_md(t("footer", "📍 from CodeIsland")))
    return _wrap(t("approval_title", "⚠️ Agent needs permission"), elements, "orange")


def build_question_card(msg):
    req_id = msg["reqId"]
    items = (msg.get("payload", {}) or {}).get("items", [])
    elements = [_md("\n".join(_header_lines(msg))), {"tag": "hr"}]
    form_elements = []
    any_options = False
    for idx, q in enumerate(items):
        label = q.get("question", "")
        prefix = "" if len(items) == 1 else "%d、" % (idx + 1)
        form_elements.append(_md("**%s%s**" % (prefix, label)))
        options = q.get("options") or []
        if options:
            any_options = True
            opts = [{"text": {"tag": "plain_text", "content": str(o)}, "value": str(i)}
                    for i, o in enumerate(options)]
            multi = bool(q.get("multi"))
            field = ("m_%d" if multi else "s_%d") % idx
            sel = {
                "tag": "multi_select_static" if multi else "select_static",
                "name": field,
                "placeholder": {"tag": "plain_text", "content": t("please_select", "Please select")},
                "options": opts,
                "required": False,
            }
            form_elements.append(sel)
    if any_options:
        form_elements.append(_button_row([
            _btn(t("submit", "Submit"), "primary", "device_chat_submit", req_id, form_submit=True),
            _btn(t("skip", "Skip"), "default", "device_chat_cancel", req_id, form_submit=True),
        ]))
        elements.append({"tag": "form", "name": "form_%s" % req_id, "elements": form_elements})
    else:
        # No preset options (free-text question) — can't answer via buttons; offer skip only.
        elements.extend(form_elements)
        elements.append(_md(t("answer_on_desktop", "Please answer on your computer.")))
        elements.append(_button_row([_btn(t("skip", "Skip"), "default", "device_chat_cancel", req_id)]))
    elements.append(_md(t("footer", "📍 from CodeIsland")))
    return _wrap(t("question_title", "🤖 Agent has a question"), elements, "blue")


def build_resolved_card(title, resolved_text):
    return _wrap(title, [_md(resolved_text)], "grey")


def build_test_card():
    elements = [
        _md("**CodeIsland**"),
        {"tag": "hr"},
        _md(t("test_body", "If you can see this card, Lark push is configured correctly.")),
    ]
    return _wrap(t("test_title", "✅ CodeIsland test"), elements, "green")


# ── Feishu I/O ───────────────────────────────────────────────────────────────

def receive_id_type_for(tgt):
    v = tgt.get("value", "")
    if tgt.get("type") == "group":
        return "chat_id", v
    if "@" in v:
        return "email", v
    if v.startswith("ou_"):
        return "open_id", v
    if v.startswith("on_"):
        return "union_id", v
    return "user_id", v


def auth_and_bot_name(app_id, app_secret):
    """Verify credentials and fetch the bot's display name via plain HTTP (no SDK guessing)."""
    token_req = urllib.request.Request(
        FEISHU_BASE + "/open-apis/auth/v3/tenant_access_token/internal",
        data=json.dumps({"app_id": app_id, "app_secret": app_secret}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(token_req, timeout=15) as resp:
        tok = json.loads(resp.read().decode("utf-8"))
    if tok.get("code") != 0:
        raise RuntimeError(tok.get("msg") or "auth failed (code %s)" % tok.get("code"))
    token = tok["tenant_access_token"]
    try:
        info_req = urllib.request.Request(
            FEISHU_BASE + "/open-apis/bot/v3/info",
            headers={"Authorization": "Bearer " + token},
            method="GET",
        )
        with urllib.request.urlopen(info_req, timeout=15) as resp:
            info = json.loads(resp.read().decode("utf-8"))
        return (info.get("bot", {}) or {}).get("app_name") or "Lark Bot"
    except Exception:
        return "Lark Bot"


def send_card(card):
    """Returns (message_id, error_message). On success error_message is None."""
    rid_type, rid = receive_id_type_for(target)
    body = (CreateMessageRequestBody.builder()
            .receive_id(rid).msg_type("interactive").content(json.dumps(card)).build())
    req = CreateMessageRequest.builder().receive_id_type(rid_type).request_body(body).build()
    resp = client.im.v1.message.create(req)
    if not resp.success():
        return None, "code %s: %s" % (resp.code, resp.msg)
    return resp.data.message_id, None


def patch_card(message_id, card):
    body = PatchMessageRequestBody.builder().content(json.dumps(card)).build()
    req = PatchMessageRequest.builder().message_id(message_id).request_body(body).build()
    try:
        client.im.v1.message.patch(req)
    except Exception as e:
        log_err("patch failed: %s" % e)


# ── WebSocket card-action handler ────────────────────────────────────────────

def on_card_action(data):
    try:
        event = getattr(data, "event", None)
        action = getattr(event, "action", None)
        context = getattr(event, "context", None)

        # Button value carries {reqId, actionId} for plain buttons, but Feishu schema-2.0 FORM
        # submits arrive with an empty value — so fall back to the tapped message id (→ reqId)
        # and the button name (we name every button "btn_<actionId>").
        value = getattr(action, "value", None) or {}
        req_id = value.get("reqId") if isinstance(value, dict) else None
        action_id = value.get("actionId") if isinstance(value, dict) else None

        if not req_id:
            open_msg_id = getattr(context, "open_message_id", None)
            if open_msg_id:
                with STATE_LOCK:
                    req_id = msg_to_req.get(open_msg_id)
        if not action_id:
            name = getattr(action, "name", None) or ""
            if name.startswith("btn_"):
                action_id = name[len("btn_"):]

        if not req_id or not action_id:
            flog("ws: card action unresolved (reqId=%s actionId=%s)" % (req_id, action_id))
            return None

        form_value = {}
        raw_form = getattr(action, "form_value", None) or {}
        if isinstance(raw_form, dict):
            for k, v in raw_form.items():
                if isinstance(v, list):
                    parts = [(x.get("value") if isinstance(x, dict) else x) for x in v]
                    form_value[k] = ",".join(str(p) for p in parts if p is not None)
                elif isinstance(v, dict):
                    form_value[k] = str(v.get("value", ""))
                else:
                    form_value[k] = str(v)

        emit({"type": "decision", "reqId": req_id, "actionId": action_id, "formValue": form_value})

        # Resolve the card to a "confirmed on phone" state. Feishu rolls back the optimistic UI
        # unless the callback RETURNS the updated card, so prefer returning it; only fall back to
        # an async REST patch if the response type isn't available in this lark-oapi build.
        with STATE_LOCK:
            entry = req_to_msg.pop(req_id, None)
            if entry:
                msg_to_req.pop(entry["message_id"], None)
        title = entry["title"] if entry else t("approval_title", "CodeIsland")
        confirmed_text = t("resolved_phone", "✅ Confirmed on phone")
        resolved_card = build_resolved_card(title, confirmed_text)

        if P2CardActionTriggerResponse is not None:
            return P2CardActionTriggerResponse({
                "toast": {"type": "success", "content": confirmed_text},
                "card": {"type": "raw", "data": resolved_card},
            })
        if entry:
            patch_card(entry["message_id"], resolved_card)
    except Exception as e:
        flog("ws: card action ERROR %r" % e)
        log_err("card action error: %s" % e)
    return None


def start_ws(app_id, app_secret):
    """Run the card-action WebSocket listener, reconnecting forever on failure so a transient
    drop (or the app not yet having long-connection enabled) never permanently disables
    two-way replies — and never takes down the (send-capable) main process."""
    while True:
        try:
            handler = (lark.EventDispatcherHandler.builder("", "")
                       .register_p2_card_action_trigger(on_card_action)
                       .build())
            ws = lark.ws.Client(app_id, app_secret, event_handler=handler, log_level=lark.LogLevel.ERROR)
            flog("ws: connecting")
            ws.start()  # blocks while connected
            flog("ws: start() returned; will retry")
        except BaseException as e:
            flog("ws: error %r; retry in 10s" % e)
        time.sleep(10)


# ── Command handling ─────────────────────────────────────────────────────────

def handle_config(msg):
    global client, target, i18n
    app_id = msg.get("appId", "")
    app_secret = msg.get("appSecret", "")
    target = msg.get("target", target)
    i18n = msg.get("i18n", {}) or {}
    if not app_id or not app_secret:
        emit({"type": "error", "code": "auth", "message": "missing appId/appSecret"})
        return False
    try:
        bot_name = auth_and_bot_name(app_id, app_secret)
    except Exception as e:
        flog("config: auth failed %r" % e)
        emit({"type": "error", "code": "auth", "message": str(e)})
        return False
    client = lark.Client.builder().app_id(app_id).app_secret(app_secret).log_level(lark.LogLevel.ERROR).build()
    threading.Thread(target=start_ws, args=(app_id, app_secret), daemon=True).start()
    flog("config: ready bot=%s target=%s" % (bot_name, target))
    emit({"type": "ready", "botName": bot_name})
    return True


def handle_push(msg):
    if client is None:
        return
    card = build_approval_card(msg) if msg.get("askType") == "approval" else build_question_card(msg)
    title = card["header"]["title"]["content"]
    message_id, err = send_card(card)
    if message_id:
        with STATE_LOCK:
            req_to_msg[msg["reqId"]] = {"message_id": message_id, "title": title}
            msg_to_req[message_id] = msg["reqId"]
        emit({"type": "pushed", "reqId": msg["reqId"], "messageId": message_id})
    else:
        emit({"type": "send_error", "reqId": msg.get("reqId"), "message": err or "send failed"})


def handle_resolve(msg):
    req_id = msg.get("reqId")
    with STATE_LOCK:
        entry = req_to_msg.pop(req_id, None)
        if entry:
            msg_to_req.pop(entry["message_id"], None)
    if entry:
        patch_card(entry["message_id"],
                   build_resolved_card(entry["title"], t("resolved_desktop", "✅ Handled on desktop")))


def handle_test(_msg):
    if client is None:
        emit({"type": "test_result", "ok": False, "message": "not connected"})
        return
    _mid, err = send_card(build_test_card())
    emit({"type": "test_result", "ok": err is None, "message": err or ""})


def main():
    flog("sidecar: started (pid %d, python %s)" % (os.getpid(), sys.version.split()[0]))
    configured = False
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            mtype = msg.get("type")
            flog("← %s" % mtype)
            try:
                if mtype == "config":
                    configured = handle_config(msg)
                elif not configured:
                    continue
                elif mtype == "push":
                    handle_push(msg)
                elif mtype == "resolve":
                    handle_resolve(msg)
                elif mtype == "test":
                    handle_test(msg)
            except Exception as e:
                flog("command %s failed: %r" % (mtype, e))
                log_err("command %s failed: %s" % (mtype, e))
    finally:
        flog("sidecar: stdin loop ended (EOF) — exiting")


if __name__ == "__main__":
    main()
