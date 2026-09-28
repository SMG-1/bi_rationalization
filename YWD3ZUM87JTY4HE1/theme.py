"""Carbon-flavored light/dark theme for Streamlit-in-Snowflake apps.

Palette-driven with every color forced, so the app renders identically
regardless of the viewer's Streamlit theme — both the canvas and the nav
rail switch with the mode. CSP-safe. Usage:

    import theme
    dark = st.session_state.get("dark_mode", True)
    theme.inject(dark=dark)             # right after set_page_config
    theme.sidebar_brand("ELT Console")
    theme.page_header("Operations", "Pipeline Health", "caption ...")
    # sidebar: st.toggle("Dark mode") -> update session state -> rerun

After inject(), module attrs BLUE/GOOD/BAD/WARN/TEXT/GV reflect the mode.
"""
import altair as alt
import streamlit as st

FONT = "'IBM Plex Sans', -apple-system, 'Segoe UI', 'Helvetica Neue', sans-serif"
MONO = "'IBM Plex Mono', ui-monospace, 'SF Mono', Menlo, monospace"

_DARK = {
    "blue": "#4589ff", "blue_deep": "#0f62fe",
    "canvas_css": ("radial-gradient(1100px 500px at 85% -10%, rgba(15,98,254,.12), transparent 60%),"
                   "linear-gradient(180deg, #0a0f1e 0%, #0d1428 100%)"),
    "surface": "#121a2e", "surface2": "#182238", "hairline": "#233150",
    "text": "#e2e9f5", "muted": "#93a4c3", "subtle": "#5f7195",
    "good": "#42be65", "bad": "#ff8389", "warn": "#f1c21b",
    "card_grad": "linear-gradient(180deg, #182238 0%, #121a2e 100%)",
    "card_shadow": "0 6px 20px rgba(2,6,18,.35)",
    "grid": "#1b2743", "code_bg": "#182238",
    "pill_alpha": ".14", "hover_border": "#2e4370",
    # 10-slot categorical palette, fixed order (never cycle past it — fold into
    # "Other" instead). Slot hues match _LIGHT's so a series keeps its identity
    # across the mode toggle. CVD-validated on this surface; teal/pink separated.
    "cat": ["#4589ff", "#be95ff", "#3ddbd9", "#b28600", "#ff7eb6",
            "#42be65", "#a56eff", "#eb6200", "#1192e8", "#fa4d56"],
    "gv": {"bg": "transparent", "node": "#182238", "node_border": "#31456f",
           "text": "#e2e9f5", "edge": "#44557a", "accent": "#0f62fe",
           "accent_text": "#ffffff", "good": "#0e2c1a", "good_border": "#1f6f3f",
           "good_text": "#42be65", "bad": "#331418", "bad_border": "#7a2e34",
           "bad_text": "#ff8389"},
    "rail_bg": "linear-gradient(180deg, #070c19 0%, #0b1226 100%)",
    "rail_border": "#233150", "rail_text": "#93a4c3", "rail_subtle": "#5f7195",
    "rail_hover": "rgba(69,137,255,.10)",
    "rail_sel_bg": "linear-gradient(90deg, rgba(15,98,254,.28), rgba(15,98,254,.10))",
    "rail_sel_bar": "#4589ff", "rail_sel_text": "#ffffff",
    "brand_name": "#ffffff",
    "df_bg": "#121a2e", "df_text": "#e2e9f5",
}

