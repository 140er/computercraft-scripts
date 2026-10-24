"""Native keyboard and mouse input for the private test client's Xvfb display (XTest)."""
import ctypes
import ctypes.util
import os
import re
import subprocess
import time


class Input:
    def __init__(self, display):
        x11, xtst = ctypes.util.find_library("X11"), ctypes.util.find_library("Xtst")
        if not x11 or not xtst:
            raise RuntimeError("Native input needs libX11 and libXtst")
        self.x, self.t = ctypes.CDLL(x11), ctypes.CDLL(xtst)
        x, t = self.x, self.t
        x.XOpenDisplay.argtypes = [ctypes.c_char_p]; x.XOpenDisplay.restype = ctypes.c_void_p
        x.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]; x.XKeysymToKeycode.restype = ctypes.c_uint
        x.XStringToKeysym.argtypes = [ctypes.c_char_p]; x.XStringToKeysym.restype = ctypes.c_ulong
        x.XFlush.argtypes = [ctypes.c_void_p]
        x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        x.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        t.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        t.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        t.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
        self.d = x.XOpenDisplay(display.encode())
        if not self.d:
            raise RuntimeError(f"Cannot open X display {display}")
        tree = subprocess.run(["xwininfo", "-root", "-tree"], env={**os.environ, "DISPLAY": display},
                              capture_output=True, text=True, timeout=10).stdout
        window = re.search(r'\s+(0x[0-9a-f]+) "Minecraft', tree)
        if window:
            x.XSetInputFocus(self.d, int(window.group(1), 16), 2, 0); x.XFlush(self.d)

    def key(self, name, down):
        code = self.x.XKeysymToKeycode(self.d, self.x.XStringToKeysym(name.encode()))
        if not code:
            raise ValueError("Unknown key " + name)
        self.t.XTestFakeKeyEvent(self.d, code, int(down), 0); self.x.XFlush(self.d)

    def press(self, name):
        self.key(name, True); time.sleep(.2); self.key(name, False)

    def click(self, x, y, button=1):
        self.t.XTestFakeMotionEvent(self.d, -1, int(x), int(y), 0); self.x.XFlush(self.d); time.sleep(.08)
        self.t.XTestFakeButtonEvent(self.d, button, 1, 0); self.x.XFlush(self.d); time.sleep(.12)
        self.t.XTestFakeButtonEvent(self.d, button, 0, 0); self.x.XFlush(self.d); time.sleep(.1)

    def close(self):
        if self.d:
            self.x.XCloseDisplay(self.d); self.d = None
