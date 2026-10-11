#ifndef CONFIG_H
#define CONFIG_H
#define DJVULIBRE_VERSION "3.5.28"
#define HAVE_BOOL 1
/* Define to 1 if you have the <dirent.h> header file, and it defines `DIR'.
   */
#define HAVE_DIRENT_H 1
#define HAVE_EXCEPTIONS 1
#define HAVE_FSEEKO 1
#define HAVE_GCCTLS 1
#define HAVE_GETHOSTNAME 1
#define HAVE_GETOPT_H 1
#define HAVE_GETPAGESIZE 1
#define HAVE_GETPWUID 1
#define HAVE_ICONV_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_ISWSPACE 1
#define HAVE_LANGINFO_H 1
#define HAVE_LIBM 1
#define HAVE_LONG_LONG_INT 1
#define HAVE_MBSTATE_T 1
#define HAVE_MEMBER_TEMPLATES 1
#define HAVE_MEMORY_H 1
#define HAVE_MKSTEMP 1
#define HAVE_MMAP 1
#define HAVE_NAMESPACES 1
#define HAVE_NL_LANGINFO 1
#define HAVE_PTHREAD 1
#define HAVE_PUTC_UNLOCKED 1
#define HAVE_SCHED_H 1
#define HAVE_SCHED_YIELD 1
#define HAVE_SETENV 1
#define HAVE_SIGACTION 1
#define HAVE_STDINCLUDES 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRERROR 1
#define HAVE_STRFTIME 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
/* Define to 1 if you have the <sys/dir.h> header file, and it defines `DIR'.
   */
#define HAVE_SYS_MMAN_H 1
/* Define to 1 if you have the <sys/ndir.h> header file, and it defines `DIR'.
   */
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_WAIT_H 1
#define HAVE_TYPENAME 1
#define HAVE_UNISTD_H 1
#define HAVE_VSNPRINTF 1
#define HAVE_WCHAR_H 1
#define HAVE_WCHAR_T 1
#define HAVE_WCRTOMB 1
#define HAVE_WCTYPE_H 1
#define PACKAGE "djvulibre"
#define PACKAGE_BUGREPORT ""
#define PACKAGE_NAME "djvulibre"
#define PACKAGE_STRING "djvulibre 3.5.28"
#define PACKAGE_TARNAME "djvulibre"
#define PACKAGE_URL ""
#define PACKAGE_VERSION "3.5.28"
#define STDC_HEADERS 1
#define TIME_WITH_SYS_TIME 1
#define VERSION "3.5.28"
#ifndef _DARWIN_USE_64_BIT_INODE
# define _DARWIN_USE_64_BIT_INODE 1
#endif
/* Define for Solaris 2.5.1 so the uint32_t typedef from <sys/synch.h>,
   <pthread.h>, or <semaphore.h> is not used. If the typedef were allowed, the
   #define below would cause a syntax error. */
/* Define to the type of a signed integer type of width exactly 16 bits if
   such a type exists and the standard includes do not define it. */
/* Define to the type of a signed integer type of width exactly 32 bits if
   such a type exists and the standard includes do not define it. */
/* Define to the type of an unsigned integer type of width exactly 16 bits if
   such a type exists and the standard includes do not define it. */
/* Define to the type of an unsigned integer type of width exactly 32 bits if
   such a type exists and the standard includes do not define it. */
#define AUTOCONF 1
#if defined(__CYGWIN32__) || !defined(_WIN32)
# define UNIX 1
#endif
#if !defined(HAVE_BOOL) && !defined(bool)
#define bool  char
#define true  1
#define false 0
#endif
#if ! defined(HAVE_WCHAR_T)
#define HAS_WCHAR 0
#define HAS_WCTYPE 0
#define HAS_MBSTATE 0
#else
#define HAS_WCHAR 1
#if defined(HAVE_WCTYPE_H) && defined(HAVE_ISWSPACE)
#define HAS_WCTYPE 1
#endif
#if defined(HAVE_MBSTATE_T) && defined(HAVE_WCRTOMB)
#define HAS_MBSTATE 1
#endif
#endif
#if defined(HAVE_ICONV_H) && defined(HAVE_ICONV)
#define HAS_ICONV 1
#else
#define HAS_ICONV 0
#endif
#define HAS_CTRL_C_IN_ERR_MSG 1
#ifndef HAVE_MEMBER_TEMPLATES
#define GCONTAINER_NO_MEMBER_TEMPLATES 1
#endif
#ifndef HAVE_TYPENAME
#define GCONTAINER_NO_TYPENAME 1
#endif
#ifdef HAVE_JPEG
#define NEED_JPEG_DECODER 1
#endif
#if defined(HAVE_MMAP) && defined(HAVE_SYS_MMAN_H)
#define HAS_MEMMAP 1
#else
#define HAS_MEMMAP 0
#endif
#endif
