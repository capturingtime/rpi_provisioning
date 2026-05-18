"""
Photobooth runtime — asyncio entry point for Raspberry Pi 4B.
Run with: python3 rpi_provisioning/booth_boot/resources/run_booth.py
"""
import asyncio
import board
import random
from datetime import datetime
from typing import Optional

from photobooth import RPi, Uploader
from photobooth.strip import PhotoStrip
from photobooth.template_loader import LocalTemplateLoader

# --- Hardware / storage ---
S3_BUCKET = "public.capturingtimephoto.net"
BOOTH_DIR = "/opt/booth_images"
CAMERA_MODEL = "Canon EOS 800D"
CAMERA_STARTUP_CONFIG = {
    "autoexposuremode": 3,  # Manual — prevents built-in flash from auto-firing
}
MAX_PRINTS = 3

# --- Print compositor templates (folders under TEMPLATE_BASE_DIR) ---
# ACTIVE_TEMPLATE: None = plain single-shot
#                  folder with shot_count=1 = single shot + final overlay
#                  folder with shot_count>1 = series / strip mode
TEMPLATE_BASE_DIR = "/opt/photobooth/templates"
ACTIVE_TEMPLATE = "strip_test_template"

# --- Button roles (GPIO event labels — context-dependent) ---
# KEEP_BUTTON  GPIO 23 green: keep (review) | print receipt (idle) | show last shot (series_capture)
# REDO_BUTTON  GPIO 24 red:   redo (review) | start over (series_capture)
# "capture"    GPIO 25 blue:  start capture (idle) | continue / next shot (review)
KEEP_BUTTON = "green"  # GPIO 23 / pin 16
REDO_BUTTON = "red"  # GPIO 24 / pin 18

# --- Post-capture reaction phrases (one is chosen at random) ---
CAPTURE_PHRASES = [
    "Awesome!  ",
    "Looking great!  ",
    "Love it!  ",
    "Stunning!  ",
    "Perfect shot!  ",
    "Beautiful!  ",
    "Amazing!  ",
    "That's the one!  ",
]

# --- Django screen URLs ---
ATTRACT_URL = "http://127.0.0.1:8000/main/attract/"
REVIEW_URL = "http://127.0.0.1:8000/main/last_capture/"
SINGLE_FINAL_URL = "http://127.0.0.1:8000/main/single_final/"
SERIES_FINAL_URL = "http://127.0.0.1:8000/main/series_final/"
SERIES_CAPTURE_URL = "http://127.0.0.1:8000/main/series_capture/"


