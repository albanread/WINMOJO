// Smallest target that still proves the windows-arm64 toolchain end to end:
// the clang driver, the MSVC STL headers found via -imsvc, and a CRT link.

#include <cstdio>
#include <string>
#include <vector>

int main() {
  std::vector<std::string> parts{"windows", "arm64", "clang"};
  std::string joined;
  for (const auto &part : parts) {
    if (!joined.empty()) {
      joined += "-";
    }
    joined += part;
  }

  std::printf("winmojo smoke ok: %s\n", joined.c_str());
  std::printf("pointer width: %zu bits\n", sizeof(void *) * 8);
  return 0;
}
