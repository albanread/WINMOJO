//===----------------------------------------------------------------------===//
//
// A POSIX shim for the entry points the Mojo standard library calls by name.
//
// The standard library reaches libc through `external_call["name", ...]`, so
// these have to exist as C symbols at link time or every program that touches
// os/subprocess/file_descriptor fails to link. The MSVC CRT supplies most of
// what it wants: `oldnames.lib` aliases the legacy set (open, read, write, dup,
// stat, chdir, ...) to their underscore-prefixed spellings, and `_popen` and
// `_pclose` exist under those names. What is left has no CRT equivalent at all
// and is implemented here on Win32.
//
// The aim is behavioural equivalence at the call sites the standard library
// actually has -- not a general POSIX layer. Where Windows cannot express a
// POSIX guarantee, the difference is commented rather than papered over.
//
// GNU's Windows ports (Cygwin, MSYS2, glibc) are GPL and cannot be used here;
// this file is written against the Win32 API directly and stays under the
// repository's Apache-2.0-with-LLVM-exceptions licence.
//
//===----------------------------------------------------------------------===//

#ifdef _WIN32

#include "Support/SymbolExport.h"

#include <windows.h>

#include <errno.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <string>

// Linux's PATH_MAX. The standard library sizes its realpath destination buffer
// against this value, so we must not write more than this into a caller buffer
// even though Windows itself permits considerably longer paths.
#define KGEN_POSIX_PATH_MAX 4096

#define KGEN_FD_CLOEXEC 1
#define KGEN_F_GETFD 1
#define KGEN_F_SETFD 2

namespace {

/// Translate a Win32 error into the closest errno value. Only the codes these
/// entry points can actually produce are mapped; anything else becomes EINVAL,
/// which is at least an error rather than a spurious success.
int errnoFromWin32(DWORD err) {
  switch (err) {
  case ERROR_FILE_NOT_FOUND:
  case ERROR_PATH_NOT_FOUND:
  case ERROR_INVALID_DRIVE:
    return ENOENT;
  case ERROR_ACCESS_DENIED:
  case ERROR_SHARING_VIOLATION:
    return EACCES;
  case ERROR_FILE_EXISTS:
  case ERROR_ALREADY_EXISTS:
    return EEXIST;
  case ERROR_NOT_SAME_DEVICE:
    return EXDEV;
  case ERROR_TOO_MANY_LINKS:
    return EMLINK;
  case ERROR_DIRECTORY:
  case ERROR_INVALID_NAME:
    return EINVAL;
  case ERROR_FILENAME_EXCED_RANGE:
    return ENAMETOOLONG;
  case ERROR_NOT_ENOUGH_MEMORY:
  case ERROR_OUTOFMEMORY:
    return ENOMEM;
  case ERROR_PRIVILEGE_NOT_HELD:
    // CreateSymbolicLinkW without Developer Mode or SeCreateSymbolicLink.
    return EPERM;
  default:
    return EINVAL;
  }
}

void setErrnoFromWin32() { errno = errnoFromWin32(::GetLastError()); }

/// UTF-8 to UTF-16. Mojo strings are UTF-8, so every path crossing into a
/// Win32 W-suffixed call goes through here. Returns false on malformed input.
bool widen(const char *utf8, std::wstring &out) {
  if (!utf8) {
    errno = EINVAL;
    return false;
  }
  int n = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1,
                                nullptr, 0);
  if (n <= 0) {
    errno = EINVAL;
    return false;
  }
  out.resize(static_cast<size_t>(n - 1));
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8, -1, &out[0],
                            n) <= 0) {
    errno = EINVAL;
    return false;
  }
  return true;
}

/// UTF-16 back to UTF-8.
bool narrow(const wchar_t *wide, std::string &out) {
  int n = ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr,
                                nullptr);
  if (n <= 0) {
    errno = EINVAL;
    return false;
  }
  out.resize(static_cast<size_t>(n - 1));
  if (::WideCharToMultiByte(CP_UTF8, 0, wide, -1, &out[0], n, nullptr,
                            nullptr) <= 0) {
    errno = EINVAL;
    return false;
  }
  return true;
}

/// Open a path purely to identify it. FILE_FLAG_BACKUP_SEMANTICS is what makes
/// a directory openable as a handle; without it this works on files only.
HANDLE openForQuery(const wchar_t *path) {
  return ::CreateFileW(path, /*dwDesiredAccess=*/0,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       /*lpSecurityAttributes=*/nullptr, OPEN_EXISTING,
                       FILE_FLAG_BACKUP_SEMANTICS, /*hTemplateFile=*/nullptr);
}

