#ifndef STRING_H
#define STRING_H

#include <stddef.h>

char *strcpy(char *d, char *s);
    //@ requires [?f]string(s, ?cs) &*& chars(d, length(cs) + 1, _);
    //@ ensures [f]string(s, cs) &*& chars(d, length(cs) + 1, append(cs, {0})) &*& result == d;
    //@ terminates;

void memcpy(void *array, void *array0, size_t count);
    //@ requires chars_(array, count, _) &*& [?f]chars(array0, count, ?cs0);
    //@ ensures chars(array, count, cs0) &*& [f]chars(array0, count, cs0);
    //@ terminates;

void memmove(void *dest, void *src, size_t count);
    /*@
    requires
        chars(src, count, ?cs) &*&
        dest <= src ?
            chars(dest, src - dest, _)
        :
            chars_(src + count, dest - src, _);
    @*/
    /*@
    ensures
        chars(dest, count, cs) &*&
        dest <= src ?
            chars(dest + count, src - dest, _)
        :
            chars(src, dest - src, _);
    @*/
    //@ terminates;

size_t strlen(char *string);
    //@ requires [?f]string(string, ?cs);
    //@ ensures [f]string(string, cs) &*& result == length(cs);
    //@ terminates;

int memcmp(char *array, char *array0, size_t count);
    //@ requires [?f]chars(array, ?n, ?cs) &*& [?f0]chars(array0, ?n0, ?cs0) &*& count <= n &*& count <= n0;
    //@ ensures [f]chars(array, n, cs) &*& [f0]chars(array0, n0, cs0) &*& (result == 0) == (take(count, cs) == take(count, cs0));
    //@ terminates;

int strcmp(char *s1, char *s2);
    //@ requires [?f1]string(s1, ?cs1) &*& [?f2]string(s2, ?cs2);
    //@ ensures [f1]string(s1, cs1) &*& [f2]string(s2, cs2) &*& (result == 0) == (cs1 == cs2);
    //@ terminates;

char *memchr(char *array, char c, size_t count);
    //@ requires [?f]chars(array, count, ?cs);
    //@ ensures [f]chars(array, count, cs) &*& result == 0 ? mem(c, cs) == false : mem(c, cs) == true &*& result == array + index_of(c, cs);
    //@ terminates;

char* strchr(char *str, char c);
    //@ requires [?f]string(str, ?cs);
    /*@ ensures
            [f]string(str, cs) &*&
            c == 0 ? 
                result == str + length(cs)
            : 
                result == 0 ?
                    mem(c, cs) == false
                :
                    mem(c, cs) == true &*& result == str + index_of(c, cs);
    @*/
    //@ terminates;

void* memset(void *array, char value, size_t size);
    //@ requires chars_(array, size, _);
    //@ ensures chars(array, size, ?cs1) &*& all_eq(cs1, value) == true &*& result == array;
    //@ terminates;

char *strdup(char *string);
    //@ requires [?f]string(string, ?cs);
    //@ ensures [f]string(string, cs) &*& result == 0 ? true : string(result, cs) &*& malloc_block_chars(result, length(cs) + 1);
    //@ terminates;

#endif