_LIGHT = {
    "blue": "#0f62fe", "blue_deep": "#0f62fe",
    "canvas_css": ("radial-gradient(1100px 500px at 85% -10%, rgba(15,98,254,.05), transparent 60%),"
                   "linear-gradient(180deg, #f7f9fd 0%, #eef2f9 100%)"),
    "surface": "#ffffff", "surface2": "#ffffff", "hairline": "#dfe5f0",
    "text": "#161616", "muted": "#52627e", "subtle": "#8494b3",
    "good": "#198038", "bad": "#da1e28", "warn": "#8e6a00",
    "card_grad": "linear-gradient(180deg, #ffffff 0%, #fbfcfe 100%)",
    "card_shadow": "0 2px 10px rgba(16,37,74,.07)",
    "grid": "#e9edf5", "code_bg": "#eef3ff",
    "pill_alpha": ".10", "hover_border": "#b9c9e8",
    # Same slot order as _DARK (blue, purple, teal, gold, magenta, green,
    # violet, orange, cyan, red); validated on white.
    "cat": ["#0f62fe", "#6929c4", "#009d9a", "#b28600", "#9f1853",
            "#198038", "#a56eff", "#8a3800", "#1192e8", "#fa4d56"],
    "gv": {"bg": "transparent", "node": "#ffffff", "node_border": "#c6d2e8",
           "text": "#161616", "edge": "#8ea3c8", "accent": "#0f62fe",
           "accent_text": "#ffffff", "good": "#defbe6", "good_border": "#6fdc8c",
           "good_text": "#0e6027", "bad": "#fff1f1", "bad_border": "#ffb3b8",
           "bad_text": "#a2191f"},
    "rail_bg": "linear-gradient(180deg, #ffffff 0%, #f3f6fc 100%)",
    "rail_border": "#dfe5f0", "rail_text": "#52627e", "rail_subtle": "#8494b3",
    "rail_hover": "rgba(15,98,254,.07)",
    "rail_sel_bg": "rgba(15,98,254,.10)",
    "rail_sel_bar": "#0f62fe", "rail_sel_text": "#0f62fe",
    "brand_name": "#161616",
    "df_bg": "#ffffff", "df_text": "#161616",
}

# set by inject()
BLUE = _DARK["blue"]; GOOD = _DARK["good"]; BAD = _DARK["bad"]
WARN = _DARK["warn"]; TEXT = _DARK["text"]; MUTED = _DARK["muted"]
GV = _DARK["gv"]


