"""Record the single iPhone reconnect-while-typing interaction through the existing UI-test runner."""
import json
import subprocess
import sys
import time
from urllib.request import Request, urlopen

import proof
from proof import HERE


def record(phone, appearance):
    plan = proof.build_test_runner(phone.scratch, phone.out, HERE / "UITests/ReconnectTypingProof.swift")
    proof.configure(plan, THRUSH_CAPTURE_ENDPOINT=phone.endpoint, THRUSH_CAPTURE_APPEARANCE=appearance)

    def state():
        with urlopen(phone.endpoint + "/motion/state", timeout=5) as response:
            return json.load(response)

    with (phone.out / "reconnect-ui.log").open("w") as log, subprocess.Popen(
        ["xcodebuild", "test-without-building", "-xctestrun", plan, "-destination",
         "platform=iOS Simulator,id=" + phone.device, "-parallel-testing-enabled", "NO",
         "-resultBundlePath", phone.scratch / "reconnect.xcresult"], stdout=log, stderr=log
    ) as test:
        try:
            def running():
                if test.poll() is not None:
                    raise RuntimeError("The UI test exited before completing its checkpoints. See reconnect-ui.log.")
                return state()

            def ready():
                terminal = phone.state()
                return (running()["appReady"] and terminal.get("scene") == "reconnect-typing" and terminal.get("gpuCompleted")
                        and (terminal.get("keyboardLanguage") or "").lower().startswith("en")
                        and terminal.get("keyboardHeight", 0) > 90 and terminal.get("accessoryHeight", 0) >= 44)

            proof.wait("the live English keyboard on the running terminal", ready, 120)
            initial = phone.state()
            reconnecting = None
            final = None
            first_visible = last_visible = None

            def finished():
                nonlocal reconnecting, final, first_visible, last_visible
                terminal = phone.state()
                wire = state()
                if (terminal.get("cursorSpinner") and
                        wire["interrupted"] and not wire["resumed"]):
                    reconnecting = terminal
                    last_visible = time.monotonic() - recording_started
                    if first_visible is None:
                        first_visible = last_visible
                if not wire["complete"] and test.poll() is not None:
                    raise RuntimeError("Native typing stopped before the remote echo. See reconnect-ui.log.")
                if wire["complete"] and terminal.get("gpuCompleted") and not terminal.get("cursorSpinner"):
                    final = terminal
                    return True
                return False

            # record_switch returns control when simctl reports its first real video frame.
            with phone.record_switch("reconnect-typing"):
                recording_started = time.monotonic()
                with urlopen(Request(phone.endpoint + "/motion/start", method="POST"), timeout=5):
                    pass
                proof.wait("held input echoed exactly once after the resumed replay", finished, 90)
            with urlopen(Request(phone.endpoint + "/motion/observed", method="POST"), timeout=5):
                pass
            if test.wait(45):
                raise RuntimeError("The native reconnect typing test failed. See reconnect-ui.log.")
            wire = state()
            if (wire["attachments"] != 2 or not wire["replayAcknowledged"] or
                    bytes.fromhex(wire["liveBytesHex"]) != b"git" or bytes.fromhex(wire["heldBytesHex"]) != b" status"):
                raise RuntimeError("Peer bytes or attachment count disagreed with the native proof.")
            if not reconnecting:
                raise RuntimeError("The cursor spinner did not appear during recording.")
            for observed in [reconnecting, final]:
                if any(observed.get(key) != initial.get(key) for key in ("pid", "keyboardHeight", "accessoryHeight", "keyboardLanguage")):
                    raise RuntimeError("The native keyboard moved or changed during reconnect.")
            proof.save(phone.out / "reconnect-wire.json", wire)
            views = phone.out / "reconnect-view.json"
            proof.save(views, dict(live=initial, reconnecting=reconnecting, resumed=final,
                                  spinnerIntervalSeconds=[first_visible, last_visible]))
            still = phone.out / "reconnect-typing-held.png"
            with (phone.out / "reconnect-cursor.log").open("w") as log:
                subprocess.run([sys.executable, HERE / "reconnect-cursor.py",
                                phone.out / "reconnect-typing.mov", views, appearance, still],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=240)
        finally:
            if test.poll() is None:
                test.terminate()
                try:
                    test.wait(10)
                except subprocess.TimeoutExpired:
                    test.kill()
