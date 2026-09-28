"""
BI Rationalization & Migration Workbench
Streamlit in Snowflake app
(fictional "Ridgeline Health"; all data synthetic).

Pages:
- Estate Overview       three platforms, one asset model, and the hours rationalization removes
- Inventory Explorer    every asset with its profile, sources, fields, components and usage
- Usage & Health        the Pareto, the staleness histogram, and the subscription trap
- Duplicates            clusters found structurally, each with a canonical member
- Rationalization       THE page — rules in priority order, reasons, and the human review gate
- Wave Plan             foundation wave plus waves of roughly equal effort, by subject area
- Target Data Model     entities derived from lineage, generated artifacts, metric conflicts
- Conversion Workbench  rules plus Claude residual pass to Sigma, reviewed field by field
- Reconciliation        the harness against the target mart, and acceptance sign-off
- Migration Copilot     Cortex Agents over the estate record and the migration reference
"""

import json

import altair as alt
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

import theme
import copilot
import wizard

session = get_active_session()
st.set_page_config(page_title="BI Rationalization & Migration Workbench", layout="wide")
_dark = st.session_state.get("dark_mode", True)
theme.inject(dark=_dark)

DB = "BI_MODERNIZATION"
WH = "BI_MOD_WH"
BLUE = theme.BLUE
DISPOSITIONS = ["RETIRE", "CONSOLIDATE", "MIGRATE", "REBUILD", "SELF_SERVICE", "INVESTIGATE"]


@st.cache_data(ttl=300)
def q(sql):
    return session.sql(sql).to_pandas()


def live(sql):
    return session.sql(sql).to_pandas()


def jload(v, default=None):
    """VARIANT / ARRAY / OBJECT columns arrive as JSON text through to_pandas."""
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return default
    if isinstance(v, (dict, list)):
        return v
    try:
        return json.loads(v)
    except Exception:
        return default if default is not None else v


def table(frame, **kw):
    kw.setdefault("use_container_width", True)
    kw.setdefault("hide_index", True)
    st.dataframe(theme.df(frame), **kw)


def sql_in(values):
    return ", ".join("'" + str(v).replace("'", "''") + "'" for v in values)


# =============================================================================
PAGES = ["Setup Wizard", "Estate Overview", "Inventory Explorer", "Usage & Health", "Duplicates",
         "Rationalization", "Wave Plan", "Target Data Model", "Conversion Workbench",
         "Reconciliation", "Migration Copilot"]

theme.sidebar_brand("BI Rationalization & Migration")
if st.session_state.get("page") not in PAGES:
    st.session_state.page = "Estate Overview"
st.session_state.page = st.sidebar.radio("", PAGES, index=PAGES.index(st.session_state.page))
page = st.session_state.page
st.sidebar.toggle("Dark mode", key="dark_mode", value=_dark)

try:
    _asof = q(f"SELECT {DB}.INVENTORY.AS_OF_DATE() AS D").iloc[0]["D"]
    st.sidebar.caption(f"Tool extracts as of **{_asof}**")
except Exception:
    _asof = None
st.sidebar.caption("Ridgeline Health — synthetic estate: Tableau, Power BI, SAP BusinessObjects")


# =============================================================================
def page_estate_overview():
    theme.page_header(
        "Three tools, one model of the estate",
        "What Ridgeline Health has, and what it would cost to move it as-is",
        "Every Tableau workbook, Power BI report and BusinessObjects document is "
        "conformed into one asset model before anything is scored. The hours on the "
        "right are the same estate costed twice: once if every asset is converted, "
        "once after the rule engine and the reviewers have had their say.")

    summ = q(f"SELECT * FROM {DB}.RATIONALIZATION.V_RATIONALIZATION_SUMMARY ORDER BY ASSETS DESC")
    base = q(f"""
        SELECT COUNT(*) AS ASSETS, COUNT(DISTINCT a.PLATFORM) AS PLATFORMS,
               SUM(us.VIEWS_365) AS VIEWS_365,
               ROUND(COUNT_IF(us.VIEWS_365 = 0) / COUNT(*) * 100, 1) AS PCT_ZERO_VIEWS,
               (SELECT COUNT(*) FROM {DB}.CONFORMED.V_DUPLICATE_CLUSTER_SUMMARY) AS CLUSTERS
        FROM {DB}.CONFORMED.ASSET a JOIN {DB}.CONFORMED.USAGE_SUMMARY us ON us.ASSET_ID = a.ASSET_ID""").iloc[0]
    as_is = float(summ["EFFORT_HOURS_IF_MIGRATED_AS_IS"].sum())
    after = float(summ["EFFORT_HOURS"].sum())

    c = st.columns(6)
    c[0].metric("Assets", f"{int(base['ASSETS']):,}")
    c[1].metric("Platforms", int(base["PLATFORMS"]))
    c[2].metric("Views, 12 months", f"{int(base['VIEWS_365']):,}")
    c[3].metric("Zero views in 365 days", f"{base['PCT_ZERO_VIEWS']}%")
    c[4].metric("Duplicate clusters", int(base["CLUSTERS"]))
    c[5].metric("Hours after rationalization", f"{after:,.0f}",
                f"{after - as_is:,.0f} vs {as_is:,.0f} as-is", delta_color="inverse")

    left, right = st.columns([3, 2])
    with left:
        st.markdown("#### Assets by platform and final disposition")
        st.caption("Stacked by the disposition that stands after review; pending "
                   "reviews show the recommendation.")
        pf = q(f"""SELECT PLATFORM, FINAL_DISPOSITION, COUNT(*) AS N
                   FROM {DB}.RATIONALIZATION.V_FINAL_DISPOSITION GROUP BY 1, 2""")
        st.altair_chart(
            alt.Chart(pf).mark_bar().encode(
                x=alt.X("N:Q", title="assets", stack="zero"),
                y=alt.Y("PLATFORM:N", title=None),
                color=alt.Color("FINAL_DISPOSITION:N", title="disposition", sort=DISPOSITIONS),
                tooltip=["PLATFORM", "FINAL_DISPOSITION", "N"],
            ).properties(height=200), use_container_width=True)
    with right:
        st.markdown("#### Effort, two ways")
        st.caption("Conversion hours per asset come from the complexity band in "
                   "SCORING_POLICY and are marked TO CONFIRM until wave 1 calibrates them.")
        eff = pd.DataFrame({"Scenario": ["Migrate everything as-is", "After rationalization"],
                            "Hours": [as_is, after]})
        st.altair_chart(
            alt.Chart(eff).mark_bar(color=BLUE).encode(
                x=alt.X("Hours:Q", title="hours"),
                y=alt.Y("Scenario:N", title=None, sort=None),
                tooltip=["Scenario", "Hours"],
            ).properties(height=200), use_container_width=True)

    st.markdown("#### Rationalization summary")
    st.caption("One row per final disposition: share of the estate, share of the "
               "views, hours, and how many have been through the review gate.")
    table(summ)
    if _asof is not None:
        st.caption(f"All usage windows (30, 90, 365 days) are measured back from the "
                   f"extract date, {_asof}, which INVENTORY.AS_OF_DATE() returns. "
                   "Nothing in this app looks at today's date.")