def _css(p):
    return f"""
<style>
/* ================= chrome & canvas ================= */
#MainMenu, footer {{ visibility: hidden; }}
[data-testid="stHeader"] {{ background: transparent; }}
.stApp {{ background: {p['canvas_css']}; font-family: {FONT}; }}
.block-container {{ padding-top: 1.1rem; max-width: 1250px; }}

/* keep Streamlit's Material icon font working (collapse arrow, status icons):
   never force our font onto icon elements */
[data-testid="stIconMaterial"], [class*="material-symbols"], .material-icons {{
    font-family: "Material Symbols Rounded", "Material Symbols Outlined", "Material Icons" !important;
}}

/* force readable text regardless of client theme */
.stApp h1, .stApp h2, .stApp h3, .stApp h4 {{ color: {p['text']} !important; font-family: {FONT}; }}
[data-testid="stMarkdownContainer"] p, [data-testid="stMarkdownContainer"] li,
.stApp label p, [data-testid="stWidgetLabel"] p {{ color: {p['text']} !important; }}
[data-testid="stCaptionContainer"] p {{ color: {p['muted']} !important; }}
.stApp code {{ background: {p['code_bg']}; color: {p['blue']}; border-radius: 5px;
               font-family: {MONO}; padding: 1px 6px; }}
.stApp h3 {{
    font-size: 1.02rem !important; font-weight: 600 !important;
    letter-spacing: .01em; padding-left: 12px; border-left: 3px solid {p['blue_deep']};
    margin-top: .6rem;
}}

/* ================= sidebar nav rail ================= */
[data-testid="stSidebar"] {{
    background: {p['rail_bg']}; border-right: 1px solid {p['rail_border']}; min-width: 264px;
}}
[data-testid="stSidebar"] p, [data-testid="stSidebar"] span,
[data-testid="stSidebar"] label, [data-testid="stSidebar"] div {{
    color: {p['rail_text']}; font-family: {FONT};
}}
[data-testid="stSidebar"] hr {{ border-color: {p['rail_border']}; }}
[data-testid="stSidebar"] .stRadio label > div:first-child {{ display: none; }}
[data-testid="stSidebar"] .stRadio label {{
    padding: 9px 12px; border-radius: 9px; width: 100%; cursor: pointer;
    border-left: 3px solid transparent; transition: all .14s ease; margin-bottom: 2px;
}}
[data-testid="stSidebar"] .stRadio label:hover {{ background: {p['rail_hover']}; }}
[data-testid="stSidebar"] .stRadio label:has(input:checked) {{
    background: {p['rail_sel_bg']};
    border-left: 3px solid {p['rail_sel_bar']};
}}
[data-testid="stSidebar"] .stRadio label:has(input:checked) p {{
    color: {p['rail_sel_text']} !important; font-weight: 600;
}}
[data-testid="stSidebar"] .stRadio p {{ font-size: .93rem; }}

/* ================= cards ================= */
[data-testid="stMetric"] {{
    background: {p['card_grad']};
    border: 1px solid {p['hairline']}; border-radius: 14px; padding: 16px 18px 13px 18px;
    box-shadow: {p['card_shadow']};
    transition: border-color .15s ease;
}}
[data-testid="stMetric"]:hover {{ border-color: {p['hover_border']}; }}
[data-testid="stMetricLabel"] {{ overflow: visible !important; }}
[data-testid="stMetricLabel"] > div,
[data-testid="stMetricLabel"] p {{
    white-space: normal !important; overflow: visible !important; text-overflow: clip !important;
    line-height: 1.25; min-height: 2.5em;
}}
[data-testid="stMetricLabel"] p {{
    font-size: .70rem !important; letter-spacing: .09em; text-transform: uppercase;
    color: {p['subtle']} !important; font-weight: 700;
}}
[data-testid="stMetricValue"] {{ color: {p['text']} !important; font-weight: 300; font-size: 1.9rem !important; }}
[data-testid="stMetricValue"] > div {{ overflow: visible !important; white-space: nowrap; }}
[data-testid="stExpander"] {{
    background: {p['surface']}; border: 1px solid {p['hairline']} !important;
    border-radius: 12px; overflow: hidden;
}}
[data-testid="stExpander"] summary {{ color: {p['text']} !important; }}
[data-testid="stExpander"] summary:hover {{ color: {p['blue']} !important; }}
[data-testid="stDataFrame"] {{
    border: 1px solid {p['hairline']}; border-radius: 12px; overflow: hidden;
    box-shadow: {p['card_shadow']};
}}

/* ================= buttons (flat — no glow) ================= */
.stButton > button, .stDownloadButton > button, .stFormSubmitButton > button,
[data-testid="stBaseButton-secondary"] {{
    border-radius: 9px; border: 1px solid {p['hairline']} !important;
    background: {p['surface2']} !important; color: {p['text']} !important; font-weight: 500;
    padding: .5rem 1.05rem; box-shadow: none; transition: border-color .12s ease, color .12s ease;
}}
[data-testid="stBaseButton-secondary"] p {{ color: {p['text']} !important; }}
.stButton > button:hover, .stDownloadButton > button:hover,
.stFormSubmitButton > button:hover, [data-testid="stBaseButton-secondary"]:hover {{
    border-color: {p['blue']} !important; color: {p['blue']} !important;
    background: {p['surface2']} !important; box-shadow: none;
}}
[data-testid="stBaseButton-secondary"]:hover p {{ color: {p['blue']} !important; }}
.stButton > button[kind="primary"], [data-testid="stBaseButton-primary"] {{
    background: {p['blue_deep']} !important; border-color: {p['blue_deep']} !important;
    color: #fff !important; font-weight: 600; box-shadow: none;
}}
[data-testid="stBaseButton-primary"] p {{ color: #fff !important; }}
.stButton > button[kind="primary"]:hover, [data-testid="stBaseButton-primary"]:hover {{
    background: #0353e9; border-color: #0353e9; color: #fff; box-shadow: none;
}}
.stButton > button:disabled {{ opacity: .45; }}

/* ================= inputs ================= */
.stTextInput input, .stNumberInput input, .stTextArea textarea {{
    background: {p['surface2']} !important; color: {p['text']} !important;
    border-radius: 9px !important; border: 1px solid {p['hairline']} !important;
    box-shadow: none !important;
}}
.stTextInput input:focus, .stTextArea textarea:focus {{
    border-color: {p['blue']} !important;
}}
.stSelectbox [data-baseweb="select"] > div, .stMultiSelect [data-baseweb="select"] > div {{
    background: {p['surface2']} !important; border-radius: 9px !important;
    border-color: {p['hairline']} !important; color: {p['text']} !important;
}}
.stSelectbox [data-baseweb="select"] *, .stMultiSelect [data-baseweb="select"] * {{
    color: {p['text']};
}}
[data-baseweb="popover"] [data-baseweb="menu"] {{ background: {p['surface2']}; }}
[data-baseweb="popover"] [data-baseweb="menu"] * {{ color: {p['text']}; }}
.stSlider [data-baseweb="slider"] div[role="slider"] {{ background: {p['blue']}; }}
.stCheckbox p, .stApp [data-testid="stMain"] .stRadio p {{ color: {p['text']} !important; }}
[data-testid="stFileUploaderDropzone"] {{
    background: {p['surface']} !important; border: 1px dashed {p['hover_border']} !important;
    border-radius: 12px !important;
}}
[data-testid="stFileUploaderDropzone"] * {{ color: {p['muted']} !important; }}

/* ================= tabs ================= */
.stTabs [data-baseweb="tab-list"] {{
    gap: 6px; border-bottom: 1px solid {p['hairline']}; background: transparent;
}}
.stTabs [data-baseweb="tab"] {{
    border-radius: 9px 9px 0 0; padding: 9px 16px; font-weight: 500;
    color: {p['muted']}; background: transparent;
}}
.stTabs [aria-selected="true"] {{ color: {p['blue']} !important; }}
.stTabs [data-baseweb="tab-highlight"] {{ background-color: {p['blue']}; }}

/* ================= alerts & status ================= */
[data-testid="stAlert"] {{
    border-radius: 11px; border: 1px solid {p['hairline']}; background: {p['surface']};
}}
[data-testid="stAlert"] p {{ color: {p['text']} !important; }}
div[data-testid="stStatus"] {{
    background: {p['surface']}; border: 1px solid {p['hairline']}; border-radius: 12px;
}}

/* ================= custom components ================= */
.hk-header {{ margin: 0 0 4px 0; }}
.hk-eyebrow {{
    display: inline-flex; align-items: center; gap: 9px;
    font-size: .72rem; font-weight: 700; letter-spacing: .12em;
    text-transform: uppercase; color: {p['blue']};
}}
.hk-eyebrow::before {{
    content: ""; width: 26px; height: 3px; background: {p['blue_deep']}; border-radius: 2px;
}}
.hk-title {{
    font-size: 2.05rem; font-weight: 275; color: {p['text']};
    margin: .18rem 0 .2rem 0; line-height: 1.18; font-family: {FONT};
}}
.hk-caption {{ color: {p['muted']}; font-size: .95rem; margin-bottom: .3rem; max-width: 62rem; }}
.hk-rule {{
    border: none; height: 1px; margin: .7rem 0 1.2rem 0;
    background: linear-gradient(90deg, {p['hairline']}, transparent 70%);
}}
.hk-pill {{
    display: inline-block; padding: 3px 11px; border-radius: 999px;
    font-size: .73rem; font-weight: 700; letter-spacing: .03em;
}}
.hk-pill-good {{ background: rgba(66,190,101,{p['pill_alpha']}); color: {p['good']};
                 border: 1px solid rgba(66,190,101,.35); }}
.hk-pill-bad  {{ background: rgba(218,30,40,{p['pill_alpha']}); color: {p['bad']};
                 border: 1px solid rgba(218,30,40,.35); }}
.hk-pill-warn {{ background: rgba(241,194,27,{p['pill_alpha']}); color: {p['warn']};
                 border: 1px solid rgba(178,134,0,.35); }}
.hk-pill-info {{ background: rgba(69,137,255,{p['pill_alpha']}); color: {p['blue']};
                 border: 1px solid rgba(69,137,255,.35); }}
.hk-brand {{
    display: flex; align-items: center; gap: 11px; padding: 8px 2px 16px 2px;
    border-bottom: 1px solid {p['rail_border']}; margin-bottom: 12px;
}}
.hk-brand-mark {{
    width: 36px; height: 36px; border-radius: 10px;
    background: linear-gradient(135deg, #2f7bff, #0f62fe);
    display: flex; align-items: center; justify-content: center;
    color: #fff !important; font-weight: 700; font-size: 1.05rem;
}}
.hk-brand-name {{ font-weight: 600; font-size: 1.04rem; color: {p['brand_name']} !important; line-height: 1.15; }}
.hk-brand-sub {{ font-size: .72rem; color: {p['rail_subtle']} !important; }}
</style>
"""


