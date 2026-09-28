"""
Governed Copilot — shared Cortex Agents chat surface for the HCLS accelerator demos.

One module, one call: an accelerator's Streamlit app supplies a CONFIG describing
its tools (Cortex Analyst over its semantic model + its Cortex Search services),
its instructions, and its quick-starts; this renders the full assistant.

What it provides (all verified live on the partner account):
  - POST /api/v2/cortex/agent:run via _snowflake.send_snow_api_request
  - native Cortex Agents threads (POST /api/v2/cortex/threads) with server-side
    context, and a self-heal fallback to message replay if a thread desyncs
  - saved conversations per user (new / switch / rename / delete / export)
  - inline citations, rendered Analyst result tables, tool trace, generated SQL
  - follow-up suggestion chips and 👍/👎 feedback
  - every turn logged to GOVERNANCE.COPILOT_INTERACTION_LOG

This file is deployed alongside the app (like theme.py) — keep it byte-identical
across demos so a fix lands everywhere. Master copy:
accelerators/revenue-cycle-intelligence/demo/streamlit/copilot.py

Config keys (see any accelerator app for a worked example):
  db, warehouse, semantic_model, model, tools, tool_resources, instructions,
  eyebrow, title, blurb, placeholder, spinner, starters, footer, agent_id,
  analyst_tool, origin, agent_object (optional, for the CoWork/CLI footer note)
"""

import json
import uuid

import pandas as pd
import streamlit as st

import theme

DEFAULT_MODEL = "claude-haiku-4-5"   # fast interactive orchestration
BUDGET = {"seconds": 100, "tokens": 48000}


# =============================================================================
# RESPONSE PARSING
# =============================================================================
def _walk(obj, acc):
    if isinstance(obj, dict):
        t = obj.get("type")
        if t == "text" and isinstance(obj.get("text"), str):
            acc["text"].append(obj["text"])
        if t == "cortex_search_citation":
            acc["cites"].append((obj.get("doc_title") or obj.get("doc_id") or "source",
                                 obj.get("text") or ""))
        if t in ("cortex_analyst_text_to_sql", "cortex_search") and obj.get("name"):
            acc["tools"].add(obj["name"])
        if isinstance(obj.get("sql"), str):
            acc["sql"].append(obj["sql"])
        if isinstance(obj.get("result_set"), dict):
            acc["results"].append(obj["result_set"])
        if isinstance(obj.get("assistant_message_id"), int):
            acc["amid"] = obj["assistant_message_id"]
        if isinstance(obj.get("thread_id"), int):
            acc["tid"] = obj["thread_id"]
        if isinstance(obj.get("suggestions"), list):
            acc["suggestions"] += [s for s in obj["suggestions"] if isinstance(s, str)]
        for v in obj.values():
            _walk(v, acc)
    elif isinstance(obj, list):
        for v in obj:
            _walk(v, acc)


def _result_df(rs):
    try:
        cols = [c["name"] for c in rs.get("resultSetMetaData", {}).get("rowType", [])]
        data = rs.get("data", [])
        if cols and data:
            return pd.DataFrame(data, columns=cols)
    except Exception:
        pass
    return None


def parse_agent(content, analyst_tool="analyst"):
    acc = {"text": [], "cites": [], "tools": set(), "sql": [], "results": [],
           "suggestions": [], "amid": None, "tid": None}
    try:
        obj = json.loads(content)
    except Exception:
        obj = None
    if obj is None:   # SSE fallback — walk every event, prefer the aggregated response
        agg, completes = None, []
        for raw in str(content).splitlines():
            raw = raw.strip()
            if not raw.startswith("data:"):
                continue
            p = raw[5:].strip()
            if not p or p == "[DONE]":
                continue
            try:
                d = json.loads(p)
            except Exception:
                continue
            _walk(d, acc)   # ids / SQL / result sets can arrive on any event
            if isinstance(d, dict) and isinstance(d.get("content"), list) \
                    and d.get("role") == "assistant":
                agg = d
            elif isinstance(d, dict) and "text" in d and "annotations" in d \
                    and "content_index" in d:
                completes.append(d)
        if agg is not None:
            obj = agg
        elif completes:
            obj = {"content": [{"type": "text", "text": c.get("text", ""),
                                "annotations": c.get("annotations", [])} for c in completes]}
    if obj is not None:
        _walk(obj, acc)
        # authoritative ids come from the final response metadata, not stray fields
        meta = obj.get("metadata") if isinstance(obj, dict) else None
        if isinstance(meta, dict):
            if isinstance(meta.get("assistant_message_id"), int):
                acc["amid"] = meta["assistant_message_id"]
            if isinstance(meta.get("thread_id"), int):
                acc["tid"] = meta["thread_id"]
    seen, cites = set(), []
    for title, snip in acc["cites"]:
        if title not in seen:
            seen.add(title)
            cites.append((title, snip))
    tools = sorted(acc["tools"])
    if acc["sql"] and analyst_tool not in tools:
        tools.append(analyst_tool)
    seen_r, results = set(), []
    for rs in acc["results"]:
        rdf = _result_df(rs)
        if rdf is None or rdf.empty:
            continue
        sig = (tuple(map(str, rdf.columns)), tuple(rdf.iloc[0].astype(str)))
        if sig in seen_r:
            continue
        seen_r.add(sig)
        results.append({"cols": [str(c) for c in rdf.columns],
                        "rows": rdf.head(50).astype(str).values.tolist()})
    return {"text": "\n".join(t for t in acc["text"] if t and t.strip()),
            "cites": cites, "tools": tools, "sql": acc["sql"], "results": results,
            "suggestions": acc["suggestions"][:3], "amid": acc["amid"], "tid": acc["tid"]}


