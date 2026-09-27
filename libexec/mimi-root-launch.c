/*
 * mimi-root-launch — the only program mimi asks sudo to run.
 *
 * It starts the bash helper with a fixed environment, so BASH_ENV and
 * SHELLOPTS from the caller are not applied before the helper's first line.
 * The helper it starts is the mimi-root-apply sitting in the same directory,
 * which is the root-owned copy, not the user-writable one in the repo.
 */
#include <errno.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static void die(const char *msg) {
    fprintf(stderr, "mimi-root-launch: %s\n", msg);
    exit(1);
}

int main(int argc, char **argv) {
    const char *test_flag = getenv("MIMI_ROOT_TEST");
    int testing = test_flag != NULL && strcmp(test_flag, "1") == 0;
    if (!testing && geteuid() != 0) {
        die("this needs root: run it with sudo");
    }

    char *owned = strdup(argv[0] != NULL ? argv[0] : "");
    if (owned == NULL) {
        die("out of memory");
    }
    char *dir = dirname(owned);
    char script[4096];
    int n = snprintf(script, sizeof script, "%s/mimi-root-apply", dir);
    if (n < 0 || (size_t)n >= sizeof script) {
        die("helper path is too long");
    }

    struct stat st;
    if (lstat(script, &st) != 0 || S_ISLNK(st.st_mode) || !S_ISREG(st.st_mode)) {
        die("mimi-root-apply next to this launcher is missing or is a symlink");
    }
    if (!testing && (st.st_uid != 0 || (st.st_mode & 022) != 0)) {
        die("mimi-root-apply is not a root-owned, non-writable file");
    }

    char **args = calloc((size_t)argc + 4, sizeof(char *));
    if (args == NULL) {
        die("out of memory");
    }
    args[0] = "/bin/bash";
    args[1] = "--noprofile";
    args[2] = "--norc";
    args[3] = script;
    for (int i = 1; i < argc; i++) {
        args[i + 3] = argv[i];
    }
    args[argc + 3] = NULL;

    char path_env[] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin";
    char ifs_env[] = "IFS= \t\n";
    char test_env[] = "MIMI_ROOT_TEST=1";
    char prefix_env[4096];
    char *envp[6];
    int e = 0;
    envp[e++] = path_env;
    envp[e++] = ifs_env;
    if (testing) {
        envp[e++] = test_env;
        const char *prefix = getenv("MIMI_ROOT_PREFIX");
        if (prefix != NULL) {
            int pn = snprintf(prefix_env, sizeof prefix_env, "MIMI_ROOT_PREFIX=%s", prefix);
            if (pn < 0 || (size_t)pn >= sizeof prefix_env) {
                die("test prefix is too long");
            }
            envp[e++] = prefix_env;
        }
    }
    envp[e] = NULL;

    execve("/bin/bash", args, envp);
    fprintf(stderr, "mimi-root-launch: execve: %s\n", strerror(errno));
    return 1;
}