def inject(dark: bool = True):
    """Apply the theme and set module color attrs for the chosen mode."""
    global BLUE, GOOD, BAD, WARN, TEXT, MUTED, GV
    _MODE["dark"] = dark
    p = _DARK if dark else _LIGHT
    BLUE, GOOD, BAD, WARN = p["blue"], p["good"], p["bad"], p["warn"]
    TEXT, MUTED, GV = p["text"], p["muted"], p["gv"]
    st.markdown(_css(p), unsafe_allow_html=True)
    _register_altair(p, dark)


def sidebar_brand(name: str, sub: str = "Hakkoda, an IBM Company"):
    st.sidebar.markdown(
        f'<div class="hk-brand"><div class="hk-brand-mark">H</div>'
        f'<div><div class="hk-brand-name">{name}</div>'
        f'<div class="hk-brand-sub">{sub}</div></div></div>',
        unsafe_allow_html=True)


def page_header(eyebrow: str, title: str, caption: str = ""):
    cap = f'<div class="hk-caption">{caption}</div>' if caption else ""
    st.markdown(
        f'<div class="hk-header"><span class="hk-eyebrow">{eyebrow}</span>'
        f'<div class="hk-title">{title}</div>{cap}</div><hr class="hk-rule"/>',
        unsafe_allow_html=True)


