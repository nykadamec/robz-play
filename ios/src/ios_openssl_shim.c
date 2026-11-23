// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Self-contained iOS CommonCrypto + secp256k1 + AES-GCM/CFB128 shim for chiaki-lib.

#include <openssl/evp.h>
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonHMAC.h>
#include <Security/SecRandom.h>

#include <netinet/in.h>
#include <chiaki/common.h>
#include <chiaki/remote/holepunch.h>

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

int RAND_bytes(unsigned char *buf, int num)
{
	if(num <= 0)
		return 1;
	return SecRandomCopyBytes(kSecRandomDefault, (size_t)num, buf) == errSecSuccess ? 1 : 0;
}

unsigned char *SHA256(const unsigned char *d, size_t n, unsigned char *md)
{
	static unsigned char static_md[32];
	unsigned char *out = md ? md : static_md;
	CC_SHA256(d, (CC_LONG)n, out);
	return out;
}

struct evp_md_st { int dummy; };
static const struct evp_md_st kSha256Md = { 256 };

const EVP_MD *EVP_sha256(void)
{
	return &kSha256Md;
}

unsigned char *HMAC(const EVP_MD *evp_md, const void *key, int key_len,
	const unsigned char *d, size_t n, unsigned char *md, unsigned int *md_len)
{
	(void)evp_md;
	static unsigned char static_hmac[32];
	unsigned char *out = md ? md : static_hmac;
	CCHmac(kCCHmacAlgSHA256, key, (size_t)key_len, d, n, out);
	if(md_len)
		*md_len = 32;
	return out;
}

enum CipherKind
{
	CIPHER_AES_128_ECB = 1,
	CIPHER_AES_128_CFB128 = 2,
	CIPHER_AES_128_GCM = 3,
};

struct evp_cipher_st
{
	int kind;
};

static const struct evp_cipher_st kAes128Ecb    = { CIPHER_AES_128_ECB };
static const struct evp_cipher_st kAes128Cfb128 = { CIPHER_AES_128_CFB128 };
static const struct evp_cipher_st kAes128Gcm    = { CIPHER_AES_128_GCM };

const EVP_CIPHER *EVP_aes_128_ecb(void)    { return &kAes128Ecb; }
const EVP_CIPHER *EVP_aes_128_cfb128(void) { return &kAes128Cfb128; }
const EVP_CIPHER *EVP_aes_128_gcm(void)    { return &kAes128Gcm; }

static void aes128_ecb_block(const uint8_t key[16], const uint8_t in[16], uint8_t out[16])
{
	size_t moved = 0;
	CCCrypt(kCCEncrypt, kCCAlgorithmAES128, kCCOptionECBMode, key, 16, NULL, in, 16, out, 16, &moved);
}

// GF(2^128) multiplication for NIST SP 800-38D GHASH
static void ghash_mul(uint8_t X[16], const uint8_t H[16])
{
	uint8_t Z[16] = {0};
	uint8_t V[16];
	memcpy(V, H, 16);

	for(int i = 0; i < 128; i++)
	{
		if((X[i >> 3] >> (7 - (i & 7))) & 1)
		{
			for(int j = 0; j < 16; j++)
				Z[j] ^= V[j];
		}
		uint8_t lsb = V[15] & 1;
		for(int j = 15; j > 0; j--)
			V[j] = (uint8_t)((V[j] >> 1) | ((V[j - 1] & 1) << 7));
		V[0] >>= 1;
		if(lsb)
			V[0] ^= 0xe1;
	}
	memcpy(X, Z, 16);
}

static void ghash_update(uint8_t Y[16], const uint8_t H[16], const uint8_t *data, size_t len)
{
	size_t off = 0;
	while(off + 16 <= len)
	{
		for(int i = 0; i < 16; i++)
			Y[i] ^= data[off + i];
		ghash_mul(Y, H);
		off += 16;
	}
	if(off < len)
	{
		for(size_t i = 0; i < len - off; i++)
			Y[i] ^= data[off + i];
		ghash_mul(Y, H);
	}
}

static void put_be64(uint8_t out[8], uint64_t v)
{
	for(int i = 0; i < 8; i++)
		out[7 - i] = (uint8_t)((v >> (i * 8)) & 0xff);
}

