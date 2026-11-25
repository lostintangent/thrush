"""Record the single iPhone reconnect-while-typing interaction through the existing UI-test runner."""
import json
from pathlib import Path
import plistlib
import runpy
import subprocess
from urllib.request import Request, urlopen

HERE = Path(__file__).resolve().parent


def record(phone, appearance, wait_for, save_json):
    ui = runpy.run_path(str(HERE / "run.py"))
    plan = ui["build_test_runner"](phone.scratch, phone.out, source=HERE / "ReconnectTypingProof.swift")
    config = plistlib.loads(plan.read_bytes())
    config[ui["RUNNER"]]["EnvironmentVariables"].update(THRUSH_CAPTURE_ENDPOINT=phone.endpoint,
                                                         THRUSH_CAPTURE_APPEARANCE=appearance)
    plan.write_bytes(plistlib.dumps(config))

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
                return (running()["appReady"] and terminal.get("scene") == "notice-motion" and terminal.get("gpuCompleted")
                        and (terminal.get("keyboardLanguage") or "").lower().startswith("en")
                        and terminal.get("keyboardHeight", 0) > 90 and terminal.get("accessoryHeight", 0) >= 44)

            wait_for("the live English keyboard on the running terminal", ready, 120)
            with phone.record_switch("reconnect-typing"):
                with urlopen(Request(phone.endpoint + "/motion/start", method="POST"), timeout=5):
                    pass
                wait_for("held input echoed exactly once after the resumed replay", lambda: state()["complete"], 90)
            if test.wait(45):
                raise RuntimeError("The native reconnect typing test failed. See reconnect-ui.log.")
            proof = state()
            if (proof["attachments"] != 2 or not proof["replayAcknowledged"] or
                    bytes.fromhex(proof["liveBytesHex"]) != b"git" or bytes.fromhex(proof["heldBytesHex"]) != b" status"):
                raise RuntimeError("Peer bytes or attachment count disagreed with the native proof.")
            save_json(phone.out / "reconnect-wire.json", proof)
        finally:
            if test.poll() is None:
                test.terminate()
                try:
                    test.wait(10)
                except subprocess.TimeoutExpired:
                    test.kill()
