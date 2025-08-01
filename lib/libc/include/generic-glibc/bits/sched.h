/* Definitions of constants and data structure for POSIX 1003.1b-1993
   scheduling interface.
   Copyright (C) 1996-2025 Free Software Foundation, Inc.
   This file is part of the GNU C Library.

   The GNU C Library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   The GNU C Library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with the GNU C Library; if not, see
   <https://www.gnu.org/licenses/>.  */

#ifndef _BITS_SCHED_H
#define _BITS_SCHED_H 1

#ifndef _SCHED_H
# error "Never include <bits/sched.h> directly; use <sched.h> instead."
#endif

/* Scheduling algorithms.  */
#define SCHED_OTHER		0
#define SCHED_FIFO		1
#define SCHED_RR		2
#ifdef __USE_GNU
# define SCHED_NORMAL		0
# define SCHED_BATCH		3
# define SCHED_ISO		4
# define SCHED_IDLE		5
# define SCHED_DEADLINE		6
# define SCHED_EXT		7

/* Flags that can be used in policy values.  */
# define SCHED_RESET_ON_FORK	0x40000000

/* Flags for the sched_flags field in struct sched_attr.   */
#define SCHED_FLAG_RESET_ON_FORK	0x01
#define SCHED_FLAG_RECLAIM		0x02
#define SCHED_FLAG_DL_OVERRUN		0x04
#define SCHED_FLAG_KEEP_POLICY		0x08
#define SCHED_FLAG_KEEP_PARAMS		0x10
#define SCHED_FLAG_UTIL_CLAMP_MIN	0x20
#define SCHED_FLAG_UTIL_CLAMP_MAX	0x40

/* Combinations of sched_flags fields.  */
#define SCHED_FLAG_KEEP_ALL \
  (SCHED_FLAG_KEEP_POLICY | SCHED_FLAG_KEEP_PARAMS)
#define SCHED_FLAG_UTIL_CLAMP \
  (SCHED_FLAG_UTIL_CLAMP_MIN | SCHED_FLAG_UTIL_CLAMP_MAX)

/* Use "" to work around incorrect macro expansion of the
   __has_include argument (GCC PR 80005).  */
# ifdef __has_include
#  if __has_include ("linux/sched/types.h")
/* Some older Linux versions defined sched_param in <linux/sched/types.h>.  */
#   define sched_param __glibc_mask_sched_param
#   include <linux/sched/types.h>
#   undef sched_param
#  endif
# endif
# ifndef SCHED_ATTR_SIZE_VER0
#  include <linux/types.h>
#  define SCHED_ATTR_SIZE_VER0 48
#  define SCHED_ATTR_SIZE_VER1 56
struct sched_attr
{
  __u32 size;
  __u32 sched_policy;
  __u64 sched_flags;
  __s32 sched_nice;
  __u32 sched_priority;
  __u64 sched_runtime;
  __u64 sched_deadline;
  __u64 sched_period;
  __u32 sched_util_min;
  __u32 sched_util_max;
  /* Additional fields may be added at the end.  */
};
# endif /* !SCHED_ATTR_SIZE_VER0 */

/* Cloning flags.  */
# define CSIGNAL       0x000000ff /* Signal mask to be sent at exit.  */
# define CLONE_VM      0x00000100 /* Set if VM shared between processes.  */
# define CLONE_FS      0x00000200 /* Set if fs info shared between processes.  */
# define CLONE_FILES   0x00000400 /* Set if open files shared between processes.  */
# define CLONE_SIGHAND 0x00000800 /* Set if signal handlers shared.  */
# define CLONE_PIDFD   0x00001000 /* Set if a pidfd should be placed
				     in parent.  */
# define CLONE_PTRACE  0x00002000 /* Set if tracing continues on the child.  */
# define CLONE_VFORK   0x00004000 /* Set if the parent wants the child to
				     wake it up on mm_release.  */
# define CLONE_PARENT  0x00008000 /* Set if we want to have the same
				     parent as the cloner.  */
# define CLONE_THREAD  0x00010000 /* Set to add to same thread group.  */
# define CLONE_NEWNS   0x00020000 /* Set to create new namespace.  */
# define CLONE_SYSVSEM 0x00040000 /* Set to shared SVID SEM_UNDO semantics.  */
# define CLONE_SETTLS  0x00080000 /* Set TLS info.  */
# define CLONE_PARENT_SETTID 0x00100000 /* Store TID in userlevel buffer
					   before MM copy.  */
# define CLONE_CHILD_CLEARTID 0x00200000 /* Register exit futex and memory
					    location to clear.  */
# define CLONE_DETACHED 0x00400000 /* Create clone detached.  */
# define CLONE_UNTRACED 0x00800000 /* Set if the tracing process can't
				      force CLONE_PTRACE on this clone.  */
# define CLONE_CHILD_SETTID 0x01000000 /* Store TID in userlevel buffer in
					  the child.  */
# define CLONE_NEWCGROUP    0x02000000	/* New cgroup namespace.  */
# define CLONE_NEWUTS	0x04000000	/* New utsname group.  */
# define CLONE_NEWIPC	0x08000000	/* New ipcs.  */
# define CLONE_NEWUSER	0x10000000	/* New user namespace.  */
# define CLONE_NEWPID	0x20000000	/* New pid namespace.  */
# define CLONE_NEWNET	0x40000000	/* New network namespace.  */
# define CLONE_IO	0x80000000	/* Clone I/O context.  */

/* cloning flags intersect with CSIGNAL so can be used only with unshare and
   clone3 syscalls.  */
#define CLONE_NEWTIME	0x00000080      /* New time namespace */
#endif

#include <bits/types/struct_sched_param.h>

__BEGIN_DECLS

#ifdef __USE_GNU
/* Clone current process.  */
extern int clone (int (*__fn) (void *__arg), void *__child_stack,
		  int __flags, void *__arg, ...) __THROW;

/* Unshare the specified resources.  */
extern int unshare (int __flags) __THROW;

/* Get index of currently used CPU.  */
extern int sched_getcpu (void) __THROW;

/* Get currently used CPU and NUMA node.  */
extern int getcpu (unsigned int *, unsigned int *) __THROW;

/* Switch process to namespace of type NSTYPE indicated by FD.  */
extern int setns (int __fd, int __nstype) __THROW;

/* Apply the scheduling attributes from *ATTR to the process or thread TID.  */
int sched_setattr (pid_t tid, struct sched_attr *attr, unsigned int flags)
  __THROW __nonnull ((2));

/* Obtain the scheduling attributes of the process or thread TID and
   store it in *ATTR.  */
int sched_getattr (pid_t tid, struct sched_attr *attr, unsigned int size,
		   unsigned int flags)
  __THROW __nonnull ((2));

#endif

__END_DECLS

#endif /* bits/sched.h */