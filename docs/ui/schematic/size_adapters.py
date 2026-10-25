"""Explicit, fontless test adapters for layout-boundary comparisons."""
import copy
import jobs as J
import other as O
import status as ST
import system as SY
import shop as SH
import ar as AR
import screens as SC
import mapscreen as MS
import panel as PN
import pocket as PK

BASELINE = [(15, 10), (26, 20), (29, 12), (39, 19), (51, 19), (57, 24),
            (80, 30), (100, 38), (164, 81), (37, 17), (53, 23)]
SCREENS = {}


def register(ids, scene, widths, heights, states=("scene",)):
    for ident in ids.split():
        SCREENS[ident] = dict(id=ident, scene=scene, luaEntry=ident, pythonEntry=ident,
                             widths=widths, heights=heights, states=list(states))


register("status", "status", [24, 30, 36, 52, 96], [6, 9, 14, 17, 22, 32],
         ("scene", "missing", "empty", "crowded", "tight"))
register("mining mining-setup mining-ores", "jobs", [24, 30, 36, 52], [4, 6, 8, 14, 19, 22],
         ("scene", "empty"))
register("lumber lumber-setup", "jobs", [24, 30, 36, 52], [14, 19, 22])
register("drops drops-add drops-edit drops-remove drops-setup", "jobs",
         [18, 24, 30, 34, 36, 52], [12, 14, 19, 22])
register("build build-setup build-picker", "other", [24, 36], [16, 19],
         ("scene", "empty", "missing"))
register("health attention events alerts errors events-picker", "other", [20, 23, 30, 40], [16])
register("turtle turtle-pose", "other", [36], [16, 19], ("scene", "error", "confirm"))
register("inventory", "other", [24, 36], [16, 19, 22, 36],
         ("scene", "empty", "unknown", "stale", "next"))
register("shop shop-item shop-low shop-find shop-picker", "stock", [16, 24, 29, 36, 39, 40, 52, 74, 90], [16])
register("ar", "ar", [20, 26, 27, 29], [7, 16], ("scene", "empty", "error"))
register("terminal terminal-code terminal-log terminal-roles", "system", [30, 40, 48], [14])
register("unassigned unloaded alert", "system", [7, 15, 24, 40], [3, 6, 8, 10, 12, 14])

register("map", "map", [25, 52, 65, 80, 98, 131], [30], ("scene", "selection", "zoom"))
register("ar-focus", "ar", [20, 26, 27, 29], [7, 16], ("scene", "next", "empty"))
register("drops-queue", "jobs", [18, 24, 30, 36, 52], [12, 14, 19, 22],
         ("running", "stopping", "stopped", "done", "facing", "feedback"))
register("drops-tools", "jobs", [18, 24, 30, 36, 52], [12, 14, 19, 22], ("scene", "release", "found"))
register("build-return", "other", [24, 36], [16, 19], O.BUILD_RETURN_MODES)
register("errors-detail", "other", [20, 23, 30, 40], [16], ("scene", "next"))
register("events-history", "other", [20, 23, 30, 40], [16], ("scene", "next", "find", "picker", "facts"))
register("errors-clear", "other", [20, 23, 30, 40], [16], ("scene", "confirm", "empty", "detail", "next"))
register("shop-saved", "stock", [16, 24, 36, 52, 90], [16],
         ("browse", "item", "lists", "list", "draft", "full"))

register("drops-dimension drops-preview drops-saved", "jobs", [18, 24, 30, 34, 36, 52], [12, 14, 19, 22])
register("ar-follow", "ar", [20, 26, 27, 29], [7, 16], ("scene", "missing"))
register("health-diagnostics", "other", [20, 23, 30, 40], [16], ("scene", "next"))

register("panel", "panel", [19, 26, 37, 40, 56, 75, 77, 116, 155],
         [7, 9, 11, 12, 13, 15, 19, 20, 21, 23], ("scene", "builder", "next", "keyboard", "missing"))
register("panel-alerts", "panel", [19, 26, 40], [12], ("scene", "empty", "next"))
register("panel-pair", "panel", [19, 25, 31, 37, 40, 42, 48, 54, 60, 66], [12, 14, 16, 18], ("scene", "code"))
register("panel-paired pocket-paired", "panel", [26, 40], [10, 12], ("scene", "next", "confirm"))
register("panel-enroll pocket-enroll", "panel", [23, 25, 28, 40], [10, 12], ("scene",))
register("panel-worker", "panel", [19, 26, 40], [8, 10, 12], ("scene", "missing", "pending", "busy", "error"))
register("pocket-fleet pocket-jobs pocket-shop pocket-pair pocket-alerts", "system", [19, 24, 26, 36], [12, 14, 17, 20])
SCREENS["pocket-pair"]["states"] += ["code"]
register("pocket-lists", "stock", [16, 24, 36, 52], [10, 16], ("scene", "list", "draft", "row"))
register("pocket-minimum", "stock", [16, 24, 26], [10, 12], ("scene",))

