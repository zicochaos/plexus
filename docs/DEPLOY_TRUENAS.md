# Custom Plexus on TrueNAS / Portainer

How to **build**, **deploy**, and **update** a private Plexus fork on this lab
(TrueNAS + Portainer), including how to **check upstream** and fold in new
releases without losing fork-only features (e.g. xAI SuperGrok OAuth).

Upstream (`ghcr.io/mcowger/plexus`, `github.com/mcowger/plexus`) does **not** ship
those features — never switch stack 94 back to upstream `latest` if you need them.

```text
check upstream  →  update private fork  →  docker build on TrueNAS  →  Portainer recreate
```

---

## Source of truth (Git remotes)

| Remote | URL | Role |
|--------|-----|------|
| **`origin`** | `git@git-ssh.dnx.ovh:wmc/plexus.git` | **Forgejo — primary** (commit/push here) |
| **`upstream`** | `https://github.com/mcowger/plexus.git` | Official Plexus (fetch only) |
| **`github`** (optional) | `https://github.com/zicochaos/plexus.git` | Public GitHub mirror if needed |

```bash
# One-time remote layout (from a clone of this tree)
git remote rename origin upstream          # if origin still pointed at mcowger
git remote add origin git@git-ssh.dnx.ovh:wmc/plexus.git
# optional mirror:
# git remote add github https://github.com/zicochaos/plexus.git

git remote -v
git push -u origin feat/xai-oauth-supergrok
# later: git push origin main   # if you promote the branch
```

Web UI (Forgejo): `https://git.dnx.ovh` → org/user **wmc** → **plexus**.

---

## Lab map

| Item | Value |
|------|--------|
| TrueNAS | `192.168.66.66` |
| Portainer | `https://192.168.66.66:31015` (endpoint **3** = local Docker) |
| Plexus stack | name **`plexus`**, ID **94**, port **4000** |
| Image (running) | **`plexus:xai-latest`** (local Docker tag) |
| Optional registry | `192.168.66.66:5000` (stack `registry`, ID 98) |
| Data | `/mnt/SSD/nas-ssd/openclaw-lxc/plexus/data` |
| Config mount | `/mnt/SSD/nas-ssd/openclaw-lxc/plexus/config/plexus.yaml` |
| Git origin | `git@git-ssh.dnx.ovh:wmc/plexus.git` |
| Feature branch | `feat/xai-oauth-supergrok` (or merge into `main` on Forgejo) |

### Image tags

| Tag | Use |
|-----|-----|
| `plexus:xai-latest` | Rolling deploy tag Portainer uses |
| `plexus:xai-<gitsha>` | Immutable pin for rollback |

**Prefer local tags on TrueNAS.** Docker on TrueNAS expects HTTPS for
`192.168.66.66:5000`; plain HTTP registry fails with *server gave HTTP response
to HTTPS client*. Build on the NAS, tag locally, redeploy with **pullImage:
false**. Use the registry only after configuring insecure-registries/TLS.

Portainer compose (stack 94) should look like:

```yaml
services:
  plexus:
    image: plexus:xai-latest
    # volumes / env / ports unchanged
```

---

## Build / deploy (TrueNAS — recommended)

SSH to TrueNAS (needs sudo for Docker). **Clone from Forgejo** (primary):

```bash
ssh sbochna@192.168.66.66
```

TrueNAS must have an SSH key authorized on Forgejo (`git@git-ssh.dnx.ovh`).

### Full rebuild from Forgejo

```bash
BUILD_DIR=/tmp/plexus-xai-build
REPO=git@git-ssh.dnx.ovh:wmc/plexus.git
BRANCH=feat/xai-oauth-supergrok   # or main after you merge the feature

sudo rm -rf "$BUILD_DIR"
git clone --branch "$BRANCH" --depth 1 "$REPO" "$BUILD_DIR"
cd "$BUILD_DIR"
SHA=$(git rev-parse --short HEAD)

sudo docker build --platform linux/amd64 \
  --build-arg "APP_VERSION=xai-${SHA}" \
  -t "plexus:xai-latest" \
  -t "plexus:xai-${SHA}" \
  .
```

**Portainer UI after build:**

1. Stacks → **plexus** (94)  
2. Confirm `image: plexus:xai-latest`  
3. **Update the stack** with **Re-pull image / Pull image = OFF** (local tag)  
4. Wait until container is Up  

### Optional: helper from a Mac with Docker

```bash
# repo root, on the feature branch
./scripts/deploy-truenas-image.sh
```