struct evp_cipher_ctx_st
{
	int kind;
	int enc;
	uint8_t key[16];
	uint8_t iv[64];
	size_t iv_len;
	size_t cfb_off;
	uint8_t gcm_H[16];
	uint8_t gcm_J0[16];
	uint8_t gcm_Y[16];
	size_t gcm_aad_len;
};

EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void)
{
	EVP_CIPHER_CTX *ctx = (EVP_CIPHER_CTX *)calloc(1, sizeof(EVP_CIPHER_CTX));
	if(ctx)
		ctx->iv_len = 12;
	return ctx;
}

void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx)
{
	free(ctx);
}

int EVP_CipherInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *cipher, void *impl,
	const unsigned char *key, const unsigned char *iv, int enc)
{
	(void)impl;
	if(!ctx)
		return 0;
	if(cipher)
		ctx->kind = cipher->kind;
	if(enc >= 0)
		ctx->enc = enc;
	if(key)
		memcpy(ctx->key, key, 16);
	if(iv)
	{
		size_t copy_len = ctx->iv_len <= sizeof(ctx->iv) ? ctx->iv_len : sizeof(ctx->iv);
		if(ctx->kind != CIPHER_AES_128_GCM)
			copy_len = 16;
		memcpy(ctx->iv, iv, copy_len);
		ctx->cfb_off = 0;
	}
	if(ctx->kind == CIPHER_AES_128_GCM && key && iv)
	{
		uint8_t zero[16] = {0};
		aes128_ecb_block(ctx->key, zero, ctx->gcm_H);
		memset(ctx->gcm_J0, 0, 16);
		if(ctx->iv_len == 12)
		{
			memcpy(ctx->gcm_J0, ctx->iv, 12);
			ctx->gcm_J0[15] = 1;
		}
		else
		{
			ghash_update(ctx->gcm_J0, ctx->gcm_H, ctx->iv, ctx->iv_len);
			uint8_t len_block[16] = {0};
			put_be64(len_block + 8, (uint64_t)ctx->iv_len * 8ULL);
			ghash_update(ctx->gcm_J0, ctx->gcm_H, len_block, 16);
		}
		memset(ctx->gcm_Y, 0, 16);
		ctx->gcm_aad_len = 0;
	}
	return 1;
}

int EVP_EncryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *cipher, void *impl,
	const unsigned char *key, const unsigned char *iv)
{
	return EVP_CipherInit_ex(ctx, cipher, impl, key, iv, 1);
}

int EVP_DecryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *cipher, void *impl,
	const unsigned char *key, const unsigned char *iv)
{
	return EVP_CipherInit_ex(ctx, cipher, impl, key, iv, 0);
}

int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *ctx, int pad)
{
	(void)ctx;
	(void)pad;
	return 1;
}

int EVP_CIPHER_CTX_ctrl(EVP_CIPHER_CTX *ctx, int type, int arg, void *ptr)
{
	if(!ctx)
		return 0;
	if(type == EVP_CTRL_GCM_SET_IVLEN)
	{
		if(arg <= 0 || (size_t)arg > sizeof(ctx->iv))
			return 0;
		ctx->iv_len = (size_t)arg;
		return 1;
	}
	if(type == EVP_CTRL_GCM_GET_TAG)
	{
		if(arg <= 0 || arg > 16 || !ptr)
			return 0;
		uint8_t tag[16];
		aes128_ecb_block(ctx->key, ctx->gcm_J0, tag);
		for(int i = 0; i < 16; i++)
			tag[i] ^= ctx->gcm_Y[i];
		memcpy(ptr, tag, (size_t)arg);
		return 1;
	}
	return 0;
}

int EVP_EncryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
	const unsigned char *in, int inl)
{
	if(!ctx || inl < 0)
		return 0;
	if(ctx->kind == CIPHER_AES_128_ECB)
	{
		size_t moved = 0;
		CCCryptorStatus st = CCCrypt(kCCEncrypt, kCCAlgorithmAES128, kCCOptionECBMode,
			ctx->key, 16, NULL, in, (size_t)inl, out, (size_t)inl, &moved);
		if(st != kCCSuccess)
			return 0;
		if(outl)
			*outl = (int)moved;
		return 1;
	}
	if(ctx->kind == CIPHER_AES_128_CFB128)
	{
		size_t n = ctx->cfb_off;
		for(int i = 0; i < inl; i++)
		{
			if(n == 0)
				aes128_ecb_block(ctx->key, ctx->iv, ctx->iv);
			if(ctx->enc)
			{
				uint8_t c = in[i] ^ ctx->iv[n];
				out[i] = c;
				ctx->iv[n] = c;
			}
			else
			{
				uint8_t c = in[i];
				out[i] = c ^ ctx->iv[n];
				ctx->iv[n] = c;
			}
			n = (n + 1) & 15;
		}
		ctx->cfb_off = n;
		if(outl)
			*outl = inl;
		return 1;
	}
	if(ctx->kind == CIPHER_AES_128_GCM)
	{
		if(!out && in && inl > 0)
		{
			ghash_update(ctx->gcm_Y, ctx->gcm_H, in, (size_t)inl);
			ctx->gcm_aad_len += (size_t)inl;
		}
		if(outl)
			*outl = inl;
		return 1;
	}
	return 0;
}