# =============================================================================
def page_inventory_explorer():
    theme.page_header(
        "The conformed inventory",
        "Every asset, browsable, with what sits underneath it",
        "Filters run over the final disposition view joined to the conformed asset "
        "table. Pick one asset to see its scored profile, the tables it reads, the "
        "fields it computes, its components and its weekly usage.")

    fd = q(f"""SELECT f.ASSET_ID, f.TITLE, f.PLATFORM, f.ASSET_KIND, f.OWNER_DEPARTMENT, f.OWNER_EMAIL,
                      f.SUBJECT_AREA, f.RECOMMENDED_DISPOSITION, f.FINAL_DISPOSITION, f.REVIEW_STATUS,
                      f.RULE_ID, f.COMPLEXITY_BAND, f.VIEWS_90, f.VIEWS_365, f.DAYS_SINCE_LAST_VIEW,
                      f.SUBSCRIPTION_COUNT, a.CONTAINER_PATH, a.IS_CERTIFIED, a.MODIFIED_AT
               FROM {DB}.RATIONALIZATION.V_FINAL_DISPOSITION f
               JOIN {DB}.CONFORMED.ASSET a ON a.ASSET_ID = f.ASSET_ID
               ORDER BY f.VIEWS_365 DESC""")
    fc = st.columns(4)
    plat = fc[0].multiselect("Platform", sorted(fd["PLATFORM"].dropna().unique()))
    dept = fc[1].multiselect("Owner department", sorted(fd["OWNER_DEPARTMENT"].dropna().unique()))
    area = fc[2].multiselect("Subject area", sorted(fd["SUBJECT_AREA"].dropna().unique()))
    disp = fc[3].multiselect("Final disposition", DISPOSITIONS)
    view = fd
    if plat:
        view = view[view["PLATFORM"].isin(plat)]
    if dept:
        view = view[view["OWNER_DEPARTMENT"].isin(dept)]
    if area:
        view = view[view["SUBJECT_AREA"].isin(area)]
    if disp:
        view = view[view["FINAL_DISPOSITION"].isin(disp)]
    st.caption(f"{len(view):,} of {len(fd):,} assets")
    table(view.drop(columns=["OWNER_EMAIL", "CONTAINER_PATH"]), height=320)

    if view.empty:
        return
    labels = (view["TITLE"] + "  ·  " + view["ASSET_ID"]).tolist()
    pick = st.selectbox("Asset", labels)
    aid = pick.rsplit("  ·  ", 1)[1]

    prof = q(f"SELECT * FROM {DB}.RATIONALIZATION.V_ASSET_PROFILE WHERE ASSET_ID = '{aid}'")
    if not prof.empty:
        p = prof.iloc[0]
        st.markdown(f"### {p['TITLE']}")
        pills = [theme.pill(p["PLATFORM"], "info"), theme.pill(p["ASSET_KIND"], "info"),
                 theme.pill(f"BAND {p['COMPLEXITY_BAND']}", "warn" if p["COMPLEXITY_BAND"] in ("L", "XL") else "info")]
        if p["IS_CERTIFIED"]:
            pills.append(theme.pill("CERTIFIED", "good"))
        if p["IS_REGULATORY"]:
            pills.append(theme.pill("REGULATORY", "warn"))
        if p["HAS_DECOMMISSIONED_SOURCE"]:
            pills.append(theme.pill("DECOMMISSIONED SOURCE", "bad"))
        st.markdown(" ".join(pills), unsafe_allow_html=True)
        c = st.columns(6)
        c[0].metric("Usage score", p["USAGE_SCORE"])
        c[1].metric("Criticality", p["CRITICALITY_SCORE"])
        c[2].metric("Complexity points", p["COMPLEXITY_POINTS"])
        c[3].metric("Data health", p["DATA_HEALTH_SCORE"])
        c[4].metric("Views, 90 days", int(p["VIEWS_90"]))
        c[5].metric("Subscribers", int(p["SUBSCRIPTION_COUNT"]))
        st.caption(f"{p['CONTAINER_PATH']}  ·  owner {p['OWNER_EMAIL']} ({p['OWNER_DEPARTMENT']}"
                   f"{'' if p['OWNER_IS_ACTIVE'] else ', no longer active'})  ·  "
                   f"subject area {p['SUBJECT_AREA']}")
        with st.expander("Full profile row"):
            table(prof.T.reset_index().rename(columns={"index": "COLUMN", 0: "VALUE"}).astype(str))

    st.markdown("#### Weekly views")
    wk = q(f"""SELECT DATE_TRUNC('week', USAGE_DATE) AS WEEK, SUM(VIEW_COUNT) AS VIEWS,
                      COUNT(DISTINCT USER_EMAIL) AS VIEWERS
               FROM {DB}.CONFORMED.USAGE_DAILY WHERE ASSET_ID = '{aid}' GROUP BY 1 ORDER BY 1""")
    if wk.empty:
        st.caption("No logged interactive views for this asset in the extract window.")
    else:
        st.altair_chart(
            alt.Chart(wk).mark_area(color=BLUE, opacity=0.6, line=True).encode(
                x=alt.X("WEEK:T", title=None), y=alt.Y("VIEWS:Q", title="views"),
                tooltip=["WEEK:T", "VIEWS", "VIEWERS"],
            ).properties(height=140), use_container_width=True)

    left, right = st.columns(2)
    with left:
        st.markdown("#### Data sources")
        st.caption("Each physical table the asset reads, with its catalog status.")
        table(q(f"""SELECT SOURCE_NAME, CONNECTION_TYPE, SOURCE_DATABASE, SOURCE_SCHEMA, SOURCE_TABLE,
                           SUBJECT_AREA, CONFORMED_ENTITY, HAS_CUSTOM_SQL, HAS_EXTRACT, IS_CERTIFIED,
                           IS_DECOMMISSIONED, IS_UNMANAGED_SOURCE, IS_UNCATALOGED, REFRESH_SCHEDULE
                    FROM {DB}.CONFORMED.ASSET_DATA_SOURCE WHERE ASSET_ID = '{aid}'
                    ORDER BY SOURCE_DATABASE, SOURCE_TABLE"""), height=240)
    with right:
        st.markdown("#### Components")
        st.caption("Sheets, pages or report elements, with what each one plots.")
        comp = q(f"""SELECT NAME, COMPONENT_KIND, VIZ_TYPE, DIMENSIONS, MEASURES, FILTERS, HAS_PARAMETER
                     FROM {DB}.CONFORMED.ASSET_COMPONENT WHERE ASSET_ID = '{aid}' ORDER BY NAME""")
        table(comp.astype(str), height=240)

    st.markdown("#### Fields")
    st.caption("Base fields carry lineage to a source column; calculated fields carry "
               "the expression in the tool's own language and a complexity tag the "
               "conversion step keys on.")
    table(q(f"""SELECT FIELD_NAME, FIELD_KIND, ROLE, COMPLEXITY_TAG, EXPRESSION, EXPRESSION_LANGUAGE,
                       SOURCE_DATABASE, SOURCE_TABLE, SOURCE_COLUMN
                FROM {DB}.CONFORMED.ASSET_FIELD WHERE ASSET_ID = '{aid}'
                ORDER BY FIELD_KIND DESC, FIELD_NAME"""), height=320)


# =============================================================================
def page_usage_health():
    theme.page_header(
        "Usage, and what usage cannot see",
        "Where the views are, how stale the rest is, and the subscription trap",
        "A handful of assets carry most of the reading. That is normal and it is "
        "the argument for rationalization. But a view count is only evidence of "
        "interactive use, and three tables below list the assets it is blind to.")

    par = q(f"""
        WITH r AS (
            SELECT VIEWS_365,
                   ROW_NUMBER() OVER (ORDER BY VIEWS_365 DESC) AS RN,
                   COUNT(*) OVER () AS N,
                   SUM(VIEWS_365) OVER (ORDER BY VIEWS_365 DESC ROWS UNBOUNDED PRECEDING) AS CUM_VIEWS,
                   SUM(VIEWS_365) OVER () AS TOTAL_VIEWS
            FROM {DB}.CONFORMED.USAGE_SUMMARY)
        SELECT ROUND(RN / N * 100, 1) AS PCT_ASSETS, ROUND(CUM_VIEWS / NULLIF(TOTAL_VIEWS, 0) * 100, 1) AS PCT_VIEWS
        FROM r QUALIFY MOD(RN, GREATEST(1, FLOOR(N / 200))) = 0 OR RN = N ORDER BY RN""")
    hist = q(f"""
        SELECT CASE WHEN DAYS_SINCE_LAST_VIEW = 9999 THEN 'never'
                    WHEN DAYS_SINCE_LAST_VIEW <= 30 THEN '0-30'
                    WHEN DAYS_SINCE_LAST_VIEW <= 90 THEN '31-90'
                    WHEN DAYS_SINCE_LAST_VIEW <= 180 THEN '91-180'
                    WHEN DAYS_SINCE_LAST_VIEW <= 365 THEN '181-365'
                    ELSE '>365' END AS BUCKET, COUNT(*) AS ASSETS
        FROM {DB}.CONFORMED.USAGE_SUMMARY GROUP BY 1""")
    order = ["0-30", "31-90", "91-180", "181-365", ">365", "never"]

    p20 = par[par["PCT_ASSETS"] >= 20]["PCT_VIEWS"].min() if not par.empty else None
    c = st.columns(4)
    c[0].metric("Views carried by the top 20% of assets", f"{p20}%" if p20 is not None else "n/a")
    c[1].metric("Not viewed in a year", int(hist[hist["BUCKET"].isin([">365", "never"])]["ASSETS"].sum()))
    c[2].metric("Viewed in the last 30 days", int(hist[hist["BUCKET"] == "0-30"]["ASSETS"].sum()))
    c[3].metric("Never viewed in the extract window", int(hist[hist["BUCKET"] == "never"]["ASSETS"].sum()))

    left, right = st.columns(2)
    with left:
        st.markdown("#### The Pareto")
        st.caption("Cumulative share of 12-month views against cumulative share of "
                   "assets, most-read first.")
        st.altair_chart(
            alt.Chart(par).mark_line(color=BLUE, point=False).encode(
                x=alt.X("PCT_ASSETS:Q", title="% of assets"),
                y=alt.Y("PCT_VIEWS:Q", title="% of views"),
                tooltip=["PCT_ASSETS", "PCT_VIEWS"],
            ).properties(height=260), use_container_width=True)
    with right:
        st.markdown("#### Days since last interactive view")
        st.caption("Staleness buckets across the whole estate.")
        st.altair_chart(
            alt.Chart(hist).mark_bar(color=BLUE).encode(
                x=alt.X("BUCKET:N", title="days", sort=order),
                y=alt.Y("ASSETS:Q", title="assets"),
                tooltip=["BUCKET", "ASSETS"],
            ).properties(height=260), use_container_width=True)

    st.markdown("#### Subscription-delivered, zero interactive views")
    st.caption("The trap. An emailed PDF every Monday logs no view in the tool, so a "
               "usage-only rationalization retires the CFO's most-read document. The "
               "engine routes these to INVESTIGATE (rule R055) instead of RETIRE, and a "
               "person confirms with the recipients.")
    table(q(f"""SELECT a.ASSET_ID, a.TITLE, a.PLATFORM, a.OWNER_DEPARTMENT, d.SUBSCRIPTION_COUNT,
                       d.EXEC_SUBSCRIBER_COUNT, d.INACTIVE_SUBSCRIBER_COUNT, d.DELIVERY_DESTINATION,
                       us.VIEWS_90, us.VIEWS_365, us.DAYS_SINCE_LAST_VIEW
                FROM {DB}.CONFORMED.ASSET a
                JOIN {DB}.CONFORMED.ASSET_DELIVERY d ON d.ASSET_ID = a.ASSET_ID
                JOIN {DB}.CONFORMED.USAGE_SUMMARY us ON us.ASSET_ID = a.ASSET_ID
                WHERE d.SUBSCRIPTION_COUNT > 0 AND us.VIEWS_90 = 0
                ORDER BY d.EXEC_SUBSCRIBER_COUNT DESC, d.SUBSCRIPTION_COUNT DESC"""), height=260)

    left, right = st.columns(2)
    with left:
        st.markdown("#### Reads a decommissioned source")
        st.caption("Whatever these show, it is not current. Retire if unread; rebuild "
                   "on the replacement system if read.")
        table(q(f"""SELECT a.ASSET_ID, a.TITLE, a.PLATFORM, us.VIEWS_90, us.DAYS_SINCE_LAST_VIEW,
                           d.SUBSCRIPTION_COUNT
                    FROM {DB}.CONFORMED.ASSET_COMPLEXITY c
                    JOIN {DB}.CONFORMED.ASSET a ON a.ASSET_ID = c.ASSET_ID
                    JOIN {DB}.CONFORMED.USAGE_SUMMARY us ON us.ASSET_ID = a.ASSET_ID
                    JOIN {DB}.CONFORMED.ASSET_DELIVERY d ON d.ASSET_ID = a.ASSET_ID
                    WHERE c.HAS_DECOMMISSIONED_SOURCE ORDER BY us.VIEWS_90 DESC"""), height=260)
    with right:
        st.markdown("#### Scheduled but unread")
        st.caption("A refresh or schedule keeps running for an asset nobody opened in "
                   "90 days; compute spent on nothing.")
        table(q(f"""SELECT a.ASSET_ID, a.TITLE, a.PLATFORM, d.REFRESH_RUNS_90, d.REFRESH_FAILURES_90,
                           d.LAST_SCHEDULE_STATUS, d.SUBSCRIPTION_COUNT, us.DAYS_SINCE_LAST_VIEW
                    FROM {DB}.CONFORMED.ASSET_DELIVERY d
                    JOIN {DB}.CONFORMED.ASSET a ON a.ASSET_ID = d.ASSET_ID
                    JOIN {DB}.CONFORMED.USAGE_SUMMARY us ON us.ASSET_ID = d.ASSET_ID
                    WHERE d.IS_SCHEDULED AND us.VIEWS_90 = 0
                    ORDER BY d.REFRESH_RUNS_90 DESC"""), height=260)