Targets the HTTP registry by default; on this lab, **building on TrueNAS + local
tag** is more reliable (see registry HTTPS note).

---

## Check upstream for updates

Goal: see whether `mcowger/plexus` `main` has commits you do not have yet.

### Remotes (once)

```bash
cd /path/to/plexus   # clone of git@git-ssh.dnx.ovh:wmc/plexus.git
git remote -v
# origin    → Forgejo wmc/plexus
# upstream  → github.com/mcowger/plexus   (add if missing:)
git remote add upstream https://github.com/mcowger/plexus.git
```

### Are we behind upstream?

```bash
git fetch origin
git fetch upstream

# commits on upstream/main not in your current branch
git log --oneline HEAD..upstream/main

# count only
git rev-list --count HEAD..upstream/main

# files that would change
git diff --stat HEAD...upstream/main
```

| Result | Meaning |
|--------|---------|
| `0` commits | Fork is up to date with upstream `main` |
| `N > 0` | Upstream moved; rebase/merge, then rebuild image |
| conflicts later | Touch points: OAuth, enums, `config.ts`, frontend providers |

### Web UI

- Forgejo: compare your branch to a bookmark of upstream if you mirror it  
- Or open `https://github.com/mcowger/plexus/commits/main` and compare SHAs  

### Upstream Docker images

```text
ghcr.io/mcowger/plexus:latest
```

Useful only to know what they shipped — **not** as the running image for stack 94.

---

## Apply upstream updates

```bash
cd /path/to/plexus
git fetch upstream
git checkout feat/xai-oauth-supergrok   # or main

# Prefer rebase for a linear history; merge is fine if you prefer
git rebase upstream/main
# conflicts → fix → git add … → git rebase --continue

# Push to Forgejo (source of truth)
git push origin feat/xai-oauth-supergrok --force-with-lease   # only if rebased
```

Conflict hotspots for xAI OAuth:

- `packages/backend/src/services/oauth/`
- `packages/backend/src/config.ts` (`OAuthProviderSchema`)
- `packages/backend/drizzle/schema/postgres/enums.ts`
- `packages/frontend/src/hooks/useProviderForm.tsx`
- `packages/backend/src/transformers/oauth/oauth-transformer.ts`
- `packages/backend/src/index.ts` (`registerXaiOAuthProvider`)

After a clean rebase/merge:

1. **Rebuild** image on TrueNAS (section above).  
2. **Redeploy** stack 94 (`plexus:xai-latest`).  
3. **Verify** (section below).  

### Cadence

| When | Action |
|------|--------|
| Weekly | `git fetch upstream && git rev-list --count HEAD..upstream/main` |
| Non-zero count | Read log, rebase onto `upstream/main`, push `origin`, rebuild, redeploy |
| Security fix on upstream | Same, prioritize immediately |

---

## Verify after deploy

```bash
curl -sS http://192.168.66.66:4000/health

ssh sbochna@192.168.66.66 \
  'sudo docker ps --filter name=^plexus$ --format "{{.Image}} {{.Status}}"'
# expect: plexus:xai-latest   Up …

# ADMIN_KEY from Portainer env — do not commit
curl -sS -H "x-admin-key: $ADMIN_KEY" \
  http://192.168.66.66:4000/v0/management/oauth/providers
# expect "id": "xai"
```

UI: `http://192.168.66.66:4000/ui/`

---

## Rollback

```bash
sudo docker images 'plexus:xai*'
# Portainer: set image to e.g. plexus:xai-5cdbece, Update stack, Pull OFF
```

Data under `/mnt/SSD/nas-ssd/openclaw-lxc/plexus/data` survives image swaps.

---

## Checklist: routine update

```text
[ ] git fetch origin && git fetch upstream
[ ] git rev-list --count HEAD..upstream/main   # 0 → stop
[ ] git log --oneline HEAD..upstream/main
[ ] git rebase upstream/main                   # or merge
[ ] git push origin HEAD --force-with-lease    # if rebased
[ ] on TrueNAS: clone origin → docker build → plexus:xai-latest (+ :xai-$SHA)
[ ] Portainer stack 94: Update (pull OFF)
[ ] health OK + oauth providers include xai
```

---

## Do not

- Deploy `ghcr.io/mcowger/plexus:latest` for this stack if you need xAI OAuth.  
- Commit real `ADMIN_KEY` / tokens into git.  
- Use relative volume paths in Portainer (`./data`).  
- Force-push without `--force-with-lease` after rebase.  
- Treat GitHub as required — **Forgejo `origin` is enough** for TrueNAS builds.
