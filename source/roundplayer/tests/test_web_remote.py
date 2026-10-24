"""Headless smoke test of the web remote against a running playback manager + web_remote.
Run: python3 -I tests/test_web_remote.py  (needs playwright + chromium, services on :8000/:8080)
"""
import asyncio, json, sys
from playwright.async_api import async_playwright

BASE = "http://127.0.0.1:8080"

async def main():
    errors, console = [], []
    async with async_playwright() as p:
        b = await p.chromium.launch()
        page = await b.new_page(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("console", lambda m: console.append(f"{m.type}: {m.text}") if m.type in ("error", "warning") else None)
        await page.goto(BASE, wait_until="networkidle")
        await page.wait_for_timeout(1500)
        # telemetry connected?
        conn = await page.get_attribute("#conn", "class")
        title = await page.text_content("#npTitle")
        print("conn:", conn, "| title:", title)
        # tabs
        for tab in ("lib", "yt", "queue", "settings", "now"):
            await page.click(f'nav button[data-tab="{tab}"]')
            await page.wait_for_timeout(600)
            assert await page.is_visible(f"#tab-{tab}"), tab
        # transport: play toggles icon + hits API
        await page.click('nav button[data-tab="now"]')
        await page.click("#btnPlay"); await page.wait_for_timeout(500)
        st = json.loads(await page.evaluate("fetch('/api/state').then(r=>r.text())"))
        print("after play: is_playing =", st["is_playing"])
        await page.click("#btnPlay"); await page.wait_for_timeout(500)
        # queue add + list
        await page.evaluate("fetch('/api/queue/add',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({video_id:'gAjR4_CbPpQ',title:'T',artist:'A'})})")
        await page.click('nav button[data-tab="queue"]'); await page.wait_for_timeout(800)
        rows = await page.locator("#queueList .item").count()
        print("queue rows:", rows)
        await page.click("#btnClearQueue"); await page.wait_for_timeout(600)
        # settings render
        await page.click('nav button[data-tab="settings"]'); await page.wait_for_timeout(1500)
        print("audio kv:", (await page.text_content("#audioLive"))[:80].replace("\n", " "))
        print("net kv:", (await page.text_content("#netStatus"))[:80].replace("\n", " "))
        print("dac opts:", await page.locator("#dacOpts select").count())
        await page.screenshot(path="/tmp/rp/remote_settings.png", full_page=True)
        await page.click('nav button[data-tab="now"]'); await page.wait_for_timeout(400)
        await page.screenshot(path="/tmp/rp/remote_now.png", full_page=True)
        await b.close()
    print("page errors:", errors)
    print("console:", console[:10])
    sys.exit(1 if errors else 0)

asyncio.run(main())
