# Agent instructions (any coding agent)

This file is the vendor-neutral entry point for Cursor, Claude Code, Copilot, Codex, Gemini, and other coding agents. Tool-specific folders (`.cursor/`, `.claude/`) only point here.

When the user asks to install, deploy, sync, or stand up Tazama on Kubernetes, **read and follow** `skills/tazama-helm-install/SKILL.md`. Do the install yourself. Do not only quote the README.

When the user asks which wrapper flags to combine (CMS, BIAR, relays, selectors, destroy), read `skills/tazama-helm-k3s/SKILL.md` and `skills/tazama-helm-install/commands.md`.

## Hard rules

- Repo root contains `tazama.cmd`, `tazama.sh`, and `helmfile.yaml.gotmpl`. Run wrappers from that folder.
- Windows: `.\tazama.cmd ...` only. Never `.\tazama.ps1` (execution policy blocks it).
- Linux/macOS: `./tazama.sh ...`.
- First install: `sync`, not `apply`. Default: profile `core`, cloud `onprem`.
- Kind / k3s / kubeadm / Docker Desktop Kubernetes → `-Cloud onprem`. Never mix Kind with `-Cloud eks`.
- On-prem ingress is NodePort. LoadBalancer on Kind hangs Helm `--wait`.
- TMS port **3000**, admin **5100**. Not Docker Compose 5000.
- No Hasura. Configuration is admin-service (`.\tazama.cmd configure`).
- Helmfile must be 1.x. Never commit `values/secrets.yaml`.

## Default first install

```powershell
.\tazama.cmd sync -Profile core -Cloud onprem
kubectl get pods -n tazama
kubectl port-forward -n tazama svc/tms-service 3000:3000
```

```bash
chmod +x tazama.sh
./tazama.sh sync core onprem
```

Full playbook: `skills/tazama-helm-install/SKILL.md`.