int EVP_DecryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl,
	const unsigned char *in, int inl)
{
	return EVP_EncryptUpdate(ctx, out, outl, in, inl);
}

int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *outm, int *outl)
{
	(void)outm;
	if(!ctx)
		return 0;
	if(ctx->kind == CIPHER_AES_128_GCM)
	{
		uint8_t len_block[16] = {0};
		put_be64(len_block, (uint64_t)ctx->gcm_aad_len * 8ULL);
		put_be64(len_block + 8, 0ULL);
		ghash_update(ctx->gcm_Y, ctx->gcm_H, len_block, 16);
	}
	if(outl)
		*outl = 0;
	return 1;
}

// ============================================================================
// Minimal secp256k1 implementation for ChiakiECDH (p = 2^256 - 2^32 - 977)
// ============================================================================

typedef struct { uint64_t v[4]; } fe256; // little-endian limbs: v[0] is lowest 64 bits

static const fe256 SECP256K1_P = {{
	0xFFFFFFFEFFFFFC2FULL, 0xFFFFFFFFFFFFFFFFULL,
	0xFFFFFFFFFFFFFFFFULL, 0xFFFFFFFFFFFFFFFFULL
}};

static const fe256 SECP256K1_GX = {{
	0x59F2815B16F81798ULL, 0x029BFCDB2DCE28D9ULL,
	0x55A06295CE870B07ULL, 0x79BE667EF9DCBBACULL
}};

static const fe256 SECP256K1_GY = {{
	0x9C47D08FFB10D4B8ULL, 0xFD17B448A6855419ULL,
	0x5DA4FBFC0E1108A8ULL, 0x483ADA7726A3C465ULL
}};

static int fe_cmp(const fe256 *a, const fe256 *b)
{
	for(int i = 3; i >= 0; i--)
	{
		if(a->v[i] != b->v[i])
			return a->v[i] > b->v[i] ? 1 : -1;
	}
	return 0;
}

static bool fe_is_zero(const fe256 *a)
{
	return (a->v[0] | a->v[1] | a->v[2] | a->v[3]) == 0;
}

static uint64_t fe_raw_add(fe256 *r, const fe256 *a, const fe256 *b)
{
	unsigned __int128 c = 0;
	for(int i = 0; i < 4; i++)
	{
		c += (unsigned __int128)a->v[i] + b->v[i];
		r->v[i] = (uint64_t)c;
		c >>= 64;
	}
	return (uint64_t)c;
}

static uint64_t fe_raw_sub(fe256 *r, const fe256 *a, const fe256 *b)
{
	unsigned __int128 borrow = 0;
	for(int i = 0; i < 4; i++)
	{
		unsigned __int128 ai = a->v[i];
		unsigned __int128 bi = (unsigned __int128)b->v[i] + borrow;
		r->v[i] = (uint64_t)(ai - bi);
		borrow = (ai < bi) ? 1 : 0;
	}
	return (uint64_t)borrow;
}

static void fe_add(fe256 *r, const fe256 *a, const fe256 *b)
{
	uint64_t carry = fe_raw_add(r, a, b);
	if(carry || fe_cmp(r, &SECP256K1_P) >= 0)
		fe_raw_sub(r, r, &SECP256K1_P);
}

static void fe_sub(fe256 *r, const fe256 *a, const fe256 *b)
{
	if(fe_raw_sub(r, a, b))
		fe_raw_add(r, r, &SECP256K1_P);
}

