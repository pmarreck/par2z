#ifndef PAR2_H
#define PAR2_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Par2CreateHandle Par2CreateHandle;
typedef struct Par2VerifyHandle Par2VerifyHandle;
typedef struct Par2RecoverHandle Par2RecoverHandle;
typedef struct Par2ThreadPool Par2ThreadPool;

typedef enum Par2Error {
	PAR2_OK = 0,
	PAR2_ERR_INVALID_ARGUMENT = 1,
	PAR2_ERR_IO = 2,
	PAR2_ERR_OUT_OF_MEMORY = 3,
	PAR2_ERR_INTERNAL = 4,
	PAR2_ERR_UNSUPPORTED = 5,
	PAR2_ERR_NOT_FOUND = 6,
	PAR2_ERR_DATA_CORRUPT = 7,
	PAR2_ERR_INSUFFICIENT_RECOVERY = 8,
	PAR2_ERR_PARITY_MISSING_FILE = 9,
	PAR2_ERR_PARITY_CORRUPT = 10,
} Par2Error;

typedef void *(*Par2AllocFn)(void *ctx, size_t size, size_t align);
typedef void *(*Par2ReallocFn)(void *ctx, void *ptr, size_t old_size, size_t new_size, size_t align);
typedef void (*Par2FreeFn)(void *ctx, void *ptr, size_t old_size, size_t align);

typedef struct Par2Allocator {
	void *ctx;
	Par2AllocFn alloc;
	Par2ReallocFn realloc;
	Par2FreeFn free;
} Par2Allocator;

typedef size_t (*Par2ReadAtFn)(void *ctx, uint64_t offset, uint8_t *out, size_t len);
typedef size_t (*Par2WriteFn)(void *ctx, const uint8_t *data, size_t len);
typedef void (*Par2CloseFn)(void *ctx);

typedef struct Par2Output {
	void *ctx;
	Par2WriteFn write;
	Par2CloseFn close;
} Par2Output;

typedef Par2Error (*Par2OpenOutputFn)(void *ctx, const char *path, Par2Output *out);

typedef struct Par2CreateOptions {
	uint64_t block_size;
	uint64_t block_count;
	uint64_t redundancy_percent;
	uint64_t recovery_blocks;
	uint64_t first_recovery_block;
	uint32_t uniform_recovery;
	uint32_t limit_recovery;
	uint64_t recovery_file_count;
	uint32_t include_input_slices;
	uint32_t emit_packed;
	uint32_t emit_rfsc;
	uint32_t include_volume_meta;
	uint32_t thread_count;
	uint64_t memory_mb;
	const char *basepath;
	const char *comment;
	Par2Allocator allocator;
} Par2CreateOptions;

typedef struct Par2VerifyOptions {
	uint64_t memory_mb;
	const char *basepath;
	Par2Allocator allocator;
} Par2VerifyOptions;

typedef struct Par2RecoverOptions {
	uint64_t memory_mb;
	uint32_t allow_unsafe_paths;
	uint32_t thread_count;
	const char *basepath;
	Par2Allocator allocator;
} Par2RecoverOptions;

// Metadata flags for SFMD v2 packet
#define PAR2_MFLAG_HAS_UID   0x0001  // uid field is valid
#define PAR2_MFLAG_HAS_GID   0x0002  // gid field is valid
#define PAR2_MFLAG_HAS_MODE  0x0004  // mode field is valid
#define PAR2_MFLAG_HAS_CTIME 0x0008  // ctime field is valid

typedef struct par2_source_metadata_t {
	int64_t mtime_ns;
	int64_t ctime_ns;
	uint64_t size;
	uint32_t uid;      // POSIX user ID, 0xFFFFFFFF if unavailable
	uint32_t gid;      // POSIX group ID, 0xFFFFFFFF if unavailable
	uint16_t mode;     // POSIX permission bits, 0xFFFF if unavailable
	uint16_t flags;    // Bitmask of PAR2_MFLAG_* indicating valid fields
} par2_source_metadata_t;

// Validation flags for SFVS packet
#define PAR2_VFLAG_MAGIC     0x01  // Magic bytes / file signature validated
#define PAR2_VFLAG_STRUCTURE 0x02  // Container/chunk structure validated
#define PAR2_VFLAG_CHECKSUM  0x04  // Internal checksums verified
#define PAR2_VFLAG_DECODE    0x08  // Decompression/decode succeeded
#define PAR2_VFLAG_CHARSET   0x10  // Character encoding validated
#define PAR2_VFLAG_SEMANTIC  0x20  // Content semantically valid
#define PAR2_VFLAG_COMPLETE  0x80  // Every byte covered by integrity check