# =============================================================================
def page_duplicates():
    theme.page_header(
        "Seventeen versions of the census report",
        "Duplicate clusters, found structurally rather than by eye",
        "Two assets join a cluster when they share a normalized title, or sit on the "
        "same conformed entities and compute the same named metrics with a close "
        "title. Each cluster nominates one canonical member: certified first, then "
        "most read, then most recently maintained. Everything else consolidates into it.")

    cl = q(f"""SELECT CLUSTER_ID, CANONICAL_TITLE, CANONICAL_ASSET_ID, CLUSTER_SIZE, PLATFORM_COUNT, PLATFORMS,
                      SUBJECT_AREA, CLUSTER_VIEWS_365, ROUND(CANONICAL_VIEW_SHARE * 100, 1) AS CANONICAL_VIEW_SHARE_PCT,
                      DEAD_MEMBERS
               FROM {DB}.CONFORMED.V_DUPLICATE_CLUSTER_SUMMARY ORDER BY CLUSTER_SIZE DESC, CLUSTER_VIEWS_365 DESC""")
    c = st.columns(4)
    c[0].metric("Clusters", len(cl))
    c[1].metric("Assets in clusters", int(cl["CLUSTER_SIZE"].sum()) if len(cl) else 0)
    c[2].metric("Assets that collapse", int((cl["CLUSTER_SIZE"] - 1).sum()) if len(cl) else 0)
    c[3].metric("Cross-platform clusters", int((cl["PLATFORM_COUNT"] > 1).sum()) if len(cl) else 0)

    st.markdown("#### Clusters")
    st.caption("Largest first. A low canonical view share means the readers are "
               "spread across the copies, which is the strongest case for consolidating.")
    table(cl, height=320)

    if cl.empty:
        return
    labels = (cl["CLUSTER_ID"] + "  ·  " + cl["CANONICAL_TITLE"] + " (" + cl["CLUSTER_SIZE"].astype(str) + ")").tolist()
    pick = st.selectbox("Cluster", labels)
    cid = pick.split("  ·  ", 1)[0]
    mem = q(f"""SELECT c.ASSET_ID, c.TITLE, c.PLATFORM, c.IS_CANONICAL, a.OWNER_DEPARTMENT, a.CONTAINER_PATH,
                       a.IS_CERTIFIED, a.IS_PERSONAL_SPACE, us.VIEWS_365, us.VIEWERS_365, us.DAYS_SINCE_LAST_VIEW,
                       a.MODIFIED_AT::DATE AS MODIFIED
                FROM {DB}.CONFORMED.DUPLICATE_CLUSTER c
                JOIN {DB}.CONFORMED.ASSET a ON a.ASSET_ID = c.ASSET_ID
                JOIN {DB}.CONFORMED.USAGE_SUMMARY us ON us.ASSET_ID = c.ASSET_ID
                WHERE c.CLUSTER_ID = '{cid}' ORDER BY c.IS_CANONICAL DESC, us.VIEWS_365 DESC""")
    st.markdown(f"#### Members of {cid}")
    canon = mem[mem["IS_CANONICAL"]]
    if len(canon):
        st.markdown(theme.pill(f"CANONICAL: {canon.iloc[0]['TITLE']} ({canon.iloc[0]['ASSET_ID']})", "good"),
                    unsafe_allow_html=True)
    st.caption("The canonical is flagged; every other row is a CONSOLIDATE candidate "
               "into it, and its differences become requirements on the canonical.")
    table(mem)


