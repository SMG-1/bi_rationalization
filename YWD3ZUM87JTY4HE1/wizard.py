"""
Setup Wizard — drop the workbench into a client account and use it from here.

Six steps, in the order an engagement actually does them:
  1 Extracts     load each platform's metadata and usage files into INVENTORY
  2 Directory    the HR directory (executives, developers, leavers)
  3 Catalog      what each referenced source table IS — seeded from the common
                 HCLS tables, completed by the client
  4 Register     regulatory obligations the usage numbers cannot see
  5 Policy       thresholds and rule order
  6 Run          execute the pipeline server-side and watch the step log

Nothing here needs a laptop: uploads go to @INVENTORY.LANDING through the
Snowpark session, and the pipeline runs the SQL files staged on
@APP.WORKBENCH_STAGE with EXECUTE IMMEDIATE FROM.
"""
import io
import time

import pandas as pd
import streamlit as st

import theme

DB = "BI_MODERNIZATION"

# table -> (platform, what it is, where it comes from, required?)
EXTRACTS = [
    ("TABLEAU_WORKBOOKS", "TABLEAU", "Workbooks", "REST API: GET /sites/{id}/workbooks", True),
    ("TABLEAU_VIEWS", "TABLEAU", "Views / sheets", "REST API: GET /sites/{id}/views", True),
    ("TABLEAU_DATASOURCES", "TABLEAU", "Data sources with tables", "Metadata API (GraphQL): workbooks → embeddedDatasources → upstreamTables", True),
    ("TABLEAU_CALCULATED_FIELDS", "TABLEAU", "Calculated fields", "Metadata API: calculatedFields { formula }", True),
    ("TABLEAU_FIELD_LINEAGE", "TABLEAU", "Field lineage", "Metadata API: fields → upstreamColumns", False),
    ("TABLEAU_VIEWS_STATS", "TABLEAU", "Usage (views_stats)", "Server repository: views_stats / historical_events, or Admin Insights", True),
    ("TABLEAU_SUBSCRIPTIONS", "TABLEAU", "Subscriptions", "REST API: GET /sites/{id}/subscriptions", False),
    ("TABLEAU_EXTRACT_REFRESHES", "TABLEAU", "Extract refresh runs", "REST API: background jobs", False),
    ("PBI_WORKSPACES", "POWER_BI", "Workspaces", "Admin API: GET /admin/groups", True),
    ("PBI_REPORTS", "POWER_BI", "Reports", "Admin API: GET /admin/reports", True),
    ("PBI_REPORT_PAGES", "POWER_BI", "Report pages / visuals", "REST: GET /reports/{id}/pages (visual detail via PBIX inspection)", False),
    ("PBI_DATASETS", "POWER_BI", "Datasets", "Scanner API: workspaces/getInfo with datasetSchema", True),
    ("PBI_DATASET_TABLES", "POWER_BI", "Dataset tables + M source", "Scanner API: datasetSchema=true&datasetExpressions=true", True),
    ("PBI_MEASURES", "POWER_BI", "DAX measures", "Scanner API: datasetSchema measures", True),
    ("PBI_ACTIVITY_EVENTS", "POWER_BI", "Usage (activity events)", "Admin API: GET /admin/activityevents — 30-day retention, export continuously", True),
    ("PBI_REFRESH_HISTORY", "POWER_BI", "Refresh history", "REST: GET /datasets/{id}/refreshes", False),
    ("PBI_SUBSCRIPTIONS", "POWER_BI", "Subscriptions", "Admin API: GET /admin/reports/{id}/subscriptions", False),
    ("BO_UNIVERSES", "SAP_BO", "Universes", "CMS query: SI_KIND='Universe' / 'DSL.Universe'", True),
    ("BO_UNIVERSE_OBJECTS", "SAP_BO", "Universe objects", "Universe Design Tool / IDT SDK export (objects with SELECT)", True),
    ("BO_WEBI_DOCUMENTS", "SAP_BO", "Webi / Crystal documents", "CMS query: SI_KIND='Webi' / 'CrystalReport'", True),
    ("BO_WEBI_QUERIES", "SAP_BO", "Document queries", "RESTful Web Services: /documents/{id}/dataproviders", True),
    ("BO_WEBI_VARIABLES", "SAP_BO", "Variables (formulas)", "RESTful Web Services: /documents/{id}/variables", True),
    ("BO_REPORT_ELEMENTS", "SAP_BO", "Report elements", "RESTful Web Services: /documents/{id}/reports/{rid}/elements", False),
    ("BO_AUDIT_EVENTS", "SAP_BO", "Usage (audit events)", "Auditing Data Store: ADS_EVENT joined to ADS_EVENT_TYPE_STR", True),
    ("BO_SCHEDULES", "SAP_BO", "Schedules", "CMS query: SI_SCHEDULEINFO on document instances", False),
    ("MEDE_REPORTS", "MEDEANALYTICS", "Report catalog", "Admin console export of reports/dashboards by module — no public API; confirm columns with the vendor", True),
    ("MEDE_REPORT_FIELDS", "MEDEANALYTICS", "Fields and measures", "Report definition export; vendor-defined measures carry no formula (measure dictionary)", True),
    ("MEDE_REPORT_SECTIONS", "MEDEANALYTICS", "Sections / visuals", "Report definition export", False),
    ("MEDE_USER_ACTIVITY", "MEDEANALYTICS", "Usage (user activity)", "Admin console user-activity / audit export", True),
    ("MEDE_DELIVERIES", "MEDEANALYTICS", "Scheduled deliveries", "Admin console schedule export", False),
]
SHARED = [
    ("USER_DIRECTORY", "HR directory", "Workday / AD export: email, department, title, executive flag, BI developer flag, active flag", True),
]


