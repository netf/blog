// landlock-run: run a command under a Landlock ruleset, unprivileged.
//
//   landlock-run [-r PATH]... [-w PATH]... [-c PORT]... -- CMD [ARGS...]
//
//   -r PATH   allow read + execute beneath PATH
//   -w PATH   allow read, execute and every write/create/remove right beneath PATH
//   -c PORT   allow TCP connect() to PORT (any address; Landlock has no address rules)
//
// Everything not listed is denied: reading or writing other paths, and TCP connect to any
// other port. Landlock (ABI 4+) does not restrict UDP, which the lab measures.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/landlock.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define FS_READ (LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR)
#define FS_ALL                                                                                    \
  (FS_READ | LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_REMOVE_DIR |                      \
   LANDLOCK_ACCESS_FS_REMOVE_FILE | LANDLOCK_ACCESS_FS_MAKE_CHAR | LANDLOCK_ACCESS_FS_MAKE_DIR |  \
   LANDLOCK_ACCESS_FS_MAKE_REG | LANDLOCK_ACCESS_FS_MAKE_SOCK | LANDLOCK_ACCESS_FS_MAKE_FIFO |    \
   LANDLOCK_ACCESS_FS_MAKE_BLOCK | LANDLOCK_ACCESS_FS_MAKE_SYM | LANDLOCK_ACCESS_FS_REFER |       \
   LANDLOCK_ACCESS_FS_TRUNCATE)
#define FS_FILE_RIGHTS \
  (LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_WRITE_FILE | LANDLOCK_ACCESS_FS_TRUNCATE)

static void die(const char *what) { perror(what); exit(126); }

static void add_path(int rs, const char *p, uint64_t access) {
  int fd = open(p, O_PATH | O_CLOEXEC);
  if (fd < 0) return;  // missing paths (e.g. /lib64) are skipped
  struct stat st;
  if (fstat(fd, &st) == 0 && !S_ISDIR(st.st_mode)) access &= FS_FILE_RIGHTS;
  struct landlock_path_beneath_attr pb = {.allowed_access = access, .parent_fd = fd};
  if (syscall(SYS_landlock_add_rule, rs, LANDLOCK_RULE_PATH_BENEATH, &pb, 0)) die(p);
  close(fd);
}

int main(int argc, char **argv) {
  long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 4) { fprintf(stderr, "landlock ABI %ld < 4 (need network rules)\n", abi); return 126; }
  struct landlock_ruleset_attr attr = {
      .handled_access_fs = FS_ALL,
      .handled_access_net = LANDLOCK_ACCESS_NET_BIND_TCP | LANDLOCK_ACCESS_NET_CONNECT_TCP,
  };
  int rs = syscall(SYS_landlock_create_ruleset, &attr, sizeof(attr), 0);
  if (rs < 0) die("landlock_create_ruleset");

  int i = 1;
  for (; i < argc; i++) {
    if (!strcmp(argv[i], "--")) { i++; break; }
    if (i + 1 >= argc) { fprintf(stderr, "missing value for %s\n", argv[i]); return 2; }
    if (!strcmp(argv[i], "-r")) add_path(rs, argv[++i], FS_READ);
    else if (!strcmp(argv[i], "-w")) add_path(rs, argv[++i], FS_ALL);
    else if (!strcmp(argv[i], "-c")) {
      struct landlock_net_port_attr np = {.allowed_access = LANDLOCK_ACCESS_NET_CONNECT_TCP,
                                          .port = strtoull(argv[++i], NULL, 10)};
      if (syscall(SYS_landlock_add_rule, rs, LANDLOCK_RULE_NET_PORT, &np, 0)) die("net rule");
    } else { fprintf(stderr, "unknown flag %s\n", argv[i]); return 2; }
  }
  if (i >= argc) { fprintf(stderr, "no command\n"); return 2; }
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) die("no_new_privs");
  if (syscall(SYS_landlock_restrict_self, rs, 0)) die("landlock_restrict_self");
  close(rs);
  execvp(argv[i], argv + i);
  die(argv[i]);
}
