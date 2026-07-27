#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, json, sys, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location("cache",ROOT/"scripts/sync-presentation-cache.py")
module=importlib.util.module_from_spec(spec);sys.modules[spec.name]=module;spec.loader.exec_module(module)
PNG=module.PNG+b"x"*40
class Source:
    def __init__(self,payload,fail=False):self.payload=payload;self.fail=fail
    def presentation(self,pid):return self.payload
    def slide_png(self,pid,page):
        if self.fail:raise module.CacheError("testfout")
        return PNG

def assets(root):
    player=root/"player";fallback=root/"fallback";player.mkdir();fallback.mkdir()
    for n in ("index.html","slideshow.css","slideshow.js"):(player/n).write_text(n)
    (fallback/"index.html").write_text("fallback");(fallback/"offline.css").write_text("css")
    return player,fallback
class Tests(unittest.TestCase):
    def cfg(self,**x):
        raw=dict(module.DEFAULTS);raw.update({"PRESENTATION_URL":"https://docs.google.com/presentation/d/test/present"});raw.update(x);return module.build_config(raw)
    def test_hidden_default(self):
        p={"slides":[{"objectId":"a","slideProperties":{"isSkipped":False}},{"objectId":"b","slideProperties":{"isSkipped":True}}]}
        selected,count=module.select_slides(p,False);self.assertEqual(selected,[("a",False)]);self.assertEqual(count,1)
    def test_hidden_included(self):
        p={"slides":[{"objectId":"b","slideProperties":{"isSkipped":True}}]}
        self.assertEqual(module.select_slides(p,True)[0],[("b",True)])
    def test_publish(self):
        p={"title":"T","slides":[{"objectId":"a","slideProperties":{}},{"objectId":"b","slideProperties":{"isSkipped":True}}]}
        with tempfile.TemporaryDirectory() as t:
            r=Path(t);player,_=assets(r);root=r/"cache";m=module.publish(self.cfg(),Source(p),root,player)
            self.assertEqual([x["objectId"] for x in m["slides"]],["a"]);self.assertTrue(module.cache_valid(root))
    def test_failed_sync_preserves_old_cache(self):
        with tempfile.TemporaryDirectory() as t:
            r=Path(t);player,_=assets(r);root=r/"cache";d=root/"versions"/"old"/"slides";d.mkdir(parents=True)
            (d.parent/"index.html").write_text("old");(d/"slide.png").write_bytes(PNG)
            old={"version":"old","slides":[{"file":"slides/slide.png"}]};(root/"cache-manifest.json").write_text(json.dumps(old));(root/"index.html").write_text("redirect")
            with self.assertRaises(module.CacheError):module.publish(self.cfg(),Source({"slides":[{"objectId":"x"}]},True),root,player)
            self.assertEqual((root/"index.html").read_text(),"redirect");self.assertTrue(module.cache_valid(root))
    def test_website_mode(self):
        with tempfile.TemporaryDirectory() as t:
            r=Path(t);player,fallback=assets(r);conf=r/"c";conf.write_text('CONTENT_MODE="website"\n');root=r/"cache"
            self.assertEqual(module.run(["--config",str(conf),"--cache-root",str(root),"--player-dir",str(player),"--fallback-dir",str(fallback)]),0)
            self.assertEqual((root/"index.html").read_text(),"fallback")
if __name__=="__main__":unittest.main()