typedef struct par2_validation_state_t {
	uint8_t flags;           // Validation flags (bitmask of PAR2_VFLAG_*)
	uint8_t reserved;        // Reserved, must be 0
	uint8_t container[4];    // FourCC of container format (e.g., "FORM", "RIFF"), or zeros
	uint8_t subtype[4];      // FourCC of format subtype (e.g., "PNG\0", "JPEG")
} par2_validation_state_t;

const char *par2_version(void);

Par2Error par2_create_new(const Par2CreateOptions *opts, Par2CreateHandle **out_handle);
void par2_create_destroy(Par2CreateHandle *handle);
Par2Error par2_create_add_path(Par2CreateHandle *handle, const char *path);
Par2Error par2_create_add_memory(Par2CreateHandle *handle, const char *name, const uint8_t *data, size_t len);
Par2Error par2_create_add_stream(Par2CreateHandle *handle, const char *name, uint64_t len, Par2ReadAtFn read_at, void *ctx);
Par2Error par2_create_set_metadata(Par2CreateHandle *handle, const par2_source_metadata_t *metadata);
Par2Error par2_create_set_validation_state(Par2CreateHandle *handle, const par2_validation_state_t *state);
Par2Error par2_create_set_output_path(Par2CreateHandle *handle, const char *par2_path);
Par2Error par2_create_set_output_open(Par2CreateHandle *handle, Par2OpenOutputFn open_fn, void *ctx);
Par2Error par2_create_run(Par2CreateHandle *handle);
const char *par2_create_last_error(Par2CreateHandle *handle);

Par2Error par2_verify_new(const Par2VerifyOptions *opts, Par2VerifyHandle **out_handle);
void par2_verify_destroy(Par2VerifyHandle *handle);
Par2Error par2_verify_set_par2_path(Par2VerifyHandle *handle, const char *par2_path);
Par2Error par2_verify_set_par2_data(Par2VerifyHandle *handle, const uint8_t *data, size_t len);
Par2Error par2_verify_add_par2_data(Par2VerifyHandle *handle, const uint8_t *data, size_t len, const char *name);
Par2Error par2_verify_add_path(Par2VerifyHandle *handle, const char *path);
Par2Error par2_verify_add_memory(Par2VerifyHandle *handle, const char *name, const uint8_t *data, size_t len);
Par2Error par2_verify_add_stream(Par2VerifyHandle *handle, const char *name, uint64_t len, Par2ReadAtFn read_at, void *ctx);
Par2Error par2_verify_run(Par2VerifyHandle *handle);
Par2Error par2_get_metadata(Par2VerifyHandle *handle, par2_source_metadata_t *out_metadata);
bool par2_has_metadata(Par2VerifyHandle *handle);
Par2Error par2_get_validation_state(Par2VerifyHandle *handle, par2_validation_state_t *out_state);
bool par2_has_validation_state(Par2VerifyHandle *handle);
const char *par2_verify_last_error(Par2VerifyHandle *handle);
const char *par2_verify_last_status(Par2VerifyHandle *handle);

Par2Error par2_recover_new(const Par2RecoverOptions *opts, Par2RecoverHandle **out_handle);
void par2_recover_destroy(Par2RecoverHandle *handle);
Par2Error par2_recover_set_par2_path(Par2RecoverHandle *handle, const char *par2_path);
Par2Error par2_recover_set_par2_data(Par2RecoverHandle *handle, const uint8_t *data, size_t len);
Par2Error par2_recover_add_par2_data(Par2RecoverHandle *handle, const uint8_t *data, size_t len, const char *name);
Par2Error par2_recover_add_path(Par2RecoverHandle *handle, const char *path);
Par2Error par2_recover_add_memory(Par2RecoverHandle *handle, const char *name, const uint8_t *data, size_t len);
Par2Error par2_recover_add_stream(Par2RecoverHandle *handle, const char *name, uint64_t len, Par2ReadAtFn read_at, void *ctx);
Par2Error par2_recover_set_output_dir(Par2RecoverHandle *handle, const char *out_dir);
Par2Error par2_recover_set_output_open(Par2RecoverHandle *handle, Par2OpenOutputFn open_fn, void *ctx);
Par2Error par2_recover_run(Par2RecoverHandle *handle);
const char *par2_recover_last_error(Par2RecoverHandle *handle);

// Thread pool configuration (global or caller-owned).
// If a caller-owned pool is set global, it must outlive all work that uses it.
Par2Error par2_thread_pool_create(uint32_t thread_count, Par2ThreadPool **out_pool);
void par2_thread_pool_destroy(Par2ThreadPool *pool);
Par2Error par2_thread_pool_set_global(Par2ThreadPool *pool);
Par2Error par2_thread_pool_configure(uint32_t thread_count);

#ifdef __cplusplus
}
#endif

#endif
