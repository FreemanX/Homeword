"""Hardware and OS of the machine a benchmark ran on (recorded in every result file; latency depends on it)."""
import platform, re, subprocess


def _run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def machine_info():
    gpu = re.search(r"Total Number of Cores:\s*(\d+)", _run("system_profiler", "SPDisplaysDataType"))
    mem = _run("sysctl", "-n", "hw.memsize")
    return {
        "chip": _run("sysctl", "-n", "machdep.cpu.brand_string"),
        "cpu_cores": f"{_run('sysctl', '-n', 'hw.perflevel0.physicalcpu')}P+{_run('sysctl', '-n', 'hw.perflevel1.physicalcpu')}E",
        "gpu_cores": int(gpu.group(1)) if gpu else None,
        "ram_gb": round(int(mem) / 2**30) if mem.isdigit() else None,
        "macos": f"{platform.mac_ver()[0]} ({_run('sw_vers', '-buildVersion')})",
    }


def model_users(mine=()):
    """What else would use the on-device model during a benchmark: a running predictd or ghostd (the engine), Homeword (it
    restarts the engine on its own), `pred try`. Another user evicts the run's cache and changes outputs, so results would be
    invalid. `mine`: pids of this run's own processes, left out."""
    found = []
    for pattern, what in (("-x predictd", "predictd"), ("-x ghostd", "ghostd (the engine)"),
                          ("-x Homeword", "Homeword"), ("-f bin/pred try", "pred try")):
        pids = [p for p in _run("pgrep", *pattern.split(" ", 1)).split() if int(p) not in mine]
        if pids:
            found.append(f"{what} (pid {', '.join(pids)})")
    return found


def describe(m):
    return f"{m['chip']}, {m['cpu_cores']} CPU, {m['gpu_cores']}-core GPU, {m['ram_gb']} GB RAM, macOS {m['macos']}"


if __name__ == "__main__":
    print(describe(machine_info()))