def _cols(session, table):
    df = session.sql(f"""SELECT COLUMN_NAME, DATA_TYPE FROM {DB}.INFORMATION_SCHEMA.COLUMNS
                         WHERE TABLE_SCHEMA = 'INVENTORY' AND TABLE_NAME = '{table}' ORDER BY ORDINAL_POSITION""").to_pandas()
    return df


def _status(session):
    return session.sql(f"SELECT * FROM {DB}.APP.V_EXTRACT_STATUS").to_pandas().set_index("TABLE_NAME")


def _upload(session, table, file, replace):
    """Stream the uploaded file to @INVENTORY.LANDING and COPY it in (header-driven)."""
    name = f"{table.lower()}_{int(time.time())}.csv"
    session.file.put_stream(io.BytesIO(file.getvalue()), f"@{DB}.INVENTORY.LANDING/{name}",
                            auto_compress=False, overwrite=True)
    return session.sql(f"CALL {DB}.APP.SP_LOAD_EXTRACT(?, ?, ?)", params=[table, name, bool(replace)]).collect()[0][0]


def _save_editor(session, table, schema, key_cols, edited, original):
    """Write a data_editor result back: delete removed keys, merge the rest."""
    cols = list(edited.columns)
    ok = 0
    orig_keys = set(tuple(r) for r in original[key_cols].astype(str).values.tolist()) if len(original) else set()
    new_keys = set(tuple(r) for r in edited[key_cols].astype(str).values.tolist())
    for k in orig_keys - new_keys:
        where = " AND ".join(f"{c} = ?" for c in key_cols)
        session.sql(f"DELETE FROM {DB}.{schema}.{table} WHERE {where}", params=list(k)).collect()
    for _, row in edited.iterrows():
        vals = [None if (isinstance(v, float) and pd.isna(v)) else v for v in row.tolist()]
        if any(v is None or str(v).strip() == "" for v in [row[c] for c in key_cols]):
            continue
        where = " AND ".join(f"{c} = ?" for c in key_cols)
        session.sql(f"DELETE FROM {DB}.{schema}.{table} WHERE {where}", params=[row[c] for c in key_cols]).collect()
        placeholders = ", ".join("?" for _ in cols)
        session.sql(f"INSERT INTO {DB}.{schema}.{table} ({', '.join(cols)}) VALUES ({placeholders})", params=vals).collect()
        ok += 1
    return ok