# =============================================================================
def page_rationalization():
    theme.page_header(
        "Rules are rows, and a recommendation is not a decision",
        "The rule engine, its reasons, and the human review gate",
        "The engine walks DISPOSITION_RULE in priority order and assigns each asset "
        "to the first rule it satisfies, so every recommendation is explainable in "
        "one line. A named reviewer then accepts, overrides or defers it. "
        "V_FINAL_DISPOSITION is what the wave plan and the target model read.")

    hits = q(f"SELECT * FROM {DB}.RATIONALIZATION.V_RULE_HITS ORDER BY PRIORITY")
    fd = q(f"""SELECT ASSET_ID, TITLE, PLATFORM, OWNER_DEPARTMENT, SUBJECT_AREA, RULE_ID, RULE_NAME,
                      RECOMMENDED_DISPOSITION, FINAL_DISPOSITION, CONFIDENCE, REVIEW_STATUS, REVIEWER,
                      EFFORT_HOURS, VIEWS_365, DAYS_SINCE_LAST_VIEW, SUBSCRIPTION_COUNT, REASON, REVIEW_NOTE
               FROM {DB}.RATIONALIZATION.V_FINAL_DISPOSITION ORDER BY VIEWS_365 DESC""")
    c = st.columns(5)
    c[0].metric("Assets assigned", len(fd))
    c[1].metric("Rules enabled with hits", int((hits["ASSETS"] > 0).sum()))
    c[2].metric("Reviewed", int((fd["REVIEW_STATUS"] != "PENDING").sum()))
    c[3].metric("Overridden", int((fd["REVIEW_STATUS"] == "OVERRIDE").sum()))
    c[4].metric("Pending review", int((fd["REVIEW_STATUS"] == "PENDING").sum()))

    st.markdown("#### Rules, in the order they fire")
    st.caption("Priority order is the policy. The regulatory rule runs before any "
               "usage rule on purpose, so a once-a-year filing is never retired for "
               "being read once a year.")
    table(hits)

    with st.expander("Scoring policy and re-run"):
        st.caption("Thresholds live in SCORING_POLICY, not in a query. Change a value "
                   "and re-run; the engine does not change. Effort hours are TO CONFIRM "
                   "until wave 1 calibrates them.")
        table(q(f"SELECT POLICY_KEY, POLICY_VALUE, DESCRIPTION, SET_BY, SET_AT FROM {DB}.RATIONALIZATION.SCORING_POLICY ORDER BY POLICY_KEY"))
        ok = st.checkbox("I understand this writes a new rationalization run", key="rr_ok")
        if st.button("Re-run the rule engine", disabled=not ok, key="rr_btn"):
            try:
                msg = live(f"CALL {DB}.RATIONALIZATION.SP_RUN_RATIONALIZATION('Re-run from the workbench')").iloc[0, 0]
                st.success(str(msg))
                q.clear()
            except Exception as e:
                st.error(str(e)[:600])

    st.markdown("#### Dispositions with their reason")
    fc = st.columns(3)
    f_disp = fc[0].multiselect("Final disposition", DISPOSITIONS, key="rat_disp")
    f_rule = fc[1].multiselect("Rule", hits["RULE_ID"].tolist(), key="rat_rule")
    f_rev = fc[2].multiselect("Review status", ["PENDING", "ACCEPT", "OVERRIDE", "DEFER"], key="rat_rev")
    view = fd
    if f_disp:
        view = view[view["FINAL_DISPOSITION"].isin(f_disp)]
    if f_rule:
        view = view[view["RULE_ID"].isin(f_rule)]
    if f_rev:
        view = view[view["REVIEW_STATUS"].isin(f_rev)]
    st.caption(f"{len(view):,} assets. The REASON column is the rule's evidence rendered "
               "into a sentence; it is what goes to the owner.")
    table(view, height=360)

    st.markdown("#### Review gate")
    if view.empty:
        st.caption("No assets match the filters.")
        return
    labels = (view["TITLE"] + "  ·  " + view["ASSET_ID"]).tolist()
    pick = st.selectbox("Asset to review", labels, key="rat_pick")
    aid = pick.rsplit("  ·  ", 1)[1]
    row = q(f"""SELECT * FROM {DB}.RATIONALIZATION.V_FINAL_DISPOSITION WHERE ASSET_ID = '{aid}'""").iloc[0]
    st.markdown(" ".join([
        theme.pill(f"RECOMMENDED {row['RECOMMENDED_DISPOSITION']} · {row['RULE_ID']}", "info"),
        theme.pill(f"FINAL {row['FINAL_DISPOSITION']}", "good" if row["REVIEW_STATUS"] != "PENDING" else "warn"),
        theme.pill(f"{row['CONFIDENCE']} CONFIDENCE", "info"),
        theme.pill(f"REVIEW {row['REVIEW_STATUS']}", "info")]), unsafe_allow_html=True)
    st.info(str(row["REASON"]))
    left, right = st.columns([2, 3])
    with left:
        st.caption("Evidence captured at assignment time.")
        st.json(jload(row["EVIDENCE"], {}))
        if row["CONSOLIDATE_INTO"]:
            st.caption(f"Consolidates into {row['CONSOLIDATE_INTO']}")
        if row["REVIEW_STATUS"] != "PENDING":
            st.caption(f"Last decision by {row['REVIEWER']} on {row['DECIDED_AT']}: {row['REVIEW_NOTE']}")
    with right:
        with st.form("review_form"):
            role = st.text_input("Reviewer role", placeholder="e.g. Director, Decision Support")
            decision = st.selectbox("Decision", ["ACCEPT", "OVERRIDE", "DEFER"])
            final = st.selectbox("Final disposition", DISPOSITIONS,
                                 index=DISPOSITIONS.index(row["RECOMMENDED_DISPOSITION"])
                                 if row["RECOMMENDED_DISPOSITION"] in DISPOSITIONS else 0)
            note = st.text_area("Note to the record", placeholder="What did you confirm, and with whom?")
            if st.form_submit_button("Record decision"):
                if not role.strip() or not note.strip():
                    st.warning("A role and a note are required; the record has to say who decided and why.")
                else:
                    session.sql(
                        f"INSERT INTO {DB}.RATIONALIZATION.DISPOSITION_REVIEW "
                        "(ASSET_ID, REVIEWER_ROLE, DECISION, FINAL_DISPOSITION, NOTE) SELECT ?, ?, ?, ?, ?",
                        params=[aid, role.strip(), decision, final, note.strip()]).collect()
                    q.clear()
                    st.rerun()

    st.markdown("#### Recent reviews")
    st.caption("Every decision with the name on it. The latest decision per asset wins.")
    table(q(f"""SELECT r.REVIEW_ID, r.ASSET_ID, a.TITLE, r.REVIEWER, r.REVIEWER_ROLE, r.DECISION,
                       r.FINAL_DISPOSITION, r.NOTE, r.DECIDED_AT
                FROM {DB}.RATIONALIZATION.DISPOSITION_REVIEW r
                JOIN {DB}.CONFORMED.ASSET a ON a.ASSET_ID = r.ASSET_ID
                ORDER BY r.DECIDED_AT DESC LIMIT 40"""))


# =============================================================================
def page_wave_plan():
    theme.page_header(
        "Waves follow the data model, not the org chart",
        "Foundation first, then subject areas in priority order",
        "Surviving assets are grouped by subject area because that is how the target "
        "model gets built: when FACT_DENIAL and DIM_PAYER exist, every denial report "
        "becomes convertible at once. Wave 0 is the conformed dimensions more than one "
        "subject area depends on.")

    ws = q(f"SELECT * FROM {DB}.RATIONALIZATION.V_WAVE_SUMMARY ORDER BY WAVE_NO")
    wp = q(f"SELECT * FROM {DB}.RATIONALIZATION.WAVE_PLAN ORDER BY WAVE_NO, EFFORT_HOURS DESC")
    c = st.columns(4)
    c[0].metric("Waves after foundation", int(ws["WAVE_NO"].nunique()))
    c[1].metric("Surviving assets", int(ws["ASSETS"].sum()))
    c[2].metric("Effort hours", f"{int(ws['EFFORT_HOURS'].sum()):,}")
    c[3].metric("Subject areas", int(ws["SUBJECT_AREAS"].sum()))

    st.markdown("#### Effort by wave, by disposition")
    st.caption("Waves are cut to roughly equal effort; what differs is who is waiting.")
    long = ws[["WAVE_NO", "MIGRATE_ASSETS", "REBUILD_ASSETS", "SELF_SERVICE_ASSETS"]].melt(
        "WAVE_NO", var_name="DISPOSITION", value_name="N_ASSETS")
    long["DISPOSITION"] = long["DISPOSITION"].str.replace("_ASSETS", "")
    left, right = st.columns(2)
    with left:
        st.altair_chart(
            alt.Chart(long).mark_bar().encode(
                x=alt.X("WAVE_NO:O", title="wave"), y=alt.Y("N_ASSETS:Q", title="assets"),
                color=alt.Color("DISPOSITION:N", title=None), tooltip=["WAVE_NO", "DISPOSITION", "N_ASSETS"],
            ).properties(height=240), use_container_width=True)
    with right:
        st.altair_chart(
            alt.Chart(ws).mark_bar(color=BLUE).encode(
                x=alt.X("WAVE_NO:O", title="wave"), y=alt.Y("EFFORT_HOURS:Q", title="hours"),
                tooltip=["WAVE_NO", "EFFORT_HOURS", "AREAS"],
            ).properties(height=240), use_container_width=True)

    st.markdown("#### The wave plan")
    st.caption("One row per subject area per wave, with the entities it needs in the target.")
    table(wp.astype({"REQUIRED_ENTITIES": str}))

    st.markdown("#### Subject area priority")
    st.caption("Readers and executives first; regulatory deadlines pull forward. The "
               "score is the argument; the rank is the schedule.")
    table(q(f"SELECT * FROM {DB}.RATIONALIZATION.SUBJECT_AREA_PRIORITY ORDER BY PRIORITY_RANK"))


