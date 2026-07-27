#!/usr/bin/env python3
"""Bewaar zichtbare Google Slides-dia's als veilige lokale offlinecache."""
from __future__ import annotations
import argparse, fcntl, json, os, re, shutil, sys, tempfile, urllib.parse
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

try:
    import requests
    from google.auth.transport.requests import Request
    from google.oauth2 import service_account
except ImportError as exc:  # pragma: no cover
    requests = None
    Request = None
    service_account = None
    IMPORT_ERROR = exc
else:
    IMPORT_ERROR = None

DEFAULTS = {
    "CONTENT_MODE": "presentation",
    "PRESENTATION_URL": "",
    "PRESENTATION_CACHE_ENABLED": "true",
    "PRESENTATION_CACHE_INCLUDE_SKIPPED_SLIDES": "false",
    "PRESENTATION_CACHE_SLIDE_SECONDS": "5",
    "PRESENTATION_CACHE_HTTP_TIMEOUT_SECONDS": "20",
    "GOOGLE_SERVICE_ACCOUNT_FILE": "/etc/digitalsignage/google-service-account.json",
}
PNG = b"\x89PNG\r\n\x1a\n"
SCOPE = "https://www.googleapis.com/auth/presentations.readonly"

class CacheError(RuntimeError): pass

@dataclass
class Config:
    mode: str
    url: str
    enabled: bool
    include_skipped: bool
    slide_seconds: int
    timeout: int
    credentials: Path


def read_config(path: Path) -> dict[str, str]:
    data = dict(DEFAULTS)
    if not path.exists(): return data
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line: continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if not key.replace("_", "").isalnum(): continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"": value = value[1:-1]
        data[key] = value
    return data


def as_bool(value: str, default: bool) -> bool:
    val = value.strip().lower()
    if val in {"1","true","yes","ja","on"}: return True
    if val in {"0","false","no","nee","off"}: return False
    return default


def as_int(value: str, default: int, minimum: int = 1) -> int:
    try: parsed = int(value)
    except ValueError: return default
    return parsed if parsed >= minimum else default


def build_config(raw: dict[str,str]) -> Config:
    mode = raw.get("CONTENT_MODE", "presentation").strip().lower()
    if mode not in {"presentation", "website"}: mode = "presentation"
    return Config(
        mode=mode,
        url=raw.get("PRESENTATION_URL", "").strip(),
        enabled=as_bool(raw.get("PRESENTATION_CACHE_ENABLED", "true"), True),
        include_skipped=as_bool(raw.get("PRESENTATION_CACHE_INCLUDE_SKIPPED_SLIDES", "false"), False),
        slide_seconds=as_int(raw.get("PRESENTATION_CACHE_SLIDE_SECONDS", "5"), 5),
        timeout=as_int(raw.get("PRESENTATION_CACHE_HTTP_TIMEOUT_SECONDS", "20"), 20, 3),
        credentials=Path(raw.get("GOOGLE_SERVICE_ACCOUNT_FILE", DEFAULTS["GOOGLE_SERVICE_ACCOUNT_FILE"])),
    )


def presentation_id(url: str) -> str | None:
    match = re.search(r"/presentation/d/([^/]+)", urllib.parse.urlparse(url).path)
    return match.group(1) if match else None


def select_slides(payload: dict[str,Any], include_skipped: bool) -> tuple[list[tuple[str,bool]], int]:
    selected, skipped_count = [], 0
    slides = payload.get("slides", [])
    if not isinstance(slides, list): raise CacheError("Slides API gaf geen geldige slides-lijst")
    for slide in slides:
        if not isinstance(slide, dict): continue
        object_id = str(slide.get("objectId", "")).strip()
        props = slide.get("slideProperties", {})
        skipped = bool(props.get("isSkipped", False)) if isinstance(props, dict) else False
        if skipped: skipped_count += 1
        if object_id and (include_skipped or not skipped): selected.append((object_id, skipped))
    if not selected: raise CacheError("geen zichtbare dia's gevonden")
    return selected, skipped_count


def valid_png(data: bytes, page_id: str) -> None:
    if len(data) < 32 or not data.startswith(PNG): raise CacheError(f"dia {page_id} is geen geldige PNG")


