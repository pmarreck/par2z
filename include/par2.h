#ifndef PAR2_H
#define PAR2_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Par2Ctx Par2Ctx;

typedef enum Par2Error {
	PAR2_OK = 0,
	PAR2_ERR_UNIMPLEMENTED = 1,
	PAR2_ERR_INVALID_ARGUMENT = 2,
} Par2Error;

const char *par2_version(void);
Par2Error par2_ctx_create(Par2Ctx **out_ctx);
void par2_ctx_destroy(Par2Ctx *ctx);

#ifdef __cplusplus
}
#endif

#endif