# =============================================================================
def page_target_model():
    theme.page_header(
        "Derived, not drawn",
        "The target model the surviving reports actually need",
        "Every entity here is in the backlog because a surviving asset reads it; "
        "every attribute because one uses it; every metric because one computes it. "
        "A retired report does not get to put an attribute into the target model.")

    s = q(f"SELECT * FROM {DB}.TARGET_MODEL.V_TARGET_MODEL_SUMMARY").iloc[0]
    c = st.columns(6)
    c[0].metric("Entities", int(s["ENTITIES"]), f"{int(s['FACTS'])} facts, {int(s['DIMENSIONS'])} dims", delta_color="off")
    c[1].metric("Shared entities", int(s["SHARED_ENTITIES"]))
    c[2].metric("Attributes", int(s["ATTRIBUTES"]))
    c[3].metric("Entities needing a source", int(s["ENTITIES_NEEDING_A_SOURCE"]))
    c[4].metric("Metrics", int(s["METRICS"]), f"{int(s['CONFLICTING_METRICS'])} conflicting", delta_color="inverse")
    c[5].metric("Certified definitions", int(s["CERTIFIED_METRICS"]))

    st.markdown("#### Build backlog")
    st.caption("In build order: foundation first, shared entities before private ones, "
               "then by how many assets each unblocks. Build hours are indicative and "
               "TO CONFIRM against the data team's velocity.")
    bl = q(f"""SELECT BUILD_ORDER, WAVE_NO, ENTITY_NAME, ENTITY_ROLE, SUBJECT_AREA, IS_SHARED, ASSETS_UNBLOCKED,
                      EXEC_ASSETS, REGULATORY_ASSETS, ATTRIBUTES, METRICS, CONFLICTING_METRICS, SOURCE_TABLES,
                      SOURCE_STATUS, BUILD_HOURS_INDICATIVE, GRAIN
               FROM {DB}.TARGET_MODEL.V_BUILD_BACKLOG ORDER BY BUILD_ORDER""")
    table(bl, height=320)

    ent = st.selectbox("Entity", bl["ENTITY_NAME"].tolist())
    left, right = st.columns(2)
    with left:
        st.markdown("#### Attributes")
        table(q(f"""SELECT ATTRIBUTE_NAME, ATTRIBUTE_CLASS, REFERENCING_ASSETS, SURVIVING_ASSETS, HAS_LIVE_SOURCE,
                           FIRST_WAVE_NEEDED, SOURCE_COLUMNS
                    FROM {DB}.TARGET_MODEL.ENTITY_ATTRIBUTE WHERE ENTITY_NAME = '{ent}'
                    ORDER BY ATTRIBUTE_CLASS = 'KEY' DESC, REFERENCING_ASSETS DESC""").astype({"SOURCE_COLUMNS": str}),
              height=300)
    with right:
        st.markdown("#### Source to target")
        st.caption("A mapping that lands on a decommissioned table or a spreadsheet "
                   "is a decision, not a mapping, and it says so.")
        table(q(f"""SELECT ATTRIBUTE_NAME, TARGET_TYPE, SOURCE_COLUMN, SYSTEM_FAMILY, MAPPING_STATUS, REFERENCING_ASSETS
                    FROM {DB}.TARGET_MODEL.V_SOURCE_TO_TARGET_MAP WHERE ENTITY_NAME = '{ent}'
                    ORDER BY MAPPING_STATUS <> 'MAPPED' DESC, REFERENCING_ASSETS DESC"""), height=300)

    st.markdown("#### Generated artifacts")
    st.caption("The data team receives files, not a diagram. All three regenerate from "
               "the derived model; nothing is hand-maintained.")
    art = q(f"""SELECT ARTIFACT_KIND, FILE_NAME, CONTENT FROM {DB}.TARGET_MODEL.GENERATED_ARTIFACT
                WHERE ENTITY_NAME = '{ent}'""")
    tabs = st.tabs(["DDL", "dbt model", "dbt schema.yml"])
    for tab, kind, lang in zip(tabs, ["DDL", "DBT_MODEL", "DBT_SCHEMA"], ["sql", "sql", "yaml"]):
        with tab:
            a = art[art["ARTIFACT_KIND"] == kind]
            if a.empty:
                st.caption("Not generated for this entity.")
            else:
                st.code(a.iloc[0]["CONTENT"], language=lang)
                st.download_button(f"Download {a.iloc[0]['FILE_NAME']}", a.iloc[0]["CONTENT"],
                                   file_name=a.iloc[0]["FILE_NAME"], key=f"dl_{kind}_{ent}")

    st.markdown("#### Metric conflicts")
    st.caption("One business term, several formulas. Claude, via Cortex, proposes one "
               "canonical definition and sorts the variants into equivalent and "
               "divergent. The proposal stays PROPOSED until a named person certifies it.")
    mr = q(f"""SELECT METRIC_ID, METRIC_NAME, PRIMARY_ENTITY, DEFINITION_STATUS, VARIANT_COUNT, LANGUAGES,
                      ASSET_COUNT, VIEWS_365, DOMINANT_SHARE_PCT, RESOLUTION_STATUS, EQUIVALENT_COUNT, DIVERGENT_COUNT,
                      CERTIFIED_BY
               FROM {DB}.TARGET_MODEL.V_METRIC_RECONCILIATION
               ORDER BY DEFINITION_STATUS = 'CONFLICTING' DESC, VARIANT_COUNT DESC""")
    table(mr, height=280)
    mpick = st.selectbox("Metric", (mr["METRIC_ID"] + "  ·  " + mr["METRIC_NAME"]).tolist())
    mid = mpick.split("  ·  ", 1)[0]
    m = q(f"SELECT * FROM {DB}.TARGET_MODEL.V_METRIC_RECONCILIATION WHERE METRIC_ID = '{mid}'").iloc[0]

    st.markdown(f"##### {m['METRIC_NAME']}  ·  {m['DEFINITION_STATUS']}")
    st.caption("Every variant found in surviving assets, most used first.")
    table(q(f"""SELECT v.EXPRESSION_LANGUAGE, v.EXPRESSION, v.COMPLEXITY_TAG, v.ASSET_COUNT, v.VIEWS_365, v.FIELD_NAME
                FROM {DB}.TARGET_MODEL.METRIC_VARIANT v
                JOIN {DB}.TARGET_MODEL.METRIC m ON m.FIELD_NAME_KEY = v.FIELD_NAME_KEY
                WHERE m.METRIC_ID = '{mid}' ORDER BY v.ASSET_COUNT DESC"""))

    if m["RESOLUTION_STATUS"] is None or pd.isna(m["RESOLUTION_STATUS"]):
        st.warning("No proposal yet for this metric. TARGET_MODEL.SP_PROPOSE_METRIC_DEFINITIONS() "
                   "writes one, with STATUS = PROPOSED.")
        return
    status = m["RESOLUTION_STATUS"]
    st.markdown(" ".join([
        theme.pill(status, "good" if status == "CERTIFIED" else "warn"),
        theme.pill(f"PROPOSED BY {m['PROPOSED_BY']} · {m['MODEL_USED']}", "info")]), unsafe_allow_html=True)
    st.markdown(f"**Canonical name** — {m['CANONICAL_NAME']}")
    st.code(m["DEFINITION_SQL"] or "", language="sql")
    st.markdown(f"**Definition** — {m['DEFINITION_TEXT']}")
    dv = jload(m["DIVERGENT_VARIANTS"], [])
    if dv:
        st.markdown("**Divergent variants — each needs a decision**")
        table(pd.DataFrame(dv))
    else:
        st.caption("The model judged every variant equivalent to the canonical.")
    st.markdown(f"**Rationale** — {m['RATIONALE']}")
    if status == "CERTIFIED":
        st.success(f"Certified by {m['CERTIFIED_BY']}.")
    else:
        st.caption("This proposal was produced by a model. It becomes the definition "
                   "only when a named owner certifies it here.")
        with st.form("certify_form"):
            who = st.text_input("Certifier name and role", placeholder="e.g. Casey Lindqvist, Manager, Revenue Cycle Analytics")
            if st.form_submit_button("Certify this definition"):
                if not who.strip():
                    st.warning("A name is required.")
                else:
                    session.sql(
                        f"UPDATE {DB}.TARGET_MODEL.METRIC_RESOLUTION SET STATUS = 'CERTIFIED', CERTIFIED_BY = ?, "
                        "CERTIFIED_AT = CURRENT_TIMESTAMP() WHERE METRIC_ID = ? AND RESOLUTION_ID = "
                        f"(SELECT MAX(RESOLUTION_ID) FROM {DB}.TARGET_MODEL.METRIC_RESOLUTION WHERE METRIC_ID = ?)",
                        params=[who.strip(), mid, mid]).collect()
                    q.clear()
                    st.rerun()