def render(session, q, live):
    theme.page_header("Setup Wizard", "From extracts to a running rationalization, inside Snowflake",
                      "Load the platform extracts, tell the engine what the source tables are and which "
                      "reports are obligations, tune the thresholds, and run. Everything you change here "
                      "survives a re-run; the engine never overwrites a decision.")

    status = _status(session)
    loaded = int((status["ROWS_LOADED"] > 0).sum())
    cat = status.loc["SOURCE_SYSTEM_CATALOG", "ROWS_LOADED"]
    try:
        unc = live(f"SELECT COUNT(*) N FROM {DB}.APP.V_REFERENCED_SOURCE_TABLES WHERE NOT IS_CATALOGED").iloc[0]["N"]
    except Exception:
        unc = None
    last = live(f"SELECT MAX(RUN_ID) R, MAX(ENDED_AT) T FROM {DB}.APP.PIPELINE_RUN")
    c = st.columns(4)
    c[0].metric("Extract tables loaded", f"{loaded} of {len(status)}")
    c[1].metric("Cataloged source tables", int(cat))
    c[2].metric("Referenced but uncataloged", "—" if unc is None else int(unc))
    c[3].metric("Last pipeline run", "never" if pd.isna(last.iloc[0]["R"]) else f"#{int(last.iloc[0]['R'])}")

    tabs = st.tabs(["1 · Extracts", "2 · Directory", "3 · Source catalog", "4 · Regulatory register",
                    "5 · Policy & rules", "6 · Run"])

    # ------------------------------------------------------------ 1 extracts
    with tabs[0]:
        st.caption("One CSV per table, header row required, columns in any order (matched by name). "
                   "Download the template for the exact column list. Upload replaces or appends; "
                   "usage tables are typically appended month by month.")
        plat = st.radio("Platform", ["TABLEAU", "POWER_BI", "SAP_BO", "MEDEANALYTICS"], horizontal=True, key="wz_plat")
        rows = [e for e in EXTRACTS if e[1] == plat]
        summary = pd.DataFrame([{"Table": t, "What": w, "Where it comes from": src, "Required": "yes" if req else "",
                                 "Rows loaded": int(status.loc[t, "ROWS_LOADED"]) if t in status.index else 0}
                                for t, _, w, src, req in rows])
        st.dataframe(theme.df(summary), use_container_width=True, hide_index=True)
        table = st.selectbox("Table to load", [r[0] for r in rows], key="wz_tbl")
        cols = _cols(session, table)
        left, right = st.columns([2, 1])
        with left:
            f = st.file_uploader(f"CSV for INVENTORY.{table}", type=["csv"], key=f"up_{table}")
            replace = st.checkbox("Replace existing rows (otherwise append)", key=f"rp_{table}")
            if f is not None and st.button("Load", key=f"ld_{table}", type="primary"):
                try:
                    msg = _upload(session, table, f, replace)
                    st.success(msg)
                    q.clear()
                except Exception as e:
                    st.error(f"Load failed: {str(e)[:600]}")
        with right:
            st.caption("Expected columns")
            st.dataframe(theme.df(cols), use_container_width=True, hide_index=True, height=260)
            st.download_button("Download CSV template", (",".join(cols["COLUMN_NAME"]) + "\n").encode(),
                               file_name=f"{table.lower()}_template.csv", key=f"tp_{table}")
        with st.expander("Starting from a client estate? Clear the demo data first"):
            st.caption("Truncates every INVENTORY extract table. Keeps the catalog seed, policy, rules and register. "
                       "The demo data can be regenerated from the repo; this cannot be undone from the app.")
            sure = st.checkbox("I understand — clear all extract tables", key="wz_clear_ok")
            if sure and st.button("Clear inventory", key="wz_clear"):
                st.warning(live(f"CALL {DB}.APP.SP_CLEAR_INVENTORY()").iloc[0, 0])
                q.clear()
                st.rerun()

    # ------------------------------------------------------------ 2 directory
    with tabs[1]:
        st.caption("Who is an executive, who builds reports, who has left. Executive readers protect an asset; "
                   "developer-only views do not count as an audience; leavers still holding subscriptions are flagged.")
        d = live(f"""SELECT COUNT(*) PEOPLE, COUNT_IF(IS_EXECUTIVE) EXECUTIVES, COUNT_IF(IS_BI_DEVELOPER) DEVELOPERS,
                            COUNT_IF(NOT IS_ACTIVE) INACTIVE, COUNT(*) - COUNT(DISTINCT LOWER(EMAIL)) DUPLICATE_EMAILS
                     FROM {DB}.INVENTORY.USER_DIRECTORY""")
        c = st.columns(5)
        for i, k in enumerate(["PEOPLE", "EXECUTIVES", "DEVELOPERS", "INACTIVE", "DUPLICATE_EMAILS"]):
            c[i].metric(k.replace("_", " ").title(), int(d.iloc[0][k]))
        if int(d.iloc[0]["DUPLICATE_EMAILS"]) > 0:
            st.info("Duplicate emails are handled: the conform step keeps one record per address "
                    "(active, then executive, then developer). Shared mailboxes and service accounts are normal.")
        cols = _cols(session, "USER_DIRECTORY")
        f = st.file_uploader("CSV for INVENTORY.USER_DIRECTORY", type=["csv"], key="up_dir")
        replace = st.checkbox("Replace existing rows", value=True, key="rp_dir")
        if f is not None and st.button("Load directory", key="ld_dir", type="primary"):
            try:
                st.success(_upload(session, "USER_DIRECTORY", f, replace))
                q.clear()
            except Exception as e:
                st.error(f"Load failed: {str(e)[:600]}")
        st.download_button("Download CSV template", (",".join(cols["COLUMN_NAME"]) + "\n").encode(),
                           file_name="user_directory_template.csv", key="tp_dir")
        st.dataframe(theme.df(live(f"SELECT DEPARTMENT, COUNT(*) PEOPLE, COUNT_IF(IS_EXECUTIVE) EXECUTIVES FROM {DB}.INVENTORY.USER_DIRECTORY GROUP BY 1 ORDER BY 2 DESC")),
                     use_container_width=True, hide_index=True, height=260)

    # ------------------------------------------------------------ 3 catalog
    with tabs[2]:
        st.caption("Every table the extracts reference, with what the catalog knows about it. Rows the seed "
                   "recognizes arrive pre-filled (common Epic Clarity, Caboodle, Lawson, Workday, Facets and registry "
                   "tables). Fill SUBJECT_AREA, ENTITY_ROLE (FACT / DIM) and CONFORMED_ENTITY for the rest — this is the "
                   "bridge from lineage to the target model, and it is the most important thing a client team does here.")
        ref = live(f"SELECT * FROM {DB}.APP.V_REFERENCED_SOURCE_TABLES ORDER BY IS_CATALOGED, ASSETS_REFERENCING DESC")
        c = st.columns(4)
        c[0].metric("Referenced tables", len(ref))
        c[1].metric("Cataloged", int(ref["IS_CATALOGED"].sum()))
        c[2].metric("Suggested from seed", int(ref["SUGGESTED_FROM_SEED"].sum()))
        c[3].metric("Assets on uncataloged tables", int(ref.loc[~ref["IS_CATALOGED"], "ASSETS_REFERENCING"].sum()))
        only_missing = st.checkbox("Show only uncataloged", value=True, key="wz_cat_missing")
        view = ref[~ref["IS_CATALOGED"]] if only_missing else ref
        edit_cols = ["SOURCE_DATABASE", "SOURCE_SCHEMA", "SOURCE_TABLE", "SUBJECT_AREA", "ENTITY_ROLE", "CONFORMED_ENTITY",
                     "GRAIN", "IS_DECOMMISSIONED", "SYSTEM_FAMILY", "ASSETS_REFERENCING", "PLATFORMS"]
        edited = st.data_editor(
            view[edit_cols], key="wz_cat_editor", use_container_width=True, hide_index=True, num_rows="dynamic",
            disabled=["ASSETS_REFERENCING", "PLATFORMS"],
            column_config={"ENTITY_ROLE": st.column_config.SelectboxColumn(options=["FACT", "DIM"]),
                           "IS_DECOMMISSIONED": st.column_config.CheckboxColumn()})
        if st.button("Save catalog rows", key="wz_cat_save", type="primary"):
            ready = edited[edited["SUBJECT_AREA"].notna() & edited["ENTITY_ROLE"].notna() & edited["CONFORMED_ENTITY"].notna()]
            n = 0
            for _, r in ready.iterrows():
                session.sql(f"""MERGE INTO {DB}.INVENTORY.SOURCE_SYSTEM_CATALOG t
                    USING (SELECT ? SOURCE_DATABASE, ? SOURCE_SCHEMA, ? SOURCE_TABLE) s
                    ON UPPER(t.SOURCE_DATABASE) = UPPER(s.SOURCE_DATABASE) AND UPPER(t.SOURCE_TABLE) = UPPER(s.SOURCE_TABLE)
                    WHEN MATCHED THEN UPDATE SET SUBJECT_AREA = ?, ENTITY_ROLE = ?, CONFORMED_ENTITY = ?, GRAIN = ?, IS_DECOMMISSIONED = ?, SYSTEM_FAMILY = ?
                    WHEN NOT MATCHED THEN INSERT (SOURCE_DATABASE, SOURCE_SCHEMA, SOURCE_TABLE, SUBJECT_AREA, ENTITY_ROLE, CONFORMED_ENTITY, GRAIN, IS_DECOMMISSIONED, SYSTEM_FAMILY)
                    VALUES (s.SOURCE_DATABASE, s.SOURCE_SCHEMA, s.SOURCE_TABLE, ?, ?, ?, ?, ?, ?)""",
                    params=[r["SOURCE_DATABASE"], r["SOURCE_SCHEMA"], r["SOURCE_TABLE"],
                            r["SUBJECT_AREA"], r["ENTITY_ROLE"], r["CONFORMED_ENTITY"], r["GRAIN"], bool(r["IS_DECOMMISSIONED"]), r["SYSTEM_FAMILY"],
                            r["SUBJECT_AREA"], r["ENTITY_ROLE"], r["CONFORMED_ENTITY"], r["GRAIN"], bool(r["IS_DECOMMISSIONED"]), r["SYSTEM_FAMILY"]]).collect()
                n += 1
            st.success(f"{n} catalog rows saved ({len(edited) - n} left incomplete)")
            q.clear()
            st.rerun()
        with st.expander("Load a catalog CSV instead"):
            cols = _cols(session, "SOURCE_SYSTEM_CATALOG")
            f = st.file_uploader("CSV for INVENTORY.SOURCE_SYSTEM_CATALOG", type=["csv"], key="up_cat")
            if f is not None and st.button("Load catalog", key="ld_cat"):
                st.success(_upload(session, "SOURCE_SYSTEM_CATALOG", f, True))
                q.clear()
            st.download_button("Download CSV template", (",".join(cols["COLUMN_NAME"]) + "\n").encode(),
                               file_name="source_system_catalog_template.csv", key="tp_cat")

    # ------------------------------------------------------------ 4 register
    with tabs[3]:
        st.caption("Obligations the usage numbers cannot see. A title pattern (regex, case-insensitive) or an explicit "
                   "asset id. The register runs before any usage rule: an annual filing opened by two people is never a zombie.")
        reg = live(f"SELECT REGISTER_ID, OBLIGATION, AUTHORITY, TITLE_PATTERN, CADENCE, OWNER_ROLE, NOTE FROM {DB}.RATIONALIZATION.REGULATORY_REGISTER ORDER BY REGISTER_ID")
        edited = st.data_editor(reg, key="wz_reg_editor", use_container_width=True, hide_index=True, num_rows="dynamic")
        if st.button("Save register", key="wz_reg_save", type="primary"):
            n = _save_editor(session, "REGULATORY_REGISTER", "RATIONALIZATION", ["REGISTER_ID"], edited, reg)
            st.success(f"{n} obligations saved")
            q.clear()
        st.markdown("**What the patterns currently match**")
        try:
            m = live(f"""SELECT m.REGISTER_ID, m.OBLIGATION, COUNT(*) ASSETS, LISTAGG(a.TITLE, ' | ') WITHIN GROUP (ORDER BY a.TITLE) SAMPLE_TITLES
                         FROM {DB}.RATIONALIZATION.V_REGULATORY_MATCH m JOIN {DB}.CONFORMED.ASSET a ON a.ASSET_ID = m.ASSET_ID
                         GROUP BY 1, 2 ORDER BY 3 DESC""")
            st.dataframe(theme.df(m), use_container_width=True, hide_index=True)
        except Exception:
            st.caption("Run the pipeline once (step 6) to see matches against the conformed estate.")

    # ------------------------------------------------------------ 5 policy
    with tabs[4]:
        st.caption("Thresholds and rule order are data. Change a value, save, re-run; the engine does not change.")
        pol = live(f"SELECT POLICY_KEY, POLICY_VALUE, DESCRIPTION FROM {DB}.RATIONALIZATION.SCORING_POLICY ORDER BY POLICY_KEY")
        ep = st.data_editor(pol, key="wz_pol_editor", use_container_width=True, hide_index=True, disabled=["POLICY_KEY", "DESCRIPTION"])
        if st.button("Save policy", key="wz_pol_save", type="primary"):
            for _, r in ep.iterrows():
                session.sql(f"UPDATE {DB}.RATIONALIZATION.SCORING_POLICY SET POLICY_VALUE = ?, SET_BY = CURRENT_USER(), SET_AT = CURRENT_TIMESTAMP() WHERE POLICY_KEY = ?",
                            params=[float(r["POLICY_VALUE"]), r["POLICY_KEY"]]).collect()
            st.success("Policy saved — re-run rationalization (step 6) to apply.")
            q.clear()
        st.markdown("**Rules**")
        rules = live(f"SELECT RULE_ID, PRIORITY, IS_ENABLED, DISPOSITION, CONFIDENCE, RULE_NAME, CONDITION_SQL FROM {DB}.RATIONALIZATION.DISPOSITION_RULE ORDER BY PRIORITY")
        er = st.data_editor(rules, key="wz_rule_editor", use_container_width=True, hide_index=True,
                            disabled=["RULE_ID", "RULE_NAME", "CONDITION_SQL"],
                            column_config={"IS_ENABLED": st.column_config.CheckboxColumn(),
                                           "DISPOSITION": st.column_config.SelectboxColumn(options=["RETIRE", "CONSOLIDATE", "MIGRATE", "REBUILD", "SELF_SERVICE", "INVESTIGATE"]),
                                           "CONFIDENCE": st.column_config.SelectboxColumn(options=["HIGH", "MEDIUM"])})
        if st.button("Save rules", key="wz_rule_save", type="primary"):
            for _, r in er.iterrows():
                session.sql(f"UPDATE {DB}.RATIONALIZATION.DISPOSITION_RULE SET PRIORITY = ?, IS_ENABLED = ?, DISPOSITION = ?, CONFIDENCE = ? WHERE RULE_ID = ?",
                            params=[int(r["PRIORITY"]), bool(r["IS_ENABLED"]), r["DISPOSITION"], r["CONFIDENCE"], r["RULE_ID"]]).collect()
            st.success("Rules saved — re-run rationalization (step 6) to apply.")
            q.clear()
        st.caption("Conditions are edited in SQL (RATIONALIZATION.DISPOSITION_RULE.CONDITION_SQL) against V_ASSET_PROFILE columns; "
                   "reorder, enable and re-point dispositions here.")

    # ------------------------------------------------------------ 6 run
    with tabs[5]:
        st.caption("Runs the pipeline inside Snowflake from the SQL staged with the app. Seed tables are never re-run, "
                   "so your catalog, register, policy, rules, reviews, certifications and field decisions survive. "
                   "The definitions plane, semantic views, skills and copilot agent are rebuilt from the SQL and skills "
                   "staged with the app (change a definition in the repo, not in the table).")
        steps = live(f"SELECT SEQ, PHASE, LABEL, KIND, IS_AI FROM {DB}.APP.PIPELINE_STEP WHERE IN_APP ORDER BY SEQ")
        scope = st.radio("What to run", [
            "Everything (conform → definitions → AI → copilot)",
            "Rationalization only (after a policy, rule, register or catalog change)",
            "Target model and conversion only",
            "Definitions, search, semantic views and copilot only",
        ], key="wz_scope")
        include_ai = st.checkbox("Include the Claude steps (metric proposals, residual translation)", value=True, key="wz_ai")
        frm, to = {"Everything (conform → definitions → AI → copilot)": (3, 9),
                   "Rationalization only (after a policy, rule, register or catalog change)": (3, 4),
                   "Target model and conversion only": (5, 6.5),
                   "Definitions, search, semantic views and copilot only": (6.8, 9)}[scope]
        sel = steps[(steps["PHASE"] >= frm) & (steps["PHASE"] <= to)]
        st.dataframe(theme.df(sel), use_container_width=True, hide_index=True, height=min(400, 40 + 35 * len(sel)))
        st.caption("Typical runtime on the demo estate: conform + rationalize ~1.5 min; target model + conversion ~3 min; "
                   "the Claude metric step ~7 min. The run is submitted as a serverless task, so you can leave this page; "
                   "the log below refreshes itself every 10 seconds.")
        if st.button("Run pipeline", key="wz_go", type="primary"):
            msg = live(f"CALL {DB}.APP.SP_START_PIPELINE({frm}, {to}, {str(include_ai).upper()})").iloc[0, 0]
            (st.warning if "still RUNNING" in msg else st.success)(msg)
            q.clear()
        st.markdown("**Run log**")
        _run_log(live)


@st.fragment(run_every="10s")
def _run_log(live):
    log = live(f"""SELECT RUN_ID, SEQ, LABEL, STATUS, DATEDIFF(second, STARTED_AT, COALESCE(ENDED_AT, CURRENT_TIMESTAMP())) SECONDS,
                          MESSAGE, RUN_BY, STARTED_AT
                   FROM {DB}.APP.PIPELINE_RUN ORDER BY RUN_ID DESC, SEQ LIMIT 60""")
    active = log[log["STATUS"] == "RUNNING"]
    if len(active):
        st.info(f"Running: {active.iloc[0]['LABEL']} ({int(active.iloc[0]['SECONDS'])}s so far)")
    else:
        latest = log[log["SEQ"] > 0].head(1)
        if len(latest):
            st.caption(f"Last step: {latest.iloc[0]['LABEL']} — {latest.iloc[0]['STATUS']}")
    st.dataframe(theme.df(log), use_container_width=True, hide_index=True, height=360)
    try:
        th = live(f"SELECT STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE FROM {DB}.APP.V_PIPELINE_TASK_HISTORY LIMIT 5")
        with st.expander("Task history"):
            st.dataframe(theme.df(th), use_container_width=True, hide_index=True)
    except Exception:
        pass
