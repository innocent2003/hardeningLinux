import subprocess
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = BASE_DIR  / "scripts"


def run_script(script: Path):
    print("=" * 70)
    print(f"Running: {script}")
    print("=" * 70)

    try:
        result = subprocess.run(
            ["bash", str(script)],
            cwd=script.parent,
            text=True,
            capture_output=True
        )

        print(result.stdout)

        if result.stderr:
            print("STDERR:")
            print(result.stderr)

        if result.returncode == 0:
            print(f"[OK] {script.name}")
        else:
            print(f"[FAILED] {script.name}")
            print(f"Exit code: {result.returncode}")

        return result.returncode

    except Exception as e:
        print(f"[ERROR] Cannot run {script.name}: {e}")
        return -1


def main():
    if not SCRIPTS_DIR.exists():
        print(f"[ERROR] Directory not found: {SCRIPTS_DIR}")
        return

    scripts = sorted(SCRIPTS_DIR.glob("*.sh"))

    if not scripts:
        print(f"No bash scripts found in {SCRIPTS_DIR}")
        return

    print(f"Found {len(scripts)} bash script(s)")
    print()

    results = {}

    for script in scripts:
        results[script.name] = run_script(script)

    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)

    for name, code in results.items():
        status = "OK" if code == 0 else "FAILED"
        print(f"{name:<40} {status}")

    print("=" * 70)


if __name__ == "__main__":
    main()