/// Resolve a handle to its canonical DOS path, with the \\?\ prefix removed.
/// GetFinalPathNameByHandleW always returns the extended-length form; POSIX
/// callers expect a plain path, and the prefix leaks into error messages and
/// string comparisons if left in place.
bool finalPathOf(HANDLE h, std::wstring &out) {
  DWORD n = ::GetFinalPathNameByHandleW(h, nullptr, 0,
                                        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (n == 0)
    return false;
  out.resize(n);
  DWORD written = ::GetFinalPathNameByHandleW(
      h, &out[0], n, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (written == 0 || written >= n)
    return false;
  out.resize(written);

  // "\\?\UNC\server\share" is a UNC path; restore its "\\server\share" form.
  if (out.compare(0, 8, L"\\\\?\\UNC\\") == 0)
    out = L"\\\\" + out.substr(8);
  else if (out.compare(0, 4, L"\\\\?\\") == 0)
    out = out.substr(4);
  return true;
}

} // namespace

//===----------------------------------------------------------------------===//
// Link creation
//===----------------------------------------------------------------------===//

/// POSIX symlink(2). Note the argument order inverts: POSIX names the target
/// first, CreateSymbolicLinkW names the link first.
///
/// Windows distinguishes file and directory symlinks at creation time, so the
/// target has to be probed. A dangling symlink -- legal under POSIX -- is
/// therefore created as a file symlink, which is the closest available
/// behaviour but is not identical if the target later appears as a directory.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int
symlink(const char *target, const char *linkpath) {
  std::wstring wTarget, wLink;
  if (!widen(target, wTarget) || !widen(linkpath, wLink))
    return -1;

  DWORD flags = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
  DWORD attrs = ::GetFileAttributesW(wTarget.c_str());
  if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY))
    flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;

  if (!::CreateSymbolicLinkW(wLink.c_str(), wTarget.c_str(), flags)) {
    setErrnoFromWin32();
    return -1;
  }
  return 0;
}

/// POSIX link(2). The argument order inverts here too.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int link(const char *oldpath,
                                                        const char *newpath) {
  std::wstring wOld, wNew;
  if (!widen(oldpath, wOld) || !widen(newpath, wNew))
    return -1;

  if (!::CreateHardLinkW(wNew.c_str(), wOld.c_str(),
                         /*lpSecurityAttributes=*/nullptr)) {
    setErrnoFromWin32();
    return -1;
  }
  return 0;
}

//===----------------------------------------------------------------------===//
// Path resolution
//===----------------------------------------------------------------------===//

/// POSIX realpath(3). Resolves symlinks and returns an absolute canonical path.
///
/// The resolution is done by opening the file and asking Windows what it
/// actually opened, which follows symlinks and normalises case and short
/// (8.3) names the way POSIX expects. It also inherits POSIX's requirement
/// that the path exist: a missing component yields ENOENT rather than a
/// syntactically-cleaned string.
///
/// When `resolved` is null a buffer is allocated with malloc, which the caller
/// frees. That is only safe because every module in this build shares one CRT
/// heap (`-fms-runtime-lib=dll`); under a static CRT this allocation would be
/// freed against a different heap.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT char *
realpath(const char *path, char *resolved) {
  std::wstring wPath;
  if (!widen(path, wPath))
    return nullptr;

  HANDLE h = openForQuery(wPath.c_str());
  if (h == INVALID_HANDLE_VALUE) {
    setErrnoFromWin32();
    return nullptr;
  }

  std::wstring wFinal;
  bool ok = finalPathOf(h, wFinal);
  DWORD err = ::GetLastError();
  ::CloseHandle(h);
  if (!ok) {
    errno = errnoFromWin32(err);
    return nullptr;
  }

  std::string utf8;
  if (!narrow(wFinal.c_str(), utf8))
    return nullptr;

  if (resolved) {
    // The caller's buffer is PATH_MAX by contract and carries no length, so a
    // longer Windows path has to be refused rather than truncated.
    if (utf8.size() + 1 > KGEN_POSIX_PATH_MAX) {
      errno = ENAMETOOLONG;
      return nullptr;
    }
    ::memcpy(resolved, utf8.c_str(), utf8.size() + 1);
    return resolved;
  }

  char *out = static_cast<char *>(::malloc(utf8.size() + 1));
  if (!out) {
    errno = ENOMEM;
    return nullptr;
  }
  ::memcpy(out, utf8.c_str(), utf8.size() + 1);
  return out;
}

