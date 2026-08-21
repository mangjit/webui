# Open WebUI Auto-Installer for Ubuntu Proot-Distro on Android

A robust, **self-healing auto-installer** that deploys [Open WebUI](https://github.com/open-webui/open-webui) on Android devices inside an **Ubuntu Proot-Distro** environment, using the **uv (astral) Python manager**.

It detects your device hardware, picks the safest install profile, installs **prebuilt packages and wheels only** (never compiles unless you explicitly ask), verifies everything, and then acts as a **smart deployment manager** on every subsequent run — updating, repairing and re-optimising the environment instead of blindly re-installing.

---

## Quick Start (Android + Termux)

Inside **Termux** (not a proot shell):

```bash
pkg update
pkg install -y git
git clone https://github.com/open-webui/open-webui.git   # not required, just convenient repo home
# (or simply) mkdir -p ~/openwebui-autoinstaller  &&  # place this project folder here

cd openwebui-autoinstaller
bash termux-bootstrap.sh --with-ollama
```

What that does, in order:

1. Enables `tur-repo`, `x11-repo`, `root-repo` (Termux prebuilt repositories).
2. Installs `proot-distro`, `git`, `curl` and — from TUR — the prebuilt `uv`.
3. Installs the **Ubuntu** proot-distro image (once; `--replace` reinstalls it).
4. With `--with-ollama` (aarch64 devices): installs **native Ollama from TUR** — a prebuilt inference engine that runs outside proot and is much faster than anything we could compile. Open WebUI connects to it at `http://127.0.0.1:11434` (proot shares the device network, so localhost works).
5. Captures device info with `getprop` (Android version, ABI, SoC, GPU…) and hands it to the installer, which then runs **inside Ubuntu** via `proot-distro login`.

> **Keep Termux alive** while the server runs: install **Termux:API** and run `termux-wake-lock`. Proot processes are killed when the Android system reclaims Termux.

### Using OmniRoute (or any OpenAI-compatible gateway) instead of Ollama

If you already run **OmniRoute** in Termux (a self-hosted AI gateway exposing an OpenAI-compatible API at `http://localhost:20128/v1`, no API key required), you don't need Ollama at all:

```bash
cd openwebui-autoinstaller
bash termux-bootstrap.sh --openai-base-url http://127.0.0.1:20128/v1
```

That single command does everything: Termux repos → proot-distro Ubuntu → Open WebUI install → wires Open WebUI to OmniRoute:

- `OPENAI_API_BASE_URL=http://127.0.0.1:20128/v1` — chat completions, model listing, image generation, audio…
- `OPENAI_API_KEY=omni` — placeholder; OmniRoute works without a real key (change with `--openai-api-key` if your gateway needs one)
- `RAG_EMBEDDING_ENGINE=openai` + `RAG_EMBEDDING_MODEL=text-embedding-3-small` — **RAG embeddings also go through OmniRoute** (it exposes `/v1/embeddings`), so no local embedding model and no Ollama anywhere
- The installer is **not** passed `--with-ollama`, so nothing Ollama-related is installed.

**Requirements on your phone:**

1. OmniRoute must be **running in Termux before** you start Open WebUI (it listens on `127.0.0.1:20128`; Termux and proot-distro share the same network, so `127.0.0.1` works from inside Ubuntu). Keep Termux alive with `termux-wake-lock`.
2. Verify from inside Ubuntu: `proot-distro login ubuntu -- curl -s http://127.0.0.1:20128/v1/models`
3. In the Open WebUI UI, models appear automatically from OmniRoute's `/v1/models`. If you ever change the gateway URL later, re-run `update.sh` with the new value or edit the managed block, or set it in **Admin Panel → Settings → Connections**.

> Other OpenAI-compatible gateways (OpenRouter, LiteLLM, LM Studio server, …) work the same way — just pass their base URL with `--openai-base-url`.

### After install

- Open **http://127.0.0.1:8080** in a browser on the phone (LAN access: `http://<phone-ip>:8080`).
- First account you create becomes the **admin**.
- Manage the server later:

```bash
# inside the Ubuntu distro (proot-distro login ubuntu)
./openwebui-ctl status     # start | stop | restart | logs | watch
./update.sh                # smart update / repair
```

---

## What the installer detects

| Signal | Source | Used for |
|---|---|---|
| CPU architecture | `uname -m`, ABI from `getprop` | wheel availability; refuses unsupported 32-bit ARM |
| SoC / vendor | `/proc/cpuinfo` (implementer + Hardware), `ro.board.platform`, `ro.soc.*` | Snapdragon / Dimensity / Tensor / Exynos / … (informational + GPU inference) |
| RAM | `/proc/meminfo` | profile selection & thread tuning |
| Core count | `nproc --all` | `OMP_NUM_THREADS` / `MKL_NUM_THREADS` caps |
| Free storage | `df` | profile selection + hard pre-flight guard |
| Android version | `getprop ro.build.version.release` (via bootstrap) | compatibility notes |
| Termux version | `$TERMUX_VERSION` (via bootstrap) | diagnostics |
| Ubuntu / Proot | `/etc/os-release`, `OWI_IN_PROOT` marker | environment handling |
| GPU | `/sys/class/kgsl/kgsl-3d0/gpu_model`, `/proc/gpu_mali`, device-tree | Adreno/Mali classification |

Every probe is best-effort, falls back to `unknown`, and can be overridden with `OWI_*` environment variables. Run `./install.sh --report` (or `bash lib/detect.sh --report`) to see what was detected without installing anything.

---

## Hardware profiles

The installer derives a profile from RAM + free storage + architecture:

| Profile | Typical device | What gets installed | RAG embeddings |
|---|---|---|---|
| `full` | ≥8 GB RAM, ≥8 GB free, 64-bit | full `open-webui` dependency tree (incl. torch, transformers, onnxruntime, pandas, faster-whisper) + scipy | local sentence-transformers |
| `standard` | ≥4 GB RAM, ≥5 GB free, 64-bit | same full tree (config tuned down) | local sentence-transformers |
| `light` | ≥2 GB RAM, ≥3 GB free, 64-bit | `open-webui` **without** heavy deps + official `backend/requirements-min.txt` **auto-patched** with the small runtime deps needed to import the app (~2–3 GB saved vs full) | **Ollama** (`nomic-embed-text`) or an OpenAI-compatible embedding API |
| `minimal` | <2 GB RAM / tiny storage | light deps + most background AI chores disabled | Ollama / API |

> **Light-profile auto-patch:** the official `requirements-min.txt` is not enough to even import the app (e.g. v0.11.0 needs `Markdown`, `python-mimeparse`, `validators`, `tiktoken`, `ldap3`, `boto3`, Azure/Google storage clients, `pillow`, `fpdf2`, …). The installer installs a curated patch list and then **self-discovers** anything else a release needs by repeatedly running the real startup import (`import open_webui.main`) and installing what's missing — so it keeps working across future Open WebUI versions. All patched packages are small, pure-Python-or-light wheels.

On **32-bit ARM (armv7/armhf)** the installer refuses by default: the heavy prebuilt wheels simply don't exist for that platform (`--force` to attempt anyway, expected to fail).

### Package priority policy (never compile unless asked)

1. **Termux prebuilt packages** (tur/x11/root repos) — e.g. native `ollama`, `uv`, `proot-distro`.
2. **Official Ubuntu packages** (apt) — runtime libs such as `libgomp1` (OpenMP for numpy/torch wheels), `libatomic1`, `curl`, `git`, `ffmpeg`.
3. **Prebuilt Python wheels** — `uv pip install --no-build` (manylinux aarch64/x86_64 wheels; the whole pinned open-webui tree is wheel-available on 64-bit).
4. **Precompiled PyTorch distributions** — torch is pulled as an official PyPI wheel on aarch64; no compiling.
5. **Source builds — last resort only**: the install retry ladder first fails loudly, identifies the exact wheel-less package, and only with `--allow-build` compiles *that one* package.

---

## Smart updater (`update.sh`) — a deployment manager, not a `git pull`

Every run validates and repairs instead of assuming state. The change detector checks:

- **New releases** — compares installed version against PyPI (`open-webui==X.Y.Z`).
- **Repository updates** (git mode) — `git fetch`, HEAD comparison, `pyproject.toml` / `requirements.txt` / `package.json` checksums.
- **Dependency changes / version mismatches** — `uv pip check` (conflict graph) and live `uv pip freeze` vs. the saved `requirements.lock` (lock drift).
- **Broken packages** — import smoke tests (`open_webui`, `chromadb`, `onnxruntime`, `torch`, …).
- **Configuration changes** — the installer-managed block of `open_webui.env` is regenerated when the profile/hardware changed; your manual edits are always preserved.
- **Dead service** — the service is restarted automatically.

### What an update run does

1. Stops the server (if running).
2. Backs up the SQLite database + env file (keeps the last 5).
3. Applies exactly the needed steps (upgrade package, pull repo, rebuild frontend, regen lock, regen config).
4. Runs a post-update **health check**; on failure escalates through a **repair ladder**:
   - reinstall the specific broken package (wheels) → resync from lock → **rebuild the venv** from scratch (data untouched) → degrade a feature (e.g. switch embeddings to Ollama).
5. Restarts the service and records state.

Run it on a schedule if you like (`update.sh --yes`), or let `openwebui-ctl watch` keep the service alive with auto-restart.

---

## Layout

```
openwebui-autoinstaller/
├── install.sh            # main installer (run inside Ubuntu proot)
├── update.sh             # smart updater / repair
├── openwebui-ctl         # start/stop/restart/status/logs/watch
├── termux-bootstrap.sh   # Termux-side: repos, proot-distro, ollama, device info
├── conf/
│   └── installer.conf    # thresholds, package lists, defaults (OWI_* overrides)
└── lib/
    ├── common.sh         # logging, retries, state file, checksums, dry-run
    ├── detect.sh         # hardware / OS detection + profile
    ├── packages.sh       # apt/pkg + uv/pip (wheels-first) installers
    ├── config.sh         # open_webui.env generation & merge
    ├── repair.sh         # health checks + self-healing ladder
    ├── service.sh        # nohup+pidfile service + watchdog
    └── update-core.sh    # change detection & update orchestration
```

Installed paths (defaults, all overridable):

| Path | Purpose |
|---|---|
| `~/.openwebui-installer/` | venv, state, env file, logs, backups, lock |
| `~/.open-webui/data/` | Open WebUI database, uploads, vector store |
| `~/.local/bin/uv` | uv + managed Python 3.11 |

---

## Configuration reference

Key settings (flags to `install.sh`, or `OWI_*` env vars, or edit `conf/installer.conf`):

| Setting | Default | Meaning |
|---|---|---|
| `OWI_PROFILE` / `--profile` | auto | `full` `standard` `light` `minimal` |
| `OWI_PORT` / `--port` | 8080 | web UI port |
| `OWI_URL` / `--url` | http://localhost:8080 | `WEBUI_URL` (set to your public URL before enabling SSO) |
| `OWI_DATA_DIR` / `--data-dir` | `~/.open-webui/data` | data location |
| `OWI_PYTHON` / `--python` | 3.11 | managed CPython (3.11 or 3.12) |
| `OWI_SOURCE_MODE` / `--source` | auto | `pypi` (recommended) or `git` (dev checkout, rebuilds frontend) |
| `OWI_OLLAMA_MODE` | auto | `install` (native TUR ollama) / `none` / `auto` |
| `OWI_ALLOW_BUILD` / `--allow-build` | off | permit compiling a wheel-less package (last resort) |
| `OWI_YES` / `-y`, `OWI_DRY_RUN` / `-n` | off | non-interactive / simulate |

Open WebUI runtime settings live in `~/.openwebui-installer/open_webui.env`. The block between the `# >>> open-webui-installer: managed block <<<` markers is owned by the installer (regenerated per profile); **anything you add outside it survives every update**.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Install fails on `no matching distribution` | Likely a wheel-less package on your arch — use `--profile light` or `--allow-build`; see the log in `~/.openwebui-installer/logs/` |
| Server starts but RAG says embedding model missing | Light/minimal profile uses Ollama embeddings: `RAG_EMBEDDING_ENGINE=ollama` + run Ollama (native or inside proot) |
| "Prompt is too long" | Normal — enable Context Compaction in the UI; raise the model's context length |
| `database is locked` / slow DB | Expected on shared storage; keep SQLite on local storage, single worker (`UVICORN_WORKERS=1`, default) |
| Server dies when Termux is backgrounded | `termux-wake-lock` (Termux:API) or `openwebui-ctl watch` |
| Stuck after an update | `./update.sh --repair` — rebuilds venv from lock if needed |
| 32-bit ARM device | Not supported (no wheels). Use a 64-bit device or Docker on a real computer |

---

## What has been verified

Tested end-to-end in a sandbox (x86_64, uv 0.12, Python 3.11.16, Open WebUI v0.11.0):

- Detection report (arch/RAM/cores/storage/GPU/OS) with env overrides for Android.
- Simulated devices: Snapdragon 12 GB → `full`, Dimensity 6 GB → `standard`; `armhf` refuses safely.
- Fresh **light-profile** install: wheels-only (`--no-build`), 200 packages locked, `import open_webui.main` passes.
- Live service: `openwebui-ctl start` → `/health` returns `{"status":true}` in ~9 s.
- **Smart updater**: second run reports "up to date"; no-op when nothing changed.
- **Self-healing**: deleting a package's files (`bcrypt`) → `update.sh --repair` detects, reinstalls, re-verifies, and the running service stays healthy.
- **Idempotency**: re-running `install.sh` adopts the healthy venv and changes nothing.
- Full-profile dependency tree resolves **wheels-only** on 64-bit (torch etc. included).

## Notes & disclaimers

- Built for **aarch64 / x86_64** Android devices. Tested profile assumptions come from the official Open WebUI requirements (`Python >=3.11,<3.13`, pinned deps, bundled frontend wheel) — see the upstream repo for the authoritative version data.
- `termux-native` install mode exists but is experimental; Ubuntu proot is the supported path.
- This is community tooling, provided as-is, not affiliated with the Open WebUI project.
