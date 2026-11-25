// Counts heap allocations for the comparison runners when inserted with DYLD_INSERT_LIBRARIES.
//
// Each malloc-family call and each anonymous mmap counts once. Allocator entry points forward to
// one another inside libmalloc, so a per-thread depth keeps a forwarded call from counting twice.
// Runners read the total through comparison_allocations() before and after each measured pass.
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>

typedef unsigned long long malloc_type_id_t;
extern void *malloc_type_malloc(size_t, malloc_type_id_t);
extern void *malloc_type_calloc(size_t, size_t, malloc_type_id_t);
extern void *malloc_type_realloc(void *, size_t, malloc_type_id_t);
extern int malloc_type_posix_memalign(void **, size_t, size_t, malloc_type_id_t);
extern void *malloc_type_aligned_alloc(size_t, size_t, malloc_type_id_t);
extern void *malloc_type_zone_malloc(malloc_zone_t *, size_t, malloc_type_id_t);
extern void *malloc_type_zone_calloc(malloc_zone_t *, size_t, size_t, malloc_type_id_t);
extern void *malloc_type_zone_realloc(malloc_zone_t *, void *, size_t, malloc_type_id_t);
extern void *malloc_type_zone_memalign(malloc_zone_t *, size_t, size_t, malloc_type_id_t);

static _Atomic uint64_t total;
static pthread_key_t depth_key;
static int ready;

__attribute__((constructor)) static void prepare(void) { ready = pthread_key_create(&depth_key, NULL) == 0; }

uint64_t comparison_allocations(void) { return atomic_load_explicit(&total, memory_order_relaxed); }

static uintptr_t enter(void) {
  if (!ready) return 1;
  uintptr_t depth = (uintptr_t)pthread_getspecific(depth_key);
  if (depth == 0) atomic_fetch_add_explicit(&total, 1, memory_order_relaxed);
  pthread_setspecific(depth_key, (void *)(depth + 1));
  return depth;
}

static void leave(uintptr_t depth) {
  if (ready) pthread_setspecific(depth_key, (void *)depth);
}

#define COUNTED(type, name, params, args)      \
  static type counted_##name params {          \
    uintptr_t depth = enter();                 \
    type result = name args;                   \
    leave(depth);                              \
    return result;                             \
  }

COUNTED(void *, malloc, (size_t n), (n))
COUNTED(void *, calloc, (size_t c, size_t n), (c, n))
COUNTED(void *, realloc, (void *p, size_t n), (p, n))
COUNTED(int, posix_memalign, (void **p, size_t a, size_t n), (p, a, n))
COUNTED(void *, aligned_alloc, (size_t a, size_t n), (a, n))
COUNTED(void *, malloc_zone_malloc, (malloc_zone_t *z, size_t n), (z, n))
COUNTED(void *, malloc_zone_calloc, (malloc_zone_t *z, size_t c, size_t n), (z, c, n))
COUNTED(void *, malloc_zone_realloc, (malloc_zone_t *z, void *p, size_t n), (z, p, n))
COUNTED(void *, malloc_zone_memalign, (malloc_zone_t *z, size_t a, size_t n), (z, a, n))
COUNTED(void *, malloc_type_malloc, (size_t n, malloc_type_id_t t), (n, t))
COUNTED(void *, malloc_type_calloc, (size_t c, size_t n, malloc_type_id_t t), (c, n, t))
COUNTED(void *, malloc_type_realloc, (void *p, size_t n, malloc_type_id_t t), (p, n, t))
COUNTED(int, malloc_type_posix_memalign, (void **p, size_t a, size_t n, malloc_type_id_t t), (p, a, n, t))
COUNTED(void *, malloc_type_aligned_alloc, (size_t a, size_t n, malloc_type_id_t t), (a, n, t))
COUNTED(void *, malloc_type_zone_malloc, (malloc_zone_t *z, size_t n, malloc_type_id_t t), (z, n, t))
COUNTED(void *, malloc_type_zone_calloc, (malloc_zone_t *z, size_t c, size_t n, malloc_type_id_t t), (z, c, n, t))
COUNTED(void *, malloc_type_zone_realloc, (malloc_zone_t *z, void *p, size_t n, malloc_type_id_t t), (z, p, n, t))
COUNTED(void *, malloc_type_zone_memalign, (malloc_zone_t *z, size_t a, size_t n, malloc_type_id_t t), (z, a, n, t))

// Page allocators map anonymous memory directly instead of calling malloc.
static void *counted_mmap(void *address, size_t length, int protection, int flags, int descriptor, off_t offset) {
  uintptr_t depth = (flags & MAP_ANON) ? enter() : 1;
  void *result = mmap(address, length, protection, flags, descriptor, offset);
  if (flags & MAP_ANON) leave(depth);
  return result;
}

#define INTERPOSE(name)                                                                     \
  __attribute__((used)) static struct { const void *replacement, *original; } interpose_##name \
      __attribute__((section("__DATA,__interpose"))) = {(const void *)&counted_##name, (const void *)&name};

INTERPOSE(malloc)
INTERPOSE(calloc)
INTERPOSE(realloc)
INTERPOSE(posix_memalign)
INTERPOSE(aligned_alloc)
INTERPOSE(malloc_zone_malloc)
INTERPOSE(malloc_zone_calloc)
INTERPOSE(malloc_zone_realloc)
INTERPOSE(malloc_zone_memalign)
INTERPOSE(malloc_type_malloc)
INTERPOSE(malloc_type_calloc)
INTERPOSE(malloc_type_realloc)
INTERPOSE(malloc_type_posix_memalign)
INTERPOSE(malloc_type_aligned_alloc)
INTERPOSE(malloc_type_zone_malloc)
INTERPOSE(malloc_type_zone_calloc)
INTERPOSE(malloc_type_zone_realloc)
INTERPOSE(malloc_type_zone_memalign)
INTERPOSE(mmap)