# =============================================================================
def page_conversion():
    theme.page_header(
        "Rules first, the model for the residue, a person for the rest",
        "Calculated fields translated to Sigma, and reviewed one at a time",
        "A rule catalog handles the mechanical part of Tableau, DAX and BusinessObjects "
        "formulas. What the rules cannot finish goes to Claude with a restricted "
        "function list and a confidence. A human edit beats the model; the model beats "
        "the rules. Nothing is final until REVIEW_DECISION is set.")

    cs = q(f"SELECT * FROM {DB}.CONVERSION.V_CONVERSION_SUMMARY")
    rs = q(f"SELECT * FROM {DB}.CONVERSION.V_READINESS_SUMMARY ORDER BY WAVE_NO, CONVERSION_STATUS")
    tot = int(cs["FIELDS"].sum()) if len(cs) else 0
    c = st.columns(5)
    c[0].metric("Calculated fields", tot)
    c[1].metric("AUTO", int(cs[cs["STATUS"] == "AUTO"]["FIELDS"].sum()))
    c[2].metric("NEEDS_REVIEW", int(cs[cs["STATUS"] == "NEEDS_REVIEW"]["FIELDS"].sum()))
    c[3].metric("NEEDS_HUMAN", int(cs[cs["STATUS"] == "NEEDS_HUMAN"]["FIELDS"].sum()))
    c[4].metric("Model-assisted", int(cs["AI_ASSISTED"].sum()))

    left, right = st.columns(2)
    with left:
        st.markdown("#### Fields by source language and status")
        st.altair_chart(
            alt.Chart(cs).mark_bar().encode(
                x=alt.X("FIELDS:Q", title="fields"), y=alt.Y("SOURCE_LANGUAGE:N", title=None),
                color=alt.Color("STATUS:N", title=None, sort=["AUTO", "NEEDS_REVIEW", "NEEDS_HUMAN"]),
                tooltip=["SOURCE_LANGUAGE", "STATUS", "FIELDS", "AVG_CONFIDENCE", "AI_ASSISTED", "REVIEWED"],
            ).properties(height=200), use_container_width=True)
    with right:
        st.markdown("#### Readiness by wave")
        st.caption("READY: no field waiting on a person. BLOCKED: at least one field the "
                   "rules and the model both declined to finish.")
        table(rs, height=200)

    with st.expander("Rule catalog"):
        table(q(f"SELECT * FROM {DB}.CONVERSION.V_RULE_USAGE"))
    with st.expander("Unresolved tokens"):
        st.caption("Constructs no rule matched, by frequency; the next rule to write is at the top.")
        table(q(f"SELECT * FROM {DB}.CONVERSION.V_UNRESOLVED_TOKENS LIMIT 100"))
    with st.expander("Run the residual pass"):
        st.caption("Sends up to 50 NEEDS_REVIEW / NEEDS_HUMAN fields with no model answer yet "
                   "to the translation model configured in GOVERNANCE.AI_CONFIG. It writes "
                   "AI_* columns and a status; it never writes FINAL_EXPRESSION.")
        ok = st.checkbox("I understand this calls Cortex and updates FIELD_CONVERSION", key="ai_ok")
        if st.button("Run residual pass (50)", disabled=not ok, key="ai_btn"):
            try:
                st.success(str(live(f"CALL {DB}.CONVERSION.SP_AI_TRANSLATE(50)").iloc[0, 0]))
                q.clear()
            except Exception as e:
                st.error(str(e)[:600])

    st.markdown("#### Asset")
    ar = q(f"""SELECT ASSET_ID, TITLE, PLATFORM, FINAL_DISPOSITION, SUBJECT_AREA, WAVE_NO, COMPLEXITY_BAND,
                      CALC_FIELDS, AUTO_FIELDS, REVIEW_FIELDS, HUMAN_FIELDS, AI_ASSISTED_FIELDS, AUTO_PCT,
                      ENTITIES_WITHOUT_SOURCE, CONVERSION_STATUS
               FROM {DB}.CONVERSION.V_ASSET_CONVERSION_READINESS
               ORDER BY WAVE_NO, CONVERSION_STATUS, CALC_FIELDS DESC""")
    table(ar, height=240)
    if ar.empty:
        return
    pick = st.selectbox("Asset to convert", (ar["TITLE"] + "  ·  " + ar["ASSET_ID"]).tolist(), key="cv_pick")
    aid = pick.rsplit("  ·  ", 1)[1]

    fields = q(f"""SELECT FIELD_ID, FIELD_NAME, COMPLEXITY_TAG, SOURCE_LANGUAGE, SOURCE_EXPRESSION, EFFECTIVE_EXPRESSION,
                          STATUS, CONFIDENCE, EFFECTIVE_SOURCE, METHOD, APPLIED_RULES, UNRESOLVED_TOKENS, NOTES,
                          AI_FORMULA, AI_CONFIDENCE, AI_RATIONALE, AI_REQUIRES_HUMAN, MODEL_USED,
                          REVIEWED_BY, REVIEW_DECISION, FINAL_EXPRESSION
                   FROM {DB}.CONVERSION.V_FIELD_CONVERSION WHERE ASSET_ID = '{aid}'
                   ORDER BY CASE STATUS WHEN 'NEEDS_HUMAN' THEN 0 WHEN 'NEEDS_REVIEW' THEN 1 ELSE 2 END, FIELD_NAME""")
    st.markdown("#### Calculated fields")
    st.caption("EFFECTIVE_EXPRESSION is what the workbook spec will carry: the human "
               "edit if there is one, else the model's formula if it beat the rules, else the rules.")
    table(fields[["FIELD_NAME", "COMPLEXITY_TAG", "SOURCE_EXPRESSION", "EFFECTIVE_EXPRESSION", "STATUS",
                  "CONFIDENCE", "EFFECTIVE_SOURCE", "APPLIED_RULES", "UNRESOLVED_TOKENS", "NOTES",
                  "AI_RATIONALE", "REVIEW_DECISION", "REVIEWED_BY"]].astype(
        {"APPLIED_RULES": str, "UNRESOLVED_TOKENS": str}), height=300)

    if not fields.empty:
        st.markdown("#### Review a field")
        fpick = st.selectbox("Field", (fields["FIELD_NAME"] + "  ·  " + fields["STATUS"] + "  ·  " + fields["FIELD_ID"]).tolist(),
                             key="cv_field")
        fid = fpick.rsplit("  ·  ", 1)[1]
        f = fields[fields["FIELD_ID"] == fid].iloc[0]
        left, right = st.columns(2)
        with left:
            st.caption(f"Source ({f['SOURCE_LANGUAGE']}, {f['COMPLEXITY_TAG']})")
            st.code(f["SOURCE_EXPRESSION"] or "", language="text")
            if f["NOTES"]:
                st.caption(f"Rules: {f['NOTES']}")
        with right:
            st.caption(f"Sigma, from {f['EFFECTIVE_SOURCE']} (status {f['STATUS']}, confidence {f['CONFIDENCE']})")
            st.code(f["EFFECTIVE_EXPRESSION"] or "", language="text")
            if f["AI_RATIONALE"]:
                st.caption(f"Model ({f['MODEL_USED']}, confidence {f['AI_CONFIDENCE']}): {f['AI_RATIONALE']}")
        with st.form("field_review"):
            who = st.text_input("Reviewer", placeholder="name or email")
            dec = st.selectbox("Decision", ["ACCEPT", "EDIT", "REJECT"])
            edited = st.text_area("Final Sigma expression (used when the decision is EDIT)",
                                  value=f["EFFECTIVE_EXPRESSION"] or "")
            if st.form_submit_button("Record review"):
                if not who.strip():
                    st.warning("A reviewer name is required.")
                else:
                    final = edited.strip() if dec == "EDIT" else (f["EFFECTIVE_EXPRESSION"] if dec == "ACCEPT" else None)
                    session.sql(
                        f"UPDATE {DB}.CONVERSION.FIELD_CONVERSION SET REVIEWED_BY = ?, REVIEW_DECISION = ?, "
                        "FINAL_EXPRESSION = ? WHERE FIELD_ID = ?",
                        params=[who.strip(), dec, final, fid]).collect()
                    q.clear()
                    st.rerun()

    st.markdown("#### Sigma workbook spec")
    st.caption("Pages, elements, certified datasets, every formula with its status, the "
               "controls, and the decisions still open. The spec is the handoff to the "
               "Sigma build, and its readiness block is the gate.")
    spec = q(f"SELECT SPEC FROM {DB}.CONVERSION.WORKBOOK_SPEC WHERE ASSET_ID = '{aid}'")
    if spec.empty:
        st.caption("No spec generated for this asset.")
    else:
        obj = jload(spec.iloc[0]["SPEC"], {})
        st.json(obj, expanded=False)
        st.download_button("Download workbook spec (.json)", json.dumps(obj, indent=2),
                           file_name=f"{aid}_sigma_spec.json", key=f"dl_spec_{aid}")


