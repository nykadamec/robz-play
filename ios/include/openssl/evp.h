#ifndef ROBZPLAY_IOS_OPENSSL_SHIM_H
#define ROBZPLAY_IOS_OPENSSL_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct evp_md_st EVP_MD;
typedef struct evp_cipher_st EVP_CIPHER;
typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
typedef struct bignum_st BIGNUM;
typedef struct bn_ctx_st BN_CTX;
typedef struct ec_group_st EC_GROUP;
typedef struct ec_point_st EC_POINT;
typedef struct ec_key_st EC_KEY;

#define NID_secp256k1 714
#define POINT_CONVERSION_UNCOMPRESSED 4
#define EVP_CTRL_GCM_SET_IVLEN 0x9
#define EVP_CTRL_GCM_GET_TAG   0x10

int RAND_bytes(unsigned char *buf, int num);
unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md);

const EVP_MD *EVP_sha256(void);
unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len,
	const unsigned char *d, size_t n, unsigned char *md, unsigned int *md_len);

const EVP_CIPHER *EVP_aes_128_ecb(void);
const EVP_CIPHER *EVP_aes_128_cfb128(void);
const EVP_CIPHER *EVP_aes_128_gcm(void);

EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx);
int EVP_EncryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *cipher, void *impl,
	const unsigned char *key, const unsigned char *iv);
int EVP_DecryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *cipher, void *impl,
	const unsigned char *key, const unsigned char *iv);
int EVP_CipherInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *cipher, void *impl,
	const unsigned char *key, const unsigned char *iv, int enc);
int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *ctx, int pad);
int EVP_CIPHER_CTX_ctrl(EVP_CIPHER_CTX *ctx, int type, int arg, void *ptr);
int EVP_EncryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
	const unsigned char *in, int inl);
int EVP_DecryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
	const unsigned char *in, int inl);
int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *outm, int *outl);

BIGNUM *BN_bin2bn(const unsigned char *s, int len, BIGNUM *ret);
void BN_free(BIGNUM *a);

EC_GROUP *EC_GROUP_new_by_curve_name(int nid);
void EC_GROUP_free(EC_GROUP *group);
EC_POINT *EC_POINT_new(const EC_GROUP *group);
void EC_POINT_free(EC_POINT *point);
int EC_POINT_oct2point(const EC_GROUP *group, EC_POINT *p,
	const unsigned char *buf, size_t len, BN_CTX *ctx);
size_t EC_POINT_point2oct(const EC_GROUP *group, const EC_POINT *p,
	int form, unsigned char *buf, size_t len, BN_CTX *ctx);

EC_KEY *EC_KEY_new(void);
void EC_KEY_free(EC_KEY *key);
int EC_KEY_set_group(EC_KEY *key, const EC_GROUP *group);
int EC_KEY_generate_key(EC_KEY *key);
int EC_KEY_set_private_key(EC_KEY *key, const BIGNUM *prv);
int EC_KEY_set_public_key(EC_KEY *key, const EC_POINT *pub);
const EC_POINT *EC_KEY_get0_public_key(const EC_KEY *key);
int ECDH_compute_key(void *out, size_t outlen, const EC_POINT *pub_key,
	const EC_KEY *ecdh, void *(*KDF)(const void *in, size_t inlen, void *out, size_t *outlen));

#ifdef __cplusplus
}
#endif

#endif
