#ifndef _CRYPTO_PKEY_H_
#define _CRYPTO_PKEY_H_

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include "luastr.h"

static int password_cb(char *buf, int size, int rwflag, void *userdata)
{
	(void)rwflag;
	const struct luastr *key = (const struct luastr *)userdata;
	if (key) {
		if (size > key->len)
			size = key->len;
		memcpy(buf, key->str, size);
		return size;
	}
	return 0;
}

static inline EVP_PKEY *pkey_load(struct luastr *key, struct luastr *pass)
{
	BIO *bio = NULL;
	EVP_PKEY *pkey;
	bio = BIO_new_mem_buf(key->str, key->len);
	if (!bio) {
		printf("err:%s\n", ERR_reason_error_string(ERR_get_error()));
		return NULL;
	}
	pkey = PEM_read_bio_PrivateKey(bio, NULL, password_cb, pass);
	if (!pkey) {
		BIO_reset(bio);
		pkey = PEM_read_bio_PUBKEY(bio, NULL, password_cb, pass);
	}
	if (!pkey) {
		BIO_reset(bio);
		pkey = d2i_PUBKEY_bio(bio, NULL);
	}
	if (!pkey) {
		BIO_reset(bio);
		pkey = d2i_PrivateKey_bio(bio, NULL);
	}
	BIO_free(bio);
	return pkey;
}

#endif