// Mod p reduction using 2^256 ≡ 0x1000003D1 (mod p)
static void fe_mul(fe256 *r, const fe256 *a, const fe256 *b)
{
	uint64_t t[8] = {0};
	for(int i = 0; i < 4; i++)
	{
		unsigned __int128 carry = 0;
		for(int j = 0; j < 4; j++)
		{
			unsigned __int128 prod = (unsigned __int128)a->v[i] * b->v[j] + t[i + j] + carry;
			t[i + j] = (uint64_t)prod;
			carry = prod >> 64;
		}
		t[i + 4] = (uint64_t)carry;
	}

	const uint64_t C = 0x1000003D1ULL;
	// Fold upper limbs t[4..7] * C into t[0..4] twice
	for(int round = 0; round < 2; round++)
	{
		unsigned __int128 carry = 0;
		for(int i = 0; i < 4; i++)
		{
			unsigned __int128 s = (unsigned __int128)t[i + 4] * C + t[i] + carry;
			t[i] = (uint64_t)s;
			carry = s >> 64;
			t[i + 4] = 0;
		}
		t[4] = (uint64_t)carry;
	}

	fe256 res = {{ t[0], t[1], t[2], t[3] }};
	if(t[4] || fe_cmp(&res, &SECP256K1_P) >= 0)
		fe_raw_sub(&res, &res, &SECP256K1_P);
	*r = res;
}

static void fe_sqr(fe256 *r, const fe256 *a)
{
	fe_mul(r, a, a);
}

static void fe_inv(fe256 *r, const fe256 *a)
{
	// Fermat's little theorem: a^(p-2) mod p
	fe256 exp = SECP256K1_P;
	exp.v[0] -= 2;
	fe256 acc = {{ 1, 0, 0, 0 }};
	fe256 base = *a;
	for(int i = 0; i < 256; i++)
	{
		if((exp.v[i >> 6] >> (i & 63)) & 1ULL)
			fe_mul(&acc, &acc, &base);
		fe_sqr(&base, &base);
	}
	*r = acc;
}

static void fe_from_be(fe256 *r, const uint8_t buf[32])
{
	for(int i = 0; i < 4; i++)
	{
		uint64_t limb = 0;
		const uint8_t *p = buf + (3 - i) * 8;
		for(int j = 0; j < 8; j++)
			limb = (limb << 8) | p[j];
		r->v[i] = limb;
	}
}

static void fe_to_be(uint8_t buf[32], const fe256 *a)
{
	for(int i = 0; i < 4; i++)
	{
		uint64_t limb = a->v[3 - i];
		for(int j = 7; j >= 0; j--)
		{
			buf[i * 8 + j] = (uint8_t)(limb & 0xff);
			limb >>= 8;
		}
	}
}

typedef struct
{
	fe256 X, Y, Z;
	bool infinity;
} JacPoint;

static void jac_double(JacPoint *R, const JacPoint *P)
{
	if(P->infinity || fe_is_zero(&P->Y))
	{
		memset(R, 0, sizeof(*R));
		R->infinity = true;
		return;
	}
	fe256 S, M, X, Y, Z, Y2, Y4, X2, T;
	fe_sqr(&Y2, &P->Y);
	fe_mul(&S, &P->X, &Y2);
	fe_add(&S, &S, &S);
	fe_add(&S, &S, &S); // S = 4*X*Y^2

	fe_sqr(&X2, &P->X);
	fe_add(&M, &X2, &X2);
	fe_add(&M, &M, &X2); // M = 3*X^2 (a = 0 on secp256k1)

	fe_sqr(&X, &M);
	fe_sub(&X, &X, &S);
	fe_sub(&X, &X, &S); // X' = M^2 - 2*S

	fe_sub(&T, &S, &X);
	fe_mul(&Y, &M, &T);
	fe_sqr(&Y4, &Y2);
	fe_add(&Y4, &Y4, &Y4);
	fe_add(&Y4, &Y4, &Y4);
	fe_add(&Y4, &Y4, &Y4); // 8*Y^4
	fe_sub(&Y, &Y, &Y4);

	fe_mul(&Z, &P->Y, &P->Z);
	fe_add(&Z, &Z, &Z); // Z' = 2*Y*Z

	R->X = X;
	R->Y = Y;
	R->Z = Z;
	R->infinity = false;
}

