#include "vterm_internal.h"

#define UNICODE_INVALID 0xFFFD

#if defined(DEBUG) && DEBUG > 1
# define DEBUG_PRINT_UTF8
#endif

struct UTF8DecoderData {
  // number of bytes remaining in this codepoint
  int bytes_remaining;

  // number of bytes total in this codepoint once it's finished
  // (for detecting overlongs)
  int bytes_total;

  int this_cp;
};

static void init_utf8(VTermEncoding *enc, void *data_)
{
  struct UTF8DecoderData *data = data_;

  data->bytes_remaining = 0;
  data->bytes_total     = 0;
}

static void decode_utf8(VTermEncoding *enc, void *data_,
                        uint32_t cp[], int *cpi, int cplen,
                        const char bytes[], size_t *pos, size_t bytelen)
{
  struct UTF8DecoderData *data = data_;

#ifdef DEBUG_PRINT_UTF8
  printf("BEGIN UTF-8\n");
#endif

  for(; *pos < bytelen && *cpi < cplen; (*pos)++) {
    unsigned char c = bytes[*pos];

#ifdef DEBUG_PRINT_UTF8
    printf(" pos=%zd c=%02x rem=%d\n", *pos, c, data->bytes_remaining);
#endif

    if(c < 0x20) // C0
      return;

    else if(c >= 0x20 && c < 0x7f) {
      if(data->bytes_remaining) {
        /* ingot: this is the only branch that emits two codepoints in one
         * iteration -- the invalid marker for the abandoned multi-byte
         * sequence, then this character -- but the loop guard above only
         * proves room for one. With *cpi == cplen-1 on entry the second
         * store lands one element past the end of cp[], corrupting whatever
         * follows the caller's buffer (on_text passes vt->tmpbuffer).
         */
        if(*cpi + 2 <= cplen)
          cp[(*cpi)++] = UNICODE_INVALID;
        else if(*cpi > 0)
          /* Only one slot left, but this call has already produced output.
           * Return without advancing *pos so the caller re-enters with an
           * empty buffer and both codepoints fit. Partial consumption is
           * already the normal path for text runs longer than the codepoint
           * buffer, and *cpi > 0 guarantees forward progress.
           */
          return;
        /* else cplen < 2 (the single-shift path passes cplen == 1): there is
         * no room for the marker in any call, so drop it rather than stall.
         * The character itself is still emitted below.
         */
      }

      cp[(*cpi)++] = c;
#ifdef DEBUG_PRINT_UTF8
      printf(" UTF-8 char: U+%04x\n", c);
#endif
      data->bytes_remaining = 0;
    }

    else if(c == 0x7f) // DEL
      return;

    else if(c >= 0x80 && c < 0xc0) {
      if(!data->bytes_remaining) {
        cp[(*cpi)++] = UNICODE_INVALID;
        continue;
      }

      data->this_cp <<= 6;
      data->this_cp |= c & 0x3f;
      data->bytes_remaining--;

      if(!data->bytes_remaining) {
#ifdef DEBUG_PRINT_UTF8
        printf(" UTF-8 raw char U+%04x bytelen=%d ", data->this_cp, data->bytes_total);
#endif
        // Check for overlong sequences
        switch(data->bytes_total) {
        case 2:
          if(data->this_cp <  0x0080) data->this_cp = UNICODE_INVALID;
          break;
        case 3:
          if(data->this_cp <  0x0800) data->this_cp = UNICODE_INVALID;
          break;
        case 4:
          if(data->this_cp < 0x10000) data->this_cp = UNICODE_INVALID;
          break;
        case 5:
          if(data->this_cp < 0x200000) data->this_cp = UNICODE_INVALID;
          break;
        case 6:
          if(data->this_cp < 0x4000000) data->this_cp = UNICODE_INVALID;
          break;
        }
        // Now look for plain invalid ones
        if((data->this_cp >= 0xD800 && data->this_cp <= 0xDFFF) ||
           data->this_cp == 0xFFFE ||
           data->this_cp == 0xFFFF)
          data->this_cp = UNICODE_INVALID;
#ifdef DEBUG_PRINT_UTF8
        printf(" char: U+%04x\n", data->this_cp);
#endif
        cp[(*cpi)++] = data->this_cp;
      }
    }

    else if(c >= 0xc0 && c < 0xe0) {
      if(data->bytes_remaining)
        cp[(*cpi)++] = UNICODE_INVALID;

      data->this_cp = c & 0x1f;
      data->bytes_total = 2;
      data->bytes_remaining = 1;
    }

    else if(c >= 0xe0 && c < 0xf0) {
      if(data->bytes_remaining)
        cp[(*cpi)++] = UNICODE_INVALID;

      data->this_cp = c & 0x0f;
      data->bytes_total = 3;
      data->bytes_remaining = 2;
    }

    else if(c >= 0xf0 && c < 0xf8) {
      if(data->bytes_remaining)
        cp[(*cpi)++] = UNICODE_INVALID;

      data->this_cp = c & 0x07;
      data->bytes_total = 4;
      data->bytes_remaining = 3;
    }

    else if(c >= 0xf8 && c < 0xfc) {
      if(data->bytes_remaining)
        cp[(*cpi)++] = UNICODE_INVALID;

      data->this_cp = c & 0x03;
      data->bytes_total = 5;
      data->bytes_remaining = 4;
    }

    else if(c >= 0xfc && c < 0xfe) {
      if(data->bytes_remaining)
        cp[(*cpi)++] = UNICODE_INVALID;

      data->this_cp = c & 0x01;
      data->bytes_total = 6;
      data->bytes_remaining = 5;
    }

    else {
      cp[(*cpi)++] = UNICODE_INVALID;
    }
  }
}

