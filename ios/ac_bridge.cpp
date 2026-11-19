// ac_bridge.cpp: the only C++ surface the native iOS UI talks to.
// Everything here is called on the main thread (UIKit + the engine main loop share it),
// so injecting key presses is safe without extra locking.

#include <SDL.h>

extern void keypress(int code, bool isdown, int cooked, SDL_Keymod mod);
extern int execute(const char *p);

// When the native settings sheet / key-capture is up the game must ignore input.
extern "C" int ac_ios_input_blocked = 0;

extern "C" void ac_ios_key(int code, int down)
{
    if (ac_ios_input_blocked) return;
    keypress(code, down != 0, code, KMOD_NONE);
}

// Force-release a key even while input is blocked (used when a sheet closes).
extern "C" void ac_ios_key_force(int code, int down)
{
    keypress(code, down != 0, code, KMOD_NONE);
}

extern "C" int ac_ios_exec(const char *cmd)
{
    if (!cmd) return 0;
    return execute(cmd);
}