# =============================================================================
# AGENT CALLS
# =============================================================================
def call_agent(cfg, question, history, thread_id, parent_mid):
    import _snowflake
    if thread_id:                       # native thread → the server holds context
        messages = [{"role": "user", "content": [{"type": "text", "text": question}]}]
    else:                               # fallback → replay recent history
        messages = []
        for m in history[-8:]:
            role = "user" if m["role"] == "user" else "assistant"
            messages.append({"role": role, "content": [{"type": "text", "text": m["text"]}]})
        messages.append({"role": "user", "content": [{"type": "text", "text": question}]})
    body = {"messages": messages,
            "models": {"orchestration": cfg.get("model", DEFAULT_MODEL)},
            "instructions": cfg["instructions"],
            "orchestration": {"budget": dict(BUDGET)},
            "tools": cfg["tools"], "tool_resources": cfg["tool_resources"],
            "tool_choice": {"type": "auto"}, "stream": False}
    if thread_id:
        body["thread_id"] = thread_id
        body["parent_message_id"] = parent_mid or 0
    resp = _snowflake.send_snow_api_request(
        "POST", "/api/v2/cortex/agent:run", {}, {}, body, {}, 120000)
    if resp["status"] >= 400:
        raise Exception(f"Cortex Agents error ({resp['status']}): "
                        f"{str(resp.get('content'))[:600]}")
    return parse_agent(resp["content"], cfg.get("analyst_tool", "analyst"))


def thread_create(origin):
    import _snowflake
    try:
        r = _snowflake.send_snow_api_request(
            "POST", "/api/v2/cortex/threads", {}, {}, {"origin_application": origin}, {}, 30000)
        if r["status"] < 400:
            return json.loads(r["content"]).get("thread_id")
    except Exception:
        pass
    return None


def thread_rename(tid, name):
    import _snowflake
    try:
        _snowflake.send_snow_api_request("POST", f"/api/v2/cortex/threads/{tid}", {}, {},
                                         {"thread_name": name[:64]}, {}, 15000)
    except Exception:
        pass


def thread_delete(tid):
    import _snowflake
    try:
        _snowflake.send_snow_api_request("DELETE", f"/api/v2/cortex/threads/{tid}",
                                         {}, {}, {}, {}, 15000)
    except Exception:
        pass


# =============================================================================
# HANDOFF — call from any page to open the Copilot pre-seeded
# =============================================================================
def open_in_copilot(page_name, context, seed):
    st.session_state.copilot_seed = seed
    st.session_state.copilot_context = context
    st.session_state.page = page_name
    st.rerun()


