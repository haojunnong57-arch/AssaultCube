#ifndef __ANDROID_LOG_STUB_H__
#define __ANDROID_LOG_STUB_H__
/* Minimal android/log.h replacement: route engine logging to stderr
   (stderr is redirected to Documents/assaultcube/ac_log.txt by ios/main.m). */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

#define ANDROID_LOG_UNKNOWN 0
#define ANDROID_LOG_DEFAULT 1
#define ANDROID_LOG_VERBOSE 2
#define ANDROID_LOG_DEBUG 3
#define ANDROID_LOG_INFO  4
#define ANDROID_LOG_WARN  5
#define ANDROID_LOG_ERROR 6
#define ANDROID_LOG_FATAL 7
#define ANDROID_LOG_SILENT 8

static inline int __android_log_print(int prio, const char *tag, const char *fmt, ...)
{
    va_list ap;
    (void)prio; (void)tag;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    return 0;
}

static inline int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap)
{
    (void)prio; (void)tag;
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    return 0;
}

static inline int __android_log_write(int prio, const char *tag, const char *text)
{
    (void)prio; (void)tag;
    fputs(text, stderr);
    fputc('\n', stderr);
    return 0;
}

static inline void __android_log_assert(const char *cond, const char *tag, const char *fmt, ...)
{
    va_list ap;
    (void)cond; (void)tag;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    abort();
}

#endif
