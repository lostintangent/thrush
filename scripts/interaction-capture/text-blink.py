"""Burst-capture the styles scene on the iPhone in both appearances, first blinking and then
under Reduce Motion, and check every burst with scripts/check-text-blink.py."""
from pathlib import Path
import random
import runpy
import time

ROOT = Path(__file__).resolve().parents[2]
check_bursts = runpy.run_path(str(ROOT / "scripts/check-text-blink.py"))["check_bursts"]
# Jittered screenshots sample every phase of the 1.2 s cycle instead of aliasing with it.
BLINKING_FRAMES, STEADY_FRAMES = 30, 8


def set_reduce_motion(phone, sim, enabled):
    sim("spawn", phone.device, "defaults", "write", "com.apple.Accessibility", "ReduceMotionEnabled",
        "-bool", "true" if enabled else "false")
    sim("spawn", phone.device, "notifyutil", "-p", "com.apple.accessibility.reduce.motion.status", check=False)


def burst(phone, folder, count):
    folder.mkdir(parents=True)
    frames = []
    for index in range(count):
        path = folder / f"{index:02}.png"
        phone.screenshot(path)
        frames.append(path)
        time.sleep(random.uniform(0.03, 0.29))
    return frames


def capture(phone, sim, wait_for, save_json):
    bursts = {}
    for reduced in (False, True):
        set_reduce_motion(phone, sim, reduced)
        for appearance in ("dark", "light"):
            pid = phone.launch("styles", appearance, "portrait", "hidden")

            def ready():
                state = phone.state()
                return state if (state.get("pid") == pid and state.get("scene") == "styles" and
                                 state.get("appearance") == appearance and state.get("gpuCompleted") and
                                 state.get("generation") and state.get("keyboardHeight", 0) < 90 and
                                 state.get("reducesMotion") == reduced) else False

            state = wait_for(f"styles in {appearance}{' with Reduce Motion' if reduced else ''}", ready, 90)
            time.sleep(0.7)
            label = "steady" if reduced else "blinking"
            save_json(phone.out / f"text-blink-{appearance}-{label}.json", state)
            bursts[appearance, label] = burst(phone, phone.scratch / f"{appearance}-{label}",
                                              STEADY_FRAMES if reduced else BLINKING_FRAMES)
            if phone.state().get("pid") != pid:
                raise RuntimeError(f"The styles scene exited during the {appearance} burst.")
    set_reduce_motion(phone, sim, False)

    check_bursts(bursts, phone.out)