//===----------------------------------------------------------------------===//
// Descriptor operations
//===----------------------------------------------------------------------===//

/// POSIX fchdir(2). Windows has no directory-handle form of
/// SetCurrentDirectory, so the handle is resolved back to a path first. The
/// POSIX guarantee this loses is atomicity: if the directory is renamed
/// between the two calls, we follow the name rather than the handle.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int fchdir(int fd) {
  HANDLE h = reinterpret_cast<HANDLE>(::_get_osfhandle(fd));
  if (h == INVALID_HANDLE_VALUE) {
    errno = EBADF;
    return -1;
  }

  std::wstring wPath;
  if (!finalPathOf(h, wPath)) {
    setErrnoFromWin32();
    return -1;
  }

  if (!::SetCurrentDirectoryW(wPath.c_str())) {
    setErrnoFromWin32();
    return -1;
  }
  return 0;
}

/// POSIX fcntl(2), restricted to the commands the standard library issues:
/// F_GETFD and F_SETFD carrying FD_CLOEXEC.
///
/// Windows expresses the same idea inverted -- a handle is either inheritable
/// or not, and close-on-exec is the absence of inheritance -- so the flag is
/// negated in both directions. Any other command is rejected with EINVAL
/// rather than silently succeeding, since a quiet no-op here would surface as
/// a descriptor leak somewhere far away.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int fcntl(int fd, int cmd, ...) {
  HANDLE h = reinterpret_cast<HANDLE>(::_get_osfhandle(fd));
  if (h == INVALID_HANDLE_VALUE) {
    errno = EBADF;
    return -1;
  }

  switch (cmd) {
  case KGEN_F_GETFD: {
    DWORD flags = 0;
    if (!::GetHandleInformation(h, &flags)) {
      setErrnoFromWin32();
      return -1;
    }
    return (flags & HANDLE_FLAG_INHERIT) ? 0 : KGEN_FD_CLOEXEC;
  }
  case KGEN_F_SETFD: {
    va_list ap;
    va_start(ap, cmd);
    int want = va_arg(ap, int);
    va_end(ap);
    DWORD inherit = (want & KGEN_FD_CLOEXEC) ? 0 : HANDLE_FLAG_INHERIT;
    if (!::SetHandleInformation(h, HANDLE_FLAG_INHERIT, inherit)) {
      setErrnoFromWin32();
      return -1;
    }
    return 0;
  }
  default:
    errno = EINVAL;
    return -1;
  }
}

//===----------------------------------------------------------------------===//
// stdio
//===----------------------------------------------------------------------===//

/// POSIX getline(3). Reads through the next newline, growing *lineptr as
/// needed; the newline is kept, and the result is always NUL-terminated.
/// Returns the byte count, or -1 at end of file or on error.
///
/// The buffer is malloc/realloc'd for the caller to free -- see the note on
/// realpath about why that is sound in this build.
COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT ptrdiff_t
getline(char **lineptr, size_t *n, FILE *stream) {
  if (!lineptr || !n || !stream) {
    errno = EINVAL;
    return -1;
  }

  if (!*lineptr || *n == 0) {
    size_t cap = 128;
    char *buf = static_cast<char *>(::malloc(cap));
    if (!buf) {
      errno = ENOMEM;
      return -1;
    }
    *lineptr = buf;
    *n = cap;
  }

  size_t len = 0;
  for (;;) {
    int ch = ::getc(stream);
    if (ch == EOF) {
      // A partial final line without a trailing newline is still a line.
      if (len == 0)
        return -1;
      break;
    }

    // Keep one byte spare so the terminator always fits.
    if (len + 1 >= *n) {
      size_t cap = *n * 2;
      char *buf = static_cast<char *>(::realloc(*lineptr, cap));
      if (!buf) {
        errno = ENOMEM;
        return -1;
      }
      *lineptr = buf;
      *n = cap;
    }

    (*lineptr)[len++] = static_cast<char>(ch);
    if (ch == '\n')
      break;
  }

  (*lineptr)[len] = '\0';
  return static_cast<ptrdiff_t>(len);
}

//===----------------------------------------------------------------------===//
// Process pipes
//===----------------------------------------------------------------------===//
//
// The CRT has these under underscore-prefixed names and `oldnames.lib` does
// not alias them, so they are forwarded rather than reimplemented.

COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT FILE *popen(const char *command,
                                                           const char *mode) {
  return ::_popen(command, mode);
}

COMPILERRT_EXPORT COMPILERRT_VISIBILITY_EXPORT int pclose(FILE *stream) {
  return ::_pclose(stream);
}

#endif // _WIN32