_MODE = {"dark": True}


def df(frame):
    """Wrap a DataFrame for st.dataframe with per-mode cell colors.
    Streamlit's grid is canvas-rendered and ignores CSS; Styler cell
    properties are the supported way to force colors (headers stay
    client-themed — a Streamlit limitation)."""
    p = _DARK if _MODE["dark"] else _LIGHT
    try:
        return frame.style.set_properties(
            **{"background-color": p["df_bg"], "color": p["df_text"]})
    except Exception:
        return frame


def pill(text: str, kind: str = "info") -> str:
    """Return an HTML status pill (kind: good|bad|warn|info) for st.markdown."""
    return f'<span class="hk-pill hk-pill-{kind}">{text}</span>'


def _register_altair(p, dark):
    name = "hk_carbon_dark" if dark else "hk_carbon_light"

    def _theme():
        return {"config": {
            "font": "IBM Plex Sans, Helvetica Neue, sans-serif",
            "background": "transparent",
            "view": {"stroke": "transparent"},
            "axis": {"labelColor": p["muted"], "titleColor": p["muted"],
                     "gridColor": p["grid"], "domainColor": p["hairline"],
                     "tickColor": p["hairline"], "labelFontSize": 11, "titleFontSize": 11},
            "legend": {"labelColor": p["muted"], "titleColor": p["muted"]},
            "range": {"category": p["cat"]},
        }}
    try:
        alt.themes.register(name, _theme)
        alt.themes.enable(name)
    except Exception:
        pass