static void jac_add(JacPoint *R, const JacPoint *P, const JacPoint *Q)
{
	if(P->infinity) { *R = *Q; return; }
	if(Q->infinity) { *R = *P; return; }

	fe256 Z1Z1, Z2Z2, U1, U2, S1, S2, H, r, H2, H3, U1H2, X3, Y3, Z3, T;
	fe_sqr(&Z1Z1, &P->Z);
	fe_sqr(&Z2Z2, &Q->Z);
	fe_mul(&U1, &P->X, &Z2Z2);
	fe_mul(&U2, &Q->X, &Z1Z1);
	fe_mul(&T, &Q->Z, &Z2Z2);
	fe_mul(&S1, &P->Y, &T);
	fe_mul(&T, &P->Z, &Z1Z1);
	fe_mul(&S2, &Q->Y, &T);

	if(fe_cmp(&U1, &U2) == 0)
	{
		if(fe_cmp(&S1, &S2) == 0)
			jac_double(R, P);
		else
		{
			memset(R, 0, sizeof(*R));
			R->infinity = true;
		}
		return;
	}

	fe_sub(&H, &U2, &U1);
	fe_sub(&r, &S2, &S1);
	fe_sqr(&H2, &H);
	fe_mul(&H3, &H, &H2);
	fe_mul(&U1H2, &U1, &H2);

	fe_sqr(&X3, &r);
	fe_sub(&X3, &X3, &H3);
	fe_sub(&X3, &X3, &U1H2);
	fe_sub(&X3, &X3, &U1H2);

	fe_sub(&T, &U1H2, &X3);
	fe_mul(&Y3, &r, &T);
	fe_mul(&T, &S1, &H3);
	fe_sub(&Y3, &Y3, &T);

	fe_mul(&T, &P->Z, &Q->Z);
	fe_mul(&Z3, &T, &H);

	R->X = X3;
	R->Y = Y3;
	R->Z = Z3;
	R->infinity = false;
}

static bool jac_to_affine(fe256 *x, fe256 *y, const JacPoint *P)
{
	if(P->infinity || fe_is_zero(&P->Z))
		return false;
	fe256 zinv, z2, z3;
	fe_inv(&zinv, &P->Z);
	fe_sqr(&z2, &zinv);
	fe_mul(&z3, &z2, &zinv);
	fe_mul(x, &P->X, &z2);
	fe_mul(y, &P->Y, &z3);
	return true;
}

static bool scalar_mul(fe256 *out_x, fe256 *out_y, const fe256 *scalar, const fe256 *px, const fe256 *py)
{
	JacPoint R;
	memset(&R, 0, sizeof(R));
	R.infinity = true;

	JacPoint Q;
	Q.X = *px;
	Q.Y = *py;
	Q.Z = (fe256){{ 1, 0, 0, 0 }};
	Q.infinity = false;

	for(int i = 255; i >= 0; i--)
	{
		jac_double(&R, &R);
		if((scalar->v[i >> 6] >> (i & 63)) & 1ULL)
			jac_add(&R, &R, &Q);
	}
	return jac_to_affine(out_x, out_y, &R);
}

struct bignum_st { fe256 val; };
struct ec_group_st { int nid; };
struct ec_point_st { fe256 x, y; bool valid; };
struct ec_key_st
{
	fe256 priv;
	struct ec_point_st pub;
};

BIGNUM *BN_bin2bn(const unsigned char *s, int len, BIGNUM *ret)
{
	if(!s || len <= 0 || len > 32)
		return NULL;
	BIGNUM *bn = ret ? ret : (BIGNUM *)calloc(1, sizeof(BIGNUM));
	if(!bn)
		return NULL;
	uint8_t padded[32] = {0};
	memcpy(padded + (32 - len), s, (size_t)len);
	fe_from_be(&bn->val, padded);
	return bn;
}

void BN_free(BIGNUM *a)
{
	free(a);
}

EC_GROUP *EC_GROUP_new_by_curve_name(int nid)
{
	if(nid != NID_secp256k1)
		return NULL;
	EC_GROUP *g = (EC_GROUP *)calloc(1, sizeof(EC_GROUP));
	if(g)
		g->nid = nid;
	return g;
}

void EC_GROUP_free(EC_GROUP *group)
{
	free(group);
}

EC_POINT *EC_POINT_new(const EC_GROUP *group)
{
	(void)group;
	return (EC_POINT *)calloc(1, sizeof(EC_POINT));
}

void EC_POINT_free(EC_POINT *point)
{
	free(point);
}