class PhotoBooth:
    async def run(self):
        loop = asyncio.get_running_loop()
        self.rpi = RPi()
        self._print_counts: dict = {}
        self._last_uploaded_path: str = ""
        if Uploader is not None:
            try:
                self.uploader = Uploader(bucket_name=S3_BUCKET)
            except Exception as exc:
                print(f"Uploader init failed: {exc} — upload/print disabled")
                self.uploader = None
        else:
            print(
                "Uploader not available (boto3/utilities missing) — upload/print disabled"
            )
            self.uploader = None

        await self._startup()

        self.strip = None
        if ACTIVE_TEMPLATE:
            try:
                loader = LocalTemplateLoader(TEMPLATE_BASE_DIR)
                self.strip = PhotoStrip(loader=loader, template_name=ACTIVE_TEMPLATE)
                mode = "series" if self.strip.shot_count > 1 else "single+overlay"
                print(
                    f"Template '{ACTIVE_TEMPLATE}' loaded "
                    f"({self.strip.shot_count} shots, {mode})"
                )
            except Exception as exc:
                print(f"Active template load failed: {exc} — plain single-shot mode")

        self.rpi.setup_gpio_events(loop)

        await self.rpi.display_url(ATTRACT_URL)
        attract = asyncio.create_task(
            self.panel.scroll(
                text="Press the big blue button to begin!  ", speed=0.005, count=999
            )
        )
        last_print_time: float = 0.0

        while True:
            event = await self.rpi.next_event()

            if event == "capture":
                print("Capture button pressed")
                attract.cancel()

                is_series = self.strip is not None and self.strip.shot_count > 1
                image_path = (
                    await self._run_series() if is_series else await self._run_single()
                )

                if image_path is None:
                    await self._flush_events()
                    await self.rpi.display_url(ATTRACT_URL)
                    attract = asyncio.create_task(
                        self.panel.scroll(
                            text="Press the big blue button to begin!  ",
                            speed=0.005,
                            count=999,
                        )
                    )
                    continue

                self.rpi.copy_to_last_shot(image_path)
                self.camera.copy_last_shot_to_dir(dir=BOOTH_DIR)
                final_url = SERIES_FINAL_URL if is_series else SINGLE_FINAL_URL

                # Navigate immediately — upload runs in background while user views final screen
                await self.rpi.display_url(final_url)
                upload_task = None
                if self.uploader is not None:
                    upload_task = asyncio.create_task(self.uploader.upload(image_path))
                    self._last_uploaded_path = image_path

                # Hold final screen up to 60 s; green = print receipt, anything else = attract
                await self._flush_events()
                try:
                    decision = await asyncio.wait_for(self.rpi.next_event(), timeout=60)
                except asyncio.TimeoutError:
                    decision = None

                if decision in (KEEP_BUTTON, "capture") and upload_task is not None:
                    upload_url = await upload_task
                    await loop.run_in_executor(None, self._do_print, upload_url)
                    self._print_counts[image_path] = 1
                    last_print_time = loop.time()
                elif upload_task is not None:
                    await upload_task  # ensure upload completes before returning to attract

                await self._flush_events()
                await self.rpi.display_url(ATTRACT_URL)
                attract = asyncio.create_task(
                    self.panel.scroll(
                        text="Press the big blue button to begin!  ",
                        speed=0.005,
                        count=999,
                    )
                )

            elif event == KEEP_BUTTON:
                if self.uploader is None:
                    continue

                now = loop.time()
                if now - last_print_time <= 3:
                    continue

                last_shot = self._last_uploaded_path or self.camera.last_shot()
                if not last_shot:
                    print("Print button pressed but no last shot exists")
                    continue

                count = self._print_counts.get(last_shot, 0)
                if count >= MAX_PRINTS:
                    print(f"Max prints ({MAX_PRINTS}) exceeded for {last_shot}")
                    attract.cancel()
                    await self._flush_events()
                    await self.panel.scroll(
                        text="Max prints reached, sorry!  ", count=1
                    )
                    await self.rpi.display_url(ATTRACT_URL)
                    attract = asyncio.create_task(
                        self.panel.scroll(
                            text="Press the big blue button to begin!  ",
                            speed=0.005,
                            count=999,
                        )
                    )
                    continue

                print("Print button pressed")
                key = self.uploader.make_key(last_shot)
                presign_task = asyncio.create_task(self.uploader.presign(key))
                flash_task = asyncio.create_task(
                    self.panel.scroll(text="Printing...  ", speed=0.005, count=1)
                )
                url = await presign_task
                await flash_task
                await loop.run_in_executor(None, self._do_print, url)
                self._print_counts[last_shot] = count + 1
                last_print_time = now
                await self._flush_events()

            elif event == REDO_BUTTON:
                attract.cancel()
                await self._flush_events()
                await self.rpi.display_url(ATTRACT_URL)
                attract = asyncio.create_task(
                    self.panel.scroll(
                        text="Press the big blue button to begin!  ",
                        speed=0.005,
                        count=999,
                    )
                )

    async def _flush_events(self) -> None:
        """Drain any stale button events left over from the previous action.

        The brief sleep yields to the event loop so any in-flight
        call_soon_threadsafe callbacks are processed before we drain.
        """
        await asyncio.sleep(0.1)
        while not self.rpi.event_queue.empty():
            try:
                self.rpi.event_queue.get_nowait()
            except Exception:
                break

    # ------------------------------------------------------------------
    # Startup
    # ------------------------------------------------------------------

    async def _startup(self):
        print("Starting web server")
        await self.rpi.start_web()
        while not self.rpi.check_web():
            await asyncio.sleep(0.1)
        print("Web server ready")

        print("Starting kiosk")
        await self.rpi.start_kiosk()
        self.rpi.reset_last_shot()

        print("Setting up components and running checks")
        self.panel = self.rpi.add_neopixel(name="main", control=board.D18)
        self.camera = self.rpi.add_camera(
            name="main", model=CAMERA_MODEL, startup_config=CAMERA_STARTUP_CONFIG
        )
        self.printer = self.rpi.add_printer(name="receipt", model="PBM-8350U")

        panel_test = asyncio.create_task(self.panel.panel_test())

        if self.rpi.net_check_local():
            self.rpi.toggle_led(label="net_local", on=True)
        if self.rpi.net_check_www():
            self.rpi.toggle_led(label="net_www", on=True)

        self.rpi.toggle_led(label="camera_rdy", on=True)
        self.rpi.toggle_led(label="print_rdy", on=True)

        await panel_test
        self.rpi.toggle_led(label="shutter_rdy", on=True)
        print("Booth is online and ready")

    # ------------------------------------------------------------------
    # Capture flows
    # ------------------------------------------------------------------

    async def _run_single(self) -> Optional[str]:
        """Single-shot flow. Returns final image path, or None on redo."""
        image_path = await self._take_one_shot()
        decision = await self._review_shot(image_path, series_mode=False)
        if decision == "redo":
            return None

        if self.strip is not None and self.strip.shot_count == 1:
            loop = asyncio.get_running_loop()
            final_path = (
                f"{BOOTH_DIR}/final_{datetime.now().strftime('%Y%m%d-%Hh%Mm%Ss')}.jpg"
            )
            image_path = await loop.run_in_executor(
                None, self.strip.compose, [image_path], final_path
            )
        return image_path

    async def _run_series(self) -> Optional[str]:
        """Series flow. Returns composited strip path, or None if cancelled."""
        loop = asyncio.get_running_loop()
        total = self.strip.shot_count
        shots = []

        while len(shots) < total:
            if shots:
                await self.panel.scroll(
                    text=f"Shot {len(shots) + 1} of {total}! Get ready!  ",
                    speed=0.005,
                    count=1,
                )
            image_path = await self._take_one_shot()
            decision = await self._review_shot(image_path, series_mode=True)

            if decision == "redo":
                series_decision = await self._series_capture_review(shots)
                if series_decision == "start_over":
                    return None
                if series_decision == "redo_last":
                    shots.pop()
                continue  # retake current slot (or previous if redo_last)

            shots.append(image_path)

            if len(shots) >= total:
                continue

            # decision == "keep" — go to between-shots review page
            series_decision = await self._series_capture_review(shots)
            if series_decision == "start_over":
                return None
            if series_decision == "redo_last":
                shots.pop()

        strip_path = (
            f"{BOOTH_DIR}/strip_{datetime.now().strftime('%Y%m%d-%Hh%Mm%Ss')}.jpg"
        )
        return await loop.run_in_executor(None, self.strip.compose, shots, strip_path)

    # ------------------------------------------------------------------
    # Review helpers
    # ------------------------------------------------------------------

    async def _take_one_shot(self) -> str:
        """Run the countdown and capture one image."""
        for label in ("3...", "2...", "1...", "Smile! :D"):
            await self.panel.scroll(text=label, speed=0.001)
        twinkle_task = asyncio.create_task(self.panel.twinkle(count=30))
        image_path = await self.camera.capture_async()
        twinkle_task.cancel()
        self.panel.clear()
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, self._compress_image, image_path)
        await self.panel.scroll(
            text=random.choice(CAPTURE_PHRASES), speed=0.001, count=1
        )
        return image_path

    @staticmethod
    def _compress_image(
        image_path: str, max_dimension: int = 2048, quality: int = 85
    ) -> None:
        """Resize to max_dimension on the longest side and recompress in-place."""
        from PIL import Image

        with Image.open(image_path) as img:
            if max(img.size) > max_dimension:
                img.thumbnail((max_dimension, max_dimension), Image.LANCZOS)
            img.save(image_path, "JPEG", quality=quality, optimize=True)

    async def _review_shot(self, image_path: str, series_mode: bool = False) -> str:
        """Display shot in the review frame and wait for a decision.

        Returns:
            "keep"     — accept this shot
            "redo"     — cancel (single: → attract; series: → attract/cancel)
            "continue" — accept and skip series_capture (series_mode only)
        """
        self.rpi.copy_to_last_shot(image_path)
        await self.rpi.display_url(REVIEW_URL)
        await self._flush_events()

        decision = await self.rpi.next_event()
        while decision not in (KEEP_BUTTON, REDO_BUTTON, "capture"):
            decision = await self.rpi.next_event()

        if decision == REDO_BUTTON:
            return "redo"
        return "keep"  # KEEP_BUTTON or "capture" both keep

    async def _series_capture_review(self, shots: list) -> str:
        """Between-shots review page. Returns "continue", "start_over", or "redo_last"."""
        await self.rpi.display_url(SERIES_CAPTURE_URL)
        await self._flush_events()
        while True:
            event = await self.rpi.next_event()
            if event == "capture":
                return "continue"
            if event == REDO_BUTTON:
                return "start_over"
            if event == KEEP_BUTTON:
                if not shots:
                    continue
                decision = await self._review_shot(shots[-1], series_mode=False)
                if decision == "redo":
                    return "redo_last"
                await self.rpi.display_url(SERIES_CAPTURE_URL)
                await self._flush_events()

    # ------------------------------------------------------------------
    # Receipt printer
    # ------------------------------------------------------------------

    def _do_print(self, url: str) -> None:
        """Synchronous receipt printer — runs in thread executor from async caller."""
        self.printer.text("Capturing Time Photography")
        self.printer.ln()
        self.printer.ln()
        self.printer.text("Thank you for using our photobooth!")
        self.printer.ln()
        self.printer.ln()
        self.printer.text("Please visit us at http://capturingtimephoto.net")
        self.printer.ln()
        self.printer.text("    to schedule your free 30 minute consultation")
        self.printer.ln()
        self.printer.text("    for your next portrait session or event!")
        self.printer.ln()
        self.printer.ln()
        self.printer.text("Mention this photobooth when you book your next")
        self.printer.ln()
        self.printer.text("session with us & receive an extra 10% discount!")
        self.printer.ln()
        self.printer.ln()
        self.printer.text("Scan the QR code below to download your photo:")
        self.printer.ln()
        self.printer.qr(content=url, size=5)
        self.printer.ln()
        self.printer.text("Reach us at contact@capturingtimephoto.net")
        self.printer.ln()
        self.printer.text("Tag us on")
        self.printer.ln()
        self.printer.text("Instagram: @capturingtimephoto")
        self.printer.ln()
        self.printer.text("Facebook: @capturingtimephotollc")
        self.printer.cut()


if __name__ == "__main__":
    asyncio.run(PhotoBooth().run())
