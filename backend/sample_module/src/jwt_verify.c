#include <jwt.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const int AUTH_RESULT_OK = 0;
const int AUTH_RESULT_UNAUTHORIZED = 1;
const int AUTH_RESULT_UNAUTHENTICATED = 2;
const int AUTH_RESULT_UNEXPECTED_ERROR = 3;

const int INIT_RESULT_OK = 0;
const int INIT_RESULT_UNEXPECTED_ERROR = 1;

typedef struct {
  const char *ptr;
  size_t len;
} StringView;

typedef StringView (*get_config_value)(void *module_cfg_store, StringView key);

typedef void (*log_fn)(StringView message);

typedef struct {
  void *module_cfg_store;
  get_config_value get_config_value;
  log_fn log_debug;
  log_fn log_info;
  log_fn log_warn;
  log_fn log_err;
} ModuleInitContext;

char *jwks_issuer_url;
int jwks_ttl = 3600;
_Thread_local jwk_set_t *keys = NULL;

log_fn log_debug = NULL;
log_fn log_info = NULL;
log_fn log_warn = NULL;
log_fn log_err = NULL;

void log_debugf(const char *template, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, template);
  int n = vsnprintf(buf, sizeof(buf), template, ap);
  va_end(ap);
  if (n < 0)
    n = 0;
  if ((size_t)n >= sizeof buf)
    n = sizeof buf - 1;
  log_debug((StringView){.ptr = buf, .len = (size_t)n});
}

void log_infof(const char *template, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, template);
  int n = vsnprintf(buf, sizeof(buf), template, ap);
  va_end(ap);
  if (n < 0)
    n = 0;
  if ((size_t)n >= sizeof buf)
    n = sizeof buf - 1;
  log_info((StringView){.ptr = buf, .len = (size_t)n});
}

void log_warnf(const char *template, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, template);
  int n = vsnprintf(buf, sizeof(buf), template, ap);
  va_end(ap);
  if (n < 0)
    n = 0;
  if ((size_t)n >= sizeof buf)
    n = sizeof buf - 1;
  log_warn((StringView){.ptr = buf, .len = (size_t)n});
}

void log_errf(const char *template, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, template);
  int n = vsnprintf(buf, sizeof(buf), template, ap);
  va_end(ap);
  if (n < 0)
    n = 0;
  if ((size_t)n >= sizeof buf)
    n = sizeof buf - 1;
  log_err((StringView){.ptr = buf, .len = (size_t)n});
}

// Safely creates a heap-allocated c-string (null-terminated char pointer) from
// a StringView

StringView cstr_to_sv(const char *cstr) {
  return (StringView){
      .ptr = cstr,
      .len = strlen(cstr),
  };
}

char *sv_to_cstr(StringView sv) {
  char *buf = malloc(sv.len + 1);
  if (buf == NULL) {
    log_err(cstr_to_sv("Failed to allocate temp buffer"));
    return NULL;
  }
  memcpy(buf, sv.ptr, sv.len);
  buf[sv.len] = 0;
  return buf;
}

bool sv_is_empty(StringView sv) { return sv.len == 0; }

jwk_set_t *update_and_fetch_jwks() {
  if (jwks_issuer_url == NULL) {
    log_err(cstr_to_sv("Error fetching JWKS: jwks_issuer_url not set"));
    return NULL;
  }

  jwks_url_config_t config = {
      .ttl = jwks_ttl,
  };

  keys = jwks_load_fromurl_cached(keys, jwks_issuer_url, &config);
  if (keys == NULL) {
    log_err(cstr_to_sv("Error fetching JWKS: Allocation failure, make sure "
                       "libjwt is built with libcurl support"));
    return NULL;
  }

  if (jwks_error(keys) != 0) {
    log_errf("Error fetching JWKS: %s", jwks_error_msg(keys));
    jwks_error_clear(keys);
  }

  if (jwks_item_count(keys) == 0) {
    return NULL;
  }

  return keys;
}

void deinit_jwks() {
  jwks_free(keys);
  free(jwks_issuer_url);
}

