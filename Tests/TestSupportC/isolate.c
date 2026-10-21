// Isolates the whole test process as it loads, before any test of any target runs: no test can read the user's own
// ~/.kelp, ~/.claude, ~/.codex, keychain or git config, whichever target runs first or alone. (Swift has no load-time
// code; a C constructor runs when the test bundle is loaded.)
#include "TestSupportC.h"
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char root[64];

static void put(const char *key, const char *dir) {
    char v[PATH_MAX];
    snprintf(v, sizeof v, "%s%s", root, dir);
    setenv(key, v, 1);
}

__attribute__((constructor)) static void kelp_isolate(void) {
    // Short: a Unix socket path inside it has to fit in 104 bytes. Removed when the process exits (TestIsolation).
    snprintf(root, sizeof root, "/tmp/kr-XXXXXX");
    if (!mkdtemp(root)) { root[0] = 0; return; }
    put("KELP_HOME", "/home");
    put("CLAUDE_CONFIG_DIR", "/claude");
    put("CODEX_HOME", "/codex");
    const char *path = getenv("PATH");
    setenv("KELP_LOGIN_PATH", path ? path : "/usr/bin:/bin", 1);   // no login shell, so no profile runs
    char service[96];
    snprintf(service, sizeof service, "dev.kelp.tests.%s.%d", root + 8, (int)getpid());
    setenv("KELP_KEYCHAIN_SERVICE", service, 1);
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1);
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1);
    setenv("KELP_TEST_ISOLATED", "1", 1);
    // In-process daemons take this test process for Kelp's window (only it may trust a project's commands).
    char exe[PATH_MAX], real[PATH_MAX];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) == 0 && realpath(exe, real)) setenv("KELP_APP_EXECUTABLE", real, 1);
}

const char *kelp_test_root(void) { return root; }