# =============================================================================
# THE PAGE
# =============================================================================
def render(session, cfg):
    db = cfg["db"]
    conv_table = f"{db}.GOVERNANCE.COPILOT_CONVERSATIONS"
    log_table = f"{db}.GOVERNANCE.COPILOT_INTERACTION_LOG"

    theme.page_header(cfg.get("eyebrow", "Governed agent · Cortex Agents"),
                      cfg["title"], cfg.get("blurb", ""))

    ss = st.session_state
    ss.setdefault("copilot_messages", [])
    ss.setdefault("cp_conv_id", None)
    ss.setdefault("cp_thread_id", None)
    ss.setdefault("cp_parent_mid", 0)

    def live(sql):
        return session.sql(sql).to_pandas()

    def run_turn(question):
        """Native thread first; self-heal to message replay if it desyncs."""
        hist = ss.copilot_messages[:-1]
        try:
            return call_agent(cfg, question, hist, ss.cp_thread_id, ss.cp_parent_mid)
        except Exception as e:
            if ss.cp_thread_id and any(k in str(e)
                                       for k in ("parent_message_id", "thread", "399504")):
                ss.cp_thread_id = None
                ss.cp_parent_mid = 0
                return call_agent(cfg, question, hist, None, 0)
            raise

    def cp_list():
        try:
            return live(f"SELECT CONVERSATION_ID, TITLE FROM {conv_table} "
                        "WHERE OWNER = CURRENT_USER() ORDER BY UPDATED_AT DESC LIMIT 30")
        except Exception:
            return pd.DataFrame(columns=["CONVERSATION_ID", "TITLE"])

    def cp_load(cid):
        df = session.sql(f"SELECT MESSAGES, THREAD_ID, PARENT_MESSAGE_ID FROM {conv_table} "
                         "WHERE CONVERSATION_ID = ?", params=[cid]).to_pandas()
        if df.empty:
            return [], None, 0
        try:
            msgs = json.loads(df["MESSAGES"].iloc[0])
        except Exception:
            msgs = []
        tid, pmid = df["THREAD_ID"].iloc[0], df["PARENT_MESSAGE_ID"].iloc[0]
        return (msgs, int(tid) if pd.notna(tid) else None, int(pmid) if pd.notna(pmid) else 0)

    def cp_save(cid, title, messages, tid, pmid):
        session.sql(
            f"MERGE INTO {conv_table} t "
            "USING (SELECT ? AS CID, ? AS TITLE, ? AS MSG, ? AS TID, ? AS PMID) s "
            "ON t.CONVERSATION_ID = s.CID "
            "WHEN MATCHED THEN UPDATE SET MESSAGES=s.MSG, THREAD_ID=s.TID, "
            "PARENT_MESSAGE_ID=s.PMID, UPDATED_AT=CURRENT_TIMESTAMP() "
            "WHEN NOT MATCHED THEN INSERT (CONVERSATION_ID, TITLE, MESSAGES, THREAD_ID, "
            "PARENT_MESSAGE_ID) VALUES (s.CID, s.TITLE, s.MSG, s.TID, s.PMID)",
            params=[cid, title, json.dumps(messages), tid, pmid]).collect()

    def cp_log(context, question, answer, sources):
        session.sql(f"INSERT INTO {log_table} (CONTEXT, QUESTION, ANSWER_PREVIEW, SOURCES) "
                    "SELECT ?, ?, ?, ?",
                    params=[context, question, (answer or "")[:600], sources]).collect()

    def cp_reset():
        ss.cp_conv_id, ss.copilot_messages = None, []
        ss.cp_thread_id, ss.cp_parent_mid = None, 0

    def cp_feedback(decision):
        try:
            fb = cfg.get("on_feedback")
            if fb:
                fb(ss.cp_conv_id or "adhoc", decision)
            st.toast(f"Feedback logged ({decision})")
        except Exception:
            pass

    def render_extras(msg, key):
        cites = msg.get("cites", [])
        if cites:
            with st.expander(f"Sources ({len(cites)})"):
                for title, snip in cites:
                    st.markdown(f"**{title}** — {snip[:260]}" if snip else f"**{title}**")
        tools, sqls, results = msg.get("tools", []), msg.get("sql", []), msg.get("results", [])
        if tools or sqls or results:
            with st.expander("How the Copilot worked"):
                if tools:
                    st.markdown("Tools used: " + ", ".join(f"`{t}`" for t in tools))
                for r in results:
                    try:
                        st.dataframe(theme.df(pd.DataFrame(r["rows"], columns=r["cols"])),
                                     use_container_width=True, hide_index=True)
                    except Exception:
                        pass
                for q in sqls:
                    st.code(q, language="sql")
        fb = st.columns([1, 1, 10])
        if fb[0].button("👍", key=f"cp_up_{key}", help="Helpful — log it"):
            cp_feedback("Accepted")
        if fb[1].button("👎", key=f"cp_dn_{key}", help="Not helpful — log it"):
            cp_feedback("Rejected")

    def cur_title(convs):
        for _, r in convs.iterrows():
            if r["CONVERSATION_ID"] == ss.cp_conv_id:
                return r["TITLE"] or ""
        return ""

    # a handoff from another page starts a fresh conversation
    seed = ss.pop("copilot_seed", None)
    ctx_tag = ss.pop("copilot_context", None) or ""
    if seed:
        cp_reset()

    rail, chat = st.columns([1, 3], gap="medium")

    with rail:
        if st.button("➕  New conversation", use_container_width=True, key="cp_new"):
            cp_reset()
            st.rerun()
        st.caption("Your conversations")
        convs = cp_list()
        for _, row in convs.iterrows():
            cid = row["CONVERSATION_ID"]
            cur = cid == ss.cp_conv_id
            label = ("• " if cur else "") + (row["TITLE"] or "Untitled")[:30]
            if st.button(label, key=f"cp_conv_{cid}", use_container_width=True,
                         type="primary" if cur else "secondary"):
                ss.copilot_messages, ss.cp_thread_id, ss.cp_parent_mid = cp_load(cid)
                ss.cp_conv_id = cid
                st.rerun()
        if ss.cp_conv_id:
            st.divider()
            new_title = st.text_input("Rename", value=cur_title(convs), key="cp_rename_in",
                                      label_visibility="collapsed", placeholder="Rename…")
            rc = st.columns(2)
            if rc[0].button("Rename", use_container_width=True, key="cp_rename_btn") \
                    and new_title.strip():
                session.sql(f"UPDATE {conv_table} SET TITLE = ?, UPDATED_AT = CURRENT_TIMESTAMP() "
                            "WHERE CONVERSATION_ID = ?",
                            params=[new_title.strip(), ss.cp_conv_id]).collect()
                if ss.cp_thread_id:
                    thread_rename(ss.cp_thread_id, new_title.strip())
                st.rerun()
            if rc[1].button("🗑  Delete", use_container_width=True, key="cp_del"):
                session.sql(f"DELETE FROM {conv_table} WHERE CONVERSATION_ID = ?",
                            params=[ss.cp_conv_id]).collect()
                if ss.cp_thread_id:
                    thread_delete(ss.cp_thread_id)
                cp_reset()
                st.rerun()

    with chat:
        if ctx_tag:
            st.info(f"Opened from **{ctx_tag}** — context carried in.")
        for idx, msg in enumerate(ss.copilot_messages):
            with st.chat_message("user" if msg["role"] == "user" else "assistant"):
                st.markdown(msg["text"])
                if msg["role"] != "user":
                    render_extras(msg, f"{ss.cp_conv_id}_{idx}")
        if ss.copilot_messages and ss.copilot_messages[-1]["role"] != "user":
            sugg = ss.copilot_messages[-1].get("suggestions", [])
            if sugg:
                st.caption("Suggested follow-ups")
                fcols = st.columns(len(sugg))
                for i, s in enumerate(sugg):
                    if fcols[i].button(s[:52], key=f"cp_fu_{i}", use_container_width=True):
                        ss.copilot_seed = s
                        st.rerun()

        if not ss.copilot_messages:
            st.markdown("**Start with:**")
            scols = st.columns(2)
            for i, sug in enumerate(cfg.get("starters", [])):
                if scols[i % 2].button(sug, key=f"cp_sug_{i}", use_container_width=True):
                    ss.copilot_seed = sug
                    st.rerun()
        else:
            transcript = f"# {cfg['title']} conversation\n\n" + "\n\n".join(
                f"**{'You' if m['role'] == 'user' else 'Copilot'}:** {m['text']}"
                for m in ss.copilot_messages)
            st.download_button("⬇  Export conversation (.md)", transcript,
                               file_name="copilot_conversation.md", key="cp_export")

    typed = st.chat_input(cfg.get("placeholder", "Ask a question..."))
    active = seed or typed

    if active:
        ss.copilot_messages.append({"role": "user", "text": active})
        with st.spinner(cfg.get("spinner", "Cortex Agents is reasoning...")):
            try:
                if ss.cp_thread_id is None and len(ss.copilot_messages) == 1:
                    ss.cp_thread_id = thread_create(cfg.get("origin", "hcls_copilot"))
                    ss.cp_parent_mid = 0
                res = run_turn(active)
                if res["amid"]:
                    ss.cp_parent_mid = res["amid"]
                if res["tid"] and not ss.cp_thread_id:
                    ss.cp_thread_id = res["tid"]
                ss.copilot_messages.append(
                    {"role": "assistant",
                     "text": res["text"] or "_(No text returned — try rephrasing.)_",
                     "cites": res["cites"], "tools": res["tools"], "sql": res["sql"],
                     "results": res["results"], "suggestions": res["suggestions"]})
                try:
                    srcs = ", ".join(t for t, _ in res["cites"]) or ", ".join(res["tools"])
                    cp_log(ctx_tag, active, res["text"], srcs)
                except Exception:
                    pass
            except Exception as e:
                ss.copilot_messages.append({"role": "assistant", "text": f"⚠️ {e}"})
        try:
            if not ss.cp_conv_id:
                ss.cp_conv_id = str(uuid.uuid4())
            title = next((m["text"] for m in ss.copilot_messages if m["role"] == "user"),
                         "New conversation")[:60]
            cp_save(ss.cp_conv_id, title, ss.copilot_messages, ss.cp_thread_id, ss.cp_parent_mid)
        except Exception:
            pass
        st.rerun()

    note = cfg.get("footer", "")
    obj = cfg.get("agent_object")
    if obj:
        note += (f" The same assistant is available in **Snowflake CoWork** and the "
                 f"**Cortex Code CLI** as `{obj}`.")
    st.caption("Cortex Agents + native threads · Analyst & Search as tools · advisory · every "
               f"turn logged to GOVERNANCE.COPILOT_INTERACTION_LOG. {note}")