# =============================================================================
def page_reconciliation():
    theme.page_header(
        "Does the converted number match?",
        "The reconciliation harness against the target mart, and acceptance",
        "Each test evaluates the certified definition in the target and compares it "
        "to the source report's snapshot for the same period, within a materiality "
        "threshold set per metric. A report that used a variant definition is "
        "expected to differ, and the harness says so rather than calling it a failure.")

    ts = q(f"SELECT * FROM {DB}.CONVERSION.V_TEST_SUMMARY")
    tr = q(f"""SELECT TEST_ID, ASSET_ID, TITLE, PLATFORM, METRIC_LABEL, PERIOD_LABEL, SOURCE_LANGUAGE, OUTCOME,
                      TARGET_VALUE, SOURCE_VALUE, VARIANCE_PCT, MATERIALITY_PCT, USES_CERTIFIED_DEFINITION,
                      SOURCE_EXPRESSION, SNAPSHOT_NOTE, RUN_ID, RAN_AT
               FROM {DB}.CONVERSION.V_TEST_RESULT ORDER BY OUTCOME, VARIANCE_PCT DESC""")
    c = st.columns(5)
    c[0].metric("Tests in latest run", len(tr))
    c[1].metric("Passed", int((tr["OUTCOME"] == "PASS").sum()))
    c[2].metric("Failed", int((tr["OUTCOME"] == "FAIL").sum()))
    c[3].metric("Definition variance", int((tr["OUTCOME"] == "DEFINITION_VARIANCE").sum()))
    c[4].metric("Errors", int((tr["OUTCOME"] == "ERROR").sum()))

    left, right = st.columns([2, 3])
    with left:
        st.markdown("#### Outcomes")
        oc = tr.groupby("OUTCOME").size().reset_index(name="TESTS")
        st.altair_chart(
            alt.Chart(oc).mark_bar(color=BLUE).encode(
                x=alt.X("TESTS:Q", title="tests"),
                y=alt.Y("OUTCOME:N", title=None, sort=["PASS", "FAIL", "DEFINITION_VARIANCE", "ERROR"]),
                tooltip=["OUTCOME", "TESTS"],
            ).properties(height=200), use_container_width=True)
    with right:
        st.markdown("#### By metric")
        table(ts, height=200)

    st.caption("DEFINITION_VARIANCE means the source report computed the metric with a "
               "variant definition, so its number was never going to match the certified "
               "one. That is not a conversion defect; it is a decision for the metric's "
               "OWNER about which number is right, and it is recorded on the metric, not "
               "patched into the report.")

    fc = st.columns(3)
    f_out = fc[0].multiselect("Outcome", ["PASS", "FAIL", "DEFINITION_VARIANCE", "ERROR"])
    f_met = fc[1].multiselect("Metric", sorted(tr["METRIC_LABEL"].dropna().unique()))
    f_plat = fc[2].multiselect("Platform", sorted(tr["PLATFORM"].dropna().unique()))
    view = tr
    if f_out:
        view = view[view["OUTCOME"].isin(f_out)]
    if f_met:
        view = view[view["METRIC_LABEL"].isin(f_met)]
    if f_plat:
        view = view[view["PLATFORM"].isin(f_plat)]
    st.caption(f"{len(view):,} tests")
    table(view, height=320)

    with st.expander("Run reconciliation"):
        st.caption("Evaluates each certified definition once in the target mart and "
                   "scores every test case against its snapshot; writes a new run.")
        ok = st.checkbox("I understand this writes a new TEST_RESULT run", key="rc_ok")
        if st.button("Run reconciliation (400)", disabled=not ok, key="rc_btn"):
            try:
                st.success(str(live(f"CALL {DB}.CONVERSION.SP_RUN_RECONCILIATION(400)").iloc[0, 0]))
                q.clear()
            except Exception as e:
                st.error(str(e)[:600])

    st.markdown("#### Acceptance sign-off")
    st.caption("Acceptance is per asset and has a name on it. The copilot can draft the "
               "note; it cannot sign.")
    assets = tr[["ASSET_ID", "TITLE"]].drop_duplicates().sort_values("TITLE")
    if assets.empty:
        return
    left, right = st.columns([3, 2])
    with left:
        with st.form("signoff_form"):
            apick = st.selectbox("Asset", (assets["TITLE"] + "  ·  " + assets["ASSET_ID"]).tolist())
            role = st.text_input("Signer role", placeholder="e.g. Manager, Revenue Cycle Analytics")
            dec = st.selectbox("Decision", ["ACCEPT", "REJECT"])
            note = st.text_area("Note", placeholder="What was compared, and what remains open?")
            if st.form_submit_button("Record sign-off"):
                if not role.strip():
                    st.warning("A signer role is required.")
                else:
                    session.sql(
                        f"INSERT INTO {DB}.CONVERSION.ACCEPTANCE_SIGNOFF (ASSET_ID, SIGNER_ROLE, DECISION, NOTE) "
                        "SELECT ?, ?, ?, ?",
                        params=[apick.rsplit("  ·  ", 1)[1], role.strip(), dec, note.strip() or None]).collect()
                    q.clear()
                    st.rerun()
    with right:
        st.markdown("##### Recent sign-offs")
        table(q(f"""SELECT s.SIGNOFF_ID, a.TITLE, s.SIGNED_BY, s.SIGNER_ROLE, s.DECISION, s.NOTE, s.SIGNED_AT
                    FROM {DB}.CONVERSION.ACCEPTANCE_SIGNOFF s
                    JOIN {DB}.CONFORMED.ASSET a ON a.ASSET_ID = s.ASSET_ID
                    ORDER BY s.SIGNED_AT DESC LIMIT 20"""))


# =============================================================================
def page_copilot():
    # Same five tools, semantic views and posture as the stored agent
    # SNOWFLAKE_INTELLIGENCE.AGENTS.BI_MIGRATION_COPILOT (sql/09_agent/01_agent.sql).
    # Stage skills load only in CoWork and the Cortex Code CLI, not in inline agent:run.
    copilot.render(session, {
        "db": DB,
        "warehouse": WH,
        "model": "auto",
        "origin": "bi_modernization_migration_copilot",
        "analyst_tool": "estate_analyst",
        "agent_object": "SNOWFLAKE_INTELLIGENCE.AGENTS.BI_MIGRATION_COPILOT",
        "eyebrow": "Governed agent · Cortex Agents",
        "title": "Migration Copilot",
        "blurb":
            "Guided, not just chat: every number rests on a certified definition and "
            "names its <b>KPI id</b>. <b>Cortex Analyst</b> over two semantic views "
            "(the Program Office's estate view and Migration Engineering's delivery "
            "view, each with steward-verified questions), <b>Cortex Search</b> over the "
            "<b>definitions plane</b>, this estate's own record — every disposition with "
            "its rule and evidence, cluster, metric variant, entity, conversion packet "
            "and test — and the <b>migration reference</b>. It will not retire, "
            "consolidate or sign off anything, will not certify a metric definition, "
            "will not cite usage as proof of disuse without naming the blind spots, will "
            "not present a generated Sigma formula as final, and will not call an effort "
            "estimate a saving. The four skills run in CoWork and the Cortex Code CLI.",
        "placeholder": "Ask why an asset got its disposition, which entities to build first, what a KPI means...",
        "spinner": "Reasoning across the semantic views, the definitions, the estate record and the reference...",
        "starters": [
            "What is the estimated effort avoided by rationalization compared to migrating everything as-is, by platform?",
            "Which reports are delivered by subscription but never opened, and which departments own them?",
            "Which target entities should the data team build first, and how many reports does each unblock?",
            "Which metrics have conflicting definitions across the estate, how many of their variants did the proposer judge divergent, and did it judge every variant exactly once?",
            "Why is Provider wRVU Productivity (FINAL) marked INVESTIGATE when it is emailed to 40 people every week?",
            "What does survival rate mean, and why did its definition change?",
            "We are leaving MedeAnalytics. Why are its reports mostly REBUILD, and what is the sequence to get Denial Rate onto the new model?",
        ],
        "tools": [
            {"tool_spec": {"type": "cortex_analyst_text_to_sql", "name": "estate_analyst",
                           "description": "The BI estate for the Program Office: one row per asset "
                           "with platform, department, subject area, recommended and final "
                           "disposition, rule id and priority, review status, views and "
                           "subscriptions, scores, effort hours and wave; plus one row per "
                           "duplicate cluster with its canonical. Certified KPIs 001-009; "
                           "methods MTH-01, MTH-02."}},
            {"tool_spec": {"type": "cortex_analyst_text_to_sql", "name": "delivery_analyst",
                           "description": "Migration delivery for Migration Engineering: target "
                           "entities with build order, wave and assets unblocked; business "
                           "metrics with variant, equivalent and divergent counts; source "
                           "columns by mapping status; calculated fields by language, construct, "
                           "status and wave; readiness by wave; reconciliation tests by metric "
                           "and outcome. Certified KPIs 010-018; methods MTH-03, MTH-04, MTH-05."}},
            {"tool_spec": {"type": "cortex_search", "name": "definitions",
                           "description": "The trusted-definitions plane: KPI definitions, codified "
                           "methods, certified questions with their SQL, and the change log. "
                           "Search by id (KPI-003, MTH-01, Q-PO-03, CHG-0001) or by term."}},
            {"tool_spec": {"type": "cortex_search", "name": "estate_record",
                           "description": "This estate's own record: every asset with its "
                           "disposition, rule id, reason, evidence and any reviewer decision; "
                           "duplicate clusters with canonical members; metric definitions with "
                           "all variants and the PROPOSED resolution; target entities; rules, "
                           "policy, waves, obligations; conversion packets; reconciliation tests. "
                           "Search by title or id (DUP-0006, MET-98F2B4, R055, TC-0106)."}},
            {"tool_spec": {"type": "cortex_search", "name": "migration_reference",
                           "description": "The migration method that ships with the accelerator "
                           "(REF-01 to REF-25): why usage lies, dispositions and review, "
                           "duplicates, effort, wave planning, target model, metric "
                           "reconciliation, Tableau/DAX/BusinessObjects/MedeAnalytics to Sigma "
                           "guides, reconciliation and acceptance, owner notification."}},
        ],
        "tool_resources": {
            "estate_analyst": {
                "semantic_view": f"{DB}.AI.SV_BI_ESTATE",
                "execution_environment": {"type": "warehouse", "warehouse": WH, "query_timeout": 120}},
            "delivery_analyst": {
                "semantic_view": f"{DB}.AI.SV_MIGRATION_DELIVERY",
                "execution_environment": {"type": "warehouse", "warehouse": WH, "query_timeout": 120}},
            "definitions": {"search_service": f"{DB}.AI.DEFINITION_SEARCH",
                            "id_column": "DOC_ID", "title_column": "TITLE", "max_results": 6},
            "estate_record": {"search_service": f"{DB}.AI.ESTATE_RECORD_SEARCH",
                              "id_column": "DOC_ID", "title_column": "TITLE", "max_results": 8},
            "migration_reference": {"search_service": f"{DB}.AI.MIGRATION_REFERENCE_SEARCH",
                                    "id_column": "DOC_ID", "title_column": "TITLE", "max_results": 5},
        },
        "instructions": {
            "response": COPILOT_RESPONSE,
            "orchestration": COPILOT_ORCHESTRATION,
        },
    })


