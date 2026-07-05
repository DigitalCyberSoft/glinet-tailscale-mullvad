#!/usr/bin/env python3
"""Reproducible builder for gl-sdk4-tailscale-mullvad.

Same container rules as glinet-tailscale-feed/gui-src/build.py: GL's opkg only
extracts the *gzip-tar* .ipk container, so that is what this produces:

    <ipk> = gzip( tar( ./debian-binary, ./data.tar.gz, ./control.tar.gz ) )

Differences from the feed builder:
  * control.tar.gz also carries postinst/prerm (mode 0755) - this package
    patches a file owned by gl-sdk4-ui-tailscaleview at install time instead of
    shipping it (opkg refuses file clashes between packages).
  * Before packaging, the on-device patch is SIMULATED here against
    test/view-reference.js (vendored copy of the feed's decompressed bundle,
    version git-2025.244.27716-e9a0fdd) using the same anchors patch-view.lua
    uses, and the result is syntax-checked with `node --check`. A failure
    aborts the build: never ship snippets that cannot splice cleanly.

Usage:
    ./build.py            # verify + build -> out/
Output is deterministic (fixed mtime, sorted entries, uid/gid 0).
"""
import io, os, re, sys, gzip, shutil, tarfile, tempfile, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
PKG  = os.path.join(HERE, "gl-sdk4-tailscale-mullvad")
OUT  = os.path.join(HERE, "out")

# must stay in sync with data/usr/libexec/tailscale-mullvad/patch-view.lua
A_RENDER = ',t.hasDnsWarning?e("li"'
A_BLOCK  = "p=d.exports;e.default=p"
MARK     = "/*tsmullvad:v1*/"


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def node_check(js, label):
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(js)
        tmp = f.name
    try:
        r = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"verify: node --check failed for {label}:\n{r.stderr}")
    finally:
        os.unlink(tmp)


def simulate_patch(view_src, render, block):
    """Python mirror of patch-view.lua apply(); returns the patched source."""
    for name, anchor in (("render", A_RENDER), ("block", A_BLOCK)):
        n = view_src.count(anchor)
        if n != 1:
            sys.exit(f"verify: {name} anchor matched {n} times in reference view.js (need exactly 1)")
    i = view_src.index(A_RENDER)
    out = view_src[:i] + "," + render + view_src[i:]
    j = out.index(A_BLOCK)
    out = out[:j] + "p=d.exports;(" + block + ")(p);e.default=p" + out[j + len(A_BLOCK):]
    return MARK + out


def verify():
    render = read(os.path.join(PKG, "data/usr/share/tailscale-mullvad/render.js")).rstrip()
    block  = read(os.path.join(PKG, "data/usr/share/tailscale-mullvad/block.js")).rstrip()
    ref    = read(os.path.join(HERE, "test/view-reference.js"))

    # each snippet standalone (as the expression context it is spliced into)
    node_check(f"var t,e;var x=({render});", "render.js (standalone expression)")
    node_check(f"var f=({block});", "block.js (standalone expression)")
    # the full patched bundle, exactly as it would exist on the device
    node_check(simulate_patch(ref, render, block), "patched view.js (full bundle)")
    print("verify: anchors unique, render/block/patched bundle all pass node --check")


def make_tar_gz(src_dir, out_path, executables=()):
    entries = []
    for root, dirs, files in os.walk(src_dir):
        dirs.sort()
        for name in sorted(dirs) + sorted(files):
            full = os.path.join(root, name)
            entries.append((full, "./" + os.path.relpath(full, src_dir)))
    entries.sort(key=lambda e: e[1])
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tar:
        top = tarfile.TarInfo("./"); top.type = tarfile.DIRTYPE; top.mode = 0o755; top.mtime = 0
        tar.addfile(top)
        for full, rel in entries:
            ti = tar.gettarinfo(full, rel)
            ti.uid = ti.gid = 0; ti.uname = ti.gname = ""; ti.mtime = 0
            if rel.lstrip("./") in executables or full.endswith(".lua"):
                ti.mode = 0o755
            if ti.isreg():
                with open(full, "rb") as f:
                    tar.addfile(ti, f)
            else:
                tar.addfile(ti)
    with open(out_path, "wb") as fo:
        with gzip.GzipFile(fileobj=fo, mode="wb", mtime=0) as gz:
            gz.write(raw.getvalue())


def build():
    ctrl = read(os.path.join(PKG, "control"))
    name = re.search(r"^Package:\s*(\S+)", ctrl, re.M).group(1)
    ver  = re.search(r"^Version:\s*(\S+)",  ctrl, re.M).group(1)
    arch = re.search(r"^Architecture:\s*(\S+)", ctrl, re.M).group(1)
    work = tempfile.mkdtemp()
    try:
        stage = os.path.join(work, "data")
        shutil.copytree(os.path.join(PKG, "data"), stage)
        make_tar_gz(stage, os.path.join(work, "data.tar.gz"))

        cdir = os.path.join(work, "control"); os.makedirs(cdir)
        with open(os.path.join(cdir, "control"), "w") as f:
            f.write(ctrl)
        for script in ("postinst", "prerm"):
            src = os.path.join(PKG, script)
            if os.path.exists(src):
                shutil.copy(src, os.path.join(cdir, script))
        make_tar_gz(cdir, os.path.join(work, "control.tar.gz"),
                    executables=("postinst", "prerm"))

        with open(os.path.join(work, "debian-binary"), "w") as f:
            f.write("2.0\n")
        os.makedirs(OUT, exist_ok=True)
        out = os.path.join(OUT, f"{name}_{ver}_{arch}.ipk")
        subprocess.run(
            ["tar", "--numeric-owner", "--owner=0", "--group=0", "--mtime=@0",
             "-czf", out, "-C", work,
             "./debian-binary", "./data.tar.gz", "./control.tar.gz"], check=True)
        print(f"built {os.path.relpath(out, HERE)}  ({os.path.getsize(out)} bytes)")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    verify()
    build()