register("attention-lost", "other", [20, 23, 30, 40], [16], ("scene", "detail"))


def render(ident, state, w, h):
    if ident == "panel":
        f = dict(mining=None, lumber=None) if state == "missing" else None
        return PN.main(ST.model(), w, h, "", needs=PN.SC["needs"], f=f,
                       build=PN.BUILD if state in ("builder", "next") else None,
                       page=1 if state == "next" else 0, keyboard=state == "keyboard",
                       search=PK.SYS["search"] if state == "keyboard" else "")
    if ident == "panel-alerts":
        return PN.alerts([] if state == "empty" else PN.alert_texts(ST.model()), w, h, "", page=1 if state == "next" else 0)
    if ident == "panel-pair":
        return PN.pair(ST.model(), w, h, "", **(PN.code() if state == "code" else {}))
    if ident in ("panel-paired", "pocket-paired"):
        return PN.paired(w, h, "", page=1 if state == "next" else 0,
                         confirm=PN.SC["confirm"] if state == "confirm" else None,
                         tabs=False if ident == "pocket-paired" else None)
    if ident in ("panel-enroll", "pocket-enroll"):
        return PN.enroll(w, h, "", tabs=False if ident == "pocket-enroll" else None)
    if ident == "panel-worker":
        settings = None if state == "missing" else dict(dim="minecraft:overworld", autoToolSwap=False)
        return PN.worker(w, h, "", 4, settings,
                         block={"missing": "update required", "pending": "pending", "busy": "worker busy"}.get(state),
                         note="settings refused" if state == "error" else None)
    if ident == "pocket-fleet":
        return PK.fleet(ST.model(), w, h)
    if ident == "pocket-jobs":
        return PK.jobs(ST.model(), w, h)
    if ident == "pocket-shop":
        return PK.shop(ST.model(), w, h)
    if ident == "pocket-pair":
        return PK.pair(ST.model(), w, h, **(PN.code() if state == "code" else {}))
    if ident == "pocket-alerts":
        return PK.alerts(SC.with_alert(ST.model()), w, h)
    if ident == "pocket-lists":
        return SH.saved_pocket(page=None if state == "scene" else "supplies",
                               editing=state in ("draft", "row"), row=1 if state == "row" else None, w=w, h=h)
    if ident == "pocket-minimum":
        return PK.saved_editor(w=w, h=h)
    if ident == "status":
        m = ST.model()
        if state == "missing":
            for key in ("mining", "lumber", "today", "disk"):
                m[key] = None
        elif state == "empty":
            m["turtles"], m["flags"], m["events"] = [], [], []
        elif state in ("crowded", "tight"):
            m["turtles"] = [dict(m["turtles"][i % len(m["turtles"])], id=i + 100) for i in range(40)]
        m["tight"] = state == "tight"
        return ST.status(m, w, h)
    if ident.startswith("mining"):
        return J.mining(J.mining_model(empty=state == "empty"), w, h,
                        setup=ident != "mining", editing=ident == "mining-ores")
    if ident.startswith("lumber"):
        return J.lumber(J.lumber_setup_facts(J.lumber_model()), w, h, setup=ident == "lumber-setup")
    if ident == "map":
        return MS.screen(w, h, "", level=-58 if state != "scene" else "all",
                         scale=(1, 1) if state != "scene" else None,
                         centre=(184, -369) if state != "scene" else None,
                         pick=("turtle", "6") if state == "selection" else None)
    if ident == "ar-focus":
        return AR.picker(2, [] if state == "empty" else AR.TARGETS, 2 if state == "next" else 1, w, h)
    if ident == "drops-dimension":
        return J.drops(J.drops_model(dim=-1, nether=(3,)), w, h)
    if ident == "drops-preview":
        return J.drops(J.drops_model(testing=True, turtle=12, pose=dict(dim=0, x=118, y=64, z=-336)), w, h)
    if ident == "drops-saved":
        return J.drops(J.drops_model(testing=True, saved=True), w, h)
    if ident == "ar-follow":
        return AR.layout(1, {key: True for key in AR.ORDER}, w, h,
                         follow=("#12", state == "missing", "world"))
    if ident == "attention-lost":
        hs = dict(O.SCENE["health"], machines=[dict(id=12, role="worker", seen=3180000,
                  pose=dict(x=120, y=64, z=-30))], leases={}, points=[], holds=[], requests=[], errors=[0, 340], entries=[])
        return O.health("attention", w, h, "", facts=hs, lost_detail=state == "detail")
    if ident == "health-diagnostics":
        base = O.diagnostic_case("facts", w, h)
        return O.diagnostic_case("facts-next", w, h) if state == "next" and any(b["id"] == "next" for b in base.buttons) else base
    if ident == "drops-queue":
        return J.dropsqueue(w, h, state)()
    if ident == "drops-tools":
        m = J.drops_model(testing=True, saved=True)
        m.update(queueEnabled=True, queueTools=True, task=12 if state == "release" else None,
                 start=1 if state == "found" else 0)
        return J.drops(m, w, h)
    if ident.startswith("drops"):
        m = J.drops_model(editing=ident == "drops-add", edit=ident == "drops-edit",
                          confirm=ident == "drops-remove", testing=ident == "drops-setup")
        return J.drops(m, w, h)
    if ident == "build-return":
        return O.build_return_case(w, h, state)
    if ident.startswith("build"):
        options = {} if state == "scene" else dict(inv=[] if state == "empty" else None)
        return O.build(w, h, "", setup=ident != "build", pick=1 if ident == "build-picker" else None, **options)
    if ident == "errors-detail":
        return O.health_case("errors", w, h, detail=True, page=2 if state == "next" else 1)
    if ident == "events-history":
        base = O.history_case(w, h)
        options = dict(page=2) if state == "next" and any(b["id"] == "next" for b in base.buttons) else dict(find="lumber") if state == "find" else dict(picker=True) if state == "picker" else dict(fact=O.history_events(40)[-1]) if state == "facts" else {}
        return O.history_case(w, h, **options)
    if ident == "errors-clear":
        return O.clear_case(w, h, "detail-next" if state == "next" else "list" if state == "scene" else state)
    if ident in ("health", "attention", "events", "alerts", "errors", "events-picker"):
        return O.health("events" if ident == "events-picker" else ident, w, h, "", picker=ident == "events-picker")
    if ident.startswith("turtle"):
        row, sel = O.detail_row(), dict(id=str(O.SCENE["detail"]["id"]))
        if state == "error":
            row["error"] = "storage write failed " * 8
        if state == "confirm":
            sel["confirm"] = "remove"
        if ident == "turtle-pose":
            sel["draft"], row["uncertain"] = copy.deepcopy(O.SCENE["draft"]), True
        return O.turtle(w, h, "", sel, row)
    if ident == "inventory":
        kind = "occupied" if state in ("scene", "next") else state
        now = O.SCENE["inv"]["later" if kind == "stale" else "at"]
        return O.inventory(w, h, "", O.inv_model(kind), 2 if state == "next" else 1, now)
    if ident == "shop-saved":
        return SH.saved_native(selected="minecraft:iron_ingot" if state == "item" else None,
                               saved_page=True if state in ("lists", "full") else "supplies" if state in ("list", "draft") else None,
                               editing=state == "draft", full=state == "full", w=w, h=h)
    if ident.startswith("shop"):
        page = {"shop": "browse", "shop-item": "item", "shop-low": "low", "shop-find": "find", "shop-picker": "pick"}[ident]
        kw = next(kw for name, _, kw in SH.PAGES if name == page)
        return SH.page(page, kw, w, h, "")()
    if ident == "ar":
        return AR.layout(0 if state == "empty" else 2, {key: True for key in AR.ORDER}, w, h,
                         alert=("storage write failed " * 8, 1, 2) if state == "error" else None)
    if ident.startswith("terminal"):
        mode = {"terminal": "normal", "terminal-code": "code", "terminal-log": "log", "terminal-roles": "role"}[ident]
        return SY.terminal(ST.model(), SC.view(mode, code=SC.PK.SYS["code"], now=0, expires=292000,
                           input="6 shop", notice="display 7: status", displays=SC.ROLES), w, h)
    if ident in ("unassigned", "unloaded"):
        return SY.unassigned(w, h, 6 if ident == "unassigned" else 9, "UNASSIGNED" if ident == "unassigned" else "MAP")
    if ident == "alert":
        return SY.alert(ST.model(), SC.PK.SYS["alert"], w, h, 3000, False)
    raise ValueError("unknown Python adapter " + ident)