# The stored agent's instructions, verbatim (keep in step with sql/09_agent/01_agent.sql).
COPILOT_RESPONSE = """You help two teams run a BI rationalization and migration to Sigma on
Snowflake for Ridgeline Health without writing SQL: the BI Program Office
(what is in the Tableau, Power BI, SAP BusinessObjects and MedeAnalytics
estate, what each asset's disposition is and which rule set it, what the
usage can and cannot see, duplicate clusters, effort, waves, owner reviews)
and Migration Engineering (the data team, analytics engineers and metric
owners: which target entities to build first, conflicting metric
definitions, source columns needing a decision, calculated-field
conversion, readiness and reconciliation tests).

Every number you give rests on a certified definition. Name the KPI id and,
where a method applies, the method id — for example "survival rate
(KPI-003) under the rule engine MTH-01". If somebody uses a term the
definitions plane does not certify, say so and offer the nearest certified
KPI rather than inventing one. Say which source you used: "the record says"
for this estate's decisions (estate_record), "the method is" for the
reference (migration_reference).

SIX THINGS YOU DO NOT DO.

You do not retire, consolidate, migrate or sign off anything. A disposition
is a recommendation until a named reviewer accepts or overrides it. You can
explain the recommendation, quote the rule id and the evidence, and draft
the note that goes to the owner. You cannot record the decision. You are
advisory.

You do not certify a metric definition. You can show the variants, say
which the proposer judged equivalent and which divergent, and show the
canonical SQL labeled PROPOSED. Certification is a named owner's act
(KPI-012); zero metrics are certified today.

You do not present usage as proof of disuse without naming the blind
spots. When you cite view counts to explain a RETIRE or a low-usage
finding, say in the same sentence whether the asset has subscriptions,
scheduled delivery or embedded consumption, because those are ways a report
is read without a view being logged (KPI-002). Rule R055 (KPI-005) exists
for this reason; cite it when relevant.

You do not present a generated Sigma formula as final. A formula from the
rules or the model carries a status (AUTO, NEEDS_REVIEW, NEEDS_HUMAN) and a
confidence; quote both. When the construct has no one-line Sigma
equivalent (LOD, filter context, time intelligence, calculation contexts,
vendor-defined measures), name the modeling pattern that replaces it
rather than forcing a formula.

You do not call an effort estimate a saving. Effort hours (KPI-007,
KPI-008) and the effort reduction (KPI-009) are DRAFT band-rate estimates,
TO CONFIRM on the first wave: say "estimated effort" and "a reduction in
estimated effort", never "hours saved", "cost saved" or a dollar figure.
A reconciliation variance is a finding, not a conclusion about who built
the report.

You do not single out people. Owners and reviewers appear in the record
by department and role for routing; do not rank, blame or characterize an
individual author, and answer at department level when asked "whose
reports are worst".

Numbers. Never add up, average, subtract, or derive a share, ratio or
difference in your head: no "together about", no "the other N", no "roughly
2x". Quote only numbers that appear in a result; if the number you need is not
there, run a query for it. In this workbench a column named GRAND_TOTAL_...
(for example GRAND_TOTAL_ASSET_COUNT, GRAND_TOTAL_VIEWS_365,
GRAND_TOTAL_PASS_RATE) that comes back from a verified query is a total over
ALL rows, repeated on every row: use it only for the overall figure, never as
a row's own value. A column named GROUP_TOTAL_... is the total for that row's
group (its wave, disposition or mapping code), repeated on every row of the
group. A row's own value is in its metric column; note that the metrics
TOTAL_VIEWS_365, TOTAL_VIEWS_90, TOTAL_EFFORT_HOURS and TOTAL_SUBSCRIPTIONS
are per-row values despite their names (the verified questions return them as
VIEWS_365, VIEWS_90, EFFORT_HOURS_FINAL_DISPOSITION and SUBSCRIPTIONS), and
only GRAND_TOTAL_ marks a grand total. Quote each value under the name of the
column it came from: views only from a views column, hours only from an hours
column. Read each row's values from that row; name the items rather than
counting them yourself (the number of rows is not a figure: use a GRAND_TOTAL_
count or none). Call a row highest, lowest, most, fewest or second, or say
that every, all or none of the rows do something, only after checking that
column on every row; when the result is not sorted by that column, list the
values instead of ranking them, or run the query again ordered by it. Do not
restate a comparison the table does not show. When a result carries a
RANK_BY_... column (1 = highest), take highest, lowest and second from that
column; when it carries a per-row label or a count of rows with a property
(for example LARGEST_OUTCOME and METRICS_WHERE_DEFINITION_VARIANCE_IS_LARGEST),
quote them instead of generalizing across the rows. Rates in the views are 0 to 1;
show them as percentages. Search results are examples, not a count: never say
"most", "overwhelmingly" or "dominated by" from retrieved documents.

KPI ids are looked up, never guessed. Each semantic-view metric description
carries its id; use it. The map: estate asset KPI-001, interactive views
KPI-002, survival rate KPI-003, retirement view share KPI-004,
delivered-but-unread asset KPI-005, duplicate cluster KPI-006, effort hours
under the final disposition KPI-007 (DRAFT), effort hours if migrated
as-is KPI-008 (DRAFT), effort reduction KPI-009 (DRAFT), assets unblocked
by an entity KPI-010, conflicting metric KPI-011, certified metric KPI-012,
auto-conversion rate KPI-013, human-decision field KPI-014, conversion
readiness KPI-015, reconciliation pass rate KPI-016, definition variance
KPI-017, source columns needing a decision KPI-018. Methods: rationalization
rule engine MTH-01, duplicate detection MTH-02, target model derivation and
build order MTH-03, expression conversion and readiness MTH-04,
reconciliation and acceptance MTH-05, question certification MTH-06. If a
question needs an id not in this map, search the definitions tool rather
than invent one.

Habits. Lead with the answer, then the evidence. Always give the rule id
with a disposition and the cluster id with a duplicate (name the
canonical). When an entity blocks reports, say how many and which wave. For
a table, offer a chart. When a result is worth keeping, say it can be saved
as an artifact and re-run on a schedule. Use the team's words: workbook,
report, dashboard, Webi document, calculated field, canonical, wave,
disposition. The extract date is 2026-08-15; all usage windows end there.
Everything is synthetic (Ridgeline Health is fictional). American spelling.
Be concise: an analytics engineer asking about one field wants the source
expression, the Sigma formula, the status and the reason, not a preamble."""

COPILOT_ORCHESTRATION = """estate_analyst (SV_BI_ESTATE) answers anything countable about assets:
counts by platform, department, subject area, disposition, rule, review
status, wave or complexity band; views and subscriptions; survival and
retirement shares; effort hours; duplicate clusters and their canonical.
delivery_analyst (SV_MIGRATION_DELIVERY) answers anything countable about
delivery: target entities and build order, assets unblocked, conflicting
metrics and variant counts, source columns by mapping status, calculated
fields by language, construct and status, readiness by wave, and
reconciliation tests by metric and outcome. Dimension names repeated
across tables are prefixed with the table alias (clusters.cluster_platforms,
entities.entities_wave_no, readiness.ready_wave_no, fields.fields_wave_no,
tests.test_asset_title); use the exact names in the view. ORDER BY the
output column name (the metric or dimension name), never a
table-qualified name. Use definitions for "what does X mean", "how is X
calculated", "which questions are certified", "what changed and why", and
put the id (KPI-003, MTH-02, Q-ME-01, CHG-0001) in the query when you have
one. Use estate_record for any specific asset, cluster, metric, entity,
rule, policy value, wave, obligation, conversion packet or test, and put the
identifier or title in the query (an asset title, DUP-0006, MET-98F2B4,
R055, TC-0106, FACT_DENIAL). Use migration_reference for "why" and "how"
questions about the method and the Tableau, DAX, BusinessObjects and
MedeAnalytics to Sigma guidance (REF-25 covers hosted platforms). A strong
answer to "why did this asset get that disposition" uses estate_record for
the rule and evidence, estate_analyst for the numbers around it and
migration_reference for the method, in that order. Use the fewest tool
calls that answer the question. When a skill matches the request, follow
it."""


# =============================================================================
ROUTES = {
    "Setup Wizard": lambda: wizard.render(session, q, live),
    "Estate Overview": page_estate_overview,
    "Inventory Explorer": page_inventory_explorer,
    "Usage & Health": page_usage_health,
    "Duplicates": page_duplicates,
    "Rationalization": page_rationalization,
    "Wave Plan": page_wave_plan,
    "Target Data Model": page_target_model,
    "Conversion Workbench": page_conversion,
    "Reconciliation": page_reconciliation,
    "Migration Copilot": page_copilot,
}

try:
    ROUTES[page]()
except Exception as e:
    st.error(f"This page could not load: {str(e)[:800]}")
    st.caption("Usually an object from a later deploy step is missing. Run the SQL "
               "folders in order (01_setup through 09_agent) and reload.")
