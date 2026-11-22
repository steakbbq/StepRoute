"""Run a Lua 5.1 file through the LuaJIT lua51.dll that OBS installs (no luac or lua.exe on this PC).

    python -I tools\\lua_runner.py check <file.lua> ...    compile only (luaL_loadbuffer), no code runs
    python -I tools\\lua_runner.py run   <file.lua>        run the file; exit 1 on a Lua error

`run` first sets the Lua globals HERE (folder of the file) and SRC (HERE\\..\\src).
LuaJIT is not byte-identical to PUC Lua 5.1; the addon uses plain 5.1 syntax and library only.
"""
import ctypes
import os
import sys

DLL = r"C:\Program Files\obs-studio\bin\64bit\lua51.dll"

L = ctypes.CDLL(DLL)
vp = ctypes.c_void_p
L.luaL_newstate.restype = vp
L.luaL_openlibs.argtypes = [vp]
L.luaL_loadbuffer.argtypes = [vp, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
L.luaL_loadbuffer.restype = ctypes.c_int
L.lua_pcall.argtypes = [vp, ctypes.c_int, ctypes.c_int, ctypes.c_int]
L.lua_pcall.restype = ctypes.c_int
L.lua_tolstring.argtypes = [vp, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)]
L.lua_tolstring.restype = ctypes.c_char_p
L.lua_settop.argtypes = [vp, ctypes.c_int]


def last_error(state):
    msg = L.lua_tolstring(state, -1, None)
    L.lua_settop(state, -2)
    return (msg or b"?").decode("utf-8", "replace")


def load(state, data, name):
    if L.luaL_loadbuffer(state, data, len(data), name.encode()) != 0:
        return last_error(state)
    return None


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("check", "run"):
        print(__doc__)
        return 2
    mode, files = sys.argv[1], sys.argv[2:]
    bad = 0
    for path in files:
        path = os.path.abspath(path)
        state = L.luaL_newstate()
        L.luaL_openlibs(state)
        if mode == "run":
            here = os.path.dirname(path).replace("\\", "/")
            src = os.path.normpath(os.path.join(os.path.dirname(path), "..", "src")).replace("\\", "/")
            pre = ('HERE = "%s"\nSRC = "%s"\n' % (here, src)).encode()
            if load(state, pre, "=prelude") or L.lua_pcall(state, 0, 0, 0) != 0:
                print("FAIL prelude")
                bad += 1
                continue
        data = open(path, "rb").read()
        err = load(state, data, "@" + path)
        if err:
            print("FAIL compile", err)
            bad += 1
            continue
        if mode == "check":
            print("ok  ", path)
            continue
        if L.lua_pcall(state, 0, 0, 0) != 0:
            print("FAIL run", last_error(state))
            bad += 1
        else:
            print("ok  ", path)
        sys.stdout.flush()
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