class GoogleSource:
    def __init__(self, credentials: Path, timeout: int):
        if requests is None or service_account is None or Request is None:
            raise CacheError(f"Pythonpakketten ontbreken: {IMPORT_ERROR}")
        if not credentials.is_file(): raise CacheError(f"serviceaccountbestand ontbreekt: {credentials}")
        try: self.creds = service_account.Credentials.from_service_account_file(str(credentials), scopes=[SCOPE])
        except Exception as exc: raise CacheError(f"serviceaccount ongeldig: {exc}") from exc
        self.timeout = timeout

    def headers(self) -> dict[str,str]:
        try:
            if not self.creds.valid: self.creds.refresh(Request())
        except Exception as exc: raise CacheError(f"Google-authenticatie mislukt: {exc}") from exc
        return {"Authorization": f"Bearer {self.creds.token}"}

    def get_json(self, url: str, params: dict[str,str] | None = None) -> dict[str,Any]:
        try:
            response = requests.get(url, headers=self.headers(), params=params, timeout=self.timeout)
            response.raise_for_status(); data = response.json()
        except Exception as exc: raise CacheError(f"Google API-aanvraag mislukt: {exc}") from exc
        if not isinstance(data, dict): raise CacheError("Google API gaf geen JSON-object")
        return data

    def presentation(self, pid: str) -> dict[str,Any]:
        return self.get_json(f"https://slides.googleapis.com/v1/presentations/{urllib.parse.quote(pid, safe='')}",
            {"fields":"presentationId,title,slides(objectId,slideProperties/isSkipped)"})

    def slide_png(self, pid: str, page_id: str) -> bytes:
        meta = self.get_json(
            f"https://slides.googleapis.com/v1/presentations/{urllib.parse.quote(pid,safe='')}/pages/{urllib.parse.quote(page_id,safe='')}/thumbnail",
            {"thumbnailProperties.mimeType":"PNG", "thumbnailProperties.thumbnailSize":"LARGE"})
        url = str(meta.get("contentUrl", ""))
        if not url: raise CacheError(f"geen download-URL voor dia {page_id}")
        try:
            response = requests.get(url, timeout=self.timeout); response.raise_for_status(); data = bytes(response.content)
        except Exception as exc: raise CacheError(f"download dia {page_id} mislukt: {exc}") from exc
        valid_png(data, page_id); return data


class FixtureSource:
    def __init__(self, folder: Path): self.folder = folder
    def presentation(self, pid: str) -> dict[str,Any]: return json.loads((self.folder / "presentation.json").read_text(encoding="utf-8"))
    def slide_png(self, pid: str, page_id: str) -> bytes:
        data = (self.folder / f"{page_id}.png").read_bytes(); valid_png(data, page_id); return data


def atomic_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text); handle.flush(); os.fsync(handle.fileno())
        os.chmod(tmp, 0o644); os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)


def cache_valid(root: Path) -> bool:
    try: manifest = json.loads((root/"cache-manifest.json").read_text(encoding="utf-8"))
    except Exception: return False
    version = str(manifest.get("version", "")); slides = manifest.get("slides", [])
    if not version or not slides or not (root/"versions"/version/"index.html").is_file(): return False
    return all((root/"versions"/version/str(s.get("file", ""))).is_file() for s in slides)


def fallback(root: Path, fallback_dir: Path, reason: str) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for name in ("index.html", "offline.css"):
        atomic_text(root/name, (fallback_dir/name).read_text(encoding="utf-8"))
    (root/"cache-manifest.json").unlink(missing_ok=True)
    atomic_text(root/"cache-status.json", json.dumps({"active":"fallback","reason":reason}, indent=2)+"\n")


