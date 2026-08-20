/*===----------------------------------------------------------------------===*\
|*
|* `sleep` for the Windows test environment. See echo.c for why these exist.
|*
|* test_process uses this as a process that stays alive long enough to be
|* killed, so the only thing that matters is that it blocks and does not exit
|* on its own.
|*
\*===----------------------------------------------------------------------===*/

#include <stdio.h>
#include <stdlib.h>

#include <windows.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "sleep: missing operand\n");
    return 1;
  }

  /* sleep(1) accepts a decimal, so parse as a double rather than an int. */
  double seconds = atof(argv[1]);
  if (seconds < 0.0) {
    fprintf(stderr, "sleep: invalid time interval '%s'\n", argv[1]);
    return 1;
  }

  /* Saturate rather than overflow DWORD milliseconds: a long sleep here is
   * always killed by the test, never waited out, so the ceiling is harmless
   * and wrapping to a short sleep would make the kill test pass vacuously. */
  double ms = seconds * 1000.0;
  DWORD interval = (ms >= (double)(INFINITE - 1)) ? (INFINITE - 1) : (DWORD)ms;

  Sleep(interval);
  return 0;
}