int EC_POINT_oct2point(const EC_GROUP *group, EC_POINT *p,
	const unsigned char *buf, size_t len, BN_CTX *ctx)
{
	(void)group;
	(void)ctx;
	if(!p || !buf || len != 65 || buf[0] != 0x04)
		return 0;
	fe_from_be(&p->x, buf + 1);
	fe_from_be(&p->y, buf + 33);
	p->valid = true;
	return 1;
}

size_t EC_POINT_point2oct(const EC_GROUP *group, const EC_POINT *p,
	int form, unsigned char *buf, size_t len, BN_CTX *ctx)
{
	(void)group;
	(void)form;
	(void)ctx;
	if(!p || !p->valid || !buf || len < 65)
		return 0;
	buf[0] = 0x04;
	fe_to_be(buf + 1, &p->x);
	fe_to_be(buf + 33, &p->y);
	return 65;
}

EC_KEY *EC_KEY_new(void)
{
	return (EC_KEY *)calloc(1, sizeof(EC_KEY));
}

void EC_KEY_free(EC_KEY *key)
{
	free(key);
}

int EC_KEY_set_group(EC_KEY *key, const EC_GROUP *group)
{
	return (key && group) ? 1 : 0;
}

int EC_KEY_generate_key(EC_KEY *key)
{
	if(!key)
		return 0;
	uint8_t rnd[32];
	do
	{
		if(!RAND_bytes(rnd, 32))
			return 0;
		fe_from_be(&key->priv, rnd);
	} while(fe_is_zero(&key->priv) || fe_cmp(&key->priv, &SECP256K1_P) >= 0);

	if(!scalar_mul(&key->pub.x, &key->pub.y, &key->priv, &SECP256K1_GX, &SECP256K1_GY))
		return 0;
	key->pub.valid = true;
	return 1;
}

int EC_KEY_set_private_key(EC_KEY *key, const BIGNUM *prv)
{
	if(!key || !prv)
		return 0;
	key->priv = prv->val;
	return 1;
}

int EC_KEY_set_public_key(EC_KEY *key, const EC_POINT *pub)
{
	if(!key || !pub || !pub->valid)
		return 0;
	key->pub = *pub;
	return 1;
}

const EC_POINT *EC_KEY_get0_public_key(const EC_KEY *key)
{
	return (key && key->pub.valid) ? &key->pub : NULL;
}

int ECDH_compute_key(void *out, size_t outlen, const EC_POINT *pub_key,
	const EC_KEY *ecdh, void *(*KDF)(const void *in, size_t inlen, void *out, size_t *outlen))
{
	(void)KDF;
	if(!out || outlen < 32 || !pub_key || !pub_key->valid || !ecdh)
		return -1;
	fe256 sx, sy;
	if(!scalar_mul(&sx, &sy, &ecdh->priv, &pub_key->x, &pub_key->y))
		return -1;
	uint8_t secret[32];
	fe_to_be(secret, &sx);
	memcpy(out, secret, 32);
	return 32;
}

// Stubs for PSN cloud holepunch & AIA certificate fetching on iOS direct/LAN builds
ChiakiErrorCode chiaki_aia_init(void)
{
	return CHIAKI_ERR_SUCCESS;
}

void chiaki_holepunch_session_fini(ChiakiHolepunchSession session)
{
	(void)session;
}

ChiakiErrorCode chiaki_holepunch_session_punch_hole(ChiakiHolepunchSession session, ChiakiHolepunchPortType type)
{
	(void)session;
	(void)type;
	return CHIAKI_ERR_UNKNOWN;
}

ChiakiHolepunchRegistInfo chiaki_get_regist_info(ChiakiHolepunchSession session)
{
	(void)session;
	ChiakiHolepunchRegistInfo info;
	memset(&info, 0, sizeof(info));
	return info;
}

void chiaki_get_ps_selected_addr(ChiakiHolepunchSession session, char *ps_ip)
{
	(void)session;
	if(ps_ip)
		ps_ip[0] = '\0';
}

uint16_t chiaki_get_ps_ctrl_port(ChiakiHolepunchSession session)
{
	(void)session;
	return 9295;
}

chiaki_socket_t *chiaki_get_holepunch_sock(ChiakiHolepunchSession session, ChiakiHolepunchPortType type)
{
	(void)session;
	(void)type;
	return NULL;
}

ChiakiErrorCode holepunch_session_create_offer(ChiakiHolepunchSession session)
{
	(void)session;
	return CHIAKI_ERR_UNKNOWN;
}