static VTermEncoding encoding_utf8 = {
  .init   = &init_utf8,
  .decode = &decode_utf8,
};

static void decode_usascii(VTermEncoding *enc, void *data,
                           uint32_t cp[], int *cpi, int cplen,
                           const char bytes[], size_t *pos, size_t bytelen)
{
  int is_gr = bytes[*pos] & 0x80;

  for(; *pos < bytelen && *cpi < cplen; (*pos)++) {
    unsigned char c = bytes[*pos] ^ is_gr;

    if(c < 0x20 || c == 0x7f || c >= 0x80)
      return;

    cp[(*cpi)++] = c;
  }
}

static VTermEncoding encoding_usascii = {
  .decode = &decode_usascii,
};

struct StaticTableEncoding {
  const VTermEncoding enc;
  const uint32_t chars[128];
};

static void decode_table(VTermEncoding *enc, void *data,
                         uint32_t cp[], int *cpi, int cplen,
                         const char bytes[], size_t *pos, size_t bytelen)
{
  struct StaticTableEncoding *table = (struct StaticTableEncoding *)enc;
  int is_gr = bytes[*pos] & 0x80;

  for(; *pos < bytelen && *cpi < cplen; (*pos)++) {
    unsigned char c = bytes[*pos] ^ is_gr;

    if(c < 0x20 || c == 0x7f || c >= 0x80)
      return;

    if(table->chars[c])
      cp[(*cpi)++] = table->chars[c];
    else
      cp[(*cpi)++] = c;
  }
}

#include "encoding/DECdrawing.inc"
#include "encoding/uk.inc"

static struct {
  VTermEncodingType type;
  char designation;
  VTermEncoding *enc;
}
encodings[] = {
  { ENC_UTF8,      'u', &encoding_utf8 },
  { ENC_SINGLE_94, '0', (VTermEncoding*)&encoding_DECdrawing },
  { ENC_SINGLE_94, 'A', (VTermEncoding*)&encoding_uk },
  { ENC_SINGLE_94, 'B', &encoding_usascii },
  { 0 },
};

/* This ought to be INTERNAL but isn't because it's used by unit testing */
VTermEncoding *vterm_lookup_encoding(VTermEncodingType type, char designation)
{
  for(int i = 0; encodings[i].designation; i++)
    if(encodings[i].type == type && encodings[i].designation == designation)
      return encodings[i].enc;
  return NULL;
}