int jwks_select_key(jwt_t *jwt, jwt_config_t *config) {
  jwk_set_t *keys = config->ctx;
  jwt_value_t jval;

  if (config->key != NULL) {
    return 0;
  }

  jwt_set_GET_STR(&jval, "kid");
  if (jwt_header_get(jwt, &jval) == JWT_VALUE_ERR_NONE) {
    config->key = jwks_find_bykid(keys, jval.str_val);
    return config->key == NULL;
  }

  jwt_alg_t alg = jwt_get_alg(jwt);
  size_t n = jwks_item_count(keys);
  for (size_t i = 0; i < n; i++) {
    const jwk_item_t *k = jwks_item_get(keys, i);
    if (jwks_item_alg(k) == alg) {
      config->key = k;
      return 0;
    }
  }

  return 1;
}

// Gets called once by main thread, on module load
int on_module_init(ModuleInitContext init_ctx) {
  log_debug = init_ctx.log_debug;
  log_info = init_ctx.log_info;
  log_warn = init_ctx.log_warn;
  log_err = init_ctx.log_err;

  // Retrieve module state from the winnow config file
  StringView jwks_issuer_url_key = cstr_to_sv("jwks_issuer_url");
  StringView jwks_issuer_url_sv =
      init_ctx.get_config_value(init_ctx.module_cfg_store, jwks_issuer_url_key);
  log_infof("jwks_issuer_url_sv = %.*s", (int)jwks_issuer_url_sv.len,
            jwks_issuer_url_sv.ptr);

  if (jwks_issuer_url_sv.ptr == NULL) {
    log_errf("Failed to get jwks_issuer_url from module config");
    return INIT_RESULT_UNEXPECTED_ERROR;
  }

  jwks_issuer_url = sv_to_cstr(jwks_issuer_url_sv);
  if (jwks_issuer_url == NULL) {
    log_errf("Issuer URL duplication allocation failed");
    return INIT_RESULT_UNEXPECTED_ERROR;
  }

  // Try fetching the JWKS, allows us to fail fast on
  // bad configuration and triggers curl_global_init
  // which is thread-unsafe
  if (update_and_fetch_jwks() == NULL) {
    return INIT_RESULT_UNEXPECTED_ERROR;
  }

  return INIT_RESULT_OK;
}

// Gets called once by main thread, on cleanup
void on_module_deinit() { deinit_jwks(); }

// Multi-threaded
int on_bearer_auth(StringView bearer_token) {
  int ret = AUTH_RESULT_OK;
  jwt_checker_t *checker = NULL;

  if (sv_is_empty(bearer_token)) {
    return AUTH_RESULT_UNAUTHENTICATED;
  }

#define max_token_len 1023

  if (bearer_token.len > max_token_len) {
    log_errf("Bearer token must not exceed %d bytes", max_token_len);
    ret = AUTH_RESULT_UNAUTHENTICATED;
    goto cleanup;
  }

  char token[max_token_len + 1] = {0};
  memcpy(token, bearer_token.ptr, bearer_token.len);

  jwk_set_t *keys = update_and_fetch_jwks();
  if (keys == NULL) {
    ret = AUTH_RESULT_UNEXPECTED_ERROR;
    goto cleanup;
  }

  checker = jwt_checker_new();
  if (!checker) {
    ret = AUTH_RESULT_UNEXPECTED_ERROR;
    goto checker_error;
  }

  if (jwt_checker_setkeyring(checker, keys, JWT_VERIFY_POLICY_ANY) != 0) {
    ret = AUTH_RESULT_UNEXPECTED_ERROR;
    goto checker_error;
  }

  if (jwt_checker_setcb(checker, &jwks_select_key, keys) != 0) {
    ret = AUTH_RESULT_UNEXPECTED_ERROR;
    goto checker_error;
  }

  if (jwt_checker_verify(checker, token) != 0) {
    ret = AUTH_RESULT_UNAUTHENTICATED;
    goto checker_error;
  }

  goto cleanup;

checker_error:
  if (checker && jwt_checker_error(checker) != 0) {
    log_errf("JWT check error: %s", jwt_checker_error_msg(checker));
  }

cleanup:
  if (checker != NULL) {
    jwt_checker_free(checker);
  }

  return ret;
}
