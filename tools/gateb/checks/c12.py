import time
from .model import Criteria, values

TITLE = "Storage discovery, search and native delivery"


def evaluate(d):
    c = Criteria()
    seconds = d.get("stock_visible_seconds")
    c.require(seconds <= 30 if seconds is not None else None, "Real storage discovered within 30 seconds")
    c.require(d.get("search_filtered"), "Search filters actual stock")
    c.require(d.get("delivered_delta") == 16, "One order delivers sixteen new items")
    c.require(d.get("stock_delta") == -16 if "stock_delta" in d else None, "Stock decreases by sixteen")
    return c.finish(d)


def run(ctx):
    ctx.power("storage", "on")
    start = time.monotonic()
    ctx.navigate("wall", "shop")
    def stock():
        frame = ctx.frame("wall")
        return frame if any(b.get("id", "").startswith("item:") for b in values(frame["buttons"])) else None
    frame = ctx.wait(stock, 30)
    seconds = time.monotonic()-start if frame else None
    ctx.type_text("wall", "diamond")
    frame = ctx.wait(stock, 10)
    items = [b["id"] for b in values(frame["buttons"]) if b.get("id", "").startswith("item:")] if frame else []
    filtered = bool(items) and all("diamond" in item for item in items)
    before = ctx.count_items("storage_output", "diamond")
    storage_before = ctx.count_items("storage_stock", "diamond")
    ctx.click("wall", "item:minecraft:diamond")
    ctx.click("wall", "order:16:minecraft:diamond")
    ctx.wait(lambda: ctx.count_items("storage_output", "diamond") - before == 16, 120)
    return evaluate(ctx.record("C12-observations.json", {"stock_visible_seconds": seconds, "search_filtered": filtered,
        "delivered_delta": ctx.count_items("storage_output", "diamond") - before,
        "stock_delta": ctx.count_items("storage_stock", "diamond") - storage_before}))