def publish(cfg: Config, source: Any, root: Path, player: Path) -> dict[str,Any]:
    pid = presentation_id(cfg.url)
    if not pid: raise CacheError("ongeldige Google Slides-URL")
    payload = source.presentation(pid)
    selected, skipped_count = select_slides(payload, cfg.include_skipped)
    versions = root/"versions"; versions.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".staging-", dir=versions))
    version = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}"
    final = versions/version
    try:
        for name in ("index.html","slideshow.css","slideshow.js"): shutil.copy2(player/name, staging/name)
        (staging/"slides").mkdir()
        entries=[]
        for index,(page_id,skipped) in enumerate(selected,1):
            data=source.slide_png(pid,page_id); valid_png(data,page_id)
            rel=f"slides/slide-{index:03d}.png"; (staging/rel).write_bytes(data)
            entries.append({"objectId":page_id,"file":rel,"skipped":skipped})
        manifest={"schemaVersion":1,"version":version,"presentationId":pid,"title":payload.get("title",""),
                  "generatedAt":datetime.now(timezone.utc).isoformat(timespec="seconds"),"slideSeconds":cfg.slide_seconds,
                  "includeSkippedSlides":cfg.include_skipped,"skippedSlideCount":skipped_count,"slides":entries}
        atomic_text(staging/"manifest.json",json.dumps(manifest,indent=2)+"\n")
        atomic_text(staging/"manifest.js","window.DIGITAL_SIGNAGE_MANIFEST = "+json.dumps(manifest,separators=(",",":"))+";\n")
        os.replace(staging,final)
        relative=f"versions/{version}/index.html"
        atomic_text(root/"index.html",f'<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0;url={relative}"><script>location.replace({json.dumps(relative)})</script>')
        atomic_text(root/"cache-manifest.json",json.dumps(manifest,indent=2)+"\n")
        for old in sorted([p for p in versions.iterdir() if p.is_dir() and p.name!=version], key=lambda p:p.stat().st_mtime, reverse=True)[1:]: shutil.rmtree(old,ignore_errors=True)
        return manifest
    except Exception:
        shutil.rmtree(staging,ignore_errors=True); raise


def run(argv: list[str] | None=None) -> int:
    parser=argparse.ArgumentParser(); parser.add_argument("--config",type=Path,default=Path(os.environ.get("CONFIG_FILE","/etc/digitalsignage/digitalsignage.conf")))
    parser.add_argument("--cache-root",type=Path,default=Path("/opt/digitalsignage/offline")); parser.add_argument("--player-dir",type=Path,default=Path("/opt/digitalsignage/offline-player"))
    parser.add_argument("--fallback-dir",type=Path,default=Path("/opt/digitalsignage/offline-fallback")); parser.add_argument("--fixture-dir",type=Path)
    args=parser.parse_args(argv); cfg=build_config(read_config(args.config)); args.cache_root.mkdir(parents=True,exist_ok=True)
    with (args.cache_root/".sync.lock").open("a+") as lock:
        try: fcntl.flock(lock.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: print("cache=skipped reason=already_running"); return 0
        if cfg.mode!="presentation": fallback(args.cache_root,args.fallback_dir,"website_mode"); print("cache=fallback reason=website_mode"); return 0
        if not cfg.enabled: fallback(args.cache_root,args.fallback_dir,"disabled"); print("cache=fallback reason=disabled"); return 0
        if args.fixture_dir: source=FixtureSource(args.fixture_dir)
        else:
            if not cfg.credentials.is_file():
                if cache_valid(args.cache_root): print("cache=stale reason=credentials_missing"); return 10
                fallback(args.cache_root,args.fallback_dir,"credentials_missing"); print("cache=fallback reason=credentials_missing"); return 0
            try: source=GoogleSource(cfg.credentials,cfg.timeout)
            except CacheError as exc:
                if cache_valid(args.cache_root): print(f"cache=stale reason=auth_failed detail={exc}",file=sys.stderr); return 10
                fallback(args.cache_root,args.fallback_dir,"auth_failed"); print(f"cache=fallback reason=auth_failed detail={exc}",file=sys.stderr); return 1
        try: manifest=publish(cfg,source,args.cache_root,args.player_dir)
        except Exception as exc:
            if cache_valid(args.cache_root): print(f"cache=stale reason=sync_failed detail={exc}",file=sys.stderr); return 10
            fallback(args.cache_root,args.fallback_dir,"sync_failed"); print(f"cache=fallback reason=sync_failed detail={exc}",file=sys.stderr); return 1
        print(f"cache=updated slides={len(manifest['slides'])} skipped={manifest['skippedSlideCount']} include_skipped={str(manifest['includeSkippedSlides']).lower()}"); return 0

if __name__ == "__main__": raise SystemExit(run())